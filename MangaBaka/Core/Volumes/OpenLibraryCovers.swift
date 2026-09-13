import Foundation

/// Open Library's cover-by-ISBN endpoint, used only to fill a cover for a
/// volume that reaches the shelf with no artwork from any other source.
///
/// Public, keyless, and documented as meant for exactly this
/// (https://openlibrary.org/dev/docs/api/covers). Measured live, 2026-09-13:
/// `.../b/isbn/9781975319434-L.jpg?default=false` → 302 → 200, `image/jpeg`,
/// 349×500 (Solo Leveling vol. 1); `.../9781975345648-L.jpg?default=false`
/// → 404 (The Beginning After the End vol. 2, no cover uploaded). A 404 is an
/// answer, not a failure — most of the catalogue simply has no scan for a
/// given ISBN — so it is cached the same as a 200 rather than retried.
///
/// Never asked for a volume that already has art: Apple, Google and
/// MangaBaka's own images all come first, and this is a gap-filler behind
/// all three — see `SeriesDetailView+Store.loadOpenLibraryCovers`.
actor OpenLibraryCovers {
    /// Open Library's own guideline is "about 100 requests every 5 minutes"
    /// per IP (their stated politeness policy, not a hard limit they
    /// enforce with a status code the way Apple's 429 does). 3 seconds a
    /// request keeps to 100 in 300 seconds with no margin at all, so this is
    /// A GUESS at a gap comfortably inside it, matching the spacing already
    /// used for Apple's and Google's clients.
    static let minimumInterval: TimeInterval = 3.0
    /// A GUESS. A 404 is unlikely to become a 200 overnight — nobody uploads
    /// a cover to a specific ISBN on a schedule — but "cached forever" risks
    /// hiding a genuinely late upload for good, so this expires like the
    /// other stores' caches, just longer: a cover gap is a much rarer event
    /// to recheck than a volume list.
    static let cacheLife: TimeInterval = 30 * 24 * 3600

    private let session: URLSession
    private let clock: any Clock
    private let cacheDirectory: URL?
    private var spacing = RequestSpacing(minimumInterval: OpenLibraryCovers.minimumInterval)

    init(
        session: URLSession = .shared,
        clock: any Clock = SystemClock(),
        cacheDirectory: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("openlibrary", isDirectory: true)
    ) {
        self.session = session
        self.clock = clock
        self.cacheDirectory = cacheDirectory
    }

    /// The cover image URL for this ISBN, or nil when Open Library has none
    /// or could not be asked. One request per ISBN, ever, inside the cache
    /// life — including the negative answer.
    func coverURL(isbn: String) async -> URL? {
        let key = "v1-\(isbn)"
        if let cached = readCache(key) { return cached.url }
        guard let url = Self.requestURL(isbn: isbn) else { return nil }

        let wait = spacing.claim(now: clock.now)
        if wait > 0 {
            try? await Task.sleep(for: .seconds(wait))
            // Same gap as `AppleBooksClient.search` (gap 28): `try?` alone
            // swallows cancellation and would fall through to spending the
            // request the cancelled wait already claimed a slot for.
            guard !Task.isCancelled else { return nil }
        }

        // HEAD, not GET: the answer is only ever "does an image exist here",
        // and `default=false` (measured above) is what turns "no cover" from
        // Open Library's grey placeholder image into a real 404 to read.
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse
        else { return nil }

        let found = (200..<300).contains(http.statusCode)
        writeCache(key, found ? url : nil)
        return found ? url : nil
    }

    private static func requestURL(isbn: String) -> URL? {
        var components = URLComponents(string: "https://covers.openlibrary.org/b/isbn/\(isbn)-L.jpg")
        components?.queryItems = [URLQueryItem(name: "default", value: "false")]
        return components?.url
    }

    // MARK: - Cache

    private struct Cached: Codable {
        let storedAt: Date
        /// Nil is a remembered negative answer, not "nothing cached yet" —
        /// see `readCache`'s outer optional for that distinction.
        let url: URL?
    }

    private func file(_ key: String) -> URL? {
        cacheDirectory?.appendingPathComponent("\(key).json")
    }

    /// - Returns: nil when there is nothing usable cached; otherwise the
    ///   remembered answer, which may itself be a nil `url` (a remembered
    ///   404). Internal, like the sibling clients' `readCache`, purely so
    ///   `OpenLibraryCoversTests` can assert on it directly.
    func readCache(_ key: String) -> (url: URL?, storedAt: Date)? {
        guard let file = file(key), let data = try? Data(contentsOf: file),
              let cached = try? JSONDecoder().decode(Cached.self, from: data),
              clock.now.timeIntervalSince(cached.storedAt) < Self.cacheLife
        else { return nil }
        return (cached.url, cached.storedAt)
    }

    private func writeCache(_ key: String, _ url: URL?) {
        guard let directory = cacheDirectory, let file = file(key) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cached = Cached(storedAt: clock.now, url: url)
        try? JSONEncoder().encode(cached).write(to: file, options: .atomic)
    }
}
