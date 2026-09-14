import Foundation
import Testing
@testable import MangaBaka

/// Reading Anime News Network's Encyclopedia XML, and the one rule that
/// matters more than any parsing detail: an absent future date means
/// "unknown", never "nothing is coming".
@Suite("ANN Encyclopedia volumes")
struct ANNVolumesTests {
    private func recordedEntry() throws -> ANNEntry {
        let data = try Fixture.data("ann-delicious-in-dungeon-17164", extension: "xml")
        return try #require(ANNEncyclopedia.parse(data), "The recorded ANN answer must parse")
    }

    /// The real answer, not a tidy one. Fifteen releases, fourteen numbered
    /// graphic novels and one box set written the way ANN writes it.
    @Test("The recorded answer parses to fifteen releases with dates, ISBNs and entry links")
    func recordedAnswerParses() throws {
        let entry = try recordedEntry()
        #expect(entry.id == 17164)
        #expect(entry.name == "Delicious in Dungeon")
        #expect(entry.warning == nil)
        #expect(entry.releases.count == 15)

        let volumes = ANNEncyclopedia.volumes(in: entry, role: .english)
        #expect(volumes.count == 15)
        // ANN's terms require a link to the Encyclopedia entry on any page
        // showing their details, so a row that cannot carry one must not
        // exist. See `VolumeCatalogue.requiresPerEntryLink`.
        #expect(volumes.allSatisfy { $0.sourceLink != nil })
        #expect(volumes.allSatisfy { $0.edition.catalogue == .animeNewsNetwork })
        #expect(volumes.allSatisfy { $0.edition.language == "en" })

        let first = try #require(volumes.first { $0.number == 1 })
        #expect(first.isbn13 == "9780316471855")
        #expect(first.format == .print)
        #expect(first.releaseDate?.precision == .day)
        #expect(first.sourceLink?.absoluteString.contains("releases.php?id=32917") == true)
    }

    /// `9798855400359` is a real 979-prefixed ISBN-13 in the recorded answer.
    /// A 13-digit check that assumed 978 would drop volume 14.
    @Test("A 979-prefixed ISBN survives normalisation")
    func isbnPrefixes() throws {
        let volumes = ANNEncyclopedia.volumes(in: try recordedEntry(), role: .english)
        let fourteen = try #require(volumes.first { $0.number == 14 })
        #expect(fourteen.isbn13 == "9798855400359")
        #expect(ANNEncyclopedia.normalisedISBN("978-0-316-47185-5") == "9780316471855")
        #expect(ANNEncyclopedia.normalisedISBN("031647185") == nil, "Ten digits is not an ISBN-13")
    }

    /// Both spellings of a box set ANN actually uses, and the reason neither
    /// may take a number: a box set numbered 91 hides the real volume 91.
    @Test("Box sets are recognised in both of ANN's spellings and carry no volume number")
    func boxSets() {
        let graphicNovel = ANNEncyclopedia.readMarker(in: "Delicious in Dungeon (GN 1)")
        #expect(graphicNovel.format == .print)
        #expect(graphicNovel.number == 1)

        let ebook = ANNEncyclopedia.readMarker(in: "One Piece (eBook 12)")
        #expect(ebook.format == .digital)
        #expect(ebook.number == 12)

        let complete = ANNEncyclopedia.readMarker(in: "Delicious in Dungeon [Complete Box Set] (GN)")
        #expect(complete.format == .boxSet)
        #expect(complete.number == nil)

        let ranged = ANNEncyclopedia.readMarker(in: "One Piece - Wano to Egghead Box Set (GN 91-111)")
        #expect(ranged.format == .boxSet)
        #expect(ranged.number == nil, "A box set numbered 91 would hide the real volume 91")

        let artbook = ANNEncyclopedia.readMarker(in: "One Piece Color Walk (Artbook 1)")
        #expect(artbook.format == .other, "An artbook is not a volume of the series")
    }

    /// Every ANN release observed states a full day, so this is here as the
    /// control rather than the case: it proves the shelf reads dates through
    /// `PartialDate` (the type `Core/Editions` owns) and would carry a
    /// coarser one honestly if ANN ever sent one, instead of printing a
    /// 1 January the catalogue never claimed.
    @Test("A partial date keeps its precision instead of inventing a day")
    func datePrecision() throws {
        let day = try #require(PartialDate.parse("2017-05-23"))
        #expect(day.precision == .day)
        let month = try #require(PartialDate.parse("2021-03"))
        #expect(month.precision == .month)
        let year = try #require(PartialDate.parse("2021"))
        #expect(year.precision == .year)
        #expect(PartialDate.parse("") == nil)
        #expect(PartialDate.parse(nil) == nil)
        #expect(PartialDate.parse("soon") == nil)
    }

    // MARK: - The asymmetry

    /// **The rule this whole client exists under.** ANN's encyclopedia is
    /// volunteer-edited: The Apothecary Diaries stops at 2026-03-17 while the
    /// series is still running in English, because nobody entered the next
    /// one. That is indistinguishable on the wire from a series that has
    /// finished. So there is no value in `ForthcomingVolume` that means
    /// "nothing is coming", and a shelf with no future date says `.unknown`.
    @Test("A shelf with no future date answers unknown, never nothing-is-coming")
    func absenceIsUnknown() throws {
        let shelf = EditionShelf(edition: edition(), volumes: [volume(1, "2026-03-17")])
        let now = try #require(PartialDate.parse("2026-09-14")?.date)
        #expect(shelf.forthcoming(asOf: now) == .unknown(.noneListed))
    }

    @Test("A publisher-announced future volume is reported as announced")
    func announced() throws {
        let shelf = EditionShelf(
            edition: edition(),
            volumes: [volume(112, "2026-06-02"), volume(113, "2026-11-10"), volume(114, "2026-12-08")]
        )
        let now = try #require(PartialDate.parse("2026-09-14")?.date)
        guard case let .announced(next) = shelf.forthcoming(asOf: now) else {
            Issue.record("Expected the soonest future volume, not \(shelf.forthcoming(asOf: now))")
            return
        }
        #expect(next.number == 113, "The soonest ahead, not the newest listed")
    }

    /// A series ANN has no record of is `.notCatalogued`. Both misses in the
    /// five-series set are Korean webtoons, and the app must never read that
    /// as the series having ended.
    @Test("A series ANN does not catalogue is not-catalogued, and still not an ending")
    func notCatalogued() {
        let series = SeriesFactory.make(id: 3397, title: "Solo Leveling", type: "manhwa")
        let answer = VolumeEditions.merge(
            ann: .loaded(
                ANNVolumes(volumes: [], isCatalogued: false), fetchedAt: Date(), isPartial: false
            ),
            for: series
        )
        #expect(answer.isEmpty)
        #expect(answer.credits.isEmpty, "A source that contributed no row is owed no credit")
        #expect(answer.forthcoming(asOf: Date()) == .unknown(.notCatalogued))
    }

    @Test("An answer that was never asked for is not-asked, not empty")
    func notAsked() {
        let answer = VolumeEditions.merge(ann: .idle, for: SeriesFactory.make(title: "Anything"))
        #expect(answer.forthcoming(asOf: Date()) == .unknown(.notAsked))
    }

    // MARK: - Language

    /// The view shows English and the series' original language and nothing
    /// else (Abdi, 2026-09-14). The rule itself is `Series.coverLanguages`,
    /// which already exists for the cover fan — this proves the shelf reads
    /// that rule rather than carrying a second copy of it.
    @Test("An English ANN shelf is tagged English for a Japanese series and survives the filter")
    func englishRoleForJapaneseSeries() {
        let series = SeriesFactory.make(id: 17164, title: "Delicious in Dungeon", type: "manga")
        #expect(VolumeEditions.role(of: "en", in: series) == .english)
        #expect(VolumeEditions.role(of: "ja", in: series) == .original)
        #expect(VolumeEditions.role(of: "de", in: series) == .other)

        let answer = VolumeEditions.merge(
            ann: .loaded(
                ANNVolumes(volumes: [volume(1, "2017-05-23")], isCatalogued: true),
                fetchedAt: Date(), isPartial: false
            ),
            for: series
        )
        #expect(answer.shelves.count == 1)
        #expect(answer.shelves.first?.edition.languageRole == .english)
        #expect(answer.credits == [.animeNewsNetwork])
    }

    // MARK: - Helpers

    private func edition(role: EditionLanguageRole = .english) -> VolumeEdition {
        VolumeEdition(
            catalogue: .animeNewsNetwork, language: "en", languageRole: role,
            editionTitle: "Delicious in Dungeon"
        )
    }

    private func volume(_ number: Int, _ date: String) -> EditionVolume {
        EditionVolume(
            number: number, title: "Delicious in Dungeon (GN \(number))",
            releaseDate: PartialDate.parse(date), isbn13: nil, format: .print,
            edition: edition(), sourceLink: URL(string: "https://www.animenewsnetwork.com/x")
        )
    }
}
