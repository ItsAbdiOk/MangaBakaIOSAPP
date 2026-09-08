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

    /// IDs the reader has already reacted to, so the stack stops showing them.
    func reactedIDs() throws -> Set<Int> {
        try database.writer.read { db in
            Set(try Int.fetchAll(db, sql: "SELECT seriesId FROM shelfEntry"))
        }
    }
}
