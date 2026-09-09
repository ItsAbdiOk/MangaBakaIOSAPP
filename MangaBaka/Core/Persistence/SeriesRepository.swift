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

    /// Blends recommendations from seed series, with the reason each matched.
    /// Requires at least one seed — the API rejects a seedless request.
    func mix(seeds: [Int], filters: SearchQuery) async -> [Recommendation]

    /// Everything the detail screen shows beyond the series itself. Fetched
    /// together so one slow endpoint does not stagger the screen into place.
    func extras(for seriesId: Int) async -> SeriesExtras

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
}

/// The onward paths from a series. Every field is independently optional: a
/// series with no news is ordinary, and one failing endpoint must not empty
/// the rest of the screen.
struct SeriesExtras: Sendable, Equatable {
    var links: [SeriesLink] = []
    var news: [NewsItem] = []
    var relationships: [SeriesRelationship] = []
}

/// A search or filter request. Only non-nil fields are sent, so an untouched
/// filter never narrows the results by accident.
struct SearchQuery: Sendable, Equatable {
    var text: String?
    /// manga, novel, manhwa, manhua, oel, other
    var types: [String] = []
    /// releasing, completed, hiatus, cancelled, upcoming, unknown
    var statuses: [String] = []
    /// One of the API's 20 sort orders.
    var sort: String?
    /// 0-100 as the API expresses it.
    var minimumRating: Int?
    var limit = 30
    /// 1-based, as the API counts. `/v2/series/search` accepts up to page 100.
    var page = 1

    /// Whether this query would narrow anything at all.
    ///
    /// `sort` counts. It used to be excluded, which is what made "Surprise me"
    /// do nothing: it sets `sort = "random"` and nothing else, so the query
    /// still read as empty, `search()` returned before making a request, and
    /// the view kept rendering its idle state. A sort-only query is a real
    /// query — random and trending are both browsing, not filtering.
    var isEmpty: Bool {
        (text ?? "").trimmingCharacters(in: .whitespaces).isEmpty
            && types.isEmpty && statuses.isEmpty && minimumRating == nil
            && sort == nil
    }

    /// Repeated keys where the API wants them; a comma-joined list is rejected
    /// with HTTP 400 for these parameters.
    var queryItems: [URLQueryItem] {
        var items = [URLQueryItem(name: "limit", value: String(limit))]
        if page > 1 { items.append(URLQueryItem(name: "page", value: String(page))) }
        if let text, !text.trimmingCharacters(in: .whitespaces).isEmpty {
            items.append(URLQueryItem(name: "q", value: text))
        }
        for type in types { items.append(URLQueryItem(name: "type", value: type)) }
        for status in statuses { items.append(URLQueryItem(name: "status", value: status)) }
        if let sort { items.append(URLQueryItem(name: "sort_by", value: sort)) }
        if let minimumRating {
            items.append(URLQueryItem(name: "rating_lower", value: String(minimumRating)))
        }
        return items
    }
}

/// Which feed, and how long its cache stays fresh.
enum FeedKind: Sendable, Hashable {
    case rising
    case hiddenGems
    case trending
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
        case .trending: "/v2/series/search"
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
        case .rising, .hiddenGems, .trending, .surprise: false
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
        case .trending, .surprise: true
        case .rising, .hiddenGems, .similar, .readersAlsoLike, .mix: false
        }
    }

    /// Extra query beyond `limit`.
    var extraQuery: [URLQueryItem] {
        switch self {
        case .trending:
            [URLQueryItem(name: "sort_by", value: "trending_7d")]
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
        case .trending: 20
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

    /// An error to show only when there is nothing at all to display. When
    /// stale content exists, the content is shown instead of an error page.
    var blockingError: APIError? {
        guard case let .staleAfter(error) = origin, series.isEmpty else { return nil }
        return error
    }
}

actor SeriesRepository: SeriesRepositoryProtocol {
    private let client: APIClient
    private let database: AppDatabase
    private let clock: any Clock
    private let decoder: JSONDecoder
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
            let stale = (try? readCache(feed, requireFresh: false)) ?? []
            return FeedResult(series: stale, origin: .staleAfter(error))
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
        do {
            let series: [Series] = try await client.get("/v2/series/search", query: items)
            return FeedResult(series: series.filter(\.isDiscoverable), origin: .network)
        } catch {
            return FeedResult(series: [], origin: .staleAfter(error))
        }
    }

    func mix(seeds: [Int], filters: SearchQuery) async -> [Recommendation] {
        guard !seeds.isEmpty else { return [] }
        var items = filters.queryItems.filter { $0.name != "q" && $0.name != "sort_by" }
        // Repeated keys; the comma form is rejected with HTTP 400. See
        // FeedKind.extraQuery for the verification.
        items.append(contentsOf: seeds.map { URLQueryItem(name: "series", value: String($0)) })
        items.append(URLQueryItem(name: "strict", value: "false"))
        items.append(contentsOf: blendExclusionQuery)
        items.append(contentsOf: (contentRatings ?? []).map {
            URLQueryItem(name: "content_rating", value: $0)
        })
        if filters.types.isEmpty {
            items.append(contentsOf: formats.map { URLQueryItem(name: "type", value: $0) })
        }
        do {
            let results: [Recommendation] = try await client.get("/v1/series/mix", query: items)
            return results.filter(\.series.isDiscoverable)
        } catch {
            return []
        }
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

        return await SeriesExtras(
            links: links ?? [],
            news: news ?? [],
            relationships: (related ?? []).filter(\.series.isDiscoverable)
        )
    }

    // MARK: - Cache

    private func readCache(_ feed: FeedKind, requireFresh: Bool) throws -> [Series] {
        try database.writer.read { db in
            if requireFresh {
                guard let metadata = try FeedMetadata
                    .filter(Column("feedKey") == feed.cacheKey)
                    .fetchOne(db)
                else { return [] }

                let age = clock.now.timeIntervalSince(metadata.cachedAt)
                // A negative age means the device clock moved backwards; treat
                // that as stale rather than trusting it.
                guard age >= 0, age < feed.freshness else { return [] }
            }

            let entries = try FeedEntry
                .filter(Column("feedKey") == feed.cacheKey)
                .order(Column("position"))
                .fetchAll(db)
            guard !entries.isEmpty else { return [] }

            let rows = try CachedSeries
                .filter(entries.map(\.seriesId).contains(Column("id")))
                .fetchAll(db)
            let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })

            // Order comes from the feed, not from the series table: the API's
            // ordering is editorial and must survive a round trip.
            return entries.compactMap { entry in
                guard let row = byID[entry.seriesId] else { return nil }
                return try? decoder.decode(Series.self, from: row.payload)
            }
        }
    }

    private func write(_ series: [Series], for feed: FeedKind) throws {
        let now = clock.now
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase

        try database.writer.write { db in
            for item in series {
                let payload = try encoder.encode(item)
                try CachedSeries(id: item.id, payload: payload, cachedAt: now)
                    .save(db)
            }
            // Replace the feed wholesale rather than merging: a feed is an
            // ordered snapshot, and merging two snapshots produces an order
            // that never existed.
            try FeedEntry
                .filter(Column("feedKey") == feed.cacheKey)
                .deleteAll(db)
            for (index, item) in series.enumerated() {
                try FeedEntry(feedKey: feed.cacheKey, position: index, seriesId: item.id)
                    .insert(db)
            }
            try FeedMetadata(feedKey: feed.cacheKey, cachedAt: now).save(db)
        }
    }
}
