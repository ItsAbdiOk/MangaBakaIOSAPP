import Foundation
import GRDB

/// The on-device cache.
///
/// This is a file on the user's own device, not a server. Nothing here leaves
/// the phone, and the developer has no access to it. Its main job is to avoid
/// re-downloading what the app already has, and to let previously-seen content
/// render offline.
///
/// **Not all of it is disposable.** `shelfEntry` (the reader's saves and
/// skips), `viewedEntry` (their history) and `tagAffinity`/`tasteContribution`
/// (the taste ledger those two feed) exist nowhere else — there is no account
/// they sync to. Losing this file loses them. Two comments in here used to
/// call the whole thing "disposable cache data", and
/// `onDiskResettingIfCorrupt` renamed it aside on any failure at all on the
/// strength of that; see its doc comment.
///
/// Series are stored as an encoded JSON blob rather than as columns, so that
/// adding a field to `Series` needs no schema migration — the cache is derived
/// data and anything missing is simply refetched. (This once claimed a
/// one-day lifetime. There was none: feed rows turn over when their feed is
/// refetched, on freshness windows from zero to six hours per feed, and
/// orphaned rows are trimmed on every write; the detail cache is aged at six
/// hours and capped by row count.)
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
        // WAL so a read does not block the writer. (This comment used to say
        // "the cache is derived data: if the file is ever corrupt, losing it
        // costs a re-download, not user data" — untrue, and it was the stated
        // justification for renaming the file aside on any failure. The shelf
        // and the history live here and are not derived from anything.)
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
        }
        return try AppDatabase(writer: try DatabasePool(path: url.path, configuration: configuration))
    }

    /// In-memory database, for tests and previews.
    static func inMemory() throws -> AppDatabase {
        try AppDatabase(writer: try DatabaseQueue())
    }

    /// What opening the on-disk database actually did.
    struct OpenResult: Sendable {
        /// The three answers, which used to be two.
        ///
        /// `wasReset: Bool` collapsed "the file was corrupt and has been
        /// replaced" with "the file could not be opened and this is an
        /// in-memory stand-in" (`AppServices.swift:181` reported `true` for
        /// the latter). They need different words in front of a reader: the
        /// first has genuinely lost what was in the file, the second has lost
        /// nothing — the file is sitting there intact and the next launch may
        /// well open it.
        enum Outcome: Sendable, Equatable {
            /// The file on disk opened and migrated.
            case opened
            /// The file was corrupt, was renamed aside, and this is a new one.
            case reset
            /// No on-disk database could be opened at all; whatever is here
            /// remembers nothing between launches. The file, if there is one,
            /// has been left alone.
            case unopened
        }

        let database: AppDatabase
        let outcome: Outcome

        /// True only for `.reset`. `AppServices.makeDatabase` uses this to
        /// show a one-shot toast — gap 3: without it, a corrupt file fell
        /// back to an in-memory database *silently*, on every single launch,
        /// which read to the reader as "the app forgets my stack every day"
        /// with no explanation and no way to notice why.
        ///
        /// Kept while the shell moves to `outcome`; it is the narrower of the
        /// two old meanings, so a caller that has not moved yet stops
        /// claiming a reset for the in-memory case rather than starting to.
        var wasReset: Bool { outcome == .reset }

        init(database: AppDatabase, outcome: Outcome) {
            self.database = database
            self.outcome = outcome
        }

        init(database: AppDatabase, wasReset: Bool) {
            self.init(database: database, outcome: wasReset ? .reset : .opened)
        }
    }

    /// Opens the on-disk database, recovering from a file that exists but
    /// cannot be opened or migrated — corruption, a schema from a future
    /// version this build cannot read — by renaming it aside and starting
    /// fresh, rather than leaving that to `onDisk`'s caller to fall back to
    /// an in-memory database (which remembers nothing between launches) with
    /// no attempt to recover the on-disk path at all.
    ///
    /// The bad file is renamed, not deleted. Renaming rather than deleting
    /// leaves the actual bytes on disk for on-device diagnosis, which a
    /// `DELETE` would throw away permanently for no benefit over a rename.
    ///
    /// **Only actual corruption renames.** This used to rename for *any*
    /// throw out of `onDisk`, and the file holds `shelfEntry`, `viewedEntry`
    /// and `tagAffinity` — the reader's own saves, their history and the
    /// taste ledger, none of which the app can rebuild from the network. So
    /// a disk-full `ALTER TABLE` in a migration, a `SQLITE_BUSY` left by the
    /// previous process, or a bug in a future migration destroyed the shelf
    /// permanently and told the reader it "was reset". Every one of those is
    /// transient or fixable and none of them means the bytes are bad. Only
    /// `SQLITE_CORRUPT` and `SQLITE_NOTADB` do, and only those rename; any
    /// other failure returns nil with the file untouched, so the next launch
    /// can open it.
    ///
    /// Returns `nil` when the file was left alone, or when even a fresh file
    /// at the same path cannot be opened — at which point the caller's own
    /// in-memory fallback is what runs.
    static func onDiskResettingIfCorrupt(
        named name: String = "mangabaka.sqlite",
        now: () -> Date = Date.init
    ) -> OpenResult? {
        do {
            return OpenResult(database: try onDisk(named: name), outcome: .opened)
        } catch let error {
            guard isCorruption(error) else { return nil }
        }

        guard let directory = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ) else { return nil }
        let url = directory.appendingPathComponent(name)

        // Nothing to rename means the failure was not "an existing file is
        // corrupt" — a fresh attempt at the same path would fail identically,
        // so this is not a case `.reset` should claim to have fixed.
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        // Colons are not valid in a filename on APFS; ISO 8601's own
        // separator has to go.
        let stamp = ISO8601DateFormatter().string(from: now()).replacingOccurrences(of: ":", with: "-")
        let renamed = directory.appendingPathComponent("\(name).corrupt-\(stamp)")
        try? FileManager.default.removeItem(at: renamed)
        try? FileManager.default.moveItem(at: url, to: renamed)
        // WAL mode leaves sidecar files next to the main one; they belong to
        // the file that was just moved aside, and letting SQLite find them
        // beside a brand new file would have it try to replay someone else's
        // write-ahead log against a database that never made those writes.
        for suffix in ["-wal", "-shm"] {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name + suffix))
        }

        guard let fresh = try? onDisk(named: name) else { return nil }
        salvage(into: fresh, from: renamed)
        pruneCorruptFiles(in: directory, named: name, keeping: renamed)
        return OpenResult(database: fresh, outcome: .reset)
    }

    /// Whether the file itself is bad, as against the environment around it.
    ///
    /// `SQLITE_CORRUPT` is "the bytes do not form a database any more";
    /// `SQLITE_NOTADB` is "these bytes were never one". Everything else —
    /// `SQLITE_FULL`, `SQLITE_BUSY`, `SQLITE_IOERR`, `SQLITE_CANTOPEN`, a
    /// migration throwing something that is not a `DatabaseError` at all —
    /// says nothing about the contents and must not cost the reader their
    /// shelf.
    private static func isCorruption(_ error: any Error) -> Bool {
        guard let database = error as? DatabaseError else { return false }
        return [.SQLITE_CORRUPT, .SQLITE_NOTADB].contains(database.resultCode)
    }

    /// The classification above, reachable from a test. Provoking a real
    /// `SQLITE_FULL` from an open needs a full disk; the decision this makes
    /// is the whole of the fix and is worth asserting directly.
    nonisolated static func isCorruptionForTesting(_ error: any Error) -> Bool {
        isCorruption(error)
    }

    /// Copies the two irreplaceable tables out of the file being abandoned.
    ///
    /// The shelf is the reader's own saves and skips and the viewed list is
    /// their history; neither can be refetched, and both live in a file whose
    /// own doc comment calls it disposable. A corrupt database often still
    /// reads in part, so this is worth attempting — and worth attempting with
    /// `try?`, because failing to salvage from a file that is by definition
    /// broken is the expected case, not an error to propagate.
    ///
    /// `INSERT OR IGNORE`: the fresh database is empty, so there is nothing
    /// to conflict with today, but a future caller that salvages into a
    /// populated file should keep what is already there.
    /// `writeWithoutTransaction` because SQLite refuses `ATTACH` inside one
    /// ("cannot ATTACH database within transaction"); each `INSERT` is then
    /// its own implicit transaction, which is what a best-effort salvage
    /// wants anyway — one unreadable table does not lose the other.
    private static func salvage(into fresh: AppDatabase, from file: URL) {
        try? fresh.writer.writeWithoutTransaction { db in
            try db.execute(sql: "ATTACH DATABASE ? AS salvage", arguments: [file.path])
            defer { try? db.execute(sql: "DETACH DATABASE salvage") }
            for table in ["shelfEntry", "viewedEntry"] {
                try? db.execute(
                    sql: "INSERT OR IGNORE INTO \(table) SELECT * FROM salvage.\(table)"
                )
            }
        }
    }

    /// Keeps only the newest `.corrupt-*` file.
    ///
    /// They were never deleted, so a device that hits this repeatedly
    /// accumulated a full copy of the database per launch, forever, in
    /// Application Support — which is backed up. One is enough for diagnosis.
    private static func pruneCorruptFiles(in directory: URL, named name: String, keeping: URL) {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        for file in contents
        where file.lastPathComponent.hasPrefix("\(name).corrupt-") && file != keeping {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// **Downgrade note.** `DatabaseMigrator` only ever moves forward: it has
    /// no notion of a database that already carries a migration this build
    /// does not know about (an App Store rollback, TestFlight build N+1 on
    /// disk then N reinstalled). GRDB does not fail that case, because it
    /// never runs a migration whose name is already recorded — the file just
    /// opens as-is, with whatever extra tables or columns the newer build
    /// left behind and this build's code never reads. Nothing in this app
    /// currently drops a column or renames a table between migrations, so
    /// there is no case on record where that silence has hidden data loss;
    /// flagged here rather than fixed because building for a downgrade this
    /// project has never shipped would be solving a problem that does not
    /// exist yet.
    /// Internal rather than private so a test can migrate a database up to a
    /// named version and assert what the next one does to it. There is no
    /// other way to write a migration test that fails before the migration
    /// exists, and a migration nothing tests is how `v9_tasteContribution`
    /// shipped without its backfill.
    static var migrator: DatabaseMigrator {
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

        migrator.registerMigration("v9_tasteContribution") { db in
            // What each library series added to the taste ledger, so removing
            // the series can take exactly that back. Before this a removed
            // series kept its weight until sign-out (review R9, 2026-09-13).
            try db.create(table: "tasteContribution") { table in
                table.column("seriesId", .integer).notNull()
                table.column("tagId", .integer).notNull()
                table.column("name", .text).notNull()
                table.column("score", .double).notNull()
                table.primaryKey(["seriesId", "tagId"])
            }
        }

        migrator.registerMigration("v10_feedLastModified") { db in
            // The feed's own `Last-Modified` header value, kept verbatim so
            // the next fetch can send it back as `If-Modified-Since`.
            // MEASURED 2026-09-13 against api.mangabaka.org: feed responses
            // carry no `ETag`, only `Last-Modified` (e.g. "Sun, 13 Sep 2026
            // 13:56:53 GMT") — repeating it gets a 304 with a zero-byte body.
            // Nullable: every row already on disk predates this column, and
            // a feed with no recorded value simply fetches unconditionally,
            // exactly as it always has.
            try db.alter(table: "feedMetadata") { table in
                table.add(column: "lastModified", .text)
            }
        }

        migrator.registerMigration("v11_recountTaste") { db in
            // v9 created `tasteContribution` and nothing ever backfilled it.
            // MEASURED 2026-09-14 on the real simulator file: 945
            // `tasteSource` rows and 0 contributions — so every series
            // already in the library at the time of that migration still
            // contributes tag weight that removing it cannot take back, and
            // always would have, because `absorb` skips a series `tasteSource`
            // already names. The retraction v9 was written for has therefore
            // never worked for anybody who had a library before it shipped.
            //
            // The ledger is derived entirely from the library, so the cheapest
            // correct backfill is to forget it and let the next `absorb`
            // recount — which now writes a contribution per tag. Nothing the
            // reader typed lives in these three tables.
            try db.execute(sql: "DELETE FROM tasteSource")
            try db.execute(sql: "DELETE FROM tagAffinity")
            try db.execute(sql: "DELETE FROM tasteSeen")
        }

        migrator.registerMigration("v12_shelfOrderIndex") { db in
            // `ShelfStore` reads `ORDER BY addedAt DESC LIMIT 60`. The v2
            // index is `(kind, addedAt)`, whose leading column that query does
            // not constrain, so SQLite cannot walk it in order and sorts the
            // whole table instead — `EXPLAIN QUERY PLAN` says USE TEMP B-TREE
            // FOR ORDER BY. An index on `addedAt` alone serves it; the
            // composite stays, because the by-kind reads still use it.
            try db.create(
                index: "shelfEntry_on_addedAt", on: "shelfEntry", columns: ["addedAt"]
            )
            // `feedEntry`'s primary key is (feedKey, position), so `feedKey`
            // is already the leading column of an index SQLite maintains for
            // free. `feedEntry_on_feedKey` is a second B-tree over the same
            // column, written on every feed cache write and read by nothing
            // the primary key could not answer.
            try db.execute(sql: "DROP INDEX IF EXISTS feedEntry_on_feedKey")
        }

        return migrator
    }
}
