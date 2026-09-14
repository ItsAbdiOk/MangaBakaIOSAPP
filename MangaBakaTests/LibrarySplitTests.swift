import Foundation
import GRDB
import Testing
@testable import MangaBaka

/// Q10: one `mangabaka.sqlite` held both the reader's own data and
/// re-fetchable cache. `AppDatabase.splitReaderTables` moves the first half
/// into `mangabaka-library.sqlite` once per device.
///
/// This is the one change in the batch that can lose somebody's shelf, so the
/// tests are about the *order* of the steps rather than about the happy path:
/// copy, verify, mark, drop, and nothing dropped that was not first copied and
/// verified.
@Suite("The reader's tables move out of the cache file safely", .serialized)
struct LibrarySplitTests {
    private func testName() -> String { "splittest-\(UUID().uuidString).sqlite" }

    private func url(for name: String) throws -> URL {
        try AppDatabase.applicationSupportDirectory().appendingPathComponent(name)
    }

    private func cleanUp(_ name: String) {
        guard let directory = try? AppDatabase.applicationSupportDirectory() else { return }
        let stem = (name as NSString).deletingPathExtension
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for entry in contents where entry.hasPrefix(stem) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(entry))
        }
    }

    /// A file exactly as an existing install has it: one database, migrated by
    /// the cache migrator, with the reader's own rows in it.
    private func seedLegacyFile(named name: String) throws {
        try autoreleasepool {
            let legacy = try AppDatabase.openPool(named: name, migrator: AppDatabase.migrator)
            try legacy.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO shelfEntry (seriesId, kind, addedAt, payload)
                        VALUES (?, ?, ?, ?)
                        """,
                    arguments: [3397, "saved", Date(timeIntervalSince1970: 0), Data("s".utf8)]
                )
                try db.execute(
                    sql: "INSERT INTO viewedEntry (seriesId, viewedAt, payload) VALUES (?, ?, ?)",
                    arguments: [8, Date(timeIntervalSince1970: 0), Data("v".utf8)]
                )
                try db.execute(
                    sql: """
                        INSERT INTO tagAffinity (tagId, name, score, seriesCount)
                        VALUES (?, ?, ?, ?)
                        """,
                    arguments: [12, "Regression", 4.5, 5]
                )
                try db.execute(
                    sql: "INSERT INTO libraryEntry (seriesId, payload) VALUES (?, ?)",
                    arguments: [99, Data("l".utf8)]
                )
                // A cache row, to prove the split leaves the other half alone.
                try db.execute(
                    sql: "INSERT INTO series (id, payload, cachedAt) VALUES (?, ?, ?)",
                    arguments: [1, Data("c".utf8), Date(timeIntervalSince1970: 0)]
                )
            }
        }
    }

    private func shelfCount(in writer: any DatabaseWriter) throws -> Int {
        try writer.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM shelfEntry") ?? 0 }
    }

    /// Expected to fail before the split with: `AppDatabase.libraryWriter` did
    /// not exist, and deleting `mangabaka.sqlite` deleted the shelf with it —
    /// `#expect(shelf == 1)` would read 0, because there was no second file
    /// for the shelf to be in.
    @Test("The shelf survives the cache file being deleted outright")
    func shelfSurvivesACacheFileDeletedOutright() throws {
        let name = testName()
        defer { cleanUp(name) }
        try seedLegacyFile(named: name)

        try autoreleasepool {
            let database = try AppDatabase.onDisk(named: name)
            #expect(try shelfCount(in: database.libraryWriter) == 1)
            // The reader's tables are gone from the cache file, and the cache
            // row is not.
            let moved = try database.cacheWriter.read { db in
                (
                    try db.tableExists("shelfEntry"),
                    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM series") ?? 0
                )
            }
            #expect(moved.0 == false)
            #expect(moved.1 == 1)
        }

        // Now throw the cache file away the way a corruption reset does.
        let cache = try url(for: name)
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: cache.path + suffix))
        }
        #expect(!FileManager.default.fileExists(atPath: cache.path))

        try autoreleasepool {
            let reopened = try AppDatabase.onDisk(named: name)
            #expect(try shelfCount(in: reopened.libraryWriter) == 1)
            let viewed = try reopened.libraryWriter.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM viewedEntry") ?? 0
            }
            #expect(viewed == 1)
            // The cache file is genuinely new: nothing was restored into it.
            let series = try reopened.cacheWriter.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM series") ?? 0
            }
            #expect(series == 0)
        }
    }

    /// The interruption. Killed after any one step, the shelf row must still
    /// exist somewhere, and finishing the job later must land it in the
    /// reader's file exactly once.
    ///
    /// Expected to fail before the split with: `SplitStep` and
    /// `splitReaderTables` did not exist, so there was no order to interrupt —
    /// and had the steps been written drop-first, `#expect(survived)` would
    /// fail at `.copy` with the row in neither file.
    @Test("Interrupted after any step, no row is lost", arguments: AppDatabase.SplitStep.allCases)
    func interruptionLosesNothing(stopping step: AppDatabase.SplitStep) throws {
        let name = testName()
        defer { cleanUp(name) }
        try seedLegacyFile(named: name)
        let libraryName = AppDatabase.libraryName(for: name)
        let cachePath = try url(for: name).path

        try autoreleasepool {
            let library = try AppDatabase.openPool(
                named: libraryName, migrator: AppDatabase.libraryMigrator
            )
            try AppDatabase.splitReaderTables(
                cachePath: cachePath, library: library, stoppingAfter: step
            )

            let inLibrary = try shelfCount(in: library)
            let inCache = try autoreleasepool { () -> Int in
                let cache = try AppDatabase.openPool(named: name, migrator: AppDatabase.migrator)
                return try cache.read { db in
                    guard try db.tableExists("shelfEntry") else { return 0 }
                    return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM shelfEntry") ?? 0
                }
            }
            #expect(
                inLibrary + inCache >= 1,
                "stopping after \(step) left the shelf row in neither file"
            )
            // The drop is last, so before it the row is in both — which is the
            // safe direction, and the only direction this may be wrong in.
            if step < .drop { #expect(inCache == 1) }
        }

        // The next launch finishes what it started.
        try autoreleasepool {
            let database = try AppDatabase.onDisk(named: name)
            #expect(
                try shelfCount(in: database.libraryWriter) == 1,
                "resuming after \(step) lost or duplicated the row"
            )
            #expect(try database.cacheWriter.read { db in try db.tableExists("shelfEntry") } == false)
        }
    }

    /// The control for the whole design: if the copy cannot be verified, the
    /// drop must not happen. Without it, "copy, verify, drop" could be
    /// "copy, drop" and every test above would still pass.
    ///
    /// The fixture forces the one case `INSERT OR IGNORE` cannot resolve: the
    /// same primary key on both sides with different contents, so the copy
    /// silently keeps the destination's row and the source row never arrives.
    ///
    /// Expected to fail before the split with: no `SplitError` to catch.
    @Test("A copy that cannot be verified drops nothing")
    func verificationFailureDropsNothing() throws {
        let name = testName()
        defer { cleanUp(name) }
        try seedLegacyFile(named: name)
        let cachePath = try url(for: name).path

        try autoreleasepool {
            let library = try AppDatabase.openPool(
                named: AppDatabase.libraryName(for: name), migrator: AppDatabase.libraryMigrator
            )
            try library.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO shelfEntry (seriesId, kind, addedAt, payload)
                        VALUES (?, ?, ?, ?)
                        """,
                    arguments: [3397, "skipped", Date(timeIntervalSince1970: 1), Data("other".utf8)]
                )
            }

            #expect(throws: AppDatabase.SplitError.verificationFailed(table: "shelfEntry", missingRows: 1)) {
                try AppDatabase.splitReaderTables(cachePath: cachePath, library: library)
            }
            #expect(try AppDatabase.splitHasCompleted(library: library) == false)
        }

        // The cache file still has every one of the reader's tables.
        try autoreleasepool {
            let cache = try AppDatabase.openPool(named: name, migrator: AppDatabase.migrator)
            for table in AppDatabase.readerTables {
                #expect(try cache.read { db in try db.tableExists(table) }, "\(table) was dropped anyway")
            }
        }
    }

    /// The two migrators create the reader's tables from the same functions.
    /// This asserts that they really do produce the same schema — a column
    /// order that drifted would make the split's `SELECT *` copy columns into
    /// the wrong places, and `EXCEPT` is the only thing that would catch it.
    @Test("Both files define the reader's tables identically")
    func schemasMatch() throws {
        let cache = try DatabaseQueue()
        try AppDatabase.migrator.migrate(cache)
        let library = try DatabaseQueue()
        try AppDatabase.libraryMigrator.migrate(library)

        func definitions(_ writer: any DatabaseWriter) throws -> [String: String] {
            try writer.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT name, sql FROM sqlite_master
                    WHERE type IN ('table', 'index') AND sql IS NOT NULL
                    """)
                .reduce(into: [:]) { result, row in result[row["name"]] = row["sql"] }
            }
        }
        let inCache = try definitions(cache)
        let inLibrary = try definitions(library)

        for table in AppDatabase.readerTables {
            #expect(inLibrary[table] != nil, "\(table) missing from the reader's file")
            #expect(inCache[table] == inLibrary[table], "\(table) differs between the two files")
        }
        // The indexes too: the shelf's ORDER BY depends on one of them.
        for index in ["shelfEntry_on_kind", "shelfEntry_on_addedAt", "viewedEntry_on_viewedAt"] {
            #expect(inCache[index] == inLibrary[index], "\(index) differs between the two files")
        }
        // The control: the cache file has tables the reader's file does not,
        // so the comparison above is not passing on two identical schemas.
        #expect(inCache["series"] != nil)
        #expect(inLibrary["series"] == nil)
    }

    /// The backup saving, which is half the reason for the split.
    ///
    /// Expected to fail before it with: one file, which could not be excluded
    /// without excluding the shelf from the reader's backup too.
    @Test("The cache file is kept out of backups and the reader's file is not")
    func onlyTheCacheIsExcludedFromBackup() throws {
        let name = testName()
        defer { cleanUp(name) }

        try autoreleasepool { _ = try AppDatabase.onDisk(named: name) }

        func isExcluded(_ fileName: String) throws -> Bool {
            let values = try url(for: fileName).resourceValues(forKeys: [.isExcludedFromBackupKey])
            return values.isExcludedFromBackup ?? false
        }
        #expect(try isExcluded(name))
        #expect(try isExcluded(AppDatabase.libraryName(for: name)) == false)
    }
}
