import Foundation
import GRDB

/// The cache half of `SeriesRepository`.
///
/// Split out for the lint's body-length ceiling, which the repository reached
/// when the cache learned to report *when* it was written — the date is what
/// lets a stale screen say "last updated 19 hours ago" instead of only that a
/// refresh failed.
///
/// The seam is a real one and not just a place to cut: everything here reads
/// and writes SQLite and nothing here touches the network.
extension SeriesRepository {
    // MARK: - Cache

    /// How long a series page's extras stay good.
    ///
    /// Longer than a reading session, shorter than anything on the page
    /// meaningfully changes. The most volatile thing in there is the news row,
    /// which is a sidebar rather than the point of the screen.
    private static let detailFreshness: TimeInterval = 6 * 60 * 60

    func readDetailCache(_ seriesId: Int) throws -> SeriesExtras? {
        try database.writer.read { db in
            guard let row = try CachedDetail.fetchOne(db, key: seriesId) else { return nil }
            let age = clock.now.timeIntervalSince(row.cachedAt)
            // A negative age means the device clock moved backwards; treat that
            // as stale rather than trusting it.
            guard age >= 0, age < Self.detailFreshness else { return nil }
            return try? JSONDecoder().decode(SeriesExtras.self, from: row.payload)
        }
    }

    func writeDetailCache(_ extras: SeriesExtras, for seriesId: Int) throws {
        let payload = try JSONEncoder().encode(extras)
        try database.writer.write { db in
            try CachedDetail(
                seriesId: seriesId, payload: payload, cachedAt: clock.now
            ).save(db)
            try Self.trimDetail(db)
        }
    }

    /// Throws away every cached series page.
    ///
    /// Needed because the detail cache holds rating-filtered and tag-filtered
    /// content — a series page's tag rows, its editions, its images — and was
    /// invalidated by nothing, ever. Change the content rating and the page
    /// kept showing the tags that rating was set to hide, for six hours.
    /// What a filter governs, and therefore what a change to it must throw away.
    ///
    /// **Declared rather than remembered.** Four setters each wrote their own
    /// version of this and the four did not agree: the feed cache was cleared
    /// four times, the rating-filtered image cache never, the detail cache
    /// never by anything at all, and one setter had no first-application guard
    /// so every signed-in launch wiped the lot. Each omission was individually
    /// invisible, because the rule lived in whichever setter you happened to
    /// be reading.
    ///
    /// The test for a new filter is now "what does it filter?", and the answer
    /// is in the enum rather than in four places.
    struct CacheScope: OptionSet {
        let rawValue: Int
        /// Feeds on disk. Every filter narrows these.
        static let feeds = CacheScope(rawValue: 1 << 0)
        /// Per-series images, filtered by content rating on the way in.
        static let images = CacheScope(rawValue: 1 << 1)
        /// The six-hour series-page cache, which holds rating- and
        /// tag-filtered tags, editions and links.
        static let detail = CacheScope(rawValue: 1 << 2)
        static let everythingDerived: CacheScope = [.feeds, .images, .detail]
    }

    /// Applies a filter change and discards exactly what it invalidated.
    ///
    /// One path, so a fifth filter cannot be added with a fourth policy.
    func apply(
        _ key: String,
        changed: Bool,
        invalidating scope: CacheScope
    ) {
        let discards = shouldDiscard(key)
        guard changed, discards else { return }
        if scope.contains(.feeds) { try? discardCachedFeeds() }
        if scope.contains(.images) { cachedImages.removeAll() }
        if scope.contains(.detail) { try? discardDetailCache() }
    }

    /// The exclusion id the cached feeds on disk were written under.
    ///
    /// Persisted, because the question "is this a change?" is about the cache,
    /// and the cache outlives the process. Comparing against whatever this
    /// process happens to start with answers a different question, and both of
    /// its wrong answers have shipped.
    var cachedExclusionUserID: String? {
        get { UserDefaults.standard.string(forKey: Self.exclusionKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.exclusionKey) }
    }

    private static let exclusionKey = "cache.libraryExclusionUserID"

    func discardDetailCache() throws {
        try database.writer.write { db in
            try db.execute(sql: "DELETE FROM seriesDetail")
        }
    }

    func readCache(_ feed: FeedKind, requireFresh: Bool) throws -> [Series] {
        try readCacheWithDate(feed, requireFresh: requireFresh).series
    }

    /// The cached feed and when it was written.
    ///
    /// The date is what lets a stale screen say "last updated 19 hours ago"
    /// rather than the bare fact that a refresh failed. An age a reader can
    /// judge is the difference between "this is yesterday's, fine" and "this
    /// might be a week old, and I should worry".
    func readCacheWithDate(
        _ feed: FeedKind,
        requireFresh: Bool
    ) throws -> (series: [Series], cachedAt: Date?) {
        try database.writer.read { db in
            let metadata = try FeedMetadata
                .filter(Column("feedKey") == feed.cacheKey)
                .fetchOne(db)

            if requireFresh {
                guard let metadata else { return ([], nil) }

                let age = clock.now.timeIntervalSince(metadata.cachedAt)
                // A negative age means the device clock moved backwards; treat
                // that as stale rather than trusting it.
                guard age >= 0, age < feed.freshness else { return ([], nil) }
            }

            let entries = try FeedEntry
                .filter(Column("feedKey") == feed.cacheKey)
                .order(Column("position"))
                .fetchAll(db)
            guard !entries.isEmpty else { return ([], metadata?.cachedAt) }

            let rows = try CachedSeries
                .filter(entries.map(\.seriesId).contains(Column("id")))
                .fetchAll(db)
            let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })

            // Order comes from the feed, not from the series table: the API's
            // ordering is editorial and must survive a round trip.
            // Filtered on the way out as well as on the way in. A cached feed
            // was written under whatever the format setting was at the time,
            // and turning a format off should empty it from what is already on
            // the phone rather than only from the next fetch.
            //
            // A row that fails to decode makes the whole read a miss. It used
            // to be dropped with `try?`, and a twenty-row feed came back as
            // fourteen, served as a hit, with nothing to say why — the format
            // filter on the next line makes a short feed look expected.
            let series = try entries
                .compactMap { entry -> Series? in
                    guard let row = byID[entry.seriesId] else { return nil }
                    return try decoder.decode(Series.self, from: row.payload)
                }
                .filter(allowsFormat)
            return (series, metadata?.cachedAt)
        }
    }

    func write(_ series: [Series], for feed: FeedKind) throws {
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
            try Self.trimOrphans(db)
        }
    }

    /// Deletes series rows no feed points at any more.
    ///
    /// Replacing a feed deleted its index rows and left the series rows they
    /// pointed at, so the table grew on every fetch, forever — and the count
    /// Discover shows as "series cached" was counting the orphans. Called
    /// after every feed write and every feed discard; the detail cache is
    /// bounded by its own age check and trimmed the same way below.
    static func trimOrphans(_ db: Database) throws {
        try db.execute(sql: "DELETE FROM series WHERE id NOT IN (SELECT seriesId FROM feedEntry)")
    }

    /// The detail cache keeps the newest rows only. A series page is about
    /// 300 KB, and nothing else bounds the table.
    static let detailRowLimit = 200

    static func trimDetail(_ db: Database) throws {
        try db.execute(sql: """
            DELETE FROM seriesDetail WHERE seriesId NOT IN (
                SELECT seriesId FROM seriesDetail
                ORDER BY cachedAt DESC, seriesId DESC LIMIT \(detailRowLimit)
            )
            """)
    }
}
