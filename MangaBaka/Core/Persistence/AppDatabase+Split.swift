import Foundation
import GRDB
import OSLog

/// Moving the reader's tables out of the cache file, once, per device (Q10).
///
/// Every device that installed the app before the split has one
/// `mangabaka.sqlite` holding both halves. This copies the reader's tables
/// into `mangabaka-library.sqlite`, verifies that every row arrived, records
/// that it did, and only then drops them from the cache file — **in that
/// order, never another**. Interrupted at any point, the worst case is that
/// the rows exist in both files and the next launch finishes the job; there
/// is no point at which a row exists in neither.
///
/// And, since 2026-09-14, the same machinery run the other way for the
/// library cache: `moveLibraryCacheToCacheFile` carries `libraryEntry` and
/// `libraryMetadata` *out of* the reader's file and back into the cache file,
/// so the 24.7 MB copy of the account's library stops going into the backup
/// (see `readerTables`). Same four steps, same order, same guarantees.
extension AppDatabase {
    static let splitLogger = Logger(
        subsystem: "dev.abdirahmanmohamed.mangabaka", category: "database-split"
    )

    /// How far to get before stopping, so a test can simulate being killed
    /// mid-migration. `.drop` is the whole job and is what the app runs.
    ///
    /// Ordered deliberately: this is the order the steps must happen in, and
    /// `LibrarySplitTests` walks it stopping at each one in turn — as does
    /// `LibraryCacheMoveTests` for the move in the other direction, which
    /// shares the steps and the helpers below.
    enum SplitStep: Int, Comparable, CaseIterable, Sendable {
        case copy
        case verify
        case mark
        case drop

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    enum SplitError: Error, Equatable {
        /// A source row was not found, identically, in the destination file
        /// after the copy. Nothing is dropped.
        case verificationFailed(table: String, missingRows: Int)
        /// The two files disagree about what this table's columns are, so
        /// there is no honest way to copy it. Nothing is copied or dropped.
        case schemaDrift(table: String, cache: [String], library: [String])
    }

    /// Whether the reader's tables have already been moved out of the cache
    /// file on this device. `onDiskResettingIfCorrupt` asks before it decides
    /// whether a corrupt cache file can be deleted in silence.
    static func splitHasCompleted(library: any DatabaseWriter) throws -> Bool {
        try library.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM librarySplit") ?? 0 > 0
        }
    }

    /// Copies, verifies, marks, drops.
    ///
    /// Driven from the reader's connection with the cache file attached, so
    /// each step writes to exactly one of the two databases: SQLite does not
    /// commit atomically across attached databases when either is in WAL mode
    /// (it is atomic per database, not across the set), and a step that wrote
    /// to both could therefore half-commit. Copy and mark write only to the
    /// reader's file; drop writes only to the cache file.
    ///
    /// `INSERT OR IGNORE`, not `OR REPLACE`: on a retry after an interrupted
    /// copy the destination may already hold some of these rows, and what is
    /// there is never older than what is being copied.
    ///
    /// The marker is what makes the retry safe in the other direction. Without
    /// it, a device interrupted after the copy but before the drop would
    /// re-copy on the next launch — and if the reader had meanwhile removed
    /// something from their shelf, the stale row still sitting in the cache
    /// file would come back from the dead. With it, "copied and verified" is
    /// remembered, and the only work left is the drop.
    static func splitReaderTables(
        cachePath: String,
        library: any DatabaseWriter,
        stoppingAfter last: SplitStep = .drop
    ) throws {
        let alreadyCopied = try splitHasCompleted(library: library)

        try library.writeWithoutTransaction { db in
            // SQLite refuses `ATTACH` inside a transaction ("cannot ATTACH
            // database within transaction"), so the transactions below are
            // opened by hand rather than by wrapping this whole block.
            try db.execute(sql: "ATTACH DATABASE ? AS cache", arguments: [cachePath])
            defer { try? db.execute(sql: "DETACH DATABASE cache") }

            let present = try readerTables.filter { try db.tableExists($0, in: "cache") }
            guard !present.isEmpty else {
                // Nothing to move: a fresh install whose cache file was
                // created after the split, or a device that finished it and
                // has since lost the marker with its reader file. Either way
                // the cache file provably holds none of the reader's rows.
                if !alreadyCopied { try mark(db) }
                return
            }

            if !alreadyCopied {
                let copied = try copyAndVerify(present, .split, in: db, stoppingAfter: last)
                guard copied else { return }
                try mark(db)
            }
            guard last > .mark else { return }

            try db.inTransaction {
                for table in present {
                    try db.execute(sql: "DROP TABLE cache.\(table)")
                }
                return .commit
            }
            splitLogger.info("Moved \(present.count) reader tables out of the cache file.")
        }
    }

    /// Copies each table by name, then proves every source row arrived.
    ///
    /// **By name, not `SELECT *`.** Work-list 56: the copy used to be
    /// `INSERT INTO main.X SELECT * FROM cache.X`, which is positional, and the
    /// verification below was described as the thing that "fails loudly if the
    /// two schemas ever drift into different column orders". It cannot. Reorder
    /// `shelfEntry` to `(seriesId, kind, addedAt, payload)` on one side only and
    /// `kind` receives the date; SQLite's type affinity accepts both; the verify
    /// then compares `SELECT *` against `SELECT *`, which yields each file's own
    /// order, so the two tuples are identical and `EXCEPT` returns zero. Copy,
    /// verify, mark and drop all report success and the reader's shelf is
    /// permanently scrambled. Only an arity change was ever caught (`EXCEPT`
    /// errors on mismatched column counts). Reasoned against SQLite's `EXCEPT`
    /// semantics on 2026-09-14, not run.
    ///
    /// So: the column names are compared first and a real difference throws
    /// `schemaDrift` before anything is written, and both the copy and the
    /// verify name their columns, in the cache file's order, on both sides — a
    /// pure reorder now copies correctly instead of scrambling, and a column
    /// present on one side only refuses instead of copying wrong.
    /// `LibrarySplitTests.schemasMatch` still compares the two `sqlite_master`
    /// texts; that test remains the check on *declaration* drift, and this is
    /// the one the device runs.
    ///
    /// Direction-neutral since the library cache started moving the other
    /// way: `direction` names the attached schemas (`main` is always the
    /// reader's file, `cache` always the cache file, whichever way the rows
    /// are going) and the `INSERT OR …` clause — `IGNORE` for the split,
    /// `REPLACE` for the move back; each caller says why. The copy is one
    /// transaction and writes only the destination file,
    /// so it is atomic for that file on its own.
    ///
    /// - Returns: whether to go on and `mark`. False when `last` stopped the
    ///   job at `.copy` or `.verify`.
    struct CopyDirection {
        let source: String
        let destination: String
        let onConflict: String
        /// Cache → reader's file, first-wins. See `splitReaderTables`.
        static let split = CopyDirection(source: "cache", destination: "main", onConflict: "IGNORE")
        /// Reader's file → cache, reader's copy wins. See `moveLibraryCacheToCacheFile`.
        static let libraryMove = CopyDirection(
            source: "main", destination: "cache", onConflict: "REPLACE"
        )
    }

    private static func copyAndVerify(
        _ present: [String], _ direction: CopyDirection, in db: Database, stoppingAfter last: SplitStep
    ) throws -> Bool {
        let (source, destination) = (direction.source, direction.destination)
        let onConflict = direction.onConflict
        let plan = try copyPlan(for: present, db)
        try db.inTransaction {
            for step in plan {
                try db.execute(sql: """
                    INSERT OR \(onConflict) INTO \(destination).\(step.table) (\(step.columns))
                    SELECT \(step.columns) FROM \(source).\(step.table)
                    """)
            }
            return .commit
        }
        guard last > .copy else { return false }

        // Whole-row `EXCEPT`, not a count comparison: it proves every source
        // row arrived *identically*, value by value.
        for step in plan {
            let missing = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM (
                    SELECT \(step.columns) FROM \(source).\(step.table)
                    EXCEPT SELECT \(step.columns) FROM \(destination).\(step.table)
                )
                """) ?? 0
            guard missing == 0 else {
                throw SplitError.verificationFailed(table: step.table, missingRows: missing)
            }
        }
        return last > .verify
    }

    /// The column list to copy each table by, once the two files have been
    /// checked to agree about what those columns are.
    private static func copyPlan(
        for tables: [String], _ db: Database
    ) throws -> [(table: String, columns: String)] {
        try tables.map { table in
            let cache = try columnNames(of: table, in: "cache", db)
            let library = try columnNames(of: table, in: "main", db)
            // Sets, not sequences: a pure reorder is copyable by name and is
            // handled below. A column on one side only is not.
            guard Set(cache) == Set(library) else {
                throw SplitError.schemaDrift(table: table, cache: cache, library: library)
            }
            return (table, cache.map { "\"\($0)\"" }.joined(separator: ", "))
        }
    }

    /// `PRAGMA table_info` for one attached schema, in declaration order.
    private static func columnNames(
        of table: String, in schema: String, _ db: Database
    ) throws -> [String] {
        try Row.fetchAll(db, sql: "PRAGMA \(schema).table_info(\(table))").map { row in
            let name: String = row["name"]
            return name
        }
    }

    /// Records that the copy is done and verified. One row, id 1.
    private static func mark(_ db: Database) throws {
        try db.execute(
            sql: "INSERT OR REPLACE INTO main.librarySplit (id, completedAt) VALUES (1, ?)",
            arguments: [Date()]
        )
    }

    // MARK: - The library cache, moved the other way

    /// Whether `moveLibraryCacheToCacheFile` has copied and verified the
    /// library cache into this cache file. Lives in the cache file, unlike
    /// `librarySplit`, because it describes the *destination*: a cache reset
    /// takes the marker with the empty table it now describes, and the next
    /// open copies again — from a reader's file that still has the rows if
    /// the drop never ran, or from nothing if it did.
    static func libraryCacheMoveHasCompleted(cache: any DatabaseReader) throws -> Bool {
        try cache.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM libraryMove") ?? 0 > 0
        }
    }

    /// Copies, verifies, marks, drops — `libraryEntry` and `libraryMetadata`,
    /// reader's file to cache file. The mirror image of `splitReaderTables`,
    /// and it runs after it, from the same connection, for the same reason:
    /// each step writes to exactly one of the two files.
    ///
    /// **What each step leaves behind, if the app dies or the step throws.**
    /// The app reads the library cache from the cache file only; it never
    /// falls back to the reader's file. So:
    /// - before `.copy` commits: the cache file's pair is as it was (empty on
    ///   a split device, the pre-split rows on one that never split), the
    ///   reader's file is untouched. The app sees an empty or old cache and
    ///   walks the library again — one re-download, not a loss. Next open
    ///   retries from the top.
    /// - after `.copy`, `.verify`: rows in both files, no marker. Next open
    ///   copies again (`REPLACE`, so identical), verifies, marks, drops.
    /// - after `.mark`: rows in both files, marker set. Next open only drops.
    /// - after `.drop`: rows in the cache file only. Done; nothing to retry.
    /// The reader's file is never written before the copy has been verified,
    /// and `LibraryCacheMoveTests.interruptionLosesNothing` walks each stop.
    ///
    /// `INSERT OR REPLACE`, unlike the split's `OR IGNORE`, because here the
    /// *source* is the authoritative copy: until this ran, every build read
    /// the library cache from the reader's file, and whatever the cache file's
    /// pair holds is either empty (v13 created it) or a snapshot the split
    /// left behind when its own drop failed. `IGNORE` in that second case
    /// would keep the stale row, fail the `EXCEPT` verification, and — since
    /// nothing is dropped after a failed verification — leave 24.7 MB in the
    /// backup on every launch, forever. `REPLACE` lets the move finish; the
    /// one thing it cannot undo is a stale cache-file row whose id the
    /// reader's file no longer has, which lives until the next walk (six
    /// hours at most), and is a cache row either way.
    ///
    /// The pre-split device that upgrades straight to this build is the case
    /// that rules out clearing the destination first: its cache file still
    /// holds the 945 live rows from v7 and its reader's file an empty pair
    /// from L1, so a clear-then-copy would throw the whole cache away to copy
    /// nothing. `REPLACE` over an empty source touches none of it.
    static func moveLibraryCacheToCacheFile(
        cachePath: String,
        library: any DatabaseWriter,
        stoppingAfter last: SplitStep = .drop
    ) throws {
        try library.writeWithoutTransaction { db in
            try db.execute(sql: "ATTACH DATABASE ? AS cache", arguments: [cachePath])
            defer { try? db.execute(sql: "DETACH DATABASE cache") }

            // `main`, not `cache`: the source is the reader's file this time.
            let present = try libraryCacheTables.filter { try db.tableExists($0, in: "main") }
            guard !present.isEmpty else { return }

            let alreadyCopied = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cache.libraryMove") ?? 0 > 0
            if !alreadyCopied {
                let copied = try copyAndVerify(present, .libraryMove, in: db, stoppingAfter: last)
                guard copied else { return }
                try db.execute(
                    sql: "INSERT OR REPLACE INTO cache.libraryMove (id, completedAt) VALUES (1, ?)",
                    arguments: [Date()]
                )
            }
            guard last > .mark else { return }

            try db.inTransaction {
                for table in present {
                    try db.execute(sql: "DROP TABLE main.\(table)")
                }
                return .commit
            }
            // A dropped table frees pages; it does not shrink the file, and
            // a backup copies bytes, not rows. Measured on the real simulator
            // file right after this drop, 2026-09-14: 3,585 of 4,145 pages
            // free, the file still 17 MB — the whole saving this move exists
            // for, still on disk until this. `VACUUM main` rewrites the
            // reader's file only; the attached cache is left alone. Once,
            // here, because `present` is empty on every later open.
            let before = try Int.fetchOne(db, sql: "PRAGMA main.page_count") ?? 0
            try db.execute(sql: "VACUUM main")
            let after = try Int.fetchOne(db, sql: "PRAGMA main.page_count") ?? 0
            splitLogger.info("Moved the library cache; reader's file \(before) → \(after) pages.")
        }
    }

    /// Keeps the cache file out of iCloud and iTunes backups.
    ///
    /// MEASURED by the review: 17 MB in Application Support, 82 % of it rows
    /// the app can fetch again. Application Support is backed up by default,
    /// so every one of those bytes was going up nightly for nothing. Only the
    /// cache file is excluded — the reader's file is exactly what a backup is
    /// for, and is the reason this could not be done before the split. Since
    /// 2026-09-14 the library cache is on this side of the line too: 24.7 MB,
    /// 945 rows, all of it the server's (see `readerTables`).
    ///
    /// Best-effort: a failure here costs an oversized backup, not correctness,
    /// and the sidecars do not exist until the first write.
    static func excludeFromBackup(named name: String) {
        guard let directory = try? applicationSupportDirectory() else { return }
        for suffix in ["", "-wal", "-shm"] {
            var url = directory.appendingPathComponent(name + suffix)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            do {
                try url.setResourceValues(values)
            } catch let error {
                splitLogger.debug("Could not exclude \(name + suffix) from backup: \(error)")
            }
        }
    }
}
