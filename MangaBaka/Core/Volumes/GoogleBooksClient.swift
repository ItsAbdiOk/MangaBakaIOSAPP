import Foundation

/// The Google Books API, used only to fill covers for a series Apple Books
/// has nothing for.
///
/// Google is data only — Apple Books is where these iOS readers actually buy
/// (Abdi, 2026-09-11) — so this client is never asked when Apple already
/// answered with volumes; the caller decides that, this type only answers
/// when asked.
///
/// Unauthenticated, at Abdi's call (2026-09-12): no API key, so the shared
/// anonymous quota is what this gets. That pool was exhausted when measured
/// (HTTP 429, 2026-09-12), so a nil answer here is the expected case, not the
/// exceptional one, and every failure path must degrade to "no extra covers"
/// rather than surfacing an error. Apple Books is the source that is actually
/// relied on; this only ever adds.
actor GoogleBooksClient {
    /// No documented per-minute limit the way Apple's is; kept in the same
    /// neighbourhood as `AppleBooksClient` on the assumption that any public
    /// API that does not publish a limit still has one. A GUESS, not measured.
    static let minimumInterval: TimeInterval = 3.5
    static let cacheLife: TimeInterval = 7 * 24 * 3600

    private let baseURL: URL
    private let session: URLSession
    private let clock: any Clock
    private let cacheDirectory: URL?
    private var spacing = RequestSpacing(minimumInterval: GoogleBooksClient.minimumInterval)

    init(
        baseURL: URL = URL(string: "https://www.googleapis.com/books/v1/volumes").unsafeStoreFallback,
        session: URLSession = .shared,
        clock: any Clock = SystemClock(),
        cacheDirectory: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("googlebooks", isDirectory: true)
    ) {
        self.baseURL = baseURL
        self.session = session
        self.clock = clock
        self.cacheDirectory = cacheDirectory
    }

    /// The series' volumes, sourced from Google's catalogue, or nil when the
    /// request failed — including the shared quota being spent, which is the
    /// common case. Empty means asked and none.
    ///
    /// Call this only when Apple Books came back empty for the series — this
    /// is gap-filling, not a second source fired on every page, per Abdi's
    /// scoping (2026-09-12).
    func volumes(for series: Series, language: String? = nil) async -> [GoogleBooksVolume]? {
        guard let query = series.displayTitle, !query.isEmpty else { return [] }
        // Versioned like Apple's cache key: a matcher change must not be
        // outlived by a week of answers made under the old rule.
        let key = "v1-\(series.id)-\(language ?? "any")"
        if let cached = readCache(key) { return cached }

        guard let items = await search(query) else { return nil }
        let titles = [series.displayTitle].compactMap { $0 } + (series.titles?.map(\.title) ?? [])
        let isNovel = series.type?.lowercased().contains("novel") ?? false
        let matched = GoogleBooksMatch.volumes(in: items, titles: titles, isNovel: isNovel)
        writeCache(key, matched)
        return matched
    }

    private struct Envelope: Decodable {
        let items: [GoogleBooksItem]?
    }

    private func search(_ term: String) async -> [GoogleBooksItem]? {
        let wait = spacing.claim(now: clock.now)
        if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }

        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "q", value: "intitle:\"\(term)\""),
            // Apple's needs 200 to find a long-running series among mixed
            // editions; Google ranks similarly, so the same margin is used.
            URLQueryItem(name: "maxResults", value: "40"),
            URLQueryItem(name: "printType", value: "books")
        ]
        guard let url = components?.url else { return nil }

        guard let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse
        else { return nil }
        if http.statusCode == 429 {
            spacing.backOff(until: clock.now.addingTimeInterval(60))
            return nil
        }
        guard (200..<300).contains(http.statusCode) else { return nil }
        return try? JSONDecoder().decode(Envelope.self, from: data).items ?? []
    }

    // MARK: - Cache

    private struct Cached: Codable {
        let storedAt: Date
        let volumes: [GoogleBooksVolume]
    }

    private func file(_ key: String) -> URL? {
        cacheDirectory?.appendingPathComponent("\(key).json")
    }

    private func readCache(_ key: String) -> [GoogleBooksVolume]? {
        guard let file = file(key), let data = try? Data(contentsOf: file),
              let cached = try? JSONDecoder().decode(Cached.self, from: data),
              clock.now.timeIntervalSince(cached.storedAt) < Self.cacheLife
        else { return nil }
        return cached.volumes
    }

    private func writeCache(_ key: String, _ volumes: [GoogleBooksVolume]) {
        guard let directory = cacheDirectory, let file = file(key) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cached = Cached(storedAt: clock.now, volumes: volumes)
        try? JSONEncoder().encode(cached).write(to: file, options: .atomic)
    }
}

private extension Optional where Wrapped == URL {
    var unsafeStoreFallback: URL {
        guard let self else { preconditionFailure("Hard-coded Google Books URL failed to parse.") }
        return self
    }
}
