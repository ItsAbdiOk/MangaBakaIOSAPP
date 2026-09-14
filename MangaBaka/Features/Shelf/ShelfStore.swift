import Foundation
import GRDB

/// The reader's saves and skips, held on device.
///
/// Separate from the feed cache on purpose: a cached feed is disposable and
/// refetchable, a save is not. Clearing the cache must never lose what someone
/// chose to keep.
actor ShelfStore {
    /// Writes to `libraryWriter`'s file: a save is the one thing in this app
    /// that exists nowhere else (Q10).
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

    func record(_ series: Series, as kind: ShelfEntry.Kind) throws {
        let payload = try encoder.encode(series)
        try database.libraryWriter.write { db in
            try ShelfEntry(
                seriesId: series.id,
                kind: kind.rawValue,
                addedAt: clock.now,
                payload: payload
            ).save(db)
        }
    }

    func remove(seriesId: Int) throws {
        _ = try database.libraryWriter.write { db in
            try ShelfEntry.deleteOne(db, key: seriesId)
        }
    }

    /// - Returns: the decodable rows, and how many of the shelf's own rows
    ///   could not be decoded. `compactMap` used to drop those silently, so a
    ///   shelf whose disk cache held one row in a shape this version no
    ///   longer understands reported itself one entry shorter with nothing to
    ///   say why (gap 116, FAILURES-SUMMARY.md). Every existing caller that
    ///   only wants the series can take `.series` and see no change.
    func entries(_ kind: ShelfEntry.Kind) throws -> (series: [Series], undecodable: Int) {
        try database.libraryWriter.read { db in
            let rows = try ShelfEntry
                .filter(Column("kind") == kind.rawValue)
                .order(Column("addedAt").desc)
                .fetchAll(db)
            var series: [Series] = []
            series.reserveCapacity(rows.count)
            var undecodable = 0
            for row in rows {
                if let decoded = try? decoder.decode(Series.self, from: row.payload) {
                    series.append(decoded)
                } else {
                    undecodable += 1
                }
            }
            return (series, undecodable)
        }
    }

    /// Forgets every save and skip.
    ///
    /// Only the local shelf. A save also wrote `plan_to_read` to the reader's
    /// MangaBaka library, and this deliberately does not touch that: deleting
    /// entries from someone's real account to undo a swipe would be a much
    /// larger action than the one they asked for, and the Library tab is where
    /// account entries are removed.
    func clear() throws {
        _ = try database.libraryWriter.write { db in
            try ShelfEntry.deleteAll(db)
        }
    }

    /// IDs the reader has already reacted to, so the stack stops showing them.
    func reactedIDs() throws -> Set<Int> {
        try database.libraryWriter.read { db in
            Set(try Int.fetchAll(db, sql: "SELECT seriesId FROM shelfEntry"))
        }
    }

    /// How many reactions fall in `[from, to)`.
    ///
    /// Counted in SQL rather than by fetching every timestamp the reader has
    /// ever produced and filtering in Swift (work-list 80). That read was
    /// unbounded and grew with every swipe, and it ran on every switch back
    /// to the Stack tab — before the tab had decided whether it needed
    /// anything at all. The window is passed in because "today" is the
    /// device's local calendar day, which is `StackModel`'s to define; see
    /// `StackModel.countToday`, still the pure rule the tests hold.
    func reactionCount(from: Date, to: Date) throws -> Int {
        try database.libraryWriter.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM shelfEntry WHERE addedAt >= ? AND addedAt < ?",
                arguments: [from, to]
            ) ?? 0
        }
    }

    /// The most recently reacted-to series, newest first, capped at `limit`.
    ///
    /// For `StackModel`'s profile-exclusion list, which travels in the URL
    /// and so is capped at a fixed size (L4). That code used to take
    /// `reactedIDs().sorted().suffix(60)` — the sixty numerically *largest*
    /// series ids, which are the sixty most recently *catalogued* things the
    /// reader ever swiped, not the sixty most recently *swiped*, because
    /// series ids ascend with catalogue time, not with when this reader
    /// reacted. `addedAt` is this device's own clock at the moment of the
    /// swipe (`record`, above), so ordering by it is ordering by an actual
    /// swipe time.
    func recentlyReactedIDs(limit: Int) throws -> [Int] {
        try database.libraryWriter.read { db in
            try Int.fetchAll(
                db,
                sql: "SELECT seriesId FROM shelfEntry ORDER BY addedAt DESC LIMIT ?",
                arguments: [limit]
            )
        }
    }
}
