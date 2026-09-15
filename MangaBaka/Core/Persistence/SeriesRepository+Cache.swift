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
        try Signposts.measure("Detail cache read") {
            try database.cacheWriter.read { db in
                guard let row = try CachedDetail.fetchOne(db, key: seriesId) else { return nil }
                let age = clock.now.timeIntervalSince(row.cachedAt)
                // A negative age means the device clock moved backwards; treat
                // that as stale rather than trusting it.
                guard age >= 0, age < Self.detailFreshness else { return nil }
                do {
                    return try JSONDecoder().decode(SeriesExtras.self, from: row.payload)
                } catch {
                    // PS3: synthesized `Decodable` does not honour a stored
                    // property's default value — a missing key throws
                    // `keyNotFound`, not "use the default". Every row cached
                    // before a later `SeriesExtras` field existed then fails
                    // here, invisibly, once per build that adds one
                    // (`richTags`, `editions`, `volumes`, `worksTotal` each
                    // did this after v6). Logged so the shape that tripped it
                    // is on record; still a miss either way — the caller
                    // refetches exactly as it did before. The real fix is a
                    // hand-written `SeriesExtras.init(from:)` using
                    // `decodeIfPresent` with the type's own defaults, which
                    // lives in `Core/Model` and is reported, not made here.
                    Self.cacheLogger.error("""
                        detail cache decode failed for series \(seriesId, privacy: .public): \
                        \(String(describing: error), privacy: .public)
                        """)
                    return nil
                }
            }
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
        await cachedExtrasField(for: ids, as: CachedLinks.self).mapValues(\.links)
    }

    /// The `volumes` of every cached series page among `ids`, in one read —
    /// the Next-volume widget's snapshot asks this for the whole library at
    /// launch, and per-entry `cachedExtras` would be the 939 hops above again.
    func cachedExtrasVolumes(for ids: [Int]) async -> [Int: [SeriesWork.Volume]] {
        await cachedExtrasField(for: ids, as: CachedVolumes.self).mapValues(\.volumes)
    }

    /// One `WHERE seriesId IN (…)` read and one partial decode per row, for
    /// whichever single key `Field` names.
    private func cachedExtrasField<Field: Decodable>(for ids: [Int], as _: Field.Type) async -> [Int: Field] {
        guard !ids.isEmpty else { return [:] }
        // `await`: in an async context GRDB's asynchronous `read` is the one
        // that binds, and it is the right one — the synchronous overload
        // would block this actor's thread on SQLite.
        let rows: [CachedDetail]
        do {
            rows = try await database.cacheWriter.read { db in
                try CachedDetail.filter(ids.contains(Column("seriesId"))).fetchAll(db)
            }
        } catch {
            // D1: this used to be `try?` → `[]`, which reads exactly like
            // "nothing cached for any of these ids". The caller behind
            // `cachedExtrasLinks` (`refreshReminders`) then sees no links for
            // the whole library and schedules nothing, with no record of why.
            Self.cacheLogger.error("""
                cachedExtrasField read failed: \(String(describing: error), privacy: .public)
                """)
            rows = []
        }
        let now = clock.now
        var fields: [Int: Field] = [:]
        for row in rows {
            // Same freshness rule as `readDetailCache`, including the
            // backwards-clock case, so the two cannot drift apart.
            let age = now.timeIntervalSince(row.cachedAt)
            guard age >= 0, age < Self.detailFreshness else { continue }
            do {
                fields[row.seriesId] = try JSONDecoder().decode(Field.self, from: row.payload)
            } catch {
                // PS3, same shape as `readDetailCache`: a shape change wipes
                // this partial read too. Logged, still a miss.
                Self.cacheLogger.error("""
                    detail cache field decode failed for series \(row.seriesId, privacy: .public): \
                    \(String(describing: error), privacy: .public)
                    """)
            }
        }
        return fields
    }

    /// Just the `links` key of an encoded `SeriesExtras`, so reading the links
    /// of a whole library does not decode a whole library of series pages.
    /// `SeriesExtras` always encodes the key, so no `decodeIfPresent`.
    private struct CachedLinks: Decodable {
        var links: [SeriesLink] = []
    }

    /// Just the `volumes` key, same reasoning.
    private struct CachedVolumes: Decodable {
        var volumes: [SeriesWork.Volume] = []
    }

    func writeDetailCache(_ extras: SeriesExtras, for seriesId: Int) throws {
        let payload = try JSONEncoder().encode(extras)
        try database.cacheWriter.write { db in
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
        /// The six-hour series-page cache. Holds the *unfiltered* record —
        /// the page applies the rating at display time — so no filter
        /// change invalidates it (review perf PS1, 2026-09-15); only a
        /// token change (`forgetProfile`) and the row limit clear it.
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

    static let cacheLogger = Logger(subsystem: "dev.abdirahmanmohamed.mangabaka", category: "cache")

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
            try database.cacheWriter.write { db in
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
            try database.cacheWriter.write { db in
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
        var notes: [Int: RecommendationNote] = [:]
        var cachedAt: Date?
        var lastModified: String?
    }

    /// PS10: this used to take a `requireFresh` flag with a whole branch for
    /// `true`. Its only production caller (`SeriesRepository.feed`) has
    /// passed `false` since the freshness check moved into `feed` itself
    /// ("Read once, not twice"), and no test passed `true` either — so the
    /// branch could only ever be reached by a caller nobody has written.
    /// Deleted along with the parameter rather than left as a dead option a
    /// future caller might reach for and get the double-read `feed`'s own
    /// comment explains was the bug.
    func readCacheWithDate(_ feed: FeedKind) throws -> CachedFeed {
        try Signposts.measure("Feed cache read") {
            try database.cacheWriter.read { db in
                let metadata = try FeedMetadata
                    .filter(Column("feedKey") == feed.cacheKey)
                    .fetchOne(db)

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
                // A note that no longer decodes is dropped alone — a caption,
                // not a row, so it is not the whole-read miss a series row is.
                var notes: [Int: RecommendationNote] = [:]
                for entry in entries {
                    guard let data = entry.note,
                          let note = try? JSONDecoder().decode(RecommendationNote.self, from: data)
                    else { continue }
                    notes[entry.seriesId] = note
                }
                return CachedFeed(
                    series: series, notes: notes,
                    cachedAt: metadata?.cachedAt, lastModified: metadata?.lastModified
                )
            }
        }
    }

    func write(
        _ series: [Series], for feed: FeedKind, lastModified: String? = nil,
        notes: [Int: RecommendationNote] = [:]
    ) throws {
        let now = clock.now
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        // Plain JSON, not snake-cased: the note is this app's own type and
        // is read back with a plain decoder in `readCacheWithDate`.
        let noteEncoder = JSONEncoder()

        try Signposts.measure("Feed cache write") {
            try database.cacheWriter.write { db in
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
                    let note = try notes[item.id].map { try noteEncoder.encode($0) }
                    try FeedEntry(feedKey: feed.cacheKey, position: index, seriesId: item.id, note: note)
                        .insert(db)
                }
                try FeedMetadata(feedKey: feed.cacheKey, cachedAt: now, lastModified: lastModified).save(db)
                // PS2: nothing ever aged out a per-series feed
                // (`series/{id}/similar`, `series/{id}/readers-also-like`) —
                // `trimOrphans` below only drops a `series` row no feed
                // points at any more, and replacing *this* feed never
                // touches any *other* series' feed rows. Every series page
                // ever opened therefore left up to 48 `feedEntry` rows (and
                // whatever `series` rows only they pointed at) on disk
                // forever. Run on every write, not only on a series-page
                // write, because that is also every call site there is.
                try Self.trimSeriesFeeds(db, olderThan: now.addingTimeInterval(-Self.seriesFeedRetention))
                try Self.trimOrphans(db)
            }
        }
    }

    /// How long a per-series feed is kept once it stops being the freshest
    /// thing written under its own key.
    ///
    /// **A guess.** Longer than the endpoint's own 24 h freshness
    /// (`FeedKind.freshness` for `.similar`/`.readersAlsoLike`), so a reader
    /// who reopens a series inside a week never notices the sweep; what
    /// would settle the number instead is `SELECT COUNT(*), SUM(LENGTH(
    /// payload)) FROM series` and `SELECT COUNT(DISTINCT feedKey) FROM
    /// feedMetadata` against a real device file — nobody has run those yet
    /// (persistence.md P2, "could not determine").
    private static let seriesFeedRetention: TimeInterval = 7 * 24 * 60 * 60

    /// Ages out `series/{id}/similar` and `series/{id}/readers-also-like`
    /// feeds once they are older than `cutoff`. `trimOrphans` then reclaims
    /// whatever `series` rows only those feeds were still pointing at.
    ///
    /// A `feedEntry_on_seriesId` index (`v16_feedEntrySeriesIndex`) is what
    /// keeps `trimOrphans`' `NOT IN (SELECT seriesId FROM feedEntry)` from
    /// building a temp b-tree over the whole table on every call — including
    /// every `.surprise` deal, which writes here at freshness 0. This
    /// function's own two deletes are by `feedKey`, `feedEntry`'s leading
    /// primary-key column, so they need no index of their own.
    static func trimSeriesFeeds(_ db: Database, olderThan cutoff: Date) throws {
        try db.execute(sql: """
            DELETE FROM feedEntry WHERE feedKey IN (
                SELECT feedKey FROM feedMetadata
                WHERE (feedKey LIKE 'series/%/similar' OR feedKey LIKE 'series/%/readers-also-like')
                  AND cachedAt < ?
            )
            """, arguments: [cutoff])
        try db.execute(sql: """
            DELETE FROM feedMetadata
            WHERE (feedKey LIKE 'series/%/similar' OR feedKey LIKE 'series/%/readers-also-like')
              AND cachedAt < ?
            """, arguments: [cutoff])
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
    ///
    /// The recommendation envelope's caption survives as `FeedPage.notes`
    /// (2026-09-15): it used to be dropped here, so the series page's
    /// "Similar" and "Readers also like" rows could not say "10 shared tags"
    /// or "86 readers" the way the website does.
    func fetchConditionalFeed(
        _ feed: FeedKind,
        query: [URLQueryItem],
        ifModifiedSince: String?,
        priority: RequestPriority = .userInitiated
    ) async throws(APIError) -> APIClient.Conditional<FeedPage> {
        guard feed.isRecommendationShaped else {
            let plain: APIClient.Conditional<[Series]> = try await client.getLossyConditional(
                feed.path, query: query, priority: priority,
                ifModifiedSince: ifModifiedSince, as: Series.self
            )
            switch plain {
            case .notModified: return .notModified
            case let .fresh(series, lastModified):
                return .fresh(FeedPage(series: series), lastModified: lastModified)
            }
        }
        let wrapped: APIClient.Conditional<[Recommendation]> = try await client.getLossyConditional(
            feed.path, query: query, priority: priority,
            ifModifiedSince: ifModifiedSince, as: Recommendation.self
        )
        switch wrapped {
        case .notModified:
            return .notModified
        case let .fresh(recommendations, lastModified):
            var notes: [Int: RecommendationNote] = [:]
            for recommendation in recommendations { notes[recommendation.series.id] = recommendation.note }
            return .fresh(
                FeedPage(series: recommendations.map(\.series), notes: notes), lastModified: lastModified
            )
        }
    }

    /// One page of a feed off the wire: the series, and the caption each
    /// came with where the feed had one.
    struct FeedPage: Sendable {
        var series: [Series]
        var notes: [Int: RecommendationNote] = [:]
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
        try database.cacheWriter.write { db in
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
    ///
    /// PS2: this runs on every write, including every `.surprise` deal
    /// (freshness 0), and the `NOT IN` subquery used to build a temp b-tree
    /// over the whole of `feedEntry` on each call — no index existed on
    /// `feedEntry.seriesId` (its primary key is `(feedKey, position)`, which
    /// does not help a lookup keyed the other way). `v16_feedEntrySeriesIndex`
    /// adds one. Actual row counts on a real device file are still
    /// undetermined — nothing here can compute `SUM(LENGTH(payload))` from
    /// the code alone — so that half of P2 remains open; see `SELECT
    /// COUNT(*), SUM(LENGTH(payload)) FROM series` in persistence.md.
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
