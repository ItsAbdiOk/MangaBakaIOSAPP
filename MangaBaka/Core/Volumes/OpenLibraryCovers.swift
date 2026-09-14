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
    /// The gap this client actually waits out, which since 2026-09-14 is the
    /// *host's* and not this client's own.
    ///
    /// It was 3.0 here — A GUESS at a gap inside Open Library's stated "about
    /// 100 requests every 5 minutes" — while `OpenLibraryEditions` used 4.0,
    /// measured. Two clients, two `RequestSpacing` values, one host: they could
    /// put two requests on openlibrary.org inside one gap however either
    /// number was set. `HostRateGate.openLibrary` is now the single gate and
    /// this reads from it rather than restating a number.
    static var minimumInterval: TimeInterval { HostRateGate.openLibrary.minimumInterval }
    /// A GUESS. A 404 is unlikely to become a 200 overnight — nobody uploads
    /// a cover to a specific ISBN on a schedule — but "cached forever" risks
    /// hiding a genuinely late upload for good, so this expires like the
    /// other stores' caches, just longer: a cover gap is a much rarer event
    /// to recheck than a volume list.
    static let cacheLife: TimeInterval = 30 * 24 * 3600

    private let session: URLSession
    private let clock: any Clock
    private let cacheDirectory: URL?
    /// Shared with `OpenLibraryEditions`. Injectable so a test gets a gate of
    /// its own rather than queueing behind whatever another suite left on the
    /// process-wide one.
    private let gate: HostRateGate

    init(
        session: URLSession = ThirdPartySession.shared,
        clock: any Clock = SystemClock(),
        gate: HostRateGate = .openLibrary,
        cacheDirectory: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("openlibrary", isDirectory: true)
    ) {
        self.session = session
        self.clock = clock
        self.gate = gate
        self.cacheDirectory = cacheDirectory
    }

    /// The cover image URL for this ISBN, or nil when Open Library has none
    /// or could not be asked. One request per ISBN, ever, inside the cache
    /// life — including the negative answer.
    func coverURL(isbn: String) async -> URL? {
        let key = "v1-\(isbn)"
        if let cached = readCache(key) { return cached.url }
        guard let url = Self.requestURL(isbn: isbn) else { return nil }

        let wait = await gate.claim(now: clock.now)
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

        // A 429 is not "this ISBN has no cover". Cached as a negative it would
        // remember a rate limit for thirty days (`cacheLife`) as a fact about
        // the publisher's artwork. Found while giving the host one gate,
        // 2026-09-14 — and the back-off goes through the gate so
        // `OpenLibraryEditions` stops firing at a host that just refused this.
        if http.statusCode == 429 {
            await gate.backOff(
                retryAfterHeader: http.value(forHTTPHeaderField: "Retry-After"), now: clock.now
            )
            return nil
        }
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
