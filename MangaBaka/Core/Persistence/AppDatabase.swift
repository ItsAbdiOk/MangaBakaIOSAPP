import Foundation
import GRDB

/// The on-device cache.
///
/// This is a file on the user's own device, not a server. Nothing here leaves
/// the phone, and the developer has no access to it. Its only job is to avoid
/// re-downloading what the app already has, and to let previously-seen content
/// render offline.
///
/// Series are stored as an encoded JSON blob rather than as columns, so that
/// adding a field to `Series` needs no schema migration — the cache is derived
/// data with a one-day lifetime, and anything missing is simply refetched.
///
/// To be precise about what this does NOT do: the blob is a re-encoding of the
/// decoded `Series`, so fields the app does not model are dropped, not
/// preserved. That is acceptable precisely because the cache is disposable; a
/// newer app version refetches and gets the richer response. Do not rely on
/// reading unmodelled fields back out of an old cache.
struct AppDatabase: Sendable {
    let writer: any DatabaseWriter

    init(writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    /// On-disk database in Application Support.
    static func onDisk(named name: String = "mangabaka.sqlite") throws -> AppDatabase {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let url = directory.appendingPathComponent(name)

        var configuration = Configuration()
        // The cache is derived data: if the file is ever corrupt, losing it
        // costs a re-download, not user data.
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
        }
        return try AppDatabase(writer: try DatabasePool(path: url.path, configuration: configuration))
    }

    /// In-memory database, for tests and previews.
    static func inMemory() throws -> AppDatabase {
        try AppDatabase(writer: try DatabaseQueue())
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_cache") { db in
            // One row per series, keyed by MangaBaka's own ID.
            try db.create(table: "series") { table in
                table.primaryKey("id", .integer)
                table.column("payload", .blob).notNull()
                table.column("cachedAt", .datetime).notNull()
            }

            // An ordered feed (rising, hidden gems, a rabbit-hole list...).
            // `position` preserves the order the API returned, which carries
            // real editorial meaning and must not be re-sorted client-side.
            try db.create(table: "feedEntry") { table in
                table.column("feedKey", .text).notNull()
                table.column("position", .integer).notNull()
                table.column("seriesId", .integer).notNull()
                table.primaryKey(["feedKey", "position"])
            }
            try db.create(index: "feedEntry_on_feedKey", on: "feedEntry", columns: ["feedKey"])

            // When each feed was last fetched, so freshness is per feed rather
            // than per series.
            try db.create(table: "feedMetadata") { table in
                table.primaryKey("feedKey", .text)
                table.column("cachedAt", .datetime).notNull()
            }
        }

        migrator.registerMigration("v2_shelf") { db in
            // The reader's own reactions, local until sign-in exists. Kept in
            // its own table rather than as a column on `series` because a
            // cached series is disposable and a save is not: clearing the cache
            // must never lose what someone chose to keep.
            try db.create(table: "shelfEntry") { table in
                table.primaryKey("seriesId", .integer)
                // "saved" or "skipped". A skip is recorded, not discarded, so
                // the same series stops reappearing in the stack and can still
                // be recovered.
                table.column("kind", .text).notNull()
                table.column("addedAt", .datetime).notNull()
                // The series as it was when saved, so the shelf still renders
                // when the cache has been cleared or the reader is offline.
                table.column("payload", .blob).notNull()
            }
            try db.create(index: "shelfEntry_on_kind", on: "shelfEntry", columns: ["kind", "addedAt"])
        }

        return migrator
    }
}
