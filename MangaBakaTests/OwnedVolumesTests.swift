import Foundation
import GRDB
import Testing
@testable import MangaBaka

/// The reader's own shelf on disk: which file it is in, that a tick comes
/// back, and that the key is merge's identity and not a second one.
///
/// Every test here fails on the code before this change with a compile error
/// (`OwnedVolumes`, `OwnedVolumeKey` and `OwnedVolumeRow` did not exist);
/// the one that would fail *differently* is `tableIsInTheLibraryFile`, whose
/// doc comment says how.
@Suite("Owned volumes")
struct OwnedVolumesTests {
    /// Two files, as on a device — not `inMemory()`, which runs only the
    /// cache migrator and so has no `ownedVolume` table at all (recorded on
    /// `OwnedVolumes`).
    private func makeDatabase() throws -> AppDatabase {
        let cache = try DatabaseQueue()
        try AppDatabase.migrator.migrate(cache)
        let library = try DatabaseQueue()
        try AppDatabase.libraryMigrator.migrate(library)
        return AppDatabase(migratedCache: cache, migratedLibrary: library)
    }

    /// The brief's rule: user data goes in the file that is backed up, and
    /// the migration must not touch the cache file.
    ///
    /// EXPECTED TO FAIL before `L2_ownedVolumes` with the first `#expect`
    /// false — `libraryMigrator` stopped at `L1_readerTables` and created no
    /// such table. Would ALSO fail, on the second `#expect`, on a version of
    /// this change that registered the table in `migrator` "so `inMemory()`
    /// has it": that puts an empty copy of a reader table in the file that is
    /// excluded from backup, which is the mistake the split exists to end.
    @Test("The table is in the reader's file and not the cache file")
    func tableIsInTheLibraryFile() throws {
        let database = try makeDatabase()
        #expect(try database.libraryWriter.read { db in try db.tableExists("ownedVolume") })
        #expect(try database.cacheWriter.read { db in try db.tableExists("ownedVolume") } == false)
        // The control: a table both files are meant to have, so the second
        // assertion is not passing on an empty cache file.
        #expect(try database.cacheWriter.read { db in try db.tableExists("series") })
    }

    /// Tick, read, untick, read.
    @Test("A tick comes back, and an untick takes it away")
    func roundTrip() async throws {
        let store = OwnedVolumes(database: try makeDatabase(), clock: TestClock())
        let key = OwnedVolumeKey(seriesID: 1, volume: isbnVolume(number: 3))

        try await store.setOwned(key, true)
        #expect(try await store.owned(for: 1) == [key])

        try await store.setOwned(key, false)
        #expect(try await store.owned(for: 1).isEmpty)
    }

    /// Ticking twice is one row with the first date. The reader did not buy
    /// it again.
    @Test("A second tick keeps the first ownedAt")
    func secondTickKeepsTheFirstDate() async throws {
        let clock = TestClock()
        let database = try makeDatabase()
        let store = OwnedVolumes(database: database, clock: clock)
        let key = OwnedVolumeKey(seriesID: 1, volume: isbnVolume(number: 3))

        try await store.setOwned(key, true)
        let first = clock.now
        clock.advance(by: 3_600)
        try await store.setOwned(key, true)

        let rows = try await database.libraryWriter.read { db in try OwnedVolumeRow.fetchAll(db) }
        #expect(rows.count == 1)
        #expect(rows.first?.ownedAt == first)
    }

    /// One series' ticks are not another's, even for the same ISBN — an
    /// omnibus MangaBaka files under two series is owned on each separately.
    @Test("Ticks are per series")
    func ticksArePerSeries() async throws {
        let store = OwnedVolumes(database: try makeDatabase(), clock: TestClock())
        let volume = isbnVolume(number: 3)
        try await store.setOwned(OwnedVolumeKey(seriesID: 1, volume: volume), true)

        #expect(try await store.owned(for: 2).isEmpty)
        #expect(try await store.count() == 1)
    }

    // MARK: - The key is merge's identity

    /// `VolumeEditions.merge` collapses two catalogues' rows for one ISBN,
    /// and which catalogue wins depends on which answered better that day.
    /// So a tick must survive the winner changing: same ISBN, same key.
    ///
    /// Fails on a key built from `EditionVolume.id`, which carries
    /// `edition.id` — the two keys below would differ and a reader's tick
    /// would vanish the morning Open Library timed out.
    @Test("An ISBN row is keyed on the ISBN alone, whichever catalogue won")
    func isbnRowIsKeyedOnTheISBN() {
        let fromANN = EditionVolume(
            number: 1, title: "Delicious in Dungeon (GN 1)", releaseDate: nil,
            isbn13: "9780316471855", format: .print, edition: annEdition, sourceLink: nil
        )
        let fromOpenLibrary = EditionVolume(
            number: 1, title: "Delicious in Dungeon, Vol. 1", releaseDate: nil,
            isbn13: "978-0-316-47185-5", format: .print, edition: openLibraryEdition, sourceLink: nil
        )
        let lhs = OwnedVolumeKey(seriesID: 1, volume: fromANN)
        let rhs = OwnedVolumeKey(seriesID: 1, volume: fromOpenLibrary)
        #expect(lhs == rhs)
        #expect(lhs.identity == "isbn:9780316471855")
    }

    /// A row with no ISBN is never merged, and merge tells it from its
    /// neighbours by `EditionVolume.id`. The key reuses exactly that.
    @Test("A row with no ISBN is keyed on EditionVolume.id")
    func noISBNRowIsKeyedOnTheRowID() {
        let row = EditionVolume(
            number: 2, title: "Delicious in Dungeon (GN 2)", releaseDate: nil,
            isbn13: nil, format: .print, edition: annEdition, sourceLink: nil
        )
        #expect(OwnedVolumeKey(seriesID: 1, volume: row).identity == "row:\(row.id)")
    }

    // MARK: - Reconciliation (`docs/reviews/night/shelf.md` §B)

    /// A tick on an ISBN-less row, then the same row arrives with an ISBN:
    /// the tick moves to the ISBN and keeps its date, and the orphan is
    /// gone. A row whose title also changed is not touched — it is a
    /// different string, and the doc comment on `reconcile` says why.
    ///
    /// EXPECTED TO FAIL before the change: `reconcile(shelves:for:)` did not
    /// exist; with a no-op reconcile, `owned(for:)` still holds the `row:`
    /// key, the `isbn:` key is absent, and `count()` is 2 after the second
    /// tick rather than 1.
    @Test("A tick taken before the row had an ISBN follows the row to its ISBN")
    func reconcileMovesTickToISBN() async throws {
        let clock = TestClock()
        let database = try makeDatabase()
        let store = OwnedVolumes(database: database, clock: clock)
        let before = EditionVolume(
            number: 22, title: "薬屋のひとりごと : 猫猫の後宮謎解き手帳. 22", releaseDate: nil,
            isbn13: nil, format: .print, edition: ndlEdition, sourceLink: nil
        )
        let orphanKey = OwnedVolumeKey(seriesID: 1, volume: before)
        try await store.setOwned(orphanKey, true)
        let tickedAt = clock.now

        clock.advance(by: 7 * 86_400)
        let after = EditionVolume(
            number: 22, title: before.title, releaseDate: PartialDate.parse("2026-10-17"),
            isbn13: "9784091582294", format: .print, edition: ndlEdition, sourceLink: nil
        )
        let renamed = EditionVolume(
            number: 23, title: "薬屋のひとりごと～猫猫の後宮謎解き手帳～", releaseDate: nil,
            isbn13: "9784091582300", format: .print, edition: ndlEdition, sourceLink: nil
        )
        let shelf = EditionShelf(edition: ndlEdition, volumes: [after, renamed])

        let moved = try await store.reconcile(shelves: [shelf], for: 1)
        #expect(moved == 1)
        let owned = try await store.owned(for: 1)
        #expect(owned == [OwnedVolumeKey(seriesID: 1, volume: after)])
        #expect(!owned.contains(orphanKey), "The orphan must be gone, not duplicated")
        #expect(try await store.count() == 1)
        // The reader did not buy it again: the date is the first tick's.
        let row = try await database.libraryWriter.read { db in try OwnedVolumeRow.fetchOne(db) }
        #expect(row?.ownedAt == tickedAt)
        // A second pass with nothing to move is a no-op.
        #expect(try await store.reconcile(shelves: [shelf], for: 1) == 0)
    }

    // MARK: - Helpers

    private var ndlEdition: VolumeEdition {
        VolumeEdition(
            catalogue: .nationalDietLibrary, language: "ja", languageRole: .original, editionTitle: "小学館"
        )
    }

    private var annEdition: VolumeEdition {
        VolumeEdition(
            catalogue: .animeNewsNetwork, language: "en", languageRole: .english,
            editionTitle: "Delicious in Dungeon"
        )
    }

    private var openLibraryEdition: VolumeEdition {
        VolumeEdition(catalogue: .openLibrary, language: "en", languageRole: .english, editionTitle: nil)
    }

    private func isbnVolume(number: Int) -> EditionVolume {
        EditionVolume(
            number: number, title: "Delicious in Dungeon (GN \(number))", releaseDate: nil,
            isbn13: "978031647185\(number)", format: .print, edition: annEdition, sourceLink: nil
        )
    }
}
