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

    /// Launch 1's copy failed, the app walked and wrote a fresh library into
    /// the cache file, and launch 2 must not put the reader's older rows back
    /// over it — night review §1. The cache file here holds rows 4 and 5
    /// stamped now; the reader's file rows 1–3 stamped 1970.
    ///
    /// Fails before `cacheFileIsFresher` with `cache == [1, 2, 3]`: REPLACE
    /// wrote the stale rows over the fresh ones and dropped nothing the
    /// reader would notice until the next walk.
    @Test("A fresher walk already in the cache file survives the retry")
    func fresherCacheFileIsKept() throws {
        let name = "cachefresh-\(UUID().uuidString).sqlite"
        defer { cleanUp(name) }
        try seedSplitDevice(named: name)
        try autoreleasepool {
            let cache = try AppDatabase.openPool(named: name, migrator: AppDatabase.migrator)
            try cache.write { db in
                for id in [4, 5] {
                    try db.execute(
                        sql: "INSERT INTO libraryEntry (seriesId, payload) VALUES (?, ?)",
                        arguments: [id, Data("fresh-\(id)".utf8)]
                    )
                }
                try db.execute(
                    sql: "INSERT INTO libraryMetadata (id, cachedAt, isComplete) VALUES (1, ?, 1)",
                    arguments: [Date()]
                )
            }
        }

        try autoreleasepool {
            let database = try AppDatabase.onDisk(named: name)
            let inCache = try database.cacheWriter.read { db in
                try Int.fetchAll(db, sql: "SELECT seriesId FROM libraryEntry ORDER BY seriesId")
            }
            #expect(inCache == [4, 5])
            let readerHasTable = try database.libraryWriter.read { db in try db.tableExists("libraryEntry") }
            #expect(!readerHasTable, "the reader's stale pair is still dropped")
        }
    }

    /// The window the review named: the drop committed, the VACUUM did not
    /// run. Simulated by opening the moved device once more with a bloated
    /// reader's file (a big table created and dropped by hand) — the retry
    /// must reclaim it on an ordinary open. Fails before `vacuumIfBloated`
    /// with `freelist == 300` or so.
    @Test("A reader's file left bloated by an interrupted VACUUM is reclaimed on the next open")
    func vacuumIsRetried() throws {
        let name = "cacheretry-\(UUID().uuidString).sqlite"
        defer { cleanUp(name) }
        try seedSplitDevice(named: name)
        try autoreleasepool { _ = try AppDatabase.onDisk(named: name) }

        try autoreleasepool {
            let queue = try DatabaseQueue(path: try url(for: AppDatabase.libraryName(for: name)).path)
            try queue.write { db in
                try db.execute(sql: "CREATE TABLE bloat (payload BLOB)")
                for _ in 0..<20 {
                    try db.execute(
                        sql: "INSERT INTO bloat (payload) VALUES (?)",
                        arguments: [Data(repeating: 0x42, count: 65_536)]
                    )
                }
                try db.execute(sql: "DROP TABLE bloat")
            }
            let free = try queue.read { db in try Int.fetchOne(db, sql: "PRAGMA freelist_count") ?? 0 }
            #expect(free > 256, "the fixture must bloat past the threshold, got \(free)")
        }

        try autoreleasepool {
            let database = try AppDatabase.onDisk(named: name)
            let free = try database.libraryWriter.read { db in
                try Int.fetchOne(db, sql: "PRAGMA freelist_count") ?? -1
            }
            #expect(free == 0, "\(free) pages still on the freelist")
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
