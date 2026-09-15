import Foundation
import Testing
@testable import MangaBaka

/// The night review's Serious 1 and 2 (`docs/reviews/night/shelf.md`): a
/// shelf is one format, and a shelf built from part of a page says so.
@Suite("Volume edition shelves")
struct VolumeEditionShelfTests {
    private let series = SeriesFactory.make(id: 13, title: "One Piece", type: "manga")

    /// One Piece via ANN is `(GN n)` and `(eBook n)` for every n
    /// (`docs/sources/publishers.md:157`). Before the change `group` keyed on
    /// `VolumeEdition` alone, so one shelf held GN 1, eBook 1, GN 2 … and
    /// "You own 1 of 6" over three volumes.
    ///
    /// EXPECTED TO FAIL before the change: `answer.shelves.count == 1`, and
    /// `EditionShelf.format` did not exist (compile error).
    @Test("Print and eBook rows of one edition are two shelves, each counting its own")
    func printAndDigitalAreSeparateShelves() throws {
        // Built up in a loop with explicit types: the `flatMap` form made the
        // type checker read `annRow` as optional and cascade six errors.
        var rows: [EditionVolume] = []
        for number in 1...3 {
            rows.append(annRow(number, format: .print))
            rows.append(annRow(number, format: .digital))
        }
        let answer = VolumeEditions.merge(
            ann: .loaded(ANNVolumes(volumes: rows, isCatalogued: true), fetchedAt: .now, isPartial: false),
            for: series
        )
        #expect(answer.shelves.count == 2, "Got \(answer.shelves.map(\.id))")
        let print = try #require(answer.shelves.first { $0.format == .print })
        let digital = try #require(answer.shelves.first { $0.format == .digital })
        #expect(print.volumes.count == 3)
        #expect(digital.volumes.count == 3)
        #expect(print.volumes.allSatisfy { $0.format == .print })
        #expect(print.id != digital.id, "Two shelves with one id would collapse in `ForEach`")

        // The owned line now counts the print shelf alone.
        let owned: Set<OwnedVolumeKey> = [OwnedVolumeKey(seriesID: 13, volume: print.volumes[0])]
        #expect(OwnedSummary.line(for: print, owned: owned, seriesID: 13)
            == "You own 1 of 3 · missing vol. 2–3")
        #expect(OwnedSummary.line(for: digital, owned: owned, seriesID: 13) == nil,
                "The eBook tick is not this tick")
    }

    /// Delicious in Dungeon reads "You own 14 of 15" with the fifteenth being
    /// the box set. The box set is still shown — on its own shelf.
    @Test("A box set is not counted as a print volume and is not dropped")
    func boxSetIsItsOwnShelf() throws {
        let rows = (1...2).map { annRow($0, format: .print) } + [annRow(nil, format: .boxSet)]
        let answer = VolumeEditions.merge(
            ann: .loaded(ANNVolumes(volumes: rows, isCatalogued: true), fetchedAt: .now, isPartial: false),
            for: series
        )
        let print = try #require(answer.shelves.first { $0.format == .print })
        #expect(print.volumes.count == 2)
        #expect(answer.shelves.contains { $0.format == .boxSet && $0.volumes.count == 1 })
        let boxSets = try #require(answer.shelves.first { $0.format == .boxSet })
        #expect(EditionShelvesSection.heading(for: boxSets) == "English · One Piece · Box sets")
        #expect(EditionShelvesSection.heading(for: print) == "English · One Piece",
                "Print says nothing extra")
    }

    /// The NDL leg answered with one page of many. Its shelf is partial; a
    /// complete leg's is not.
    ///
    /// EXPECTED TO FAIL before the change: `EditionShelf.isPartial` did not
    /// exist, and `SeriesDetailView.ndlVolumes` passed `isPartial: false`
    /// regardless.
    @Test("A leg that answered partially marks its shelf, and only its shelf")
    func partialLegMarksItsShelf() throws {
        let japanese = SeriesFactory.make(
            id: 13,
            titles: [
                SeriesTitle(language: "en", traits: ["official"], title: "One Piece", isPrimary: true),
                SeriesTitle(language: "ja", traits: ["native"], title: "ワンピース", isPrimary: true)
            ],
            type: "manga"
        )
        let answer = VolumeEditions.merge(
            ann: .loaded(
                ANNVolumes(volumes: [annRow(1, format: .print)], isCatalogued: true),
                fetchedAt: .now, isPartial: false
            ),
            ndl: .loaded(.editions([ndlRow(1), ndlRow(10)]), fetchedAt: .now, isPartial: true),
            for: japanese
        )
        let ndl = try #require(answer.shelves.first { $0.edition.catalogue == .nationalDietLibrary })
        let ann = try #require(answer.shelves.first { $0.edition.catalogue == .animeNewsNetwork })
        #expect(ndl.isPartial)
        #expect(!ann.isPartial, "The control: a complete leg is not marked by a partial sibling")
    }

    // MARK: - Helpers

    private var edition: VolumeEdition {
        VolumeEdition(
            catalogue: .animeNewsNetwork, language: "en", languageRole: .english, editionTitle: "One Piece"
        )
    }

    private func annRow(_ number: Int?, format: VolumeFormat) -> EditionVolume {
        let (marker, code) = switch format {
        case .print: ("GN \(number ?? 0)", 1)
        case .digital: ("eBook \(number ?? 0)", 2)
        case .boxSet: ("GN 1-2 Box Set", 3)
        case .other: ("Artbook", 4)
        }
        return EditionVolume(
            number: number, title: "One Piece (\(marker))", releaseDate: PartialDate.parse("2003-06-02"),
            // Thirteen digits, distinct per format and number: a shared ISBN
            // would be merged into one row and hide the grouping under test.
            isbn13: "97815690\(code)000\(number ?? 9)", format: format, edition: edition,
            sourceLink: URL(string: "https://www.animenewsnetwork.com/encyclopedia/manga.php?id=1")
        )
    }

    private func ndlRow(_ number: Int) -> BookEdition {
        BookEdition(
            id: "https://ndlsearch.ndl.go.jp/books/R100000002-I0000\(number)", title: "ワンピース. \(number)",
            isbn13: "97840880000" + String(format: "%02d", number), publisher: "集英社", language: "jpn",
            published: PartialDate.parse("2003"), coverID: nil, volume: "\(number)",
            source: .nationalDietLibrary, format: .comic, formatEvidence: .catalogueGenre("漫画")
        )
    }
}
