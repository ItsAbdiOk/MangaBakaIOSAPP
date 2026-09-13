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
    ///
    /// `SeriesExtras.failure` is set when any of the six legs failed — check
    /// it rather than assuming an empty section means there was nothing to
    /// show (gap 9, FAILURES-SUMMARY.md).
    func extras(for seriesId: Int) async -> SeriesExtras
    /// The series-page extras already sitting in the six-hour detail cache,
    /// with no network call and no six-leg `extras(for:)` fetch — only what a
    /// previous visit to the page already paid for and cached.
    ///
    /// `DueThisWeekIntent` (Siri) uses this to find a library series' release
    /// links: firing `extras(for:)`'s six concurrent legs per series from a
    /// background intent would turn "what's due this week" into dozens of
    /// requests for a screen the reader never opened. Nil when nothing is
    /// cached — the caller simply has no links to check for that series,
    /// the same as if it had none.
    func cachedExtras(for seriesId: Int) async -> SeriesExtras?
    /// One series by id, for a deep link, Siri or Spotlight — a single read,
    /// not the six `extras` legs. Nil when it cannot be fetched.
    func series(id: Int) async -> Series?

    /// Every cover the series has, filtered to what the reader has allowed.
    /// Nil when the fetch failed, distinct from a series that genuinely has
    /// none — collapsing the two into `[]` (gap 32) made a throttled reader
    /// see "1 cover" instead of a failure they could retry.
    func images(for seriesId: Int) async -> [SeriesImage]?

    /// A series' formal relationships: sequels, spin-offs, the source it was
    /// adapted from. Nil on failure, distinct from an empty list, which is a
    /// real answer ("no relationships").
    func relationships(for seriesId: Int) async -> [SeriesRelationship]?

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

    /// How many series a query would return, without downloading them.
    /// Nil when the answer is unknown — never zero, which means something else.
    func count(_ query: SearchQuery) async -> Int?

}

/// The onward paths from a series. Every field is independently optional: a
/// series with no news is ordinary, and one failing endpoint must not empty
/// the rest of the screen.
struct SeriesExtras: Sendable, Equatable, Codable {
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
    /// Published volumes, with every edition of each gathered onto one — see
    /// `SeriesWork.Volume`.
    var volumes: [SeriesWork.Volume] = []
    var year: Int?
    /// The whole v1 series, not just the two fields above.
    ///
    /// A series page is built from whatever copy of the series the reader
    /// arrived with, and those copies are not equal. The swipe stack's queue
    /// carries v2 payloads, which have no description, no chapter count, no
    /// status and no `source` — so "More info" from the stack showed a page
    /// with no synopsis, no length, and no next-chapter estimate, because the
    /// estimate needs the MangaUpdates id that lives in `source`. The v1 series
    /// was already being fetched here for its tags; everything else it carried
    /// was thrown away. Kept now, and merged in by `Series.filling(gapsFrom:)`.
    var full: Series?
    /// Set when at least one of the six concurrent legs `fetchExtras` runs
    /// failed — cancellation excluded, since nobody left waiting on this
    /// answer needs to be told it didn't finish (`APIError.cancelled`).
    ///
    /// Excluded from `Codable` on purpose: `extras(for:)` refuses to persist a
    /// result this is set on (gap 9), so a cached row never actually carries
    /// one, and giving `APIError` a `Codable` conformance it does not
    /// otherwise need — just so a value nothing writes to disk can round-trip
    /// through JSON — is not worth doing.
    var failure: APIError?

    enum CodingKeys: String, CodingKey {
        case links, news, relationships, tags, richTags, editions, volumes, year, full
    }
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
        // `popularity` is a rank — 1 is the most popular — so ascending is
        // the order a reader means by "popularity". `popularity_desc` put
        // the least-rated series first: for publisher=Shueisha it answered
        // three unrated entries where `popularity_asc` answers ONE PIECE
        // (591k ratings) first. Verified live 2026-09-11.
        ("popularity_asc", "Popularity"),
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
    /// Whether the API itself says another page exists (`pagination.next !=
    /// nil`), not whether this page's `series` count reached the limit.
    ///
    /// A page is filtered locally for `isDiscoverable`/format before it
    /// reaches here, so a page that had 30 rows on the wire can arrive with
    /// fewer — a tag like "Isekai" (7,105 results) was capped at 30 forever
    /// because one filtered row made `count >= limit` false on page one.
    /// Defaults to false: a cached or failed result has no pagination to
    /// consult, and claiming more pages exist when there is nothing to fetch
    /// them from would spin a caller that trusts this flag.
    var hasMore = false
    /// The query's total row count, from the same pagination block, when the
    /// caller happened to fetch it. Nil, not zero, when unknown — see
    /// `APIClient.total`'s doc comment for why zero is never a safe default.
    var total: Int?

    /// An error to show only when there is nothing at all to display. When
    /// stale content exists, the content is shown instead of an error page.
    var blockingError: APIError? {
        guard case let .staleAfter(error) = origin, series.isEmpty else { return nil }
        return error
    }
}

actor SeriesRepository: SeriesRepositoryProtocol {
    // Internal rather than private so the cache and count halves can reach
    // them. See SeriesRepository+Cache.swift and +Count.swift — the splits are
    // the lint's doing, not a widening of who is meant to touch these.
    let client: APIClient
    // Internal rather than private so the cache half can reach them. See
    // SeriesRepository+Cache.swift — the split is the lint's doing, not a
    // widening of who is meant to touch these.
    let database: AppDatabase
    let clock: any Clock
    /// Where the exclusion id the cache was built under is persisted.
    /// Injectable so tests do not write the app's own defaults: three tests
    /// that set a fake id left it behind on the simulator, and the next real
    /// launch saw an account change and threw the feed cache away mid-load.
    let defaults: UserDefaults
    let decoder: JSONDecoder
    /// Content ratings to request, or `nil` for no filter. Defaults to the
    /// product decision: safe and suggestive, with anything stronger behind a
    /// deliberate opt-in that does not exist yet.
    var contentRatings: [String]?
    /// Formats to request, or empty for no filter. Empty is the default: the
    /// catalogue as it is, until the reader narrows it.
    var formats: [String] = []
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
    var blockedTags: [Int] = []

    /// Volume covers, per series, for as long as the app is running.
    ///
    /// In memory rather than on disk: these are only wanted while a series page
    /// or its gallery is open, and the case worth covering is going back and
    /// forward between them — which used to refetch 58 KB every time.
    var cachedImages: [Int: [SeriesImage]] = [:]

    /// Relationships, per series, for as long as the app is running. Not the
    /// disk cache: this is for the library row re-reading the same handful of
    /// finished series' relationships every time it appears, not for surviving
    /// a relaunch.
    var cachedRelationships: [Int: [SeriesRelationship]] = [:]

    init(
        client: APIClient,
        database: AppDatabase,
        clock: any Clock = SystemClock(),
        contentRatings: [String]? = ["safe", "suggestive"],
        formats: [String] = [],
        defaults: UserDefaults = .standard
    ) {
        self.client = client
        self.database = database
        self.clock = clock
        self.defaults = defaults
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

        // Whatever is already on disk for this feed, stale or not — read once
        // up front so a 304 can serve it and a genuine failure can fall back
        // to it, without a second database round trip for either.
        //
        // `lastModified` is what makes the request below conditional.
        // MEASURED 2026-09-13 against api.mangabaka.org: feed responses carry
        // no `ETag`, only `Last-Modified` (e.g. "Sun, 13 Sep 2026 13:56:53
        // GMT") and `cache-control: public, max-age=60`; sending that value
        // back as `If-Modified-Since` gets a 304 with a zero-byte body. Nil
        // here — no prior cache, or one written before this shipped — makes
        // the request below unconditional, i.e. today's behaviour exactly.
        let existing = (try? readCacheWithDate(feed, requireFresh: false)) ?? CachedFeed()

        do {
            var query = [URLQueryItem(name: "limit", value: String(feed.limit))]
            query.append(contentsOf: feed.extraQuery)
            if case .mix = feed { query.append(contentsOf: blendExclusionQuery) }
            // Filtering server-side means excluded covers are never downloaded,
            // never cached, and never briefly visible while a client-side
            // filter catches up.
            query.append(contentsOf: filterQuery())

            // Split into SeriesRepository+Cache.swift only for the lint's
            // line-count ceiling on this type — collapses the two response
            // shapes (recommendation-wrapped or bare) into one
            // `Conditional<[Series]>`.
            let conditional = try await fetchConditionalFeed(
                feed, query: query, ifModifiedSince: existing.lastModified
            )

            switch conditional {
            case .notModified:
                // The server just confirmed the rows on disk are still
                // exactly right. Nothing to rewrite — only the freshness
                // clock needed resetting, so the next visit inside the TTL
                // reads as a plain cache hit again instead of revalidating a
                // second time. `.cache`, not `.network`: what is returned did
                // not come off the wire, it is the same rows that were
                // already here, merely confirmed current — and no other
                // `.cache` result in this repository carries a `cachedAt`
                // either.
                try? touchFeedMetadata(feed)
                return FeedResult(series: existing.series, origin: .cache)
            case let .fresh(series, lastModified):
                let discoverable = series.filter { $0.isDiscoverable && allowsFormat($0) }
                try? write(discoverable, for: feed, lastModified: lastModified)
                return FeedResult(series: discoverable, origin: .network)
            }
        } catch {
            // Falling back to stale cache is the whole point of the cache on a
            // train. An empty result here is handled by `blockingError`.
            return FeedResult(
                series: existing.series,
                origin: .staleAfter(error),
                cachedAt: existing.cachedAt
            )
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
        // `blocked_tag`, not `tag_not` — see `filterQuery`'s doc comment.
        items.append(contentsOf: filterQuery(overridingTypes: filters.types, blockedTagParam: "blocked_tag"))
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
                recommendations: (envelope.data ?? [])
                    .filter { $0.series.isDiscoverable && allowsFormat($0.series) },
                dna: BlendDNA(
                    strands: envelope.dna ?? [],
                    seedCount: envelope.seedCount ?? seeds.count
                )
            )
        } catch {
            // The request itself failed — a rate limit, an outage — which is
            // not the same thing as "nothing matched". `.empty` used to stand
            // for both, and the screen told a throttled reader "Nothing
            // matched. Try loosening the filters." (gap 11).
            return MixResult(failure: error)
        }
    }

    /// `mix` answers with `data` alongside `dna` and `seed_count` at the top
    /// level, so it needs its own envelope rather than the shared one.
    private struct MixEnvelope: Decodable {
        let data: [Recommendation]?
        let dna: [BlendDNA.Strand]?
        let seedCount: Int?
    }

    /// Which filters have been handed their stored value since launch.
    ///
    /// **This is the difference between a cache and no cache.** The repository
    /// is built before the preference stores are read, so it starts with no
    /// ratings, no formats and no blocked tags. The app then applies the stored
    /// values — and every one of them differed from the empty starting state,
    /// so every launch discarded the entire feed cache before the first screen
    /// drew. Offline support was documented, tested, and silently dead.
    ///
    /// A first application is not a change. The cache on disk was written under
    /// exactly these values, because they are the values it was written under
    /// last time the app ran. Only a genuine change discards.
    private var applied: Set<String> = []

    func shouldDiscard(_ key: String) -> Bool {
        defer { applied.insert(key) }
        return applied.contains(key)
    }

    func updateContentRatings(_ ratings: [String]) async {
        let changed = ratings != contentRatings
        contentRatings = ratings
        // Ratings filter images per image and tags per tag, so all three.
        apply("ratings", changed: changed, invalidating: .everythingDerived)
    }

    func updateFormats(_ formats: [String]) async {
        let changed = formats != self.formats
        self.formats = formats
        // A format narrows which series appear, not what is shown about one.
        apply("formats", changed: changed, invalidating: .feeds)
    }

    func updateBlockedTags(_ ids: [Int]) async {
        let changed = ids != blockedTags
        blockedTags = ids
        // Blocked tags are filtered out of a series page's tag rows too, and
        // those live in the detail cache.
        apply("blockedTags", changed: changed, invalidating: [.feeds, .detail])
    }

    /// The reader's own MangaBaka id, used to keep series they already track
    /// out of a blend.
    ///
    /// **This one cannot use `applied`, and finding out why took a test.**
    /// The `applied` mechanism assumes a first application is not a change,
    /// because the cache on disk was written under exactly the values the app
    /// is about to be handed. True for ratings, formats and blocked tags,
    /// which are read from the same `UserDefaults` the cache was written
    /// under. Not true here, and the two failure modes point opposite ways:
    ///
    /// - Treat the first application as a change, and every launch by a
    ///   signed-in reader deletes the whole feed cache before the first screen
    ///   draws. That shipped, and offline support was silently dead again.
    /// - Treat it as not a change, and a reader who browses signed out and
    ///   then signs in keeps blends full of series they already track. That is
    ///   what `RecommendationQualityTests` asserts, and it failed the moment
    ///   the first fix was tried — the test was right.
    ///
    /// Both are real, so neither guess is good enough. The id the cache was
    /// actually written under is recorded beside it, and a change is measured
    /// against that rather than against whatever this process started with.
    func updateLibraryExclusion(userID: String?) async {
        let previous = cachedExclusionUserID
        libraryExclusionUserID = userID
        guard userID != previous else { return }
        cachedExclusionUserID = userID
        // Cached blends were built under the previous value, so they still
        // hold series the reader already tracks — or exclude ones they do not.
        discardCachedFeeds()
    }

    func cachedSeriesCount() async -> Int {
        cachedSeriesCountSync()
    }

    private func cachedSeriesCountSync() -> Int {
        (try? database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM series") ?? 0
        }) ?? 0
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
    /// Whether a series survives the reader's format filter.
    ///
    /// **A backstop, not a belt-and-braces nicety.** Measured against the live
    /// API on 2026-09-10: `/v2/series/discover/rising?type=manga` answered with
    /// fourteen manhwa out of twenty, and `hidden-gems?type=manga` returned a
    /// novel. Those two endpoints ignore `type` entirely. Search honours it,
    /// and `content_rating` is honoured everywhere it was tested — so the
    /// setting looked like it worked, right up until you looked at Discover.
    ///
    /// Sending the parameter is still worth doing: where the server does honour
    /// it, filtering happens before the page is chosen, so a full page comes
    /// back. Where it does not, this catches what slipped through.
    ///
    /// An empty `formats` means every format is allowed, which is the default.
    /// An unknown or absent `type` is kept: dropping a series because the API
    /// did not say what it is would hide things nobody chose to hide.
    func allowsFormat(_ series: Series) -> Bool {
        guard !formats.isEmpty else { return true }
        guard let type = series.type?.lowercased(), !type.isEmpty else { return true }
        return formats.contains(type)
    }

    /// The three standing filters — rating, format, blocked tags — built once
    /// rather than by hand at every call site.
    ///
    /// **Built here because this used to be four separate copies**: this
    /// function, `mix`, `search` and `count` each assembled the same three
    /// query items on their own, and a fourth caller would have been a fifth
    /// copy with a fifth chance to miss one — exactly the shape
    /// `SeriesRepository+Cache.swift`'s `CacheScope` exists to avoid on the
    /// invalidation side.
    ///
    /// Internal rather than private so the paging and count halves can reach
    /// it. See SeriesRepository+Paging.swift and +Count.swift — the split is
    /// the lint's doing, not a widening of who is meant to touch this.
    ///
    /// - Parameter overridingTypes: an explicit type list from the caller's
    ///   own query — a format chosen in the filter sheet — wins over the
    ///   standing `formats` preference. Sending both would intersect them, so
    ///   picking "novel" in the sheet while novels are off in Settings would
    ///   silently return nothing at all rather than what was asked for.
    ///   Empty (the default, and always for a feed, which has no query of its
    ///   own to override with) means "apply the standing preference".
    /// - Parameter blockedTagParam: the query key blocked tags are sent
    ///   under. Not one key everywhere: `blocked_tag` is the parameter meant
    ///   for a standing block and is verified, live, to actually change a
    ///   blend's results (`BlockedTags.swift`); `tag_not` is what search,
    ///   discovery and count accept instead — `blocked_tag` is not in their
    ///   spec at all. A caller that gets this wrong sends a filter the
    ///   endpoint silently ignores, which is exactly the shotgun-surgery risk
    ///   this function exists to close off.
    func filterQuery(
        overridingTypes: [String] = [],
        blockedTagParam: String = "tag_not"
    ) -> [URLQueryItem] {
        var items = (contentRatings ?? []).map { URLQueryItem(name: "content_rating", value: $0) }
        if overridingTypes.isEmpty {
            items.append(contentsOf: formats.map { URLQueryItem(name: "type", value: $0) })
        }
        items.append(contentsOf: blockedTags.map { URLQueryItem(name: blockedTagParam, value: String($0)) })
        return items
    }

    // `discardCachedFeeds()` moved to SeriesRepository+Cache.swift — it is
    // cache logic through and through, and this actor's own body was over
    // the lint's 250-line ceiling before it had a place to go.

    /// Volume covers and alternate editions.
    ///
    /// Filtered by the reader's content ratings like everything else. The
    /// rating is per image, not per series: a series rated safe can carry a
    /// suggestive alternate cover, and the filter failing on exactly the thing
    /// it exists to hide is a bug this app has already shipped once, on
    /// personalised recommendations.
    func images(for seriesId: Int) async -> [SeriesImage]? {
        if let cached = cachedImages[seriesId] { return cached }
        // Nil, not swallowed: a failed fetch and a series with no covers used
        // to look identical from here, and the gallery read "1 cover" (the
        // series' own primary cover, drawn from elsewhere) for a throttled
        // reader exactly as it would for one whose series really has one
        // (gap 32).
        guard let all: [SeriesImage] = try? await client.get("/v1/series/\(seriesId)/images") else {
            return nil
        }
        let presentable = all.presentable(allowedRatings: contentRatings)
        cachedImages[seriesId] = presentable
        return presentable
    }

    /// Everything hanging off a series page.
    ///
    /// **Cached, because it is eight requests.** Links, news, relationships,
    /// the v1 payload, editions, images, similar and readers-also-like — about
    /// 300 KB a visit, and none of it was kept, so going back and opening the
    /// same series again paid the whole cost twice.
    ///
    /// Six hours, which is longer than a reading session and shorter than
    /// anything on a series page meaningfully changes. News is the most
    /// volatile thing here and it is a sidebar, not the point of the screen.
    func series(id: Int) async -> Series? {
        // The cached extras already carry the full record when they exist;
        // otherwise one GET rather than the six concurrent legs `extras`
        // pays for a page this caller is about to open anyway (gap 62).
        if let cached = try? readDetailCache(id), let full = cached.full { return full }
        return try? await client.get("/v1/series/\(id)")
    }

    /// See the protocol doc: whatever `readDetailCache` already holds, never
    /// a fetch.
    func cachedExtras(for seriesId: Int) async -> SeriesExtras? {
        try? readDetailCache(seriesId)
    }

    func extras(for seriesId: Int) async -> SeriesExtras {
        if let cached = try? readDetailCache(seriesId) { return cached }
        let fresh = await fetchExtras(for: seriesId)
        // Cached only when every leg answered. Used to skip caching only an
        // all-empty result, on the theory that an empty struct was a dropped
        // connection wearing the same clothes as a series with nothing to
        // show — but five legs succeeding and a sixth 429'ing produced a
        // *non-empty* struct missing one section, and that was cached whole
        // for six hours (gap 9). `failure` now says directly whether this is
        // the whole answer; a partial one is never persisted at all, so the
        // next open retries instead of the missing section staying missing
        // for the rest of the cache's life.
        if fresh.failure == nil, fresh != SeriesExtras() {
            try? writeDetailCache(fresh, for: seriesId)
        }
        return fresh
    }

    /// Same endpoint `extras(for:)` folds in as one of six concurrent reads,
    /// exposed on its own for callers that want only this — the library row
    /// asks for it for up to eight finished series and does not want the
    /// other five requests each time.
    func relationships(for seriesId: Int) async -> [SeriesRelationship]? {
        if let cached = cachedRelationships[seriesId] { return cached }
        guard let fetched: [SeriesRelationship] = try? await client.get(
            "/v1/series/\(seriesId)/relationships"
        ) else { return nil }
        cachedRelationships[seriesId] = fetched
        return fetched
    }

    /// Runs one leg of `fetchExtras`, turning its typed throw into a `Result`
    /// rather than dropping it with `try?` — a struct with five legs full and
    /// one missing needs to say which one failed and why, so the section can
    /// offer Retry instead of quietly looking like a series with nothing
    /// there (gap 9, FAILURES-SUMMARY.md).
    private static func attempt<T>(
        _ operation: () async throws(APIError) -> T
    ) async -> Result<T, APIError> {
        do {
            return .success(try await operation())
        } catch {
            return .failure(error)
        }
    }

    private static func value<T>(_ result: Result<T, APIError>) -> T? { try? result.get() }

    private static func failure<T>(_ result: Result<T, APIError>) -> APIError? {
        if case let .failure(error) = result { return error }
        return nil
    }

    private func fetchExtras(for seriesId: Int) async -> SeriesExtras {
        // Concurrent rather than sequential: six independent reads, and the
        // detail screen should not wait for them in series.
        async let links: Result<[SeriesLink], APIError> = Self.attempt {
            () async throws(APIError) -> [SeriesLink] in
            try await client.get("/v1/series/\(seriesId)/links")
        }
        async let news: Result<[NewsItem], APIError> = Self.attempt {
            () async throws(APIError) -> [NewsItem] in
            try await client.get(
                "/v1/series/\(seriesId)/news",
                query: [URLQueryItem(name: "limit", value: "6")]
            )
        }
        async let related: Result<[SeriesRelationship], APIError> = Self.attempt {
            () async throws(APIError) -> [SeriesRelationship] in
            try await client.get("/v1/series/\(seriesId)/relationships")
        }
        // The only source of tags and year — see SeriesExtras.
        async let full: Result<Series, APIError> = Self.attempt {
            () async throws(APIError) -> Series in
            try await client.get("/v1/series/\(seriesId)")
        }
        async let editions: Result<[SeriesEdition], APIError> = Self.attempt {
            () async throws(APIError) -> [SeriesEdition] in
            try await client.get("/v1/series/\(seriesId)/collections")
        }
        // Published volumes: dates, prices, page counts, ISBNs and per-volume
        // cover art. A sixth concurrent read rather than a lazy one, because
        // the section sits above the fold on a short series and a spinner that
        // appears after the page has settled reads as a second page load.
        async let works: Result<[SeriesWork], APIError> = Self.attempt {
            () async throws(APIError) -> [SeriesWork] in
            try await client.get("/v1/series/\(seriesId)/works")
        }

        let results = await (links, news, related, full, editions, works)
        let detail = Self.value(results.3)

        return SeriesExtras(
            links: Self.value(results.0) ?? [],
            news: Self.value(results.1) ?? [],
            relationships: (Self.value(results.2) ?? []).filter(\.series.isDiscoverable),
            tags: detail?.tags ?? [],
            richTags: detail?.richTags ?? [],
            editions: (Self.value(results.4) ?? []).presentable,
            volumes: SeriesWork.volumes(from: Self.value(results.5) ?? []),
            year: detail?.year,
            full: detail,
            failure: Self.combinedFailure([
                Self.failure(results.0), Self.failure(results.1), Self.failure(results.2),
                Self.failure(results.3), Self.failure(results.4), Self.failure(results.5)
            ])
        )
    }

    /// The first real failure among the six legs, cancellation dropped:
    /// nobody still waiting on this page needs telling that a request they no
    /// longer care about didn't finish (`APIError.cancelled`'s doc comment).
    /// Which leg is named is arbitrary when more than one failed — no caller
    /// distinguishes among them today — but a single `APIError` is what
    /// `SeriesExtras.failure` and every test written against it expect.
    private static func combinedFailure(_ perLeg: [APIError?]) -> APIError? {
        perLeg.compactMap { $0 }.first { $0 != .cancelled }
    }
}

extension SeriesRepositoryProtocol {
    /// Stubs and any repository without a cheaper path fall back to the
    /// full record `extras` fetches.
    func series(id: Int) async -> Series? { await extras(for: id).full }

    /// Nil by default: a stub has nothing cached, and a repository with no
    /// cheaper path than `extras(for:)` should not be made to pay for a
    /// network fetch just to answer "is anything cached".
    func cachedExtras(for seriesId: Int) async -> SeriesExtras? { nil }
}
