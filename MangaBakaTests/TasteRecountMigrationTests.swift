import Foundation
import GRDB
import Testing
@testable import MangaBaka

/// Items 2 and 81 — the two things the v11/v12 migrations fix.
///
/// Item 2: `v9_tasteContribution` created the table that lets removing a
/// series take its tag weight back, and nothing ever backfilled it. MEASURED
/// 2026-09-14 on the real simulator file: 945 `tasteSource` rows, 0
/// contributions — so for every series already in the library when v9 ran,
/// removal retracts nothing, and always would have, because `absorb` skips a
/// series `tasteSource` already names.
@Suite("Migrations recount taste and fix the shelf's index", .serialized)
struct TasteRecountMigrationTests {
    private func seedV9State(_ db: Database) throws {
        try db.execute(
            sql: "INSERT INTO tasteSource (seriesId, countedAt, state) VALUES (?, ?, ?)",
            arguments: [3397, Date(timeIntervalSince1970: 0), "reading"]
        )
        try db.execute(
            sql: "INSERT INTO tagAffinity (tagId, name, score, seriesCount) VALUES (?, ?, ?, ?)",
            arguments: [94, "Isekai", 4.0, 1]
        )
        try db.execute(sql: "INSERT INTO tasteSeen (seriesId) VALUES (?)", arguments: [3397])
    }

    /// Expected to fail before item 2 with: `DatabaseMigrator.migrate(_:upTo:)`
    /// throwing "undefined migration: v11_recountTaste", because the migrator
    /// stopped at `v10_feedLastModified`. With the migration registered but
    /// not deleting, the three `== 0` assertions fail at 1.
    @Test("v11_recountTaste empties the three ledger tables")
    func migrationEmptiesLedger() throws {
        let queue = try DatabaseQueue()
        // Up to v10 only: the schema as a device that has never seen v11 has
        // it. Then the measured state — counted, contributing nothing.
        try AppDatabase.migrator.migrate(queue, upTo: "v10_feedLastModified")
        try queue.write { db in
            try seedV9State(db)
            let tasteContributionCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tasteContribution")
            #expect(tasteContributionCount == 0)
            let tasteSourceCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tasteSource")
            #expect(tasteSourceCount == 1)
        }

        try AppDatabase.migrator.migrate(queue, upTo: "v11_recountTaste")

        try queue.read { db in
            let tasteSourceCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tasteSource")
            #expect(tasteSourceCount == 0)
            let tagAffinityCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tagAffinity")
            #expect(tagAffinityCount == 0)
            let tasteSeenCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tasteSeen")
            #expect(tasteSeenCount == 0)
        }
    }

    /// The control: a database opened fresh at the current version has the
    /// same three tables empty and usable, so the assertions above are about
    /// the migration and not about a table that never existed.
    @Test("A fresh database has the ledger tables, empty")
    func freshDatabaseHasEmptyLedger() throws {
        let database = try AppDatabase.inMemory()
        try database.writer.write { db in
            let tasteSourceCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tasteSource")
            #expect(tasteSourceCount == 0)
            let tasteContributionCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tasteContribution")
            #expect(tasteContributionCount == 0)
            // Writable, not merely present.
            try seedV9State(db)
            let afterSeeding = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tasteSource")
            #expect(afterSeeding == 1)
        }
    }

    /// The `EXPLAIN QUERY PLAN` detail text for one statement, joined.
    private func plan(_ database: AppDatabase, sql: String) throws -> String {
        try database.writer.read { db in
            try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN \(sql)")
                .map { ($0["detail"] as String?) ?? "" }
                .joined(separator: " | ")
        }
    }

    /// Item 81. `shelfEntry`'s only index was `(kind, addedAt)`, whose leading
    /// column `ShelfStore`'s `ORDER BY addedAt DESC LIMIT 60` does not
    /// constrain — so SQLite sorted the whole table on every shelf read.
    ///
    /// Expected to fail before item 81 with: the plan containing
    /// "USE TEMP B-TREE FOR ORDER BY", printed by the failure message.
    @Test("The shelf's newest-first read needs no temporary sort")
    func shelfOrderUsesAnIndex() throws {
        let database = try AppDatabase.inMemory()
        let detail = try plan(
            database, sql: "SELECT * FROM shelfEntry ORDER BY addedAt DESC LIMIT 60"
        )
        #expect(!detail.contains("TEMP B-TREE"), "plan was: \(detail)")
    }

    /// The control for the plan assertion: the same table and the same shape
    /// of query, ordered by a column no index covers, *does* show a temporary
    /// sort — so the assertion above can actually fail, and what removes the
    /// sort there is `shelfEntry_on_addedAt` and nothing else.
    ///
    /// This control used to order `viewedEntry` by `rowid, seriesId DESC` and
    /// asserted a temp B-tree that never appeared: `seriesId` is that table's
    /// `INTEGER PRIMARY KEY`, so it *is* the rowid, and SQLite drops both the
    /// duplicate term and the sort, planning a bare `SCAN`. It was controlling
    /// nothing. Verified with the `sqlite3` CLI on 2026-09-14 against this
    /// schema: `ORDER BY rowid, seriesId DESC` plans `SCAN viewedEntry`, and
    /// ordering by an unindexed column plans `USE TEMP B-TREE FOR ORDER BY`.
    @Test("A sort with no index still reports a temporary B-tree")
    func unindexedSortStillSorts() throws {
        let database = try AppDatabase.inMemory()
        let detail = try plan(
            database, sql: "SELECT * FROM shelfEntry ORDER BY payload DESC LIMIT 60"
        )
        #expect(detail.contains("TEMP B-TREE"), "plan was: \(detail)")
    }

    /// Item 81's other half: `feedEntry_on_feedKey` duplicated the leading
    /// column of the primary key `(feedKey, position)`, so every feed write
    /// maintained a second B-tree for a query the primary key already serves.
    ///
    /// Expected to fail before item 81 with: the index still present.
    @Test("The redundant feedEntry index is gone")
    func redundantFeedIndexDropped() throws {
        let database = try AppDatabase.inMemory()
        let names = try database.writer.read { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT name FROM sqlite_master
                    WHERE type = 'index' AND tbl_name = 'feedEntry'
                    """
            )
        }
        #expect(!names.contains("feedEntry_on_feedKey"))
    }
}
