import Foundation
import GRDB
import Testing
@testable import MangaBaka

/// The two rules the split imposes on everything else, made enforceable.
///
/// `AppDatabase+Schema.readerTables` states in bold that a `v…` migration must
/// never touch a table on its list, and `AppDatabase+Split.copyAndVerify` used
/// to claim its `EXCEPT` caught column-order drift. Both were prose. These are
/// the tests that go red instead (work-list 27 and 56).
@Suite("The split's rules are checked, not just written down", .serialized)
struct AppDatabaseSplitRuleTests {
    private func testName() -> String { "splitrule-\(UUID().uuidString).sqlite" }

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

    /// The rule on `readerTables`, enforced.
    ///
    /// **This has to be set up as a device that predates the newest
    /// migration**, not as a fully migrated file. Re-running the migrator over
    /// a file that has already recorded v12 is a no-op and would pass whatever
    /// v12 does — the trap this test exists to avoid falling into. So: migrate
    /// only as far as v11, split (which drops the reader's tables out of the
    /// cache file), then run the whole migrator. v12 is now a migration
    /// arriving *after* the split, which is the shape every future migration
    /// has on every existing install.
    ///
    /// EXPECTED TO FAIL ON THE CODE BEFORE work-list 27 with: v12 calls
    /// `CREATE INDEX shelfEntry_on_addedAt ON shelfEntry` against a cache file
    /// that no longer has `shelfEntry`, so `migrate` throws `DatabaseError`
    /// `SQLITE_ERROR` ("no such table: shelfEntry") and `#expect(throws:
    /// Never.self)` fails. On the device that is worse than a thrown error:
    /// `isCorruption` correctly says this is not corruption, so
    /// `openRecoveringFromCorruption` returns nil, `onDiskResettingIfCorrupt`
    /// returns nil, and `AppServices.makeDatabase` falls back to an in-memory
    /// database silently, on every launch, forever.
    @Test("A migration registered after the split still opens a split cache file")
    func migratorSurvivesTheSplit() throws {
        let name = testName()
        defer { cleanUp(name) }
        let cachePath = try url(for: name).path

        try autoreleasepool {
            // An empty migrator so the file exists at v0, then only as far as
            // v11 — the state of an install from before v12 shipped.
            let cache = try AppDatabase.openPool(named: name, migrator: DatabaseMigrator())
            try AppDatabase.migrator.migrate(cache, upTo: "v11_recountTaste")
            #expect(try cache.read { db in try db.tableExists("shelfEntry") })

            let library = try AppDatabase.openPool(
                named: AppDatabase.libraryName(for: name), migrator: AppDatabase.libraryMigrator
            )
            try AppDatabase.splitReaderTables(cachePath: cachePath, library: library)
            // The precondition the rest of the test rests on: the reader's
            // tables really are gone from the cache file.
            #expect(try cache.read { db in try db.tableExists("shelfEntry") } == false)

            #expect(throws: Never.self) {
                try AppDatabase.migrator.migrate(cache)
            }
        }
    }

    /// The runtime schema check that replaces a comment which was not true.
    ///
    /// EXPECTED TO FAIL ON THE CODE BEFORE work-list 56 with: `schemaDrift`
    /// did not exist, so this does not compile — and that is worth saying
    /// plainly, because a test that fails to compile proves nothing about
    /// behaviour. The *behavioural* claim is the second half: on the old code
    /// `splitReaderTables` returned normally here, marked and dropped, and
    /// `#expect(shelf == 1)` in the reader's file would have read 1 with the
    /// row's `payload` column holding the date. This asserts the refusal
    /// instead, which is the only version that cannot silently scramble.
    @Test("A table whose columns disagree between the two files is not copied")
    func refusesToCopyWhenTheColumnsDisagree() throws {
        let name = testName()
        defer { cleanUp(name) }
        let cachePath = try url(for: name).path

        try autoreleasepool {
            let cache = try AppDatabase.openPool(named: name, migrator: AppDatabase.migrator)
            // A column the reader's file does not have. Adding one is the
            // honest way to simulate drift: SQLite cannot reorder columns in
            // place, and a set difference is what `copyPlan` refuses on.
            try cache.write { db in
                try db.execute(sql: "ALTER TABLE viewedEntry ADD COLUMN driftedColumn TEXT")
                try db.execute(
                    sql: "INSERT INTO viewedEntry (seriesId, viewedAt, payload) VALUES (?, ?, ?)",
                    arguments: [8, Date(timeIntervalSince1970: 0), Data("v".utf8)]
                )
            }

            let library = try AppDatabase.openPool(
                named: AppDatabase.libraryName(for: name), migrator: AppDatabase.libraryMigrator
            )
            #expect {
                try AppDatabase.splitReaderTables(cachePath: cachePath, library: library)
            } throws: { error in
                guard case AppDatabase.SplitError.schemaDrift(let table, _, _) = error
                else { return false }
                return table == "viewedEntry"
            }
            // Nothing was marked and nothing was dropped: a refusal, not a
            // half-done migration.
            #expect(try AppDatabase.splitHasCompleted(library: library) == false)
            #expect(try cache.read { db in try db.tableExists("viewedEntry") })
        }
    }

    /// Work-list 55, as a source pin rather than a behaviour test.
    ///
    /// The behaviour — a reader's file reset and salvaged while the cache file
    /// still holds the reader's tables, so `alreadyCopied` is false and the
    /// copy resurrects rows the reader deleted — needs a corruption that both
    /// fails the open and survives an `ATTACH`, i.e. a damaged interior page
    /// rather than a damaged header. `DatabaseCorruptionScopeTests
    /// .corruptFileIsReset` already records that nothing here can force SQLite
    /// to report one, and that `salvage` is therefore uncovered. This asserts
    /// the list `salvage` loops instead, which is the whole of the mechanism.
    ///
    /// EXPECTED TO FAIL ON THE OLD CODE with: `salvagedTables` did not exist —
    /// a compile failure, which proves nothing about behaviour, so this is
    /// recorded as a pin and not as proof.
    @Test("Salvage carries the split marker that readerTables deliberately omits")
    func salvageCarriesTheSplitMarker() {
        #expect(
            AppDatabase.readerTables.contains("librarySplit") == false,
            "splitReaderTables must not try to copy or drop the marker from the cache file"
        )
        #expect(AppDatabase.salvagedTables.contains("librarySplit"))
        #expect(AppDatabase.salvagedTables.starts(with: AppDatabase.readerTables))
    }
}
