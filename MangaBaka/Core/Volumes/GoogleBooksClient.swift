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
        session: URLSession = ThirdPartySession.shared,
        clock: any Clock = SystemClock(),
        cacheDirectory: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("googlebooks", isDirectory: true)
    ) {
        self.baseURL = baseURL
        self.session = session
        self.clock = clock
        self.cacheDirectory = cacheDirectory
    }

    /// Test-only: when this client's spacing will next let a request out.
    /// Exposed so `GoogleBooksRetryAfterTests` can prove the 429 branch
    /// honours the server's own header, rather than inferring it by actually
    /// waiting out an hour.
    var nextAllowedForTesting: Date { spacing.nextAllowed }

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
        // outlived by a week of answers made under the old rule. v2: routed
        // through the shared `AppleBooksMatch.matchedVolumes` and now
        // filters on `language` instead of decoding it and never reading it
        // (T3/F15, 2026-09-13).
        let key = "v2-\(series.id)-\(language ?? "any")"
        if let cached = readCache(key) { return cached.volumes }

        guard let items = await search(query) else { return nil }
        let titles = [series.displayTitle].compactMap { $0 } + (series.titles?.map(\.title) ?? [])
        let isNovel = series.type?.lowercased().contains("novel") ?? false
        let matched = GoogleBooksMatch.volumes(
            in: items, titles: titles, isNovel: isNovel, language: language
        )
        writeCache(key, matched)
        return matched
    }

    private struct Envelope: Decodable {
        let items: [GoogleBooksItem]?
    }

    private func search(_ term: String) async -> [GoogleBooksItem]? {
        let wait = spacing.claim(now: clock.now)
        if wait > 0 {
            try? await Task.sleep(for: .seconds(wait))
            // Gap 28: see the identical check and comment in
            // `AppleBooksClient.search` — `try?` alone lets a cancelled wait
            // fall through to firing the request anyway.
            guard !Task.isCancelled else { return nil }
        }

        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            // T11 fixed the comment about this and left the code: a title
            // that itself contains a `"` closed the phrase early and turned
            // the rest of it into loose terms, so `Aria the "Masterpiece"`
            // searched for `intitle:"Aria the "` plus two bare words. The
            // quote has no meaning inside a Google Books phrase, so it is
            // dropped rather than escaped.
            URLQueryItem(name: "q", value: "intitle:\"\(term.replacingOccurrences(of: "\"", with: ""))\""),
            // Google's documented per-request maximum (T11) — there is no
            // larger page to ask for the way Apple's `limit=200` is; a
            // long-running series with mixed editions may need a
            // `startIndex` follow-up page, not implemented (low priority
            // while the anonymous quota is already exhausted).
            URLQueryItem(name: "maxResults", value: "40"),
            URLQueryItem(name: "printType", value: "books")
        ]
        guard let url = components?.url else { return nil }

        guard let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse
        else { return nil }
        if http.statusCode == 429 {
            // Clamped and parsed in one place (`RequestSpacing.backOff`): a bare
            // `TimeInterval.init` accepted "nan" and "1e9" here, and either one
            // ended this client's spacing for the process. See that function.
            //
            // Until 2026-09-14 this was a hard-coded 60 that never read the
            // header at all — the one 429 branch of ten the shared function
            // missed, in the client documented at `:13` as the one that 429s
            // most. Google answering `Retry-After: 3600` was retried once a
            // minute for the hour it asked to be left alone. The old behaviour
            // is preserved exactly when the header is absent, because
            // `RequestSpacing.unstatedBackOff` is also 60.
            _ = spacing.backOff(
                retryAfterHeader: http.value(forHTTPHeaderField: "Retry-After"), now: clock.now
            )
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

    /// See `AppleBooksClient.readCache` — same gap-72 shape, same reason.
    private func readCache(_ key: String) -> (volumes: [GoogleBooksVolume], storedAt: Date)? {
        guard let file = file(key), let data = try? Data(contentsOf: file),
              let cached = try? JSONDecoder().decode(Cached.self, from: data),
              clock.now.timeIntervalSince(cached.storedAt) < Self.cacheLife
        else { return nil }
        return (cached.volumes, cached.storedAt)
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
