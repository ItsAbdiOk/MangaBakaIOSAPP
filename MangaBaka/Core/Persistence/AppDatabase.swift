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

        migrator.registerMigration("v3_cadence") { db in
            // One row per series we have asked MangaUpdates about.
            //
            // A row exists as soon as the question has been ASKED, whether or
            // not it produced an answer. That distinction is the whole point:
            // a null cadence with a timestamp is a settled result ("too few
            // dated releases to estimate from"), not a gap waiting to be
            // filled. Keying "have we looked at this?" off the cadence instead
            // of the timestamp made the reference implementation re-fetch the
            // same works on every build and report "8 still to do" forever.
            try db.create(table: "cadenceEntry") { table in
                table.primaryKey("seriesId", .integer)
                // The estimate, JSON-encoded. Null when the series has too
                // little release history to estimate from.
                table.column("payload", .blob)
                table.column("fetchedAt", .datetime).notNull()
                // Set when the fetch itself failed, so the next build retries
                // it rather than treating the silence as an answer.
                table.column("failure", .text)
            }
        }

        migrator.registerMigration("v4_history") { db in
            // What the reader has opened. Its own table rather than a column on
            // `series`, because the cache is disposable and this is not —
            // clearing the cache must not erase the history, and erasing the
            // history must not cost a re-download.
            try db.create(table: "viewedEntry") { table in
                table.primaryKey("seriesId", .integer)
                table.column("viewedAt", .datetime).notNull()
                // The series as it was when opened, so the row renders offline
                // and after a cache clear.
                table.column("payload", .blob).notNull()
            }
            try db.create(index: "viewedEntry_on_viewedAt", on: "viewedEntry", columns: ["viewedAt"])
        }

        migrator.registerMigration("v5_taste") { db in
            // How much each tag runs through the reader's own library.
            //
            // Counted locally rather than asked for, because the API's taste
            // endpoint answers in GENRES — six of Solo Leveling's 146 tags are
            // genres — so it can never say "you read a lot of Regression".
            try db.create(table: "tagAffinity") { table in
                table.primaryKey("tagId", .integer)
                // Kept for diagnosis: a score with no name is unreadable when
                // something looks wrong.
                table.column("name", .text).notNull()
                // Tag weight times reading state, summed across the library.
                table.column("score", .double).notNull()
                // How many of the reader's series carry it. A tag that appears
                // once is a coincidence; the same tag in five is a habit.
                table.column("seriesCount", .integer).notNull()
            }

            // Which series have already been counted, so re-reading a library
            // page does not count the same tags twice. The count is a running
            // total, so double-counting is silent and permanent without this.
            try db.create(table: "tasteSource") { table in
                table.primaryKey("seriesId", .integer)
                table.column("countedAt", .datetime).notNull()
                // The state it was counted under. A series moved from reading
                // to dropped has to be recounted at its new weight.
                table.column("state", .text).notNull()
            }
        }

        migrator.registerMigration("v6_seriesDetail") { db in
            // A series page costs eight requests and cached none of them, so
            // opening the same series twice cost sixteen. Measured: about
            // 300 KB a visit.
            //
            // Its own table rather than a column on `series`, because that row
            // is a feed's copy of a series and this is everything hanging off
            // it — and the two go stale on different clocks.
            try db.create(table: "seriesDetail") { table in
                table.primaryKey("seriesId", .integer)
                table.column("payload", .blob).notNull()
                table.column("cachedAt", .datetime).notNull()
            }
        }

        migrator.registerMigration("v7_libraryCache") { db in
            // The reader's own library, on disk.
            //
            // Measured on a real account: 939 entries, thirteen requests,
            // 24.7 MB — thirty times everything else the app fetches put
            // together. Paying that on every launch is indefensible on a
            // cellular connection, and it is the same answer every time.
            try db.create(table: "libraryEntry") { table in
                table.primaryKey("seriesId", .integer)
                table.column("payload", .blob).notNull()
            }
            // One row, holding when the whole walk finished. Per-entry
            // timestamps would let a half-written library look fresh.
            try db.create(table: "libraryMetadata") { table in
                table.primaryKey("id", .integer)
                table.column("cachedAt", .datetime).notNull()
                table.column("isComplete", .boolean).notNull()
            }
        }

        migrator.registerMigration("v8_tasteSeen") { db in
            // Every series the ledger was offered, tagged or not. The
            // "counted but no tags known" diagnostic in Settings was built to
            // catch a library payload with no tags — and a series with no tags
            // was never counted, so the diagnostic could not fire. This is the
            // count it needs: offered, as against counted.
            try db.create(table: "tasteSeen") { table in
                table.primaryKey("seriesId", .integer)
            }
        }

        return migrator
    }
}
