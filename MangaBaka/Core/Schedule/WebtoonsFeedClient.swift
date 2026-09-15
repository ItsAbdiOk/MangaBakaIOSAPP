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
        session: URLSession = ThirdPartySession.shared,
        clock: any Clock = SystemClock(),
        cacheDirectory: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("webtoons", isDirectory: true)
    ) {
        self.session = session
        self.clock = clock
        self.cacheDirectory = cacheDirectory
    }

    /// `ReleaseFeedProvider` conformance: forwards to `feed(for:seriesID:)`.
    func feed(for series: Series, links: [SeriesLink]) async -> FeedAnswer {
        await feed(for: links, seriesID: series.id)
    }

    /// See `ReleaseFeedProvider.cachedFeed`: the same `v4-<seriesID>` key
    /// `feed(for:seriesID:)` reads, and nothing else — no candidate URL is
    /// even resolved, since resolving one is itself a request.
    func cachedFeed(for series: Series, links: [SeriesLink]) async -> ReleaseFeed? {
        guard links.contains(where: { $0.safeURL != nil }) else { return nil }
        return readCacheIgnoringAge("v4-\(series.id)")?.feed
    }

    /// The feed for whichever of a series' links Webtoons will answer for.
    /// See `FeedAnswer` for what each case means; `.failed` is ordinary here
    /// and must stay silent by the time it reaches the series page — the
    /// page already has a cadence estimated from release history, and this
    /// only ever replaces it with something better when it can.
    func feed(for links: [SeriesLink], seriesID: Int) async -> FeedAnswer {
        // Only the Webtoons links. Until 2026-09-15 this was every link the
        // series had, so a series with seventeen links and no Webtoons one
        // (The Apothecary Diaries) reached `resolveFeedURLs`, found nothing,
        // and came back `.failed(.transport)` — "The request didn't complete"
        // with a Retry button, on every walk of that page, for a source the
        // series never carried. `noLinkIsNotCarried` passed the whole time
        // because it passed an empty list.
        let candidates = links.compactMap(\.safeURL).filter(WebtoonsFeedParser.isWebtoons)
        guard !candidates.isEmpty else { return .notCarried }

        // Versioned like the other caches: a parser change must not be
        // outlived by a week of entries read under the old rules. Bumped to
        // v4, from v3 (5bb36b8): the parser and the never-cache-empty rule
        // both changed without the key following, so a v3 file written under
        // the old rules could still answer for up to a week under the new
        // ones (gap 29).
        let key = "v4-\(seriesID)"
        if let cached = readCache(key) { return .answered(cached) }

        let urls = await resolveFeedURLs(candidates)
        guard !urls.isEmpty else {
            return .failed(.transport(underlying: "No usable Webtoons feed URL.", party: .webtoons))
        }

        var sawAnsweredEmpty = false
        var lastFailure: APIError?
        for url in urls {
            switch await attempt(url) {
            case let .feed(feed):
                writeCache(key, feed)
                return .answered(feed)
            case .empty:
                // A feed that parsed with a channel title but zero entries is
                // not a real answer — every `pubDate` failed to parse, the
                // shape a localised non-English edition takes (measured
                // live, `/fr/`). Caching it would hide the series for a
                // week; try the next URL. It is also not a *failure* —
                // Webtoons answered, there is simply nothing usable in this
                // candidate — so it counts toward `.answered(nil)`, not
                // toward `lastFailure`.
                sawAnsweredEmpty = true
            case .cancelled:
                return .failed(.cancelled)
            case let .failed(error, isRateLimit) where isRateLimit:
                // A rate limit is global to this client, not per-candidate:
                // trying the next URL would just spend it too.
                return .failed(error)
            case let .failed(error, _):
                lastFailure = error
            }
        }
        if sawAnsweredEmpty { return .answered(nil) }
        return .failed(
            lastFailure ?? .transport(underlying: "No Webtoons candidate answered.", party: .webtoons)
        )
    }

    /// One candidate URL's outcome, factored out of `feed(for:seriesID:)` to
    /// keep that function's branching under the lint cap — the loop over
    /// candidates is a `switch` on this rather than a wall of `guard`s.
    private enum Attempt {
        case feed(ReleaseFeed)
        case empty
        case cancelled
        case failed(APIError, isRateLimit: Bool)
    }

    private func attempt(_ url: URL) async -> Attempt {
        let wait = spacing.claim(now: clock.now)
        if wait > 0 {
            try? await Task.sleep(for: .seconds(wait))
            // Gap 28: a cancelled wait must not still spend the request.
            guard !Task.isCancelled else { return .cancelled }
        }

        guard let (data, response) = try? await session.data(from: url) else {
            return .failed(
                .transport(underlying: "Webtoons request failed.", party: .webtoons), isRateLimit: false
            )
        }
        guard let http = response as? HTTPURLResponse else {
            let error = APIError.transport(underlying: "Webtoons sent a non-HTTP response.", party: .webtoons)
            return .failed(error, isRateLimit: false)
        }
        if http.statusCode == 429 {
            // Clamped and parsed in one place (`RequestSpacing.backOff`): a bare
            // `TimeInterval.init` accepted "nan" and "1e9" here, and either one
            // ended this client's spacing for the process. See that function.
            let retryAfter = spacing.backOff(
                retryAfterHeader: http.value(forHTTPHeaderField: "Retry-After"), now: clock.now
            )
            return .failed(.rateLimited(retryAfter: retryAfter, party: .webtoons), isRateLimit: true)
        }
        // A wrong genre or slug in the path answers 500, not 404, and that is
        // indistinguishable here from the feed being down. Either way: try
        // the next candidate, if there is one.
        guard (200..<300).contains(http.statusCode) else {
            let message = "Webtoons returned \(http.statusCode)."
            let error = APIError.server(status: http.statusCode, message: message, party: .webtoons)
            return .failed(error, isRateLimit: false)
        }
        guard let feed = WebtoonsFeedParser.parse(data) else {
            return .failed(
                .decoding(underlying: "Webtoons feed did not parse.", party: .webtoons), isRateLimit: false
            )
        }
        guard !feed.entries.isEmpty else { return .empty }
        // A completed Daily Pass title's feed (Lore Olympus, measured
        // 2026-09-14) answers 200 with real entries — episodes 1-9 from
        // 2018 — that are simply not current. Same treatment as `.empty`:
        // Webtoons answered, there is nothing usable in it, try the next
        // candidate. See `ReleaseFeed.looksLikeStaleDailyPassFeed`.
        guard !feed.looksLikeStaleDailyPassFeed(asOf: clock.now) else { return .empty }
        return .feed(feed)
    }

    /// Usable feed URLs, in the order to try them, following one redirect
    /// where the stored link is a placeholder.
    ///
    /// Direct links are tried first so the common case costs no extra request.
    /// The redirect is only spent when there is nothing else, and it is worth
    /// spending: 84% of the Webtoons links measured in Abdi's library are
    /// placeholders, so without this the feature reaches one series in six.
    /// See `WebtoonsFeedParser.lookupURL`.
    ///
    /// Where the redirect lands on a non-English edition, the English variant
    /// is tried first and the landed language second — see
    /// `WebtoonsFeedParser.englishVariant`.
    private func resolveFeedURLs(_ candidates: [URL]) async -> [URL] {
        if let direct = candidates.compactMap(WebtoonsFeedParser.feedURL(for:)).first { return [direct] }

        guard let lookup = candidates.compactMap(WebtoonsFeedParser.lookupURL(for:)).first
        else { return [] }

        let wait = spacing.claim(now: clock.now)
        if wait > 0 {
            try? await Task.sleep(for: .seconds(wait))
            // Gap 28: see `feed(for:seriesID:)` above.
            guard !Task.isCancelled else { return [] }
        }
        // URLSession follows redirects itself, so the landing page's URL is
        // what comes back on the response — the body is never read.
        //
        // HEAD, not GET (2026-09-14). 84% of the Webtoons links in a real
        // library are placeholders, so most first opens ran this; a GET
        // downloads a full `no-store` HTML listing page purely to look at
        // `response.url`. Measured from a Mac and confirmed from a phone
        // (U18): HEAD answers `301` with `content-length: 0` and the same
        // `location`, so `response.url` after the redirect is identical.
        // It is also what Webtoons sees in its logs for a made-up
        // `/en/x/y/` path we never intended to read.
        var request = URLRequest(url: lookup)
        request.httpMethod = "HEAD"
        guard let (_, response) = try? await session.data(for: request),
              let resolved = response.url,
              let landed = WebtoonsFeedParser.feedURL(fromResolved: resolved)
        else { return [] }

        if let english = WebtoonsFeedParser.englishVariant(of: landed) {
            return [english, landed]
        }
        return [landed]
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
        guard let cached = readCacheIgnoringAge(key),
              clock.now.timeIntervalSince(cached.storedAt) < Self.cacheLife
        else { return nil }
        return cached.feed
    }

    /// `readCache` without the freshness gate — for `cachedFeed`, where a
    /// season-ended or otherwise-settled fact a week stale is still true, and
    /// this is read with no request behind it to refresh a miss anyway.
    private func readCacheIgnoringAge(_ key: String) -> Cached? {
        guard let file = file(key), let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(Cached.self, from: data)
    }

    private func writeCache(_ key: String, _ feed: ReleaseFeed) {
        guard let directory = cacheDirectory, let file = file(key) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cached = Cached(storedAt: clock.now, feed: feed)
        try? JSONEncoder().encode(cached).write(to: file, options: .atomic)
    }
}
