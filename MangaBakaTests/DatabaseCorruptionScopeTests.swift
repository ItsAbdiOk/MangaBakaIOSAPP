import Foundation
import GRDB
import Testing
@testable import MangaBaka

/// Item 78. `onDiskResettingIfCorrupt` renamed the database aside whenever
/// `onDisk` threw for *any* reason, and that file holds `shelfEntry`,
/// `viewedEntry` and `tagAffinity` — the reader's own saves, their history and
/// the taste ledger, none of which can be refetched. A disk-full `ALTER
/// TABLE`, a `SQLITE_BUSY` left by the previous process, or a bug in a future
/// migration therefore destroyed the shelf permanently and told the reader it
/// "was reset".
///
/// `AppDatabaseResetTests` covers only "garbage at the path", which is a real
/// corruption; nothing covered the far more likely transient failure.
@Suite("Only real corruption resets the database", .serialized)
struct DatabaseCorruptionScopeTests {
    private func testName() -> String { "corruptscope-\(UUID().uuidString).sqlite" }

    private func applicationSupportURL(for name: String) throws -> URL {
        try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appendingPathComponent(name)
    }

    private func cleanUp(_ name: String) {
        guard let url = try? applicationSupportURL(for: name) else { return }
        let directory = url.deletingLastPathComponent()
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for entry in contents where entry.hasPrefix(name) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(entry))
        }
    }

    /// `SQLITE_FULL` stands in for every transient failure: the bytes are
    /// fine, the environment is not.
    ///
    /// Expected to fail before item 78 with: `#expect(result == nil)` failing
    /// because a fresh database was returned, and then the shelf row being
    /// gone from the reopened file — the old code renamed on any throw at
    /// all, and a rename is not undoable.
    @Test("A transient open failure leaves the file, and the shelf, alone")
    func transientFailureDoesNotRename() throws {
        let name = testName()
        defer { cleanUp(name) }

        // A real, healthy database with something irreplaceable in it.
        let url = try applicationSupportURL(for: name)
        let seeded = try AppDatabase(writer: DatabasePool(path: url.path))
        try seeded.writer.write { db in
            try db.execute(
                sql: "INSERT INTO shelfEntry (seriesId, kind, addedAt, payload) VALUES (?, ?, ?, ?)",
                arguments: [3397, "saved", Date(timeIntervalSince1970: 0), Data()]
            )
        }

        // `SQLITE_FULL` is not corruption, so nothing may be renamed.
        #expect(!AppDatabase.isCorruptionForTesting(DatabaseError(resultCode: .SQLITE_FULL)))
        #expect(!AppDatabase.isCorruptionForTesting(DatabaseError(resultCode: .SQLITE_BUSY)))
        #expect(!AppDatabase.isCorruptionForTesting(DatabaseError(resultCode: .SQLITE_IOERR)))
        // The control: the two codes that *are* corruption still are, so the
        // assertions above are not passing because the check answers false to
        // everything.
        #expect(AppDatabase.isCorruptionForTesting(DatabaseError(resultCode: .SQLITE_CORRUPT)))
        #expect(AppDatabase.isCorruptionForTesting(DatabaseError(resultCode: .SQLITE_NOTADB)))

        // And the file is still openable with its shelf row, which is the
        // thing the old behaviour destroyed.
        let reopened = try #require(AppDatabase.onDiskResettingIfCorrupt(named: name))
        #expect(reopened.outcome == .opened)
        let saved = try reopened.database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM shelfEntry") ?? 0
        }
        #expect(saved == 1)
    }

    /// Expected to fail before item 78 with: no `outcome` member at all
    /// (`wasReset: Bool` was the only answer).
    ///
    /// **The fixture has to work harder than it looks.** Zeroing the header
    /// of the main file is not enough on its own: `DatabasePool` is WAL, so
    /// page 1 also exists in the `-wal` sidecar, and the next open replays
    /// the log over the zeroed bytes and succeeds — which is exactly how
    /// this test failed, with `outcome == .opened`. Checkpointing the WAL
    /// into the main file, dropping the sidecars and *then* zeroing the
    /// header is what SQLite actually answers `SQLITE_NOTADB` to. Verified
    /// with the `sqlite3` CLI on 2026-09-14: same three steps, `SELECT`
    /// returns "file is not a database (26)".
    ///
    /// What this does NOT prove, despite the fix's name: the salvage. A file
    /// whose header magic is gone cannot be `ATTACH`ed either (same
    /// verification: "no such table"), so nothing can be read out of it. A
    /// corruption that both fails the open and survives an `ATTACH` would
    /// need a damaged interior page rather than a damaged header, and
    /// nothing here forces SQLite to report one. `salvage` is therefore
    /// still uncovered.
    @Test("A genuinely corrupt file is reset")
    func corruptFileIsReset() throws {
        let name = testName()
        defer { cleanUp(name) }

        let url = try applicationSupportURL(for: name)
        try autoreleasepool {
            let seeded = try AppDatabase(writer: DatabasePool(path: url.path))
            try seeded.writer.write { db in
                try db.execute(
                    sql: "INSERT INTO shelfEntry (seriesId, kind, addedAt, payload) VALUES (?, ?, ?, ?)",
                    arguments: [3397, "saved", Date(timeIntervalSince1970: 0), Data()]
                )
                try db.execute(
                    sql: "INSERT INTO viewedEntry (seriesId, viewedAt, payload) VALUES (?, ?, ?)",
                    arguments: [8, Date(timeIntervalSince1970: 0), Data()]
                )
            }
            // Fold the write-ahead log into the main file and truncate it, so
            // the bytes about to be corrupted are the only copy of page 1.
            try seeded.writer.writeWithoutTransaction { db in
                // `Row.fetchOne`, not `execute`: `wal_checkpoint` answers with
                // a row, and the statement has to be stepped for the
                // checkpoint to happen.
                _ = try Row.fetchOne(db, sql: "PRAGMA wal_checkpoint(TRUNCATE)")
            }
        }
        // The pool is gone with the scope above; remove the sidecars it left
        // so nothing can replay a valid header back over the corruption.
        for suffix in ["-wal", "-shm"] {
            try? FileManager.default.removeItem(
                at: url.deletingLastPathComponent().appendingPathComponent(name + suffix)
            )
        }

        // Corrupt the header so SQLite reports SQLITE_NOTADB.
        let handle = try FileHandle(forWritingTo: url)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Data(repeating: 0x00, count: 16))
        try handle.close()

        let result = try #require(AppDatabase.onDiskResettingIfCorrupt(named: name))
        #expect(result.outcome == .reset)
        #expect(result.wasReset)
    }

    /// Expected to fail before item 78 with: `wasReset` being the only
    /// vocabulary, so `.unopened` — the in-memory fallback, where the file is
    /// intact and merely unopened — could not be said at all and
    /// `AppServices` reported it as a reset.
    @Test("The three outcomes are distinguishable, and only .reset claims a reset")
    func outcomesAreDistinct() throws {
        let database = try AppDatabase.inMemory()
        #expect(!AppDatabase.OpenResult(database: database, outcome: .opened).wasReset)
        #expect(AppDatabase.OpenResult(database: database, outcome: .reset).wasReset)
        #expect(!AppDatabase.OpenResult(database: database, outcome: .unopened).wasReset)
    }
}
