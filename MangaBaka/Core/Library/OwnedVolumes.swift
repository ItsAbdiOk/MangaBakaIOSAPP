import Foundation
import GRDB

/// The volumes the reader has on their own shelf — the physical one.
///
/// A tick per row of "Volumes on record". It answers the question that shelf
/// cannot: not *what exists* but *what I am missing*, which for a long series
/// is the thing a reader standing in a bookshop wants to know.
///
/// **User data, so `libraryWriter`'s file** (Q10): there is no account this
/// syncs to and nothing it could be refetched from, so it lives beside the
/// shelf and the history in the file that is backed up, and never in the
/// cache file that is not. `AppDatabase+Schema`'s `L2_ownedVolumes` creates
/// the table in that file only — `OwnedVolumesTests.tableIsInTheLibraryFile`
/// asserts the cache file does not have it.
///
/// A consequence worth stating: `AppDatabase.inMemory()` runs only the cache
/// migrator, so a store built on it (previews, the corrupt-database fallback
/// in `AppServices.makeDatabase`) has no table and every call here throws
/// `SQLITE_ERROR` "no such table". The page treats that as "nothing owned and
/// nothing to tick" rather than crash — see `SeriesDetailView.loadOwned`.
actor OwnedVolumes {
    // Internal, not private: `OwnedVolumes+Reconcile.swift` writes through it.
    let database: AppDatabase
    private let clock: any Clock

    init(database: AppDatabase, clock: any Clock = SystemClock()) {
        self.database = database
        self.clock = clock
    }

    /// Every volume ticked on one series.
    func owned(for seriesID: Int) throws -> Set<OwnedVolumeKey> {
        let rows = try database.libraryWriter.read { db in
            try OwnedVolumeRow.filter(Column("seriesId") == seriesID).fetchAll(db)
        }
        return Set(rows.map { OwnedVolumeKey(seriesID: $0.seriesId, identity: $0.identity) })
    }

    /// Ticks or unticks one volume. Ticking one already ticked keeps the
    /// original `ownedAt` — the reader did not buy it again.
    func setOwned(_ key: OwnedVolumeKey, _ owned: Bool) throws {
        let now = clock.now
        try database.libraryWriter.write { db in
            if owned {
                try OwnedVolumeRow(seriesId: key.seriesID, identity: key.identity, ownedAt: now)
                    .insert(db, onConflict: .ignore)
            } else {
                _ = try OwnedVolumeRow
                    .filter(Column("seriesId") == key.seriesID && Column("identity") == key.identity)
                    .deleteAll(db)
            }
        }
    }

    /// How many volumes are ticked across every series, for Settings to say
    /// what erasing would remove. **Nothing calls this yet** (2026-09-15):
    /// no erase control exists. When one does, the count includes ticks
    /// whose row no longer appears on any shelf, and the wording Abdi chose
    /// is "N ticks (some may be for volumes no longer listed)".
    func count() throws -> Int {
        try database.libraryWriter.read { db in try OwnedVolumeRow.fetchCount(db) }
    }
}

/// One ticked volume. Keyed on the series and `OwnedVolumeKey.identity`
/// together, so the same ISBN ticked under two series (an omnibus MangaBaka
/// files twice) is two rows, not one row that the second series un-ticks.
struct OwnedVolumeRow: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "ownedVolume"

    var seriesId: Int
    var identity: String
    var ownedAt: Date
}
