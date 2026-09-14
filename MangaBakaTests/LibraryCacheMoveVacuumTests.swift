import Foundation
import GRDB
import Testing
@testable import MangaBaka

/// The saving from `moveLibraryCacheToCacheFile` is in bytes, not rows: a
/// dropped table leaves its pages on SQLite's freelist and a backup copies
/// the file. Measured on the real simulator database after the first run of
/// the move, 2026-09-14: 3,585 of 4,145 pages free, the reader's file still
/// 17 MB — the whole point of the move, still on disk.
///
/// Its own suite beside `LibraryCacheMoveTests` only for the lint's ceiling
/// on that type's body.
@Suite("The reader's file gives its pages back after the move", .serialized)
struct LibraryCacheMoveVacuumTests {
    private func cleanUp(_ name: String) {
        guard let directory = try? AppDatabase.applicationSupportDirectory() else { return }
        let stem = (name as NSString).deletingPathExtension
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for entry in contents where entry.hasPrefix(stem) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(entry))
        }
    }

    /// A split-era device whose three library rows are big enough to occupy
    /// whole pages of their own, so the drop frees something a count sees.
    private func seedSplitDevice(named name: String) throws {
        try autoreleasepool {
            let cache = try AppDatabase.openPool(named: name, migrator: DatabaseMigrator())
            try AppDatabase.migrator.migrate(cache, upTo: "v12_shelfOrderIndex")
            try cache.write { db in
                for table in AppDatabase.readerTables + AppDatabase.libraryCacheTables {
                    try db.execute(sql: "DROP TABLE \(table)")
                }
            }
            let library = try AppDatabase.openPool(
                named: AppDatabase.libraryName(for: name), migrator: AppDatabase.libraryMigrator
            )
            try library.write { db in
                for id in [1, 2, 3] {
                    try db.execute(
                        sql: "INSERT INTO libraryEntry (seriesId, payload) VALUES (?, ?)",
                        arguments: [id, Data(repeating: 0x41, count: 65_536)]
                    )
                }
                try db.execute(
                    sql: "INSERT INTO libraryMetadata (id, cachedAt, isComplete) VALUES (1, ?, 1)",
                    arguments: [Date(timeIntervalSince1970: 0)]
                )
                try db.execute(
                    sql: "INSERT INTO librarySplit (id, completedAt) VALUES (1, ?)",
                    arguments: [Date(timeIntervalSince1970: 0)]
                )
            }
        }
    }

    /// Fails before the `VACUUM main` with a freelist of 48 or more pages —
    /// three 64 KB payloads span pages the drop frees and nothing reclaims.
    @Test("No page is left on the freelist once the library cache has moved")
    func freelistIsEmptyAfterTheMove() throws {
        let name = "cachevacuum-\(UUID().uuidString).sqlite"
        defer { cleanUp(name) }
        try seedSplitDevice(named: name)

        try autoreleasepool {
            let database = try AppDatabase.onDisk(named: name)
            let (hasTable, freelist) = try database.libraryWriter.read { db in
                (try db.tableExists("libraryEntry"), try Int.fetchOne(db, sql: "PRAGMA freelist_count") ?? -1)
            }
            #expect(!hasTable)
            #expect(freelist == 0, "\(freelist) pages still on the freelist")
        }
    }
}
