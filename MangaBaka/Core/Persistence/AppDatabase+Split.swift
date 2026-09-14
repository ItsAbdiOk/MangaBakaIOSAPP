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
extension AppDatabase {
    static let splitLogger = Logger(
        subsystem: "dev.abdirahmanmohamed.mangabaka", category: "database-split"
    )

    /// How far to get before stopping, so a test can simulate being killed
    /// mid-migration. `.drop` is the whole job and is what the app runs.
    ///
    /// Ordered deliberately: this is the order the steps must happen in, and
    /// `LibrarySplitTests` walks it stopping at each one in turn.
    enum SplitStep: Int, Comparable, CaseIterable, Sendable {
        case copy
        case verify
        case mark
        case drop

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    enum SplitError: Error, Equatable {
        /// A row in the cache file was not found, identically, in the
        /// reader's file after the copy. Nothing is dropped.
        case verificationFailed(table: String, missingRows: Int)
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
                try db.inTransaction {
                    for table in present {
                        try db.execute(
                            sql: "INSERT OR IGNORE INTO main.\(table) SELECT * FROM cache.\(table)"
                        )
                    }
                    return .commit
                }
                guard last > .copy else { return }

                // Whole-row `EXCEPT`, not a count comparison: it proves every
                // source row arrived *identically*, and it is the check that
                // fails loudly if the two schemas ever drift into different
                // column orders rather than silently copying the wrong
                // columns into each other.
                for table in present {
                    let missing = try Int.fetchOne(db, sql: """
                        SELECT COUNT(*) FROM (
                            SELECT * FROM cache.\(table) EXCEPT SELECT * FROM main.\(table)
                        )
                        """) ?? 0
                    guard missing == 0 else {
                        throw SplitError.verificationFailed(table: table, missingRows: missing)
                    }
                }
                guard last > .verify else { return }

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

    /// Records that the copy is done and verified. One row, id 1.
    private static func mark(_ db: Database) throws {
        try db.execute(
            sql: "INSERT OR REPLACE INTO main.librarySplit (id, completedAt) VALUES (1, ?)",
            arguments: [Date()]
        )
    }

    /// Keeps the cache file out of iCloud and iTunes backups.
    ///
    /// MEASURED by the review: 17 MB in Application Support, 82 % of it rows
    /// the app can fetch again. Application Support is backed up by default,
    /// so every one of those bytes was going up nightly for nothing. Only the
    /// cache file is excluded — the reader's file is exactly what a backup is
    /// for, and is the reason this could not be done before the split.
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
