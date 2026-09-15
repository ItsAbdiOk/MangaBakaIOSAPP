import Foundation
import GRDB

/// The on-device storage: **two** files on the user's own device, not a
/// server. Nothing here leaves the phone, and the developer has no access to
/// it.
///
/// **Why two (Q10, approved 2026-09-14).** It was one, and that one file mixed
/// what can be fetched again with what cannot. Two things followed, both
/// measured by the review: the corruption reset took the shelf and the history
/// with it (item 78's salvage is a rescue, not a fix), and iCloud backed up all
/// 17 MB of it, 82 % of which is re-downloadable.
///
/// - `cacheWriter` — `mangabaka.sqlite`. Feeds, series payloads, detail pages,
///   cadence estimates, and the library cache (`libraryEntry`,
///   `libraryMetadata`). Disposable, excluded from backup, discarded in
///   silence if corrupt.
/// - `libraryWriter` — `mangabaka-library.sqlite`. `shelfEntry` (the reader's
///   saves and skips), `viewedEntry` (their history), the taste ledger
///   (`tagAffinity`, `tasteSource`, `tasteSeen`, `tasteContribution`) and
///   `ownedVolume`. Every one exists nowhere else — there is no account they
///   sync to. Backed up; a corrupt one is salvaged from and the reader is
///   told.
///
/// `libraryEntry`/`libraryMetadata` sat on the backed-up side until
/// 2026-09-14, on a judgement call about their offline value. Measured that
/// day at 24.7 MB of a 17 MB-total device file (945 rows), every byte a copy
/// of what the account holds on the server; Abdi's decision was that it does
/// not belong in the backup. `moveLibraryCacheToCacheFile` carries it across
/// once per device, and a restore from backup now shows an empty library
/// until the next walk (see `readerTables`).
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
    /// The disposable half: `series`, `feedEntry`, `feedMetadata`,
    /// `seriesDetail`, `cadenceEntry`, and since 2026-09-14 `libraryEntry`
    /// and `libraryMetadata`. Every row in here can be fetched again, so this
    /// file is excluded from iCloud backup and a corrupt one is thrown away
    /// without telling anybody (Q10).
    let cacheWriter: any DatabaseWriter

    /// The irreplaceable half: `shelfEntry`, `viewedEntry`, the four taste
    /// tables, and `ownedVolume`. There is no account any of them sync to —
    /// if this file goes they are gone, so it is backed up and a corrupt one
    /// still takes the salvage path and still tells the reader.
    let libraryWriter: any DatabaseWriter

    /// Both roles on one file: `inMemory()`, previews, and every test that
    /// wants a single database it can write any table through. The cache
    /// migrator creates every table there has ever been (see `migrator`), so
    /// one file is a superset of both schemas and no store can tell.
    init(writer: any DatabaseWriter) throws {
        cacheWriter = writer
        libraryWriter = writer
        try Self.migrator.migrate(writer)
    }

    /// Two files, each already migrated by `openPool`.
    init(migratedCache: any DatabaseWriter, migratedLibrary: any DatabaseWriter) {
        cacheWriter = migratedCache
        libraryWriter = migratedLibrary
    }

    /// The reader's file, derived from the cache file's name: `mangabaka.sqlite`
    /// keeps its name (so an existing install's cache is still its cache) and
    /// the new one is `mangabaka-library.sqlite`.
    static func libraryName(for cacheName: String) -> String {
        let url = URL(fileURLWithPath: cacheName)
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        return ext.isEmpty ? "\(stem)-library" : "\(stem)-library.\(ext)"
    }

    static func applicationSupportDirectory() throws -> URL {
        try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
    }

    /// Opens and migrates one file in Application Support.
    static func openPool(named name: String, migrator: DatabaseMigrator) throws -> any DatabaseWriter {
        let url = try applicationSupportDirectory().appendingPathComponent(name)

        var configuration = Configuration()
        // WAL so a read does not block the writer. (This comment used to say
        // "the cache is derived data: if the file is ever corrupt, losing it
        // costs a re-download, not user data" — untrue of the file it was
        // written about, and it was the stated justification for renaming
        // that file aside on any failure. It is true of `cacheWriter`'s file
        // and of nothing else, which is the whole point of the split.)
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
        }
        let pool = try DatabasePool(path: url.path, configuration: configuration)
        try migrator.migrate(pool)
        return pool
    }

    /// On-disk database in Application Support: the cache file, the reader's
    /// file, and the one-time move of the reader's tables from the first to
    /// the second.
    ///
    /// Throws rather than recovers; `onDiskResettingIfCorrupt` is the entry
    /// point the app uses.
    static func onDisk(named name: String = "mangabaka.sqlite") throws -> AppDatabase {
        let cache = try openPool(named: name, migrator: migrator)
        let library = try openPool(named: libraryName(for: name), migrator: libraryMigrator)
        finishOpening(library: library, named: name)
        return AppDatabase(migratedCache: cache, migratedLibrary: library)
    }

    /// What both entry points do once the two files are open: keep the cache
    /// out of the backup, move the reader's tables across if they are still
    /// in the cache file, and move the library cache back the other way if it
    /// is still in the reader's file.
    private static func finishOpening(library: any DatabaseWriter, named name: String) {
        excludeFromBackup(named: name)
        // A move that fails must not fail the open: each leaves the rows
        // where they already were (both only ever drop after a verified
        // copy), so the app runs exactly as it did before and the next
        // launch tries again. Split first, so that on a pre-split device the
        // cache file has already been settled before the move back reads it:
        // there the reader's file holds only L1's empty pair, the move copies
        // nothing over v7's live rows (`REPLACE`, so nothing is lost) and
        // drops the empty pair.
        guard let path = try? applicationSupportDirectory().appendingPathComponent(name).path else {
            splitLogger.error("No Application Support directory; the two files stay as they are.")
            return
        }
        do {
            try splitReaderTables(cachePath: path, library: library)
        } catch let error {
            splitLogger.error("Library split failed, retrying next launch: \(error, privacy: .public)")
        }
        do {
            try moveLibraryCacheToCacheFile(cachePath: path, library: library)
        } catch let error {
            splitLogger.error("Library cache move failed, retrying next launch: \(error, privacy: .public)")
        }
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
    }

    /// Opens both on-disk files, recovering from a file that exists but
    /// cannot be opened or migrated — corruption, a schema from a future
    /// version this build cannot read — rather than leaving that to `onDisk`'s
    /// caller to fall back to an in-memory database (which remembers nothing
    /// between launches) with no attempt to recover the on-disk path at all.
    ///
    /// **The two files are recovered differently, which is the point of the
    /// split (Q10).** The reader's file is renamed aside, salvaged from, and
    /// reported as a `.reset` so the shell can say so. The cache file is
    /// deleted and nobody is told: every row in it can be fetched again, and
    /// keeping a 14 MB copy of it in Application Support for diagnosis is the
    /// accumulation `pruneCorruptFiles` exists to stop, on bytes that teach
    /// nobody anything.
    ///
    /// **Only actual corruption resets.** This used to rename for *any* throw
    /// out of `onDisk`, and the one file then held `shelfEntry`,
    /// `viewedEntry` and `tagAffinity` — the reader's own saves, their history
    /// and the taste ledger, none of which the app can rebuild from the
    /// network. So a disk-full `ALTER TABLE` in a migration, a `SQLITE_BUSY`
    /// left by the previous process, or a bug in a future migration destroyed
    /// the shelf permanently and told the reader it "was reset". Every one of
    /// those is transient or fixable and none of them means the bytes are bad.
    /// Only `SQLITE_CORRUPT` and `SQLITE_NOTADB` do, and only those reset; any
    /// other failure returns nil with both files untouched, so the next launch
    /// can open them.
    ///
    /// Returns `nil` when a file was left alone, or when even a fresh file at
    /// the same path cannot be opened — at which point the caller's own
    /// in-memory fallback is what runs.
    static func onDiskResettingIfCorrupt(
        named name: String = "mangabaka.sqlite",
        now: () -> Date = Date.init
    ) -> OpenResult? {
        // The reader's file first, because a corrupt cache file salvages
        // *into* it: on a device that has not split yet, the reader's tables
        // are still in the cache file and deleting it would take them.
        guard let library = openRecoveringFromCorruption(
            named: libraryName(for: name), migrator: libraryMigrator,
            keepingCorruptCopy: true, now: now
        ) else { return nil }
        salvageIfNeeded(library, into: library.writer)

        // Whether the cache file can be deleted in silence. Before the split
        // has run it may still be the only copy of the shelf; after it, it
        // provably holds none of the reader's rows.
        let split: Bool
        do {
            split = try splitHasCompleted(library: library.writer)
        } catch {
            // D1: this used to be `try?` → `false`, the safe direction (it
            // makes the cache file's corrupt copy kept rather than deleted
            // outright), but silent — nothing on record said the check
            // itself had failed rather than genuinely answering "not split".
            splitLogger.error("splitHasCompleted failed, assuming not split: \(error, privacy: .public)")
            split = false
        }

        guard let cache = openRecoveringFromCorruption(
            named: name, migrator: migrator,
            keepingCorruptCopy: !split, now: now
        ) else { return nil }
        // Best-effort rescue of a pre-split cache file, into the reader's
        // file where those tables now belong.
        salvageIfNeeded(cache, into: library.writer)

        finishOpening(library: library.writer, named: name)

        // A cache reset on a device that has already split has lost the reader
        // nothing, so it says `.opened` and shows no toast — that is the whole
        // point of the split, and it is the case every device is in after one
        // successful launch. A reset of the reader's own file still speaks up,
        // and so does a cache reset *before* the split, because that file may
        // still have been the only copy of the shelf and a salvage that
        // recovered nothing is not proof that there was nothing to recover.
        let lostSomething = library.wasReset || (cache.wasReset && !split)
        return OpenResult(
            database: AppDatabase(migratedCache: cache.writer, migratedLibrary: library.writer),
            outcome: lostSomething ? .reset : .opened
        )
    }

    /// One recovered file: its writer, whether it was reset, and the corrupt
    /// copy left on disk for `salvage` to read (nil when there is nothing to
    /// salvage from, or when the corrupt file was deleted outright).
    struct RecoveredFile {
        let writer: any DatabaseWriter
        let wasReset: Bool
        let corruptCopy: URL?
    }

    /// Opens one file, resetting it if and only if its bytes are bad.
    ///
    /// `keepingCorruptCopy` renames rather than deletes: renaming leaves the
    /// bytes on disk for on-device diagnosis and, more importantly, for
    /// `salvage` to read rows back out of. It is false only for a cache file
    /// that provably holds nothing irreplaceable.
    private static func openRecoveringFromCorruption(
        named name: String,
        migrator: DatabaseMigrator,
        keepingCorruptCopy: Bool,
        now: () -> Date
    ) -> RecoveredFile? {
        do {
            return RecoveredFile(
                writer: try openPool(named: name, migrator: migrator), wasReset: false, corruptCopy: nil
            )
        } catch let error {
            guard isCorruption(error) else { return nil }
        }

        guard let directory = try? applicationSupportDirectory() else { return nil }
        let url = directory.appendingPathComponent(name)

        // Nothing to move aside means the failure was not "an existing file is
        // corrupt" — a fresh attempt at the same path would fail identically,
        // so this is not a case `.reset` should claim to have fixed.
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        var corruptCopy: URL?
        if keepingCorruptCopy {
            // Colons are not valid in a filename on APFS; ISO 8601's own
            // separator has to go.
            let stamp = ISO8601DateFormatter().string(from: now()).replacingOccurrences(of: ":", with: "-")
            let renamed = directory.appendingPathComponent("\(name).corrupt-\(stamp)")
            try? FileManager.default.removeItem(at: renamed)
            try? FileManager.default.moveItem(at: url, to: renamed)
            corruptCopy = renamed
        } else {
            try? FileManager.default.removeItem(at: url)
        }
        // WAL mode leaves sidecar files next to the main one; they belong to
        // the file that has just gone, and letting SQLite find them beside a
        // brand new file would have it try to replay someone else's
        // write-ahead log against a database that never made those writes.
        for suffix in ["-wal", "-shm"] {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name + suffix))
        }

        guard let fresh = try? openPool(named: name, migrator: migrator) else { return nil }
        if let corruptCopy {
            pruneCorruptFiles(in: directory, named: name, keeping: corruptCopy)
        }
        return RecoveredFile(writer: fresh, wasReset: true, corruptCopy: corruptCopy)
    }

    /// Pulls the reader's tables out of a corrupt file, if one was kept.
    /// Returns true when at least one row came back.
    @discardableResult
    private static func salvageIfNeeded(
        _ file: RecoveredFile, into destination: any DatabaseWriter
    ) -> Bool {
        guard let corruptCopy = file.corruptCopy else { return false }
        return salvage(into: destination, from: corruptCopy)
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

    /// Copies the irreplaceable tables out of the file being abandoned.
    ///
    /// The shelf is the reader's own saves and skips and the viewed list is
    /// their history; neither can be refetched, and both used to live in a
    /// file whose own doc comment called it disposable. A corrupt database
    /// often still reads in part, so this is worth attempting — and worth
    /// attempting per table with `try?`, because failing to salvage from a
    /// file that is by definition broken is the expected case, not an error
    /// to propagate, and one unreadable table must not lose the others.
    ///
    /// It now covers all of `salvagedTables`, not just the shelf and the
    /// history: the taste ledger and the split marker are in the same file
    /// and were being left behind. Not the library cache, since 2026-09-14:
    /// it is in the cache file, and re-downloadable (see `salvagedTables`).
    ///
    /// `INSERT OR IGNORE`: the destination is normally empty, but the
    /// pre-split cache file salvages into the reader's file, which may not
    /// be — what is already there is newer and wins.
    /// `writeWithoutTransaction` because SQLite refuses `ATTACH` inside one
    /// ("cannot ATTACH database within transaction"); each `INSERT` is then
    /// its own implicit transaction.
    ///
    /// Returns true when at least one row was recovered, which is what tells
    /// `onDiskResettingIfCorrupt` whether the reader lost anything.
    @discardableResult
    private static func salvage(into destination: any DatabaseWriter, from file: URL) -> Bool {
        let recovered: Int
        do {
            recovered = try destination.writeWithoutTransaction { db -> Int in
                try db.execute(sql: "ATTACH DATABASE ? AS salvage", arguments: [file.path])
                defer { try? db.execute(sql: "DETACH DATABASE salvage") }
                var rows = 0
                // `salvagedTables`, not `readerTables`: the split marker is in the
                // reader's file too and losing it can re-run the copy (work-list
                // 55). See that list for why the two are not the same list.
                for table in salvagedTables {
                    do {
                        try db.execute(
                            sql: "INSERT OR IGNORE INTO \(table) SELECT * FROM salvage.\(table)"
                        )
                        rows += db.changesCount
                    } catch let error as DatabaseError {
                        // Expected: the table may not exist in the broken file at
                        // all (a pre-v2 cache file has no `shelfEntry`), or its
                        // pages may be the unreadable ones.
                        splitLogger.debug("Salvage skipped \(table): \(error, privacy: .public)")
                    }
                }
                return rows
            }
        } catch {
            // D1: this used to be `try?` → `0`, indistinguishable from "the
            // attach and every table both genuinely had nothing to give back".
            // A whole-salvage failure (the attach itself, a locked file) is
            // different from that and worth a line, even though the outcome
            // to the caller is the same either way.
            splitLogger.error("salvage failed: \(error, privacy: .public)")
            recovered = 0
        }
        return recovered > 0
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
}
