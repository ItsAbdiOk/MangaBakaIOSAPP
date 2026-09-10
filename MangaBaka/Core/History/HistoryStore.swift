import Foundation
import GRDB

/// What the reader has opened, on this device and nowhere else.
///
/// MangaBaka has no "recently viewed" endpoint — their homepage's "Recently
/// Added" is new releases, which this app already shows — so the only way to
/// answer *what was I just looking at?* is to remember it here.
///
/// **This is a reading-history log, and it is treated as one.** It is written
/// to the same on-device SQLite file as everything else, it is never sent
/// anywhere, and Settings can erase it in one tap. Abdi asked for it
/// deliberately on 2026-09-10 after being told exactly that.
///
/// Stored with a copy of the series, like `ShelfStore` and for the same reason:
/// the feed cache is disposable and this is not, so clearing the cache or
/// going offline must not empty the row.
actor HistoryStore {
    /// How many are kept.
    ///
    /// Twenty is roughly a week of ordinary use and about three screens of a
    /// horizontal row. Beyond that it stops being "what was I just looking at"
    /// and becomes an archive nobody asked for — and an archive is a bigger
    /// thing to hold on someone's behalf than a short list.
    static let limit = 20

    private let database: AppDatabase
    private let clock: any Clock
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(database: AppDatabase, clock: any Clock = SystemClock()) {
        self.database = database
        self.clock = clock
        encoder.keyEncodingStrategy = .convertToSnakeCase
        decoder.keyDecodingStrategy = .convertFromSnakeCase
    }

    /// Notes that the reader opened this series, and forgets the oldest if that
    /// pushes the list past `limit`.
    ///
    /// Re-opening a series moves it to the front rather than adding a second
    /// entry: the primary key is the series, so `save` overwrites the timestamp.
    /// A list that showed the same series four times would be a worse answer to
    /// "what was I just looking at" than one that shows it once.
    func record(_ series: Series) throws {
        let payload = try encoder.encode(series)
        try database.writer.write { db in
            try ViewedEntry(
                seriesId: series.id,
                viewedAt: clock.now,
                payload: payload
            ).save(db)
            try Self.trim(db)
        }
    }

    /// Most recent first, filtered by what the reader currently allows.
    ///
    /// The filter is applied on read rather than on write on purpose. Someone
    /// who turns Explicit off expects it gone from everywhere immediately,
    /// including from a list of what they had already opened — the same mistake
    /// that once left cached feeds showing exactly what a reader had just
    /// excluded. Passing nil means no filter, for callers that have none.
    func entries(allowedRatings: [String]? = nil) throws -> [Series] {
        let series = try database.writer.read { db in
            try ViewedEntry
                // seriesId only breaks a tie between two identical timestamps,
                // so the order is stable rather than whatever SQLite returns.
                .order(Column("viewedAt").desc, Column("seriesId").desc)
                .fetchAll(db)
                .compactMap { try? decoder.decode(Series.self, from: $0.payload) }
        }
        guard let allowedRatings else { return series }
        return series.filter { entry in
            guard let rating = entry.contentRating else { return true }
            return allowedRatings.contains(rating)
        }
    }

    /// Erases the history. Nothing else — a series the reader also saved stays
    /// saved, because forgetting that you looked at something is not the same
    /// as un-saving it.
    func clear() throws {
        _ = try database.writer.write { db in
            try ViewedEntry.deleteAll(db)
        }
    }

    /// How many are held, for Settings to say what clearing would remove.
    func count() throws -> Int {
        try database.writer.read { db in
            try ViewedEntry.fetchCount(db)
        }
    }

    /// Keeps the newest `limit` rows and deletes the rest.
    private static func trim(_ db: Database) throws {
        try db.execute(sql: """
            DELETE FROM viewedEntry WHERE seriesId NOT IN (
                SELECT seriesId FROM viewedEntry
                ORDER BY viewedAt DESC, seriesId DESC LIMIT \(limit)
            )
            """)
    }
}
