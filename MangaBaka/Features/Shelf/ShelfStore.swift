import Foundation
import GRDB

/// The reader's saves and skips, held on device.
///
/// Separate from the feed cache on purpose: a cached feed is disposable and
/// refetchable, a save is not. Clearing the cache must never lose what someone
/// chose to keep.
actor ShelfStore {
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
        try database.writer.write { db in
            try ShelfEntry(
                seriesId: series.id,
                kind: kind.rawValue,
                addedAt: clock.now,
                payload: payload
            ).save(db)
        }
    }

    func remove(seriesId: Int) throws {
        _ = try database.writer.write { db in
            try ShelfEntry.deleteOne(db, key: seriesId)
        }
    }

    func entries(_ kind: ShelfEntry.Kind) throws -> [Series] {
        try database.writer.read { db in
            try ShelfEntry
                .filter(Column("kind") == kind.rawValue)
                .order(Column("addedAt").desc)
                .fetchAll(db)
                .compactMap { try? decoder.decode(Series.self, from: $0.payload) }
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
        _ = try database.writer.write { db in
            try ShelfEntry.deleteAll(db)
        }
    }

    /// IDs the reader has already reacted to, so the stack stops showing them.
    func reactedIDs() throws -> Set<Int> {
        try database.writer.read { db in
            Set(try Int.fetchAll(db, sql: "SELECT seriesId FROM shelfEntry"))
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
        try database.writer.read { db in
            try Int.fetchAll(
                db,
                sql: "SELECT seriesId FROM shelfEntry ORDER BY addedAt DESC LIMIT ?",
                arguments: [limit]
            )
        }
    }
}
