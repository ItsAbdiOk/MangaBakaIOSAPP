import Foundation
import GRDB
import Testing
@testable import MangaBaka

/// `EditionAnswerStore`: the on-disk copy of a series page's merged volumes
/// answer, and the partial read the Next-volume widget takes from it.
@Suite("Edition answer store")
struct EditionAnswerStoreTests {
    /// 2026-09-09, a Wednesday — the same "now" `NextVolumeSnapshotTests` uses.
    private let now = Date(timeIntervalSince1970: 1_789_000_000)

    private struct Made {
        let store: EditionAnswerStore
        let clock: TestClock
        let database: AppDatabase
    }

    private func makeStore() throws -> Made {
        let database = try AppDatabase.inMemory()
        let clock = TestClock(now: now)
        let store = EditionAnswerStore(database: database, clock: clock)
        return Made(store: store, clock: clock, database: database)
    }

    private func edition(_ catalogue: VolumeCatalogue = .animeNewsNetwork) -> VolumeEdition {
        VolumeEdition(
            catalogue: catalogue, language: "en", languageRole: .english, editionTitle: "Solo Leveling"
        )
    }

    private func volume(
        _ number: Int, _ date: String, catalogue: VolumeCatalogue = .animeNewsNetwork,
        link: URL? = URL(string: "https://www.animenewsnetwork.com/encyclopedia/releases.php?id=1")
    ) -> EditionVolume {
        EditionVolume(
            number: number, title: "Solo Leveling (GN \(number))",
            releaseDate: PartialDate.parse(date), isbn13: "978000000000\(number % 10)", format: .print,
            edition: edition(catalogue), sourceLink: link
        )
    }

    private func answer(
        _ volumes: [EditionVolume], catalogue: VolumeCatalogue = .animeNewsNetwork
    ) -> VolumeEditionAnswer {
        VolumeEditionAnswer(
            shelves: [EditionShelf(edition: edition(catalogue), volumes: volumes)],
            credits: [catalogue], failures: [:], unaskedReason: nil
        )
    }

    private func rowCount(_ database: AppDatabase) throws -> Int {
        try database.cacheWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM editionAnswer") ?? 0
        }
    }

    // MARK: - Round trip

    /// Fails before the store existed with a compile error (no such type);
    /// before `v14_editionAnswer` with `no such table: editionAnswer`.
    @Test("A written answer reads back with its forthcoming volume, ANN link carried")
    func roundTrip() async throws {
        let made = try makeStore()
        let store = made.store
        await store.write(answer([volume(11, "2026-06-01"), volume(12, "2026-10-03")]), for: 7)
        let hits = await store.forthcoming(for: [7, 8])
        #expect(hits.keys.sorted() == [7])
        #expect(hits[7]?.volumeLabel == "Vol. 12")
        #expect(hits[7]?.date == PartialDate.parse("2026-10-03")?.date)
        #expect(hits[7]?.sourceName == "Anime News Network")
        #expect(hits[7]?.sourceURL?.host == "www.animenewsnetwork.com")
    }

    @Test("The full stored shape survives encode and decode unchanged")
    func storedShapeRoundTrips() throws {
        let original = StoredEditionAnswer(answer([volume(1, "2020-01-01"), volume(2, "2026-10-03")]))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(StoredEditionAnswer.self, from: data)
        #expect(decoded == original)
        #expect(decoded.answer.shelves.first?.volumes.count == 2)
        #expect(decoded.answer.credits == [.animeNewsNetwork])
        #expect(decoded.answer.failures.isEmpty)
    }

    /// The `write` guard: an empty merge (all legs failed, or nothing was
    /// catalogued) must not replace a good row. Fails without the guard with
    /// `hits.isEmpty`.
    @Test("An empty answer does not overwrite a stored one")
    func emptyDoesNotOverwrite() async throws {
        let made = try makeStore()
        let store = made.store
        await store.write(answer([volume(12, "2026-10-03")]), for: 7)
        await store.write(.empty, for: 7)
        let hits = await store.forthcoming(for: [7])
        #expect(hits[7]?.volumeLabel == "Vol. 12")
    }

    // MARK: - Partial decode

    /// `ForthcomingRows` names four volume keys and one edition key; the
    /// payload carries a dozen more. Fails if the partial type ever declares
    /// a key the stored shape does not write (a `keyNotFound`), and the
    /// second half fails if an unknown key were ever fatal.
    @Test("The partial decode reads only what it names and ignores the rest")
    func partialDecodeIgnoresUnnamedFields() throws {
        let stored = StoredEditionAnswer(answer([volume(12, "2026-10-03")]))
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(stored)) as? [String: Any]
        // Keys the widget has no business reading are present…
        var shelf = try #require((json?["shelves"] as? [[String: Any]])?.first)
        #expect(shelf["isPartial"] != nil)
        #expect(shelf["format"] != nil)
        #expect(((shelf["volumes"] as? [[String: Any]])?.first)?["isbn13"] != nil)
        // …and an extra key a future build might add is harmless.
        shelf["somethingNewer"] = true
        json?["shelves"] = [shelf]
        json?["credits2"] = ["x"]
        let object = try #require(json)
        let data = try JSONSerialization.data(withJSONObject: object)
        let rows = try JSONDecoder().decode(EditionAnswerStore.ForthcomingRows.self, from: data)
        #expect(rows.soonest(asOf: now)?.volumeLabel == "Vol. 12")
    }

    /// ANN's terms: a row without its own entry link is not shown
    /// (`VolumeCatalogue.requiresPerEntryLink`). The unlinked sooner row is
    /// skipped and the linked later one wins. Fails without the check with
    /// `"Vol. 12"`.
    @Test("An ANN row with no link is dropped; an Open Library row needs none")
    func annWithoutLinkIsDropped() async throws {
        let made = try makeStore()
        let store = made.store
        await store.write(answer([volume(12, "2026-10-03", link: nil), volume(13, "2026-12-01")]), for: 1)
        await store.write(
            answer([volume(3, "2026-10-03", catalogue: .openLibrary, link: nil)], catalogue: .openLibrary),
            for: 2
        )
        let hits = await store.forthcoming(for: [1, 2])
        #expect(hits[1]?.volumeLabel == "Vol. 13")
        #expect(hits[2]?.volumeLabel == "Vol. 3")
        #expect(hits[2]?.sourceName == "Open Library")
    }

    // MARK: - Freshness

    /// Fails without the age check with `hits.count == 1` after the advance.
    @Test("A row older than 30 days is not returned; one a day younger is")
    func freshness() async throws {
        let made = try makeStore()
        let store = made.store
        let clock = made.clock
        await store.write(answer([volume(12, "2027-01-03")]), for: 7)
        clock.advance(by: EditionAnswerStore.freshness - 86_400)
        let fresh = await store.forthcoming(for: [7])
        #expect(fresh.count == 1)
        clock.advance(by: 2 * 86_400)
        let stale = await store.forthcoming(for: [7])
        #expect(stale.isEmpty)
    }

    @Test("A volume whose date has passed by read time is not returned")
    func pastDateAtReadTime() async throws {
        let made = try makeStore()
        let store = made.store
        let clock = made.clock
        await store.write(answer([volume(12, "2026-09-20")]), for: 7)
        clock.advance(by: 20 * 86_400)
        let hits = await store.forthcoming(for: [7])
        #expect(hits.isEmpty)
    }

    // MARK: - Trimming

    /// Fails without `trim` with `count == rowLimit + 5`; fails if the trim
    /// keeps oldest-first with `survivors.contains(1)`.
    @Test("Kept to 300 rows, the newest by write time surviving")
    func trimsNewestFirst() async throws {
        let made = try makeStore()
        let store = made.store
        let clock = made.clock
        let database = made.database
        let limit = EditionAnswerStore.rowLimit
        for id in 1...(limit + 5) {
            await store.write(answer([volume(1, "2026-10-03")]), for: id)
            clock.advance(by: 1)
        }
        let count = try rowCount(database)
        #expect(count == limit)
        let survivors = await store.forthcoming(for: [1, 5, 6, limit + 5])
        #expect(survivors.keys.sorted() == [6, limit + 5])
    }
}
