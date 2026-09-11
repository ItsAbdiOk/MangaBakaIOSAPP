import Foundation

/// The iTunes Search API, for a series' volumes on Apple Books.
///
/// Keyless and public. Apple's documented limit is about 20 calls a minute
/// per IP, so requests are spaced like MangaUpdates' are, and every answer
/// is cached on disk for a week: a page's volumes do not change hourly, and
/// a reader opening the same series twice should not cost two calls.
actor AppleBooksClient {
    /// Twenty a minute, with margin. A GUESS at the margin; the limit itself
    /// is Apple's documented one.
    static let minimumInterval: TimeInterval = 3.5
    static let cacheLife: TimeInterval = 7 * 24 * 3600

    private let baseURL: URL
    private let session: URLSession
    private let clock: any Clock
    private let cacheDirectory: URL?
    private var spacing = RequestSpacing(minimumInterval: AppleBooksClient.minimumInterval)

    init(
        baseURL: URL = URL(string: "https://itunes.apple.com/search").unsafeStoreFallback,
        session: URLSession = .shared,
        clock: any Clock = SystemClock(),
        cacheDirectory: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("applebooks", isDirectory: true)
    ) {
        self.baseURL = baseURL
        self.session = session
        self.clock = clock
        self.cacheDirectory = cacheDirectory
    }

    /// The series' volumes in one store, or nil when the store could not be
    /// asked. Empty means asked and none: a series with no English ebook.
    func volumes(for series: Series, country: String) async -> [AppleBooksVolume]? {
        guard let query = series.displayTitle, !query.isEmpty else { return [] }
        let key = "\(series.id)-\(country.lowercased())"
        if let cached = readCache(key) { return cached }

        guard let results = await search(query, country: country) else { return nil }
        let titles = [series.displayTitle].compactMap { $0 } + (series.titles?.map(\.title) ?? [])
        let isNovel = series.type?.lowercased().contains("novel") ?? false
        let matched = AppleBooksMatch.volumes(in: results, titles: titles, isNovel: isNovel)
        writeCache(key, matched)
        return matched
    }

    private struct Envelope: Decodable {
        let results: [AppleBooksResult]
    }

    private func search(_ term: String, country: String) async -> [AppleBooksResult]? {
        let wait = spacing.claim(now: clock.now)
        if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }

        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "media", value: "ebook"),
            URLQueryItem(name: "entity", value: "ebook"),
            URLQueryItem(name: "country", value: country),
            // The API's maximum. Solo Leveling's 15 volumes came back among
            // 60 results; a long-running series needs the room.
            URLQueryItem(name: "limit", value: "200")
        ]
        guard let url = components?.url else { return nil }

        guard let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse
        else { return nil }
        if http.statusCode == 429 || http.statusCode == 403 {
            // Apple answers an over-limit client with 403 as often as 429.
            spacing.backOff(until: clock.now.addingTimeInterval(60))
            return nil
        }
        guard (200..<300).contains(http.statusCode) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Envelope.self, from: data).results
    }

    // MARK: - Cache

    private struct Cached: Codable {
        let storedAt: Date
        let volumes: [AppleBooksVolume]
    }

    private func file(_ key: String) -> URL? {
        cacheDirectory?.appendingPathComponent("\(key).json")
    }

    private func readCache(_ key: String) -> [AppleBooksVolume]? {
        guard let file = file(key), let data = try? Data(contentsOf: file),
              let cached = try? JSONDecoder().decode(Cached.self, from: data),
              clock.now.timeIntervalSince(cached.storedAt) < Self.cacheLife
        else { return nil }
        return cached.volumes
    }

    private func writeCache(_ key: String, _ volumes: [AppleBooksVolume]) {
        guard let directory = cacheDirectory, let file = file(key) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cached = Cached(storedAt: clock.now, volumes: volumes)
        try? JSONEncoder().encode(cached).write(to: file, options: .atomic)
    }
}

private extension Optional where Wrapped == URL {
    var unsafeStoreFallback: URL {
        guard let self else { preconditionFailure("Hard-coded iTunes Search URL failed to parse.") }
        return self
    }
}
