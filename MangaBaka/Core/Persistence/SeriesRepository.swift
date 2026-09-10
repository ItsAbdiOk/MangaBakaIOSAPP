import Foundation
import GRDB

/// Reads series data, deciding for itself when to use the cache and when to
/// go to the network.
///
/// Every screen talks to this rather than to `APIClient`, so no view has to
/// know whether it is looking at fresh or cached data.
protocol SeriesRepositoryProtocol: Sendable {
    /// Returns a feed, preferring cache while it is fresh.
    ///
    /// - Parameter forceRefresh: bypass the freshness check (pull to refresh).
    /// - Returns: the series, and whether they came from the network or cache.
    func feed(_ feed: FeedKind, forceRefresh: Bool) async -> FeedResult

    /// Runs a search. Deliberately never cached: a query is typed once and the
    /// answer is expected to be current, and caching every keystroke's result
    /// would fill the database with rows nobody reads twice.
    func search(_ query: SearchQuery) async -> FeedResult

    /// A later page of a feed. Only feeds whose endpoint takes `page` can
    /// answer this; the rest return empty, which callers read as "no more".
    ///
    /// Never cached. A cache is keyed by feed, and page 2 of a feed is not the
    /// feed — writing it would replace page 1 in the cache and lose the
    /// beginning of the row.
    func feedPage(_ feed: FeedKind, page: Int) async -> FeedResult

    /// Blends recommendations from seed series, with the reason each matched
    /// and the DNA the blend was derived from.
    ///
    /// Requires at least one seed — the API rejects a seedless request.
    ///
    /// - Parameter excludedTags: tag ids to keep out, sent as `tag_not`. There
    ///   is no weight parameter on this endpoint, so steering is include or
    ///   exclude and nothing in between.
    func mix(
        seeds: [Int],
        filters: SearchQuery,
        excludedTags: [Int]
    ) async -> MixResult

    /// Everything the detail screen shows beyond the series itself. Fetched
    /// together so one slow endpoint does not stagger the screen into place.
    func extras(for seriesId: Int) async -> SeriesExtras

    /// Every cover the series has, filtered to what the reader has allowed.
    func images(for seriesId: Int) async -> [SeriesImage]

    /// Replaces the content filter and discards every cached feed.
    ///
    /// The discard is the point: a cached feed was fetched under the previous
    /// filter, so keeping it would keep showing content the reader has just
    /// excluded — or hide content they have just allowed.
    func updateContentRatings(_ ratings: [String]) async

    /// Replaces the format filter and discards every cached feed, for the same
    /// reason `updateContentRatings` does.
    func updateFormats(_ formats: [String]) async

    /// The reader's own user id, so a blend can exclude what they already
    /// track. Nil clears it.
    func updateLibraryExclusion(userID: String?) async

    /// Replaces the blocked-tag list and discards every cached feed, for the
    /// same reason the other filters do.
    func updateBlockedTags(_ ids: [Int]) async

    /// How many distinct series are held on device. The mockup's Discover
    /// subtitle counts them, so it has to be a real number.
    func cachedSeriesCount() async -> Int

}

/// The onward paths from a series. Every field is independently optional: a
/// series with no news is ordinary, and one failing endpoint must not empty
/// the rest of the screen.
struct SeriesExtras: Sendable, Equatable {
    var links: [SeriesLink] = []
    var news: [NewsItem] = []
    var relationships: [SeriesRelationship] = []
    /// Tags, and a year, from `/v1/series/{id}`.
    ///
    /// Measured against the live API on 2026-09-09: v2 returns neither, on the
    /// feed endpoints *or* on `/v2/series/{id}` — its keys are identical in
    /// both, and `tags` and `year` are not among them. v1 carries `tags`,
    /// `genres` and `year`. So the series page's tag row and its "Started"
    /// stat are only ever populated from v1, and a series page built from a
    /// feed's own copy shows neither.
    var tags: [String] = []
    /// The same tags with their group, weight, spoiler flag and implications —
    /// see `SeriesTag`. v1's flat `tags` is kept only as a fallback for a
    /// series whose payload has no `tags_v2`.
    var richTags: [SeriesTag] = []
    /// Published editions — see `SeriesEdition`.
    var editions: [SeriesEdition] = []
    var year: Int?
}

/// The API's sort keys, and what to call them in front of a reader.
///
/// "popularity_desc" is a value for a query string, not a word for a screen —
/// and at large text sizes it broke across four lines mid-word.
enum SortOrder {
    static let all: [(value: String, label: String)] = [
        ("relevance_desc", "Relevance"),
        ("trending_7d", "Trending (7d)"),
        ("trending_30d", "Trending (30d)"),
        ("score_desc", "Score"),
        ("popularity_desc", "Popularity"),
        ("latest", "Latest"),
        ("random", "Random")
    ]

    static func label(for value: String?) -> String? {
        guard let value else { return nil }
        return all.first { $0.value == value }?.label
    }
}

/// Which feed, and how long its cache stays fresh.
enum FeedKind: Sendable, Hashable {
    case rising
    case hiddenGems
    case trending
    /// What MangaBaka's own homepage calls "New releases": the most recently
    /// added series, `sort_by=latest`.
    case newReleases
    /// Series similar to another, used on the detail screen.
    case similar(seriesId: Int)
    /// "Readers also like", also on the detail screen.
    case readersAlsoLike(seriesId: Int)
    /// The stack's queue, blended from seed series.
    case mix(seeds: [Int])
    /// The stack with nothing saved yet. `mix` rejects a seedless request
    /// ("At least one seed series or one include tag is required", HTTP 400,
    /// verified 2026-09-08), so a first-run stack cannot use it. Random search
    /// is a real recommendation surface rather than a placeholder.
    case surprise

    var cacheKey: String {
        switch self {
        case .rising: "discover/rising"
        case .hiddenGems: "discover/hidden-gems"
        case .trending: "discover/trending"
        case .newReleases: "discover/new-releases"
        case let .similar(id): "series/\(id)/similar"
        case let .readersAlsoLike(id): "series/\(id)/readers-also-like"
        case let .mix(seeds): "series/mix/" + seeds.sorted().map(String.init).joined(separator: "-")
        case .surprise: "series/surprise"
        }
    }

    var path: String {
        switch self {
        case .rising: "/v2/series/discover/rising"
        case .hiddenGems: "/v2/series/discover/hidden-gems"
        case .trending, .newReleases: "/v2/series/search"
        case let .similar(id): "/v2/series/\(id)/similar"
        case let .readersAlsoLike(id): "/v2/series/\(id)/readers-also-like"
        case .mix: "/v1/series/mix"
        case .surprise: "/v2/series/search"
        }
    }

    /// Whether the endpoint nests each series inside a recommendation wrapper
    /// rather than returning series directly. Verified per endpoint against the
    /// live API; the spec does not make this obvious.
    var isRecommendationShaped: Bool {
        switch self {
        case .similar, .readersAlsoLike, .mix: true
        case .rising, .hiddenGems, .trending, .newReleases, .surprise: false
        }
    }

    /// Whether the endpoint accepts a `page` parameter.
    ///
    /// Checked against the published spec, not assumed: `rising` and
    /// `hidden-gems` take only `limit` (max 20) and have no paging at all, so
    /// those two rows are 20 series and that is the whole of what exists. The
    /// search-backed rows page to 100.
    var supportsPaging: Bool {
        switch self {
        case .trending, .newReleases, .surprise: true
        case .rising, .hiddenGems, .similar, .readersAlsoLike, .mix: false
        }
    }

    /// Extra query beyond `limit`.
    var extraQuery: [URLQueryItem] {
        switch self {
        case .trending:
            [URLQueryItem(name: "sort_by", value: "trending_7d")]
        case .newReleases:
            [URLQueryItem(name: "sort_by", value: "latest")]
        case let .mix(seeds) where !seeds.isEmpty:
            // Repeated keys, not comma-joined. A comma-joined list is rejected:
            // "Invalid input: expected number, received NaN at series[0]",
            // HTTP 400, verified against the live endpoint on 2026-09-09.
            //
            // The comment that used to sit here asserted the opposite, and it
            // held up for months because a single seed has no comma in it. The
            // stack only broke once a reader had two things to blend from,
            // which is exactly when it starts being worth using.
            seeds.map { URLQueryItem(name: "series", value: String($0)) }
                + [URLQueryItem(name: "strict", value: "false")]
        case .surprise:
            [
                URLQueryItem(name: "sort_by", value: "random"),
                // The lean v2 schema omits tags entirely, so the stack card's
                // chips would never appear on this path. Asked for only here,
                // where they are shown — the discovery rows do not need them
                // and the fuller response is not free.
                URLQueryItem(name: "schema", value: "full")
            ]
        default:
            []
        }
    }

    /// Each endpoint's own maximum, taken from the spec. Requesting fewer than
    /// the maximum wastes budget, because the response is CDN-cached either way.
    var limit: Int {
        switch self {
        case .rising, .hiddenGems: 20
        case .similar, .readersAlsoLike: 24
        case .mix: 50
        case .trending, .newReleases: 20
        case .surprise: 50
        }
    }

    /// How long a locally cached copy is considered fresh.
    ///
    /// Matched to the endpoint's own CDN TTL (`x-cache-ttl-cdn-seconds`: 86400
    /// on both discover endpoints). Caching longer than the server does would
    /// show staler data than the server would have given us; caching for less
    /// spends requests on a response the CDN would have served identically.
    var freshness: TimeInterval {
        switch self {
        // Matches the endpoints' own x-cache-ttl-cdn-seconds of 86400.
        case .rising, .hiddenGems, .similar, .readersAlsoLike: 86_400
        // Search-backed and blended results are not CDN-pinned to a day; an
        // hour keeps them lively without spending requests on every visit.
        case .trending, .mix: 3_600
        // New releases changes as fast as the catalogue is edited, and the
        // whole point of the row is that it is new.
        case .newReleases: 1_800
        // A surprise queue that returned the same series on every visit would
        // not be a surprise. Never served from cache.
        case .surprise: 0
        }
    }
}

/// What a feed read produced, and where it came from.
struct FeedResult: Sendable {
    enum Origin: Sendable, Equatable {
        /// Served from cache without touching the network.
        case cache
        /// Fetched from the API.
        case network
        /// The network failed, so cached content was served instead. The error
        /// is carried so the UI can explain why the content may be out of date.
        case staleAfter(APIError)
    }

    let series: [Series]
    let origin: Origin
    /// When the cached copy was written, for a stale result that needs to say
    /// how old it is. Nil for anything that came off the network.
    var cachedAt: Date?

    /// An error to show only when there is nothing at all to display. When
    /// stale content exists, the content is shown instead of an error page.
    var blockingError: APIError? {
        guard case let .staleAfter(error) = origin, series.isEmpty else { return nil }
        return error
    }
}

actor SeriesRepository: SeriesRepositoryProtocol {
    private let client: APIClient
    // Internal rather than private so the cache half can reach them. See
    // SeriesRepository+Cache.swift — the split is the lint's doing, not a
    // widening of who is meant to touch these.
    let database: AppDatabase
    let clock: any Clock
    let decoder: JSONDecoder
    /// Content ratings to request, or `nil` for no filter. Defaults to the
    /// product decision: safe and suggestive, with anything stronger behind a
    /// deliberate opt-in that does not exist yet.
    private var contentRatings: [String]?
    /// Formats to request, or empty for no filter. Empty is the default: the
    /// catalogue as it is, until the reader narrows it.
    private var formats: [String] = []
    /// The reader's own 32-character user id. Sent as `exclude_user_library` on
    /// a blend so it stops recommending series they are already reading — the
    /// single largest source of "these recommendations are bad" for someone
    /// with a large library.
    ///
    /// Not a boolean, despite the name: the API rejects `true` with
    /// "expected string, received boolean" and requires at least 32 characters
    /// (HTTP 400, verified 2026-09-09). Only ever the reader's own id.
    private var libraryExclusionUserID: String?
    /// Tags the reader never wants to see, sent as `blocked_tag`.
    private var blockedTags: [Int] = []

    init(
        client: APIClient,
        database: AppDatabase,
        clock: any Clock = SystemClock(),
        contentRatings: [String]? = ["safe", "suggestive"],
        formats: [String] = []
    ) {
        self.client = client
        self.database = database
        self.clock = clock
        self.contentRatings = contentRatings
        self.formats = formats

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        self.decoder = decoder
    }

    func feed(_ feed: FeedKind, forceRefresh: Bool = false) async -> FeedResult {
        if !forceRefresh, let fresh = try? readCache(feed, requireFresh: true), !fresh.isEmpty {
            return FeedResult(series: fresh, origin: .cache)
        }

        do {
            var query = [URLQueryItem(name: "limit", value: String(feed.limit))]
            query.append(contentsOf: feed.extraQuery)
            if case .mix = feed { query.append(contentsOf: blendExclusionQuery) }
            // Filtering server-side means excluded covers are never downloaded,
            // never cached, and never briefly visible while a client-side
            // filter catches up.
            query.append(contentsOf: filterQuery)
            let series: [Series]
            if feed.isRecommendationShaped {
                let wrapped: [Recommendation] = try await client.get(feed.path, query: query)
                series = wrapped.map(\.series)
            } else {
                series = try await client.get(feed.path, query: query)
            }
            let discoverable = series.filter(\.isDiscoverable)
            try? write(discoverable, for: feed)
            return FeedResult(series: discoverable, origin: .network)
        } catch {
            // Falling back to stale cache is the whole point of the cache on a
            // train. An empty result here is handled by `blockingError`.
            let stale: (series: [Series], cachedAt: Date?) =
                (try? readCacheWithDate(feed, requireFresh: false)) ?? (series: [], cachedAt: nil)
            return FeedResult(
                series: stale.series,
                origin: .staleAfter(error),
                cachedAt: stale.cachedAt
            )
        }
    }

    func feedPage(_ feed: FeedKind, page: Int) async -> FeedResult {
        guard feed.supportsPaging, page > 1 else {
            return FeedResult(series: [], origin: .network)
        }
        var query = [
            URLQueryItem(name: "limit", value: String(feed.limit)),
            URLQueryItem(name: "page", value: String(page))
        ]
        query.append(contentsOf: feed.extraQuery)
        query.append(contentsOf: filterQuery)
        do {
            let series: [Series] = try await client.get(feed.path, query: query)
            return FeedResult(series: series.filter(\.isDiscoverable), origin: .network)
        } catch {
            return FeedResult(series: [], origin: .staleAfter(error))
        }
    }

    func search(_ query: SearchQuery) async -> FeedResult {
        var items = query.queryItems
        items.append(contentsOf: (contentRatings ?? []).map {
            URLQueryItem(name: "content_rating", value: $0)
        })
        // An explicit choice in the filter sheet wins over the standing
        // preference. Sending both would intersect them, so picking "novel" in
        // the sheet while novels are switched off in Settings would silently
        // return nothing at all rather than what was asked for.
        if query.types.isEmpty {
            items.append(contentsOf: formats.map { URLQueryItem(name: "type", value: $0) })
        }
        items.append(contentsOf: blockedTags.map {
            URLQueryItem(name: "tag_not", value: String($0))
        })
        do {
            let series: [Series] = try await client.get("/v2/series/search", query: items)
            return FeedResult(series: series.filter(\.isDiscoverable), origin: .network)
        } catch {
            return FeedResult(series: [], origin: .staleAfter(error))
        }
    }

    func mix(
        seeds: [Int],
        filters: SearchQuery,
        excludedTags: [Int] = []
    ) async -> MixResult {
        guard !seeds.isEmpty else { return .empty }
        var items = filters.queryItems.filter { $0.name != "q" && $0.name != "sort_by" }
        // Repeated keys; the comma form is rejected with HTTP 400. See
        // FeedKind.extraQuery for the verification.
        items.append(contentsOf: seeds.map { URLQueryItem(name: "series", value: String($0)) })
        items.append(URLQueryItem(name: "strict", value: "false"))
        items.append(contentsOf: blendExclusionQuery)
        items.append(contentsOf: blockedTags.map {
            URLQueryItem(name: "blocked_tag", value: String($0))
        })
        items.append(contentsOf: (contentRatings ?? []).map {
            URLQueryItem(name: "content_rating", value: $0)
        })
        if filters.types.isEmpty {
            items.append(contentsOf: formats.map { URLQueryItem(name: "type", value: $0) })
        }
        // Excluded strands. Proven live: excluding the top tag drops it out of
        // the DNA, promotes everything below it, and changes most of the
        // results — so the DNA doubles as feedback for the edit just made.
        items.append(contentsOf: excludedTags.map {
            URLQueryItem(name: "tag_not", value: String($0))
        })

        do {
            let envelope: MixEnvelope = try await client.getRoot(
                "/v1/series/mix",
                query: items
            )
            return MixResult(
                recommendations: (envelope.data ?? []).filter(\.series.isDiscoverable),
                dna: BlendDNA(
                    strands: envelope.dna ?? [],
                    seedCount: envelope.seedCount ?? seeds.count
                )
            )
        } catch {
            return .empty
        }
    }

    /// `mix` answers with `data` alongside `dna` and `seed_count` at the top
    /// level, so it needs its own envelope rather than the shared one.
    private struct MixEnvelope: Decodable {
        let data: [Recommendation]?
        let dna: [BlendDNA.Strand]?
        let seedCount: Int?
    }

    func updateContentRatings(_ ratings: [String]) async {
        guard ratings != contentRatings else { return }
        contentRatings = ratings
        try? discardCachedFeeds()
    }

    func updateFormats(_ formats: [String]) async {
        guard formats != self.formats else { return }
        self.formats = formats
        try? discardCachedFeeds()
    }

    func updateBlockedTags(_ ids: [Int]) async {
        guard ids != blockedTags else { return }
        blockedTags = ids
        try? discardCachedFeeds()
    }

    func cachedSeriesCount() async -> Int {
        cachedSeriesCountSync()
    }

    private func cachedSeriesCountSync() -> Int {
        (try? database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM series") ?? 0
        }) ?? 0
    }

    func updateLibraryExclusion(userID: String?) async {
        guard userID != libraryExclusionUserID else { return }
        libraryExclusionUserID = userID
        // Cached blends were built without the exclusion, so they still hold
        // series the reader already tracks.
        try? discardCachedFeeds()
    }

    /// Applies only to blends. Search and discovery are browsing surfaces where
    /// finding something already on your shelf is useful, not noise.
    private var blendExclusionQuery: [URLQueryItem] {
        guard let libraryExclusionUserID else { return [] }
        return [URLQueryItem(name: "exclude_user_library", value: libraryExclusionUserID)]
    }

    /// The filters that apply to every request, as repeated query keys.
    ///
    /// Both parameters reject a comma-joined value with HTTP 400 — a mistake
    /// that once broke every feed in the app while the tests stayed green.
    private var filterQuery: [URLQueryItem] {
        (contentRatings ?? []).map { URLQueryItem(name: "content_rating", value: $0) }
            + formats.map { URLQueryItem(name: "type", value: $0) }
            + blockedTags.map { URLQueryItem(name: "tag_not", value: String($0)) }
    }

    /// Split out because GRDB offers both a sync and an async `write`, and in
    /// an async context `try?` picks the async one, which does not compile here.
    private func discardCachedFeeds() throws {
        try database.writer.write { db in
            // Only the feed cache is cleared. The shelf holds the reader's own
            // saves and is not derived from the filter.
            try db.execute(sql: "DELETE FROM feedEntry")
            try db.execute(sql: "DELETE FROM feedMetadata")
        }
    }

    /// Volume covers and alternate editions.
    ///
    /// Filtered by the reader's content ratings like everything else. The
    /// rating is per image, not per series: a series rated safe can carry a
    /// suggestive alternate cover, and the filter failing on exactly the thing
    /// it exists to hide is a bug this app has already shipped once, on
    /// personalised recommendations.
    func images(for seriesId: Int) async -> [SeriesImage] {
        let all: [SeriesImage]? = try? await client.get("/v1/series/\(seriesId)/images")
        return (all ?? []).presentable(allowedRatings: contentRatings)
    }

    func extras(for seriesId: Int) async -> SeriesExtras {
        // Concurrent rather than sequential: three independent reads, and the
        // detail screen should not wait for them in series.
        async let links: [SeriesLink]? = try? client.get("/v1/series/\(seriesId)/links")
        async let news: [NewsItem]? = try? client.get(
            "/v1/series/\(seriesId)/news",
            query: [URLQueryItem(name: "limit", value: "6")]
        )
        async let related: [SeriesRelationship]? = try? client.get(
            "/v1/series/\(seriesId)/relationships"
        )
        // The only source of tags and year — see SeriesExtras.
        async let full: Series? = try? client.get("/v1/series/\(seriesId)")
        async let editions: [SeriesEdition]? = try? client.get(
            "/v1/series/\(seriesId)/collections"
        )

        let detail = await full
        return await SeriesExtras(
            links: links ?? [],
            news: news ?? [],
            relationships: (related ?? []).filter(\.series.isDiscoverable),
            tags: detail?.tags ?? [],
            richTags: detail?.richTags ?? [],
            editions: (await editions ?? []).presentable,
            year: detail?.year
        )
    }

}
