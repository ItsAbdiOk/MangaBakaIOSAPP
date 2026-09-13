import Foundation

/// Fetches a series' Webtoons feed, at most once a week per series.
///
/// Cached hard, for two reasons. A weekly series produces one new entry a week,
/// so asking more often buys nothing. And the request tells Webtoons which
/// series this reader opened — the app sends no telemetry anywhere else, so the
/// least it can do is not repeat itself. Nothing here is fetched unless the
/// reader opens a series that has a Webtoons link.
actor WebtoonsFeedClient: ReleaseFeedProvider {
    /// Matched to `AppleBooksClient`'s spacing. A GUESS, not measured: Webtoons
    /// publishes no rate limit for its feeds.
    static let minimumInterval: TimeInterval = 3.5
    static let cacheLife: TimeInterval = 7 * 24 * 3600

    nonisolated let source: ReleaseSource = .webtoons

    private let session: URLSession
    private let clock: any Clock
    private let cacheDirectory: URL?
    private var spacing = RequestSpacing(minimumInterval: WebtoonsFeedClient.minimumInterval)

    init(
        session: URLSession = .shared,
        clock: any Clock = SystemClock(),
        cacheDirectory: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("webtoons", isDirectory: true)
    ) {
        self.session = session
        self.clock = clock
        self.cacheDirectory = cacheDirectory
    }

    /// `ReleaseFeedProvider` conformance: forwards to `feed(for:seriesID:)`.
    func feed(for series: Series, links: [SeriesLink]) async -> ReleaseFeed? {
        await feed(for: links, seriesID: series.id)
    }

    /// The feed for whichever of a series' links Webtoons will answer for, or
    /// nil when there is none or the fetch failed.
    ///
    /// Failure is ordinary here and must stay silent: the series page already
    /// has a cadence estimated from release history, and this only ever
    /// replaces it with something better.
    func feed(for links: [SeriesLink], seriesID: Int) async -> ReleaseFeed? {
        let candidates = links.compactMap(\.safeURL)
        // Versioned like the other caches: a parser change must not be
        // outlived by a week of entries read under the old rules. Bumped to
        // v3 when `ReleaseFeed` grew `source`/`totalCount`/`finished` — the
        // Codable shape changed, so a v2 cache file would fail to decode.
        let key = "v3-\(seriesID)"
        if let cached = readCache(key) { return cached }

        guard let url = await resolveFeedURL(candidates) else { return nil }

        let wait = spacing.claim(now: clock.now)
        if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }

        guard let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse
        else { return nil }
        if http.statusCode == 429 {
            spacing.backOff(until: clock.now.addingTimeInterval(60))
            return nil
        }
        // A wrong genre or slug in the path answers 500, not 404, and that is
        // indistinguishable here from the feed being down. Either way: nothing.
        guard (200..<300).contains(http.statusCode), let feed = WebtoonsFeedParser.parse(data)
        else { return nil }
        writeCache(key, feed)
        return feed
    }

    /// A usable feed URL, following one redirect where the stored link is a
    /// placeholder.
    ///
    /// Direct links are tried first so the common case costs no extra request.
    /// The redirect is only spent when there is nothing else, and it is worth
    /// spending: 84% of the Webtoons links measured in Abdi's library are
    /// placeholders, so without this the feature reaches one series in six.
    /// See `WebtoonsFeedParser.lookupURL`.
    private func resolveFeedURL(_ candidates: [URL]) async -> URL? {
        if let direct = candidates.compactMap(WebtoonsFeedParser.feedURL(for:)).first { return direct }

        guard let lookup = candidates.compactMap(WebtoonsFeedParser.lookupURL(for:)).first
        else { return nil }

        let wait = spacing.claim(now: clock.now)
        if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
        // URLSession follows redirects itself, so the landing page's URL is
        // what comes back on the response — the body is discarded.
        guard let (_, response) = try? await session.data(from: lookup),
              let resolved = response.url
        else { return nil }
        return WebtoonsFeedParser.feedURL(fromResolved: resolved)
    }

    // MARK: - Cache

    private struct Cached: Codable {
        let storedAt: Date
        let feed: ReleaseFeed
    }

    private func file(_ key: String) -> URL? {
        cacheDirectory?.appendingPathComponent("\(key).json")
    }

    private func readCache(_ key: String) -> ReleaseFeed? {
        guard let file = file(key), let data = try? Data(contentsOf: file),
              let cached = try? JSONDecoder().decode(Cached.self, from: data),
              clock.now.timeIntervalSince(cached.storedAt) < Self.cacheLife
        else { return nil }
        return cached.feed
    }

    private func writeCache(_ key: String, _ feed: ReleaseFeed) {
        guard let directory = cacheDirectory, let file = file(key) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cached = Cached(storedAt: clock.now, feed: feed)
        try? JSONEncoder().encode(cached).write(to: file, options: .atomic)
    }
}
