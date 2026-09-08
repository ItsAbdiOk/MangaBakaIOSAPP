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

    var cacheKey: String {
        switch self {
        case .rising: "discover/rising"
        case .hiddenGems: "discover/hidden-gems"
        case .trending: "discover/trending"
        case let .similar(id): "series/\(id)/similar"
        case let .readersAlsoLike(id): "series/\(id)/readers-also-like"
        case let .mix(seeds): "series/mix/" + seeds.sorted().map(String.init).joined(separator: "-")
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
        }
    }

    /// Extra query beyond `limit`.
    var extraQuery: [String: String] {
        switch self {
        case .trending:
            ["sort_by": "trending_7d"]
        case let .mix(seeds) where !seeds.isEmpty:
            ["series": seeds.map(String.init).joined(separator: ","), "strict": "false"]
        default:
            [:]
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

    init(client: APIClient, database: AppDatabase, clock: any Clock = SystemClock()) {
        self.client = client
        self.database = database
        self.clock = clock

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        self.decoder = decoder
    }

    func feed(_ feed: FeedKind, forceRefresh: Bool = false) async -> FeedResult {
        if !forceRefresh, let fresh = try? readCache(feed, requireFresh: true), !fresh.isEmpty {
            return FeedResult(series: fresh, origin: .cache)
        }

        do {
            let series: [Series] = try await client.get(
                feed.path,
                query: ["limit": String(feed.limit)].merging(feed.extraQuery) { _, new in new }
            )
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
