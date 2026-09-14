import Foundation
import GRDB
import os

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

    /// The `links` of every cached series page among `ids`, in one read.
    ///
    /// `refreshReminders` used to await `cachedExtras(for:)` once per library
    /// entry — 939 actor hops on the launch path, each its own SQLite read and
    /// a whole `SeriesExtras` decode, for a six-hour cache that on a cold
    /// launch holds almost none of them. One hop and one `WHERE seriesId IN
    /// (…)` here, decoding only the one key the caller wants.
    ///
    /// A series with nothing cached, or a row past the six hours, is absent
    /// from the result — the same answer a nil `cachedExtras` gave.
    func cachedExtrasLinks(for ids: [Int]) async -> [Int: [SeriesLink]] {
        guard !ids.isEmpty else { return [:] }
        // `await`: in an async context GRDB's asynchronous `read` is the one
        // that binds, and it is the right one — the synchronous overload
        // would block this actor's thread on SQLite.
        let rows = (try? await database.writer.read { db in
            try CachedDetail.filter(ids.contains(Column("seriesId"))).fetchAll(db)
        }) ?? []
        let now = clock.now
        var links: [Int: [SeriesLink]] = [:]
        for row in rows {
            // Same freshness rule as `readDetailCache`, including the
            // backwards-clock case, so the two cannot drift apart.
            let age = now.timeIntervalSince(row.cachedAt)
            guard age >= 0, age < Self.detailFreshness else { continue }
            guard let decoded = try? JSONDecoder().decode(CachedLinks.self, from: row.payload)
            else { continue }
            links[row.seriesId] = decoded.links
        }
        return links
    }

    /// Just the `links` key of an encoded `SeriesExtras`, so reading the links
    /// of a whole library does not decode a whole library of series pages.
    private struct CachedLinks: Decodable {
        var links: [SeriesLink] = []
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
    ///
    /// There used to be a second condition here: a `shouldDiscard(key)` that
    /// swallowed the *first* application of each filter, because the
    /// repository was built before the preference stores were read and every
    /// launch therefore "changed" all three from empty, discarding the whole
    /// feed cache before the first screen drew. The stores are now built
    /// first and their values passed to `init`, so the starting state is
    /// already the state the cache was written under and there is no first
    /// application to special-case. Dropping the guard also fixes what it
    /// cost: a feed fetched under the defaults in the window before the
    /// stored values landed was cached for up to 24 h and *not* discarded
    /// when they did (item 62).
    ///
    /// - Returns: false if any half of the discard failed, so a caller can
    ///   tell the reader their filter has not taken effect everywhere yet.
    @discardableResult
    func apply(
        _ key: String,
        changed: Bool,
        invalidating scope: CacheScope
    ) -> Bool {
        guard changed else { return true }
        var discarded = true
        if scope.contains(.feeds) { discarded = discardCachedFeeds() && discarded }
        if scope.contains(.images) { cachedImages.removeAll() }
        if scope.contains(.detail) { discarded = discardDetailCache() && discarded }
        if !discarded {
            Self.cacheLogger.error("\(key, privacy: .public) changed but its cache discard failed")
        }
        return discarded
    }

    /// The exclusion id the cached feeds on disk were written under.
    ///
    /// Persisted, because the question "is this a change?" is about the cache,
    /// and the cache outlives the process. Comparing against whatever this
    /// process happens to start with answers a different question, and both of
    /// its wrong answers have shipped.
    var cachedExclusionUserID: String? {
        get { defaults.string(forKey: Self.exclusionKey) }
        set { defaults.set(newValue, forKey: Self.exclusionKey) }
    }

    private static let exclusionKey = "cache.libraryExclusionUserID"

    private static let cacheLogger = Logger(subsystem: "dev.abdirahmanmohamed.mangabaka", category: "cache")

    /// Split out because GRDB offers both a sync and an async `write`, and in
    /// an async context `try?` picks the async one, which does not compile
    /// here.
    ///
    /// - Returns: whether the discard actually happened. Every caller used to
    ///   spend `try?` on this and move on regardless — so a filter change
    ///   whose discard failed (a full disk, a locked file) left the reader
    ///   looking at content their new filter should have removed, with
    ///   nothing on record to say why (gap 74, FAILURES-SUMMARY.md). A caller
    ///   that only wants the old fire-and-forget behaviour can still ignore
    ///   the result; this type itself no longer does, and logs when it
    ///   happens.
    @discardableResult
    func discardCachedFeeds() -> Bool {
        do {
            try database.writer.write { db in
                // Only the feed cache is cleared. The shelf holds the
                // reader's own saves and is not derived from the filter.
                try db.execute(sql: "DELETE FROM feedEntry")
                try db.execute(sql: "DELETE FROM feedMetadata")
                try Self.trimOrphans(db)
            }
            return true
        } catch {
            let description = String(describing: error)
            Self.cacheLogger.error("discardCachedFeeds failed: \(description, privacy: .public)")
            return false
        }
    }

    /// - Returns: whether the discard actually happened.
    ///
    /// Its feeds sibling above grew this shape for gap 74; this one kept
    /// `throws` and its only caller spent `try?` on it, which is the same bug
    /// in the same file: a rating change whose detail discard failed kept
    /// showing, for six hours, the tags the rating was set to hide — the
    /// exact failure the `CacheScope` doc above was written for — with
    /// nothing logged (item 32).
    @discardableResult
    func discardDetailCache() -> Bool {
        do {
            try database.writer.write { db in
                try db.execute(sql: "DELETE FROM seriesDetail")
            }
            return true
        } catch {
            let description = String(describing: error)
            Self.cacheLogger.error("discardDetailCache failed: \(description, privacy: .public)")
            return false
        }
    }

    /// What is on disk for one feed: its rows, when they were written, and
    /// the `Last-Modified` they were written under.
    ///
    /// A struct rather than a 3-member tuple (the lint's own cap) — `cachedAt`
    /// is what lets a stale screen say "last updated 19 hours ago" rather
    /// than the bare fact that a refresh failed; `lastModified` is what lets
    /// a stale-but-present cache be revalidated with a conditional request
    /// instead of a full re-download — see `SeriesRepository.feed`.
    struct CachedFeed {
        var series: [Series] = []
        var cachedAt: Date?
        var lastModified: String?
    }

    func readCacheWithDate(
        _ feed: FeedKind,
        requireFresh: Bool
    ) throws -> CachedFeed {
        try database.writer.read { db in
            let metadata = try FeedMetadata
                .filter(Column("feedKey") == feed.cacheKey)
                .fetchOne(db)

            if requireFresh {
                guard let metadata else { return CachedFeed() }

                let age = clock.now.timeIntervalSince(metadata.cachedAt)
                // A negative age means the device clock moved backwards; treat
                // that as stale rather than trusting it.
                guard age >= 0, age < feed.freshness else { return CachedFeed() }
            }

            let entries = try FeedEntry
                .filter(Column("feedKey") == feed.cacheKey)
                .order(Column("position"))
                .fetchAll(db)
            guard !entries.isEmpty else {
                return CachedFeed(cachedAt: metadata?.cachedAt, lastModified: metadata?.lastModified)
            }

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
            return CachedFeed(
                series: series, cachedAt: metadata?.cachedAt, lastModified: metadata?.lastModified
            )
        }
    }

    func write(_ series: [Series], for feed: FeedKind, lastModified: String? = nil) throws {
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
            try FeedMetadata(feedKey: feed.cacheKey, cachedAt: now, lastModified: lastModified).save(db)
            try Self.trimOrphans(db)
        }
    }

    /// Fetches a feed conditionally and collapses its two response shapes
    /// into one `Conditional<[Series]>`: `isRecommendationShaped` endpoints
    /// wrap each series in a recommendation envelope, the rest return series
    /// directly.
    ///
    /// Split out of `SeriesRepository.feed` only for the lint's line-count
    /// ceiling on that type's body — this is still feed-fetching, not
    /// cache-reading, but every other seam in this actor was already claimed
    /// by a more specific split (`+Paging`, `+Count`).
    func fetchConditionalFeed(
        _ feed: FeedKind,
        query: [URLQueryItem],
        ifModifiedSince: String?,
        priority: RequestPriority = .userInitiated
    ) async throws(APIError) -> APIClient.Conditional<[Series]> {
        guard feed.isRecommendationShaped else {
            return try await client.getLossyConditional(
                feed.path, query: query, priority: priority,
                ifModifiedSince: ifModifiedSince, as: Series.self
            )
        }
        let wrapped: APIClient.Conditional<[Recommendation]> = try await client.getLossyConditional(
            feed.path, query: query, priority: priority,
            ifModifiedSince: ifModifiedSince, as: Recommendation.self
        )
        switch wrapped {
        case .notModified:
            return .notModified
        case let .fresh(recommendations, lastModified):
            return .fresh(recommendations.map(\.series), lastModified: lastModified)
        }
    }

    /// Resets a feed's freshness clock without touching a single row.
    ///
    /// The whole point of a 304: the server has just confirmed the rows on
    /// disk are still exactly right, so there is nothing to re-encode or
    /// reorder — only `cachedAt` needed moving forward so the next visit
    /// reads as fresh again instead of immediately trying to revalidate a
    /// second time.
    func touchFeedMetadata(_ feed: FeedKind) throws {
        let now = clock.now
        try database.writer.write { db in
            guard let existing = try FeedMetadata
                .filter(Column("feedKey") == feed.cacheKey)
                .fetchOne(db)
            else { return }
            try FeedMetadata(
                feedKey: feed.cacheKey,
                cachedAt: now,
                lastModified: existing.lastModified
            ).save(db)
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

    /// The detail cache keeps the newest rows only; nothing else bounds the
    /// table.
    ///
    /// The "about 300 KB a page" this was sized against carried no
    /// derivation. MEASURED 2026-09-14 against the real simulator file: the
    /// median encoded `seriesDetail` payload is 204 KB, so 200 rows is about
    /// 40 MB, not the 60 MB the old figure implied. The limit is left at 200
    /// — the correction makes it cheaper than believed, not more expensive,
    /// so there is nothing to act on; the number is recorded so the next
    /// person sizing this starts from a measurement.
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
