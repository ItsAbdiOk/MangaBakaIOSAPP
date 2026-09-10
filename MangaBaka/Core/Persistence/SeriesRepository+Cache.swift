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
            let series = entries
                .compactMap { entry -> Series? in
                    guard let row = byID[entry.seriesId] else { return nil }
                    return try? decoder.decode(Series.self, from: row.payload)
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
        }
    }
}
