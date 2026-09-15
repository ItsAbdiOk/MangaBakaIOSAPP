import Foundation
import GRDB
import Testing
@testable import MangaBaka

/// The library cache moves from the reader's file to the cache file
/// (2026-09-14). MEASURED on the real device file: 945 `libraryEntry` rows,
/// 24.7 MB, every byte a copy of what the account holds on the server — and
/// all of it in the iCloud backup because Q10 put it on the backed-up side.
/// `AppDatabase.moveLibraryCacheToCacheFile` carries it across once per
/// device, the mirror image of `splitReaderTables`.
///
/// Like `LibrarySplitTests`, these are about the order of the steps and what
/// each one leaves on disk, not the happy path: the reader's file is never
/// written before the copy is verified, and the app reads the cache file
/// throughout, so the worst any interruption costs is one re-download.
@Suite("The library cache moves into the cache file safely", .serialized)
struct LibraryCacheMoveTests {
    private func testName() -> String { "cachemove-\(UUID().uuidString).sqlite" }

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

    /// Three library rows and the freshness stamp, the way `LibrarySnapshot`
    /// wrote them into the reader's file before the move.
    private func seedLibraryCache(into writer: any DatabaseWriter) throws {
        try writer.write { db in
            for id in [1, 2, 3] {
                try db.execute(
                    sql: "INSERT INTO libraryEntry (seriesId, payload) VALUES (?, ?)",
                    arguments: [id, Data("entry-\(id)".utf8)]
                )
            }
            try db.execute(
                sql: "INSERT INTO libraryMetadata (id, cachedAt, isComplete) VALUES (1, ?, 1)",
                arguments: [Date(timeIntervalSince1970: 0)]
            )
        }
    }

    /// A device exactly as the split build left it: the cache file at v12 with
    /// the reader's tables — the library cache among them — dropped out of it,
    /// and the reader's file holding the library rows plus the split marker.
    ///
    /// Migrated only as far as v12 so that `v13_libraryEntryInCache` is a
    /// migration arriving *after* the split, which is the shape it has on every
    /// existing install; the drop is done by hand because the split no longer
    /// lists the pair and would leave it alone.
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
            try seedLibraryCache(into: library)
            try library.write { db in
                try db.execute(
                    sql: "INSERT INTO librarySplit (id, completedAt) VALUES (1, ?)",
                    arguments: [Date(timeIntervalSince1970: 0)]
                )
            }
        }
    }

    private func count(_ table: String, in writer: any DatabaseWriter) throws -> Int? {
        try writer.read { db in
            guard try db.tableExists(table) else { return nil }
            return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)")
        }
    }

    /// Which file holds which table, on a fresh install.
    ///
    /// EXPECTED TO FAIL BEFORE THE MOVE with: `#expect(try count("libraryEntry",
    /// in: database.cacheWriter) != nil)` reading nil — v7 created the table in
    /// the cache file and the split then dropped it, because `readerTables`
    /// listed it — and `#expect(… libraryWriter) == nil)` reading 0, because L1
    /// created the pair in the reader's file and nothing dropped it there.
    /// `ownedVolume` is the control: it must not move, in either direction.
    @Test("A fresh install has the library cache in the cache file and ownedVolume in the reader's")
    func libraryCacheLivesInTheCacheFile() throws {
        let name = testName()
        defer { cleanUp(name) }

        try autoreleasepool {
            let database = try AppDatabase.onDisk(named: name)
            for table in AppDatabase.libraryCacheTables {
                let inCache = try count(table, in: database.cacheWriter)
                let inLibrary = try count(table, in: database.libraryWriter)
                #expect(inCache != nil, "\(table) missing from the cache file")
                #expect(inLibrary == nil, "\(table) still in the reader's file")
            }
            #expect(try count("ownedVolume", in: database.libraryWriter) != nil)
            #expect(try count("ownedVolume", in: database.cacheWriter) == nil)
            #expect(try AppDatabase.libraryCacheMoveHasCompleted(cache: database.cacheWriter))
        }
    }

    /// The one-time move on a device that has already split.
    ///
    /// EXPECTED TO FAIL BEFORE THE MOVE with: `count("libraryEntry", in:
    /// database.cacheWriter)` reading nil — there was no `v13` to recreate the
    /// table in the cache file and nothing to copy the rows into it, so the
    /// three rows stayed in the reader's file (and in the backup).
    @Test("Rows already in the reader's file are carried into the cache file, once")
    func splitDeviceRowsMoveIntoTheCacheFile() throws {
        let name = testName()
        defer { cleanUp(name) }
        try seedSplitDevice(named: name)

        try autoreleasepool {
            let database = try AppDatabase.onDisk(named: name)
            #expect(try count("libraryEntry", in: database.cacheWriter) == 3)
            #expect(try count("libraryMetadata", in: database.cacheWriter) == 1)
            #expect(try count("libraryEntry", in: database.libraryWriter) == nil)
            #expect(try count("libraryMetadata", in: database.libraryWriter) == nil)
            // The split marker is untouched, so the next open does not try to
            // split again — and the reader's own table is still where it was.
            #expect(try AppDatabase.splitHasCompleted(library: database.libraryWriter))
            #expect(try count("ownedVolume", in: database.libraryWriter) != nil)
        }

        // A second open finds nothing to move and changes nothing.
        try autoreleasepool {
            let reopened = try AppDatabase.onDisk(named: name)
            #expect(try count("libraryEntry", in: reopened.cacheWriter) == 3)
            #expect(try count("libraryEntry", in: reopened.libraryWriter) == nil)
        }
    }

    /// The interruption. Killed after any one step, the rows must still be in
    /// the cache file (the copy is the first step and the only one the app
    /// reads from), the reader's file must still have them until the drop, and
    /// finishing the job later must leave exactly three rows in the cache
    /// file and none in the reader's.
    ///
    /// EXPECTED TO FAIL BEFORE THE MOVE with: `moveLibraryCacheToCacheFile`
    /// did not exist — a compile failure, which proves nothing about
    /// behaviour. The behavioural claim is the `inLibrary` line: written
    /// drop-first, or dropping after an unverified copy, `.copy` would leave
    /// the reader's file without the table and this reads nil, not 3.
    @Test("Interrupted after any step, no row is lost", arguments: AppDatabase.SplitStep.allCases)
    func interruptionLosesNothing(stopping step: AppDatabase.SplitStep) throws {
        let name = testName()
        defer { cleanUp(name) }
        try seedSplitDevice(named: name)
        let cachePath = try url(for: name).path

        try autoreleasepool {
            // The full cache migrator now, so v13 has recreated the empty pair
            // and the `libraryMove` marker table, exactly as `onDisk` would.
            let cache = try AppDatabase.openPool(named: name, migrator: AppDatabase.migrator)
            let library = try AppDatabase.openPool(
                named: AppDatabase.libraryName(for: name), migrator: AppDatabase.libraryMigrator
            )
            try AppDatabase.moveLibraryCacheToCacheFile(
                cachePath: cachePath, library: library, stoppingAfter: step
            )

            let inCache = try count("libraryEntry", in: cache)
            let inLibrary = try count("libraryEntry", in: library)
            #expect(inCache == 3, "stopping after \(step) left the cache file short")
            #expect(
                inLibrary == (step < .drop ? 3 : nil),
                "stopping after \(step) left the wrong thing in the reader's file"
            )
            let marked = try AppDatabase.libraryCacheMoveHasCompleted(cache: cache)
            #expect(marked == (step >= .mark), "the marker is written after verify and before drop")
        }

        // The next launch finishes what it started.
        try autoreleasepool {
            let database = try AppDatabase.onDisk(named: name)
            #expect(
                try count("libraryEntry", in: database.cacheWriter) == 3,
                "resuming after \(step) lost or duplicated a row"
            )
            #expect(try count("libraryMetadata", in: database.cacheWriter) == 1)
            #expect(try count("libraryEntry", in: database.libraryWriter) == nil)
            #expect(try AppDatabase.libraryCacheMoveHasCompleted(cache: database.cacheWriter))
        }
    }

    /// The refusal: when the two files disagree about the columns, nothing is
    /// copied, nothing is marked and — the point — nothing is dropped, so the
    /// reader's file is exactly as it was and the next launch can try again.
    ///
    /// EXPECTED TO FAIL BEFORE THE MOVE with: a compile failure, as above. The
    /// behavioural claim is `inLibrary == 3` after the throw: a move that
    /// dropped before verifying would read nil here.
    @Test("A table whose columns disagree between the two files is not moved, and not dropped")
    func refusesToMoveWhenTheColumnsDisagree() throws {
        let name = testName()
        defer { cleanUp(name) }
        try seedSplitDevice(named: name)
        let cachePath = try url(for: name).path

        try autoreleasepool {
            let cache = try AppDatabase.openPool(named: name, migrator: AppDatabase.migrator)
            let library = try AppDatabase.openPool(
                named: AppDatabase.libraryName(for: name), migrator: AppDatabase.libraryMigrator
            )
            // A column the cache file does not have — the same simulated drift
            // `AppDatabaseSplitRuleTests` uses, on the other file.
            try library.write { db in
                try db.execute(sql: "ALTER TABLE libraryEntry ADD COLUMN driftedColumn TEXT")
            }

            #expect {
                try AppDatabase.moveLibraryCacheToCacheFile(cachePath: cachePath, library: library)
            } throws: { error in
                guard case AppDatabase.SplitError.schemaDrift(let table, _, _) = error else { return false }
                return table == "libraryEntry"
            }
            #expect(try count("libraryEntry", in: library) == 3)
            #expect(try count("libraryMetadata", in: library) == 1)
            #expect(try count("libraryEntry", in: cache) == 0)
            #expect(try AppDatabase.libraryCacheMoveHasCompleted(cache: cache) == false)
        }
    }

    /// Why the copy is `INSERT OR REPLACE` and not the split's `OR IGNORE`.
    ///
    /// The one way the cache file can already hold a library row before the
    /// move is a split whose own drop failed, leaving a stale snapshot behind;
    /// the reader's file is what every build since read and wrote, so it is
    /// the truth. With `IGNORE` the stale row would win, the `EXCEPT`
    /// verification would throw `verificationFailed(table: "libraryEntry",
    /// missingRows: 1)`, and — since a failed verification drops nothing —
    /// the reader's file would keep its 24.7 MB copy in the backup on every
    /// launch, forever.
    ///
    /// EXPECTED TO FAIL BEFORE THE MOVE with: a compile failure, as above.
    /// Written `OR IGNORE`, `#expect(payload == "entry-1")` reads "stale".
    @Test("On a clash, the reader's file's row wins over a stale cache-file row")
    func readerFileRowsWinOverStaleCacheRows() throws {
        let name = testName()
        defer { cleanUp(name) }
        try seedSplitDevice(named: name)
        let cachePath = try url(for: name).path

        try autoreleasepool {
            let cache = try AppDatabase.openPool(named: name, migrator: AppDatabase.migrator)
            try cache.write { db in
                try db.execute(
                    sql: "INSERT INTO libraryEntry (seriesId, payload) VALUES (1, ?)",
                    arguments: [Data("stale".utf8)]
                )
            }
            let library = try AppDatabase.openPool(
                named: AppDatabase.libraryName(for: name), migrator: AppDatabase.libraryMigrator
            )
            try AppDatabase.moveLibraryCacheToCacheFile(cachePath: cachePath, library: library)

            let payload = try cache.read { db in
                try Data.fetchOne(db, sql: "SELECT payload FROM libraryEntry WHERE seriesId = 1")
            }
            #expect(payload == Data("entry-1".utf8))
            #expect(try count("libraryEntry", in: cache) == 3)
            #expect(try count("libraryEntry", in: library) == nil)
        }
    }

    /// The device that installed before the split and upgrades straight to
    /// this build: its cache file still holds the live library rows from v7,
    /// and its reader's file gets L1's empty pair. The move must copy nothing
    /// over those rows and drop only the empty pair — clearing the destination
    /// first would throw away 24.7 MB to copy zero rows.
    ///
    /// EXPECTED TO FAIL BEFORE THE MOVE with: `count("libraryEntry", in:
    /// database.cacheWriter)` reading nil — the split dropped the table out of
    /// the cache file along with the shelf.
    @Test("A pre-split device keeps the library rows already in its cache file")
    func preSplitDeviceKeepsItsCacheRows() throws {
        let name = testName()
        defer { cleanUp(name) }

        try autoreleasepool {
            let legacy = try AppDatabase.openPool(named: name, migrator: AppDatabase.migrator)
            try seedLibraryCache(into: legacy)
            try legacy.write { db in
                try db.execute(
                    sql: "INSERT INTO shelfEntry (seriesId, kind, addedAt, payload) VALUES (?, ?, ?, ?)",
                    arguments: [3397, "saved", Date(timeIntervalSince1970: 0), Data("s".utf8)]
                )
            }
        }

        try autoreleasepool {
            let database = try AppDatabase.onDisk(named: name)
            #expect(try count("libraryEntry", in: database.cacheWriter) == 3)
            #expect(try count("libraryMetadata", in: database.cacheWriter) == 1)
            #expect(try count("libraryEntry", in: database.libraryWriter) == nil)
            // The control: the split still ran, and in its own direction.
            #expect(try count("shelfEntry", in: database.libraryWriter) == 1)
            #expect(try count("shelfEntry", in: database.cacheWriter) == nil)
        }
    }

    /// `LibrarySnapshot` reads and writes the pair through `cacheWriter`. On
    /// `inMemory()` the two writers are one queue and nothing can tell; on two
    /// files a walk must land in the cache file and the reader's file must
    /// not even have the table.
    ///
    /// EXPECTED TO FAIL BEFORE THE MOVE with: `try? database.libraryWriter
    /// .write { DELETE FROM libraryEntry … }` in `writeCache` writing the two
    /// rows into the reader's file, so `count("libraryEntry", in:
    /// database.cacheWriter)` reads nil (no table after the split) and the
    /// reader's file reads 2.
    @Test("A walk is written to the cache file, not the reader's")
    func snapshotWritesToTheCacheFile() async throws {
        let name = testName()
        defer { cleanUp(name) }

        let database = try AppDatabase.onDisk(named: name)
        let snapshot = LibrarySnapshot(library: TwoEntries(), database: database)
        let walked = await snapshot.load()
        #expect(walked.entries.count == 2)

        #expect(try count("libraryEntry", in: database.cacheWriter) == 2)
        #expect(try count("libraryMetadata", in: database.cacheWriter) == 1)
        #expect(try count("libraryEntry", in: database.libraryWriter) == nil)

        // And read back from the same place: a fresh snapshot over the same
        // files answers from disk without a request.
        let provider = TwoEntries()
        let again = LibrarySnapshot(library: provider, database: database)
        let fromDisk = await again.load().entries.count
        #expect(fromDisk == 2)
        #expect(provider.calls == 0, "the cache file had the walk; no request was needed")
    }

    /// Two entries, one page, counting the requests.
    final class TwoEntries: LibraryProviding, @unchecked Sendable {
        private let lock = NSLock()
        private var counted = 0

        var calls: Int { lock.withLock { counted } }

        func library(page: Int, limit: Int) async -> [LibraryEntry] {
            lock.withLock { counted += 1 }
            guard page == 1 else { return [] }
            return [1, 2].map { id in
                LibraryEntry(
                    id: id, seriesId: id, state: .reading, progressChapter: nil,
                    progressVolume: nil, rating: nil, note: nil, startDate: nil,
                    finishDate: nil, numberOfRereads: nil, priority: nil,
                    isPrivate: nil, readLink: nil, series: nil
                )
            }
        }
        func recommendationStatus() async throws(APIError) -> RecommendationStatus { throw APIError.offline }
        func recommendations(
            limit: Int, page: Int, excluding: [Int]
        ) async -> PersonalRecommendations { PersonalRecommendations() }
        func hiddenTagIDs() async -> Set<Int>? { [] }
        func topGenres() async -> [TopGenre]? { [] }
        func update(seriesId: Int, change: LibraryChange) async throws(APIError) {}
        func add(seriesId: Int, state: LibraryEntry.State) async throws(APIError) -> Bool { true }
        func remove(seriesId: Int) async throws(APIError) {}
    }
}
