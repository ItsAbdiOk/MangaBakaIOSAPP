import Foundation
import GRDB

/// The schema: what tables there are, in which of the two files, and the
/// migrations that got them there.
///
/// Split out of `AppDatabase.swift` when the one database became two (Q10);
/// nothing here changed in that move except where it lives.
extension AppDatabase {
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

        migrator.registerMigration("v2_shelf", migrate: createShelfEntry)

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

        migrator.registerMigration("v4_history", migrate: createViewedEntry)

        migrator.registerMigration("v5_taste", migrate: createTasteTables)

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

        migrator.registerMigration("v7_libraryCache", migrate: createLibraryCache)

        migrator.registerMigration("v8_tasteSeen", migrate: createTasteSeen)

        migrator.registerMigration("v9_tasteContribution", migrate: createTasteContribution)

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
            // `shelfEntry` is on `readerTables`, which the rule below says a
            // cache migration must never touch. v12 does, and got away with it
            // only because it shipped in the same build as the split: both
            // `onDisk` and `onDiskResettingIfCorrupt` migrate the cache file
            // before `finishOpening` calls `splitReaderTables`, so on the one
            // launch where v12 runs the table is still there. That is a
            // shipping coincidence, not a licence — `ifStillInCacheFile` is
            // what the next migration copies, and `AppDatabaseSplitRuleTests`
            // is what goes red if it does not (work-list 27).
            try ifStillInCacheFile("shelfEntry", db, createShelfOrderIndex)
            // `feedEntry`'s primary key is (feedKey, position), so `feedKey`
            // is already the leading column of an index SQLite maintains for
            // free. `feedEntry_on_feedKey` is a second B-tree over the same
            // column, written on every feed cache write and read by nothing
            // the primary key could not answer.
            try db.execute(sql: "DROP INDEX IF EXISTS feedEntry_on_feedKey")
        }

        migrator.registerMigration("v13_libraryEntryInCache") { db in
            // `libraryEntry` and `libraryMetadata` come back to this file
            // (decision 2026-09-14; see `readerTables` for the measurement).
            // v7 already created both here, but on every device that has
            // launched the split build the split then dropped them, so the
            // table is there on a fresh install and absent on a split one.
            // Guarded rather than `ifNotExists` so the shared definition is
            // reused verbatim and `schemasMatch`-style `sqlite_master` text
            // stays byte-identical to v7's. The two are created and dropped
            // as a pair everywhere, so one existence check covers both.
            if try !db.tableExists("libraryEntry") {
                try createLibraryCache(db)
            }
            // Where `moveLibraryCacheToCacheFile` records that the copy out of
            // the reader's file is done and verified — the mirror of
            // `librarySplit`, and in *this* file for the same reason that one
            // is in the reader's: the marker lives with the destination, so
            // losing the destination (a cache reset) loses the marker with it
            // and the copy simply runs again against an empty table.
            try db.create(table: "libraryMove") { table in
                table.primaryKey("id", .integer)
                table.column("completedAt", .datetime).notNull()
            }
        }

        migrator.registerMigration("v14_editionAnswer") { db in
            // The merged ANN / Open Library / NDL answer a series page drew,
            // keyed by series id, so the Next-volume widget can read a
            // forthcoming volume for a page opened last week rather than
            // only one opened in the last six hours (`EditionAnswerStore`).
            // Cache, not reader data: every row is re-fetchable on the next
            // page open, so it lives in this file and out of the backup.
            // Touches nothing on `readerTables`, so no `ifStillInCacheFile`.
            try db.create(table: "editionAnswer") { table in
                table.primaryKey("seriesId", .integer)
                table.column("payload", .blob).notNull()
                table.column("fetchedAt", .datetime).notNull()
            }
        }

        return migrator
    }

    /// The tables that belong to the reader, in the order they must be copied
    /// and dropped. Named once, because `salvage`, `splitReaderTables` and
    /// `libraryMigrator` all have to agree about the list, and a table missing
    /// from one of them is a silent data loss rather than a compile error.
    ///
    /// `libraryEntry` and `libraryMetadata` were here until 2026-09-14, on the
    /// judgement that their offline value earned them a place in the backup.
    /// MEASURED on the real device file that day: 945 rows, 24.7 MB of a
    /// 17 MB-total database — the library cache alone outweighed everything
    /// else the app stores put together, and every byte of it is a copy of
    /// what MangaBaka's server holds for the account, re-downloaded on the
    /// next walk. Abdi's decision: it does not belong in the iCloud backup.
    /// They live in the cache file again (`v13_libraryEntryInCache`,
    /// `libraryCacheTables`, `moveLibraryCacheToCacheFile`), which means a
    /// restore from backup now shows an empty library until the next walk —
    /// six hours of offline value traded for 24.7 MB off every nightly backup.
    /// `ownedVolume` is the opposite case: user data with no server copy, and
    /// it stays in the reader's file.
    ///
    /// **A new `v…` migration must never touch a table on this list.** They
    /// are created in the cache file by v2-v9 for history's sake and dropped
    /// out of it again by `splitReaderTables`, so on every device that has
    /// launched once they are simply not there: an `ALTER TABLE shelfEntry` in
    /// the cache migrator would throw on open, and `onDiskResettingIfCorrupt`
    /// correctly declines to call that corruption. The device then falls all
    /// the way through to `AppServices.makeDatabase`'s in-memory database,
    /// which `.unopened` deliberately shows no toast for: an app that forgets
    /// everything, on every launch, forever, and says nothing.
    ///
    /// Change them in `libraryMigrator` instead. If a cache-side migration
    /// genuinely has to touch one — v12 does — put it through
    /// `ifStillInCacheFile` so it is a no-op on a split device rather than a
    /// throw. `AppDatabaseSplitRuleTests.migratorSurvivesTheSplit` is the
    /// enforcement: it migrates a cache file, splits it, and runs the migrator
    /// over it again. It goes red the day a migration breaks this rule, which
    /// is the day it needs to (work-list 27).
    static let readerTables = [
        "shelfEntry", "viewedEntry",
        "tagAffinity", "tasteSource", "tasteSeen", "tasteContribution"
    ]

    /// The library cache: the two tables `moveLibraryCacheToCacheFile` carries
    /// *out of* the reader's file, in the order they are copied and dropped.
    ///
    /// Both migrators still create them — v7 in the cache file, L1 in the
    /// reader's — because neither history can be rewritten, so on a fresh
    /// install the reader's file gets an empty pair that the move drops again
    /// on first open. Same shape as `readerTables` in the other direction.
    /// Together, always: `libraryMetadata` is the one-row freshness stamp for
    /// the walk in `libraryEntry`, and `LibrarySnapshot` reads, writes and
    /// clears the pair as one.
    static let libraryCacheTables = ["libraryEntry", "libraryMetadata"]

    /// What `salvage` carries out of a corrupt file: the reader's tables *and*
    /// the split marker.
    ///
    /// Not the library cache. It used to be on this list by way of
    /// `readerTables`; since 2026-09-14 it lives in the cache file (see
    /// `readerTables`), where a corrupt file is deleted without salvage
    /// because everything in it can be fetched again — and it is: one walk,
    /// thirteen requests. Carrying it out of a corrupt *reader's* file would
    /// now also put it back in the file it was just moved out of.
    ///
    /// A separate list because the two jobs are different, and work-list 55 is
    /// what happens when one list does both. `librarySplit` is deliberately off
    /// `readerTables` — `splitReaderTables` must not try to copy or drop it out
    /// of the cache file, where it does not exist. But `salvage` reads the
    /// *reader's own file*, and dropping the marker there means the next launch
    /// finds `alreadyCopied == false`; if that launch is one where the cache
    /// file still holds the reader's tables (the drop had not run yet, or this
    /// is the same launch as the first split), the copy runs a second time and
    /// every row the reader deleted since the first copy comes back from the
    /// dead. `INSERT OR IGNORE` cannot help: the deleted row is not there to
    /// be ignored.
    ///
    /// Harmless in the other direction: a pre-split *cache* file has no
    /// `librarySplit` table, and `salvage` already expects and logs a missing
    /// table per `readerTables` entry.
    ///
    /// `ownedVolume` too: it is user data with no copy anywhere else, so a
    /// salvage that dropped it would lose every tick the reader ever made.
    static let salvagedTables = readerTables + ["librarySplit", "ownedVolume"]

    /// Runs a cache-migrator step only if the table it touches is still in the
    /// cache file.
    ///
    /// The escape hatch for the rule on `readerTables`, and the only sanctioned
    /// one. A device that has split does not have these tables here, so the
    /// step is a no-op; a device installing for the first time before the split
    /// does, and the step runs exactly as it always did. Every reader table a
    /// cache migration touches goes through this, or the migrator throws on
    /// open and the app silently falls back to an in-memory database.
    static func ifStillInCacheFile(
        _ table: String, _ db: Database, _ body: (Database) throws -> Void
    ) throws {
        guard try db.tableExists(table) else { return }
        try body(db)
    }

    /// The schema of `libraryWriter`'s file.
    ///
    /// Every table here is also created by `migrator`, from the same
    /// functions: the cache migrator's history cannot be rewritten (existing
    /// installs have already recorded v1-v12 and will never re-run them), so
    /// a device that installed before the split still creates the reader's
    /// tables in the cache file and `splitReaderTables` moves them out. The
    /// shared `create…` functions are what stop the two schemas drifting;
    /// `LibrarySplitTests.schemasMatch` asserts they have not.
    static var libraryMigrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("L1_readerTables") { db in
            try createShelfEntry(db)
            try createShelfOrderIndex(db)
            try createViewedEntry(db)
            try createTasteTables(db)
            try createTasteSeen(db)
            try createTasteContribution(db)
            // Still created here, and no longer meant to be here: the pair
            // moved back to the cache file on 2026-09-14 (`libraryCacheTables`)
            // and `moveLibraryCacheToCacheFile` drops them out of this file on
            // the first open after that. Kept because existing installs have
            // recorded L1 and a migration's body must not change under them.
            try createLibraryCache(db)
            // One row, written once `splitReaderTables` has copied and
            // verified everything. Its presence is what stops a second copy
            // from a cache file whose drop was interrupted — see that
            // function for why re-copying after the app has started writing
            // here would resurrect deleted rows.
            try db.create(table: "librarySplit") { table in
                table.primaryKey("id", .integer)
                table.column("completedAt", .datetime).notNull()
            }
        }
        migrator.registerMigration("L2_ownedVolumes") { db in
            // The volumes the reader says they physically own — a tick per
            // row of "Volumes on record" (`OwnedVolumes`). Here and *not* in
            // `migrator`: this is the first reader table born after the
            // split, so there is no cache-file history to honour, and putting
            // it there as well would leave every device an empty copy in the
            // file that is not backed up. The cost is that `inMemory()`, which
            // runs only the cache migrator, has no such table — recorded on
            // `OwnedVolumes`, which is the one thing that reads it.
            //
            // Not on `readerTables` either: that list is what
            // `splitReaderTables` copies *out of the cache file*, and this
            // table was never there. `salvage` therefore does not carry it
            // out of a corrupt reader's file yet — `salvagedTables` is the
            // place to add it, and that is a one-line change outside this
            // migration.
            try db.create(table: "ownedVolume") { table in
                table.column("seriesId", .integer).notNull()
                // `OwnedVolumeKey.identity`: `isbn:…` or `row:…`.
                table.column("identity", .text).notNull()
                table.column("ownedAt", .datetime).notNull()
                table.primaryKey(["seriesId", "identity"])
            }
        }
        return migrator
    }

    // MARK: - Table definitions shared by both files

    /// The reader's own reactions, local until sign-in exists. Kept in its own
    /// table rather than as a column on `series` because a cached series is
    /// disposable and a save is not: clearing the cache must never lose what
    /// someone chose to keep.
    static func createShelfEntry(_ db: Database) throws {
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

    /// `ShelfStore` reads `ORDER BY addedAt DESC LIMIT 60`. The `(kind,
    /// addedAt)` index's leading column that query does not constrain, so
    /// SQLite cannot walk it in order and sorts the whole table instead —
    /// `EXPLAIN QUERY PLAN` says USE TEMP B-TREE FOR ORDER BY. An index on
    /// `addedAt` alone serves it; the composite stays, because the by-kind
    /// reads still use it.
    static func createShelfOrderIndex(_ db: Database) throws {
        try db.create(index: "shelfEntry_on_addedAt", on: "shelfEntry", columns: ["addedAt"])
    }

    /// What the reader has opened. Its own table rather than a column on
    /// `series`, because the cache is disposable and this is not — clearing
    /// the cache must not erase the history, and erasing the history must not
    /// cost a re-download.
    static func createViewedEntry(_ db: Database) throws {
        try db.create(table: "viewedEntry") { table in
            table.primaryKey("seriesId", .integer)
            table.column("viewedAt", .datetime).notNull()
            // The series as it was when opened, so the row renders offline
            // and after a cache clear.
            table.column("payload", .blob).notNull()
        }
        try db.create(index: "viewedEntry_on_viewedAt", on: "viewedEntry", columns: ["viewedAt"])
    }

    /// How much each tag runs through the reader's own library, and which
    /// series have already been counted.
    ///
    /// Counted locally rather than asked for, because the API's taste
    /// endpoint answers in GENRES — six of Solo Leveling's 146 tags are
    /// genres — so it can never say "you read a lot of Regression".
    static func createTasteTables(_ db: Database) throws {
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

    /// Every series the ledger was offered, tagged or not. The "counted but no
    /// tags known" diagnostic in Settings was built to catch a library payload
    /// with no tags — and a series with no tags was never counted, so the
    /// diagnostic could not fire. This is the count it needs: offered, as
    /// against counted.
    static func createTasteSeen(_ db: Database) throws {
        try db.create(table: "tasteSeen") { table in
            table.primaryKey("seriesId", .integer)
        }
    }

    /// What each library series added to the taste ledger, so removing the
    /// series can take exactly that back. Before this a removed series kept
    /// its weight until sign-out (review R9, 2026-09-13).
    static func createTasteContribution(_ db: Database) throws {
        try db.create(table: "tasteContribution") { table in
            table.column("seriesId", .integer).notNull()
            table.column("tagId", .integer).notNull()
            table.column("name", .text).notNull()
            table.column("score", .double).notNull()
            table.primaryKey(["seriesId", "tagId"])
        }
    }

    /// The reader's own library, on disk — in the cache file.
    ///
    /// Measured on a real account: 939 entries, thirteen requests, 24.7 MB —
    /// thirty times everything else the app fetches put together. Paying that
    /// on every launch is indefensible on a cellular connection, and it is the
    /// same answer every time. Which is also why it is not backed up: the
    /// same 24.7 MB (945 rows by 2026-09-14) was going up to iCloud nightly
    /// for a copy the server already holds. See `readerTables`.
    static func createLibraryCache(_ db: Database) throws {
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
}
