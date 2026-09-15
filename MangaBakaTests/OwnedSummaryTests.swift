import Foundation
import Testing
@testable import MangaBaka

/// The "You own 3 of 12 · missing vol. 4, 7" line, and the one rule that
/// matters more than the arithmetic: never guess where an unnumbered volume
/// sits.
///
/// Every test here fails on the code before this change with a compile error
/// — `OwnedSummary` and `OwnedVolumeKey` did not exist — which is worth saying
/// plainly, because a test that does not compile proves nothing about the
/// arithmetic. The assertions are what fail once the type exists and the
/// rule is wrong.
@Suite("Owned summary")
struct OwnedSummaryTests {
    private let seriesID = 7

    /// The brief's own example: three of twelve, with 4 and 7 missing.
    ///
    /// Fails with `line == nil` on a build whose `line(for:owned:seriesID:)`
    /// does not count, and with a wrong string on one that lists every
    /// missing number rather than only those below the highest known.
    @Test("Owned count, total and the gaps below the highest known volume")
    func countsAndGaps() {
        let shelf = shelf(numbers: Array(1...12))
        let owned = keys(for: shelf, numbers: [1, 2, 3, 5, 6])
        let line = OwnedSummary.line(for: shelf, owned: owned, seriesID: seriesID)
        // 8 to 12 are missing too, so the runs matter: without folding this
        // would be "4, 7, 8, 9, 10, 11, 12".
        #expect(line == "You own 5 of 12 · missing vol. 4, 7–12")
    }

    /// Nothing missing says nothing about missing.
    @Test("A complete run has no missing clause")
    func completeRun() {
        let shelf = shelf(numbers: [1, 2, 3])
        let owned = keys(for: shelf, numbers: [1, 2, 3])
        #expect(OwnedSummary.line(for: shelf, owned: owned, seriesID: seriesID) == "You own 3 of 3")
    }

    /// The rule: an owned volume with no number cannot be placed, so the
    /// line must not claim to know what is missing.
    ///
    /// Fails on a build that computes gaps from the numbered ones anyway with
    /// `"You own 2 of 4 · missing vol. 2, 3"` — a sentence that may well be
    /// false, because the unnumbered one could be volume 2.
    @Test("An unnumbered owned volume reduces the line to a count")
    func unnumberedOwnedVolumeSaysCountOnly() {
        let unnumbered = volume(number: nil, title: "Special edition")
        let shelf = EditionShelf(
            edition: edition,
            volumes: [volume(number: 1), volume(number: 2), volume(number: 3), unnumbered]
        )
        let owned: Set<OwnedVolumeKey> = [
            OwnedVolumeKey(seriesID: seriesID, volume: shelf.volumes[0]),
            OwnedVolumeKey(seriesID: seriesID, volume: unnumbered)
        ]
        #expect(OwnedSummary.line(for: shelf, owned: owned, seriesID: seriesID) == "2 owned")
    }

    /// An *unowned* unnumbered row is not the same case: it is neither a gap
    /// nor a guess, and the numbered arithmetic still stands.
    @Test("An unnumbered volume the reader does not own is ignored")
    func unnumberedUnownedVolumeIsIgnored() {
        let shelf = EditionShelf(
            edition: edition,
            volumes: [volume(number: 1), volume(number: 2), volume(number: nil, title: "Guidebook")]
        )
        let owned = keys(for: shelf, numbers: [2])
        let line = OwnedSummary.line(for: shelf, owned: owned, seriesID: seriesID)
        #expect(line == "You own 1 of 3 · missing vol. 1")
    }

    /// An edition with nothing ticked draws no line — the empty circles
    /// already say it.
    @Test("Zero owned is silent")
    func zeroOwnedIsSilent() {
        let shelf = shelf(numbers: [1, 2, 3])
        #expect(OwnedSummary.line(for: shelf, owned: [], seriesID: seriesID) == nil)
    }

    /// The control for `zeroOwnedIsSilent`: the same shelf with a tick on a
    /// *different* series is still zero owned here. Fails on a key that
    /// ignores the series id.
    @Test("A tick on another series does not count")
    func otherSeriesTickDoesNotCount() {
        let shelf = shelf(numbers: [1, 2])
        let elsewhere: Set<OwnedVolumeKey> = [OwnedVolumeKey(seriesID: 99, volume: shelf.volumes[0])]
        #expect(OwnedSummary.line(for: shelf, owned: elsewhere, seriesID: seriesID) == nil)
    }

    /// NDL's page 1 for 薬屋のひとりごと (measured 2026-09-15, 50 of 84 held)
    /// carries Square Enix volumes 1 and 10–14; 2–9 are on page 2. The line
    /// must not tell a reader holding 2–9 that they are missing.
    ///
    /// EXPECTED TO FAIL before the change: `EditionShelf.isPartial` did not
    /// exist, and with the flag ignored the line read
    /// `"You own 1 of 6 · missing vol. 2–14"`.
    @Test("A partial shelf says how many are owned and nothing about the rest")
    func partialShelfCountsOnly() {
        let shelf = EditionShelf(
            edition: edition, volumes: [1, 10, 11, 12, 13, 14].map { volume(number: $0) }, isPartial: true
        )
        let owned = keys(for: shelf, numbers: [1])
        #expect(OwnedSummary.line(for: shelf, owned: owned, seriesID: seriesID)
            == "1 owned · more volumes on record than shown")
        // The control: the same rows on a complete shelf still say "of".
        let complete = EditionShelf(edition: edition, volumes: shelf.volumes)
        #expect(OwnedSummary.line(for: complete, owned: owned, seriesID: seriesID)
            == "You own 1 of 6 · missing vol. 2–14")
        // Nothing ticked is still nothing to say, partial or not.
        #expect(OwnedSummary.line(for: shelf, owned: [], seriesID: seriesID) == nil)
    }

    /// Consecutive numbers fold to a range; singletons stay singletons.
    @Test("Runs fold to en-dash ranges")
    func runsFold() {
        #expect(OwnedSummary.runs([4, 7]) == "4, 7")
        #expect(OwnedSummary.runs([2, 3, 4, 9, 11, 12]) == "2–4, 9, 11–12")
        #expect(OwnedSummary.runs([5]) == "5")
        #expect(OwnedSummary.runs([]).isEmpty)
    }

    // MARK: - Helpers

    private var edition: VolumeEdition {
        VolumeEdition(
            catalogue: .animeNewsNetwork, language: "en", languageRole: .english,
            editionTitle: "Delicious in Dungeon"
        )
    }

    private func volume(number: Int?, title: String? = nil) -> EditionVolume {
        EditionVolume(
            number: number,
            title: title ?? "Delicious in Dungeon (GN \(number.map(String.init) ?? "?"))",
            releaseDate: nil, isbn13: nil, format: .print, edition: edition,
            sourceLink: URL(string: "https://www.animenewsnetwork.com/encyclopedia/manga.php?id=17164")
        )
    }

    private func shelf(numbers: [Int]) -> EditionShelf {
        EditionShelf(edition: edition, volumes: numbers.map { volume(number: $0) })
    }

    private func keys(for shelf: EditionShelf, numbers: [Int]) -> Set<OwnedVolumeKey> {
        Set(
            shelf.volumes
                .filter { $0.number.map(numbers.contains) ?? false }
                .map { OwnedVolumeKey(seriesID: seriesID, volume: $0) }
        )
    }
}
