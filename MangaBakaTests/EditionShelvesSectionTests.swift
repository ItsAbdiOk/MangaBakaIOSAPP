import Foundation
import Testing
@testable import MangaBaka

/// The two things the "Volumes on record" section is obliged to get right: the
/// attribution ANN's terms require per row, and copy that can never read as
/// "the series has finished".
///
/// Every test here fails on `be75a2e`: `EditionShelvesSection` did not exist,
/// so each is a compile error before the change.
@Suite("Edition shelves section")
struct EditionShelvesSectionTests {
    // MARK: - Attribution

    /// ANN's API documentation, quoted in `docs/sources/publishers.md`
    /// (2026-09-14): name Anime News Network as the source *and* link to the
    /// relevant Encyclopedia entry on any page displaying their details. A
    /// footer credit does not satisfy it, and neither does one link per
    /// section — so this asserts on the group's credit line and on the rows
    /// having their own links.
    @Test("An ANN group names Anime News Network and every row carries its own link")
    func annGroupIsCreditedAndEveryRowIsLinked() {
        let shelf = EditionShelf(
            edition: annEdition,
            volumes: [annVolume(1), annVolume(2), annVolume(3)]
        )
        #expect(EditionShelvesSection.creditLine(for: shelf).contains("Anime News Network"))
        #expect(
            shelf.volumes.allSatisfy { $0.sourceLink != nil },
            "A row with no link must never reach the view — the rule is the row's"
        )
        #expect(VolumeCatalogue.animeNewsNetwork.requiresPerEntryLink)
    }

    /// The dedupe's other half. A row Open Library also stated, collapsed into
    /// an ANN row, still owes Open Library its credit — otherwise the section
    /// is using their data under someone else's name.
    @Test("A collapsed row credits the source that lost the collapse too")
    func aCollapsedRowCreditsBothSources() {
        let volume = EditionVolume(
            number: 1, title: "Delicious in Dungeon (GN 1)",
            releaseDate: PartialDate.parse("2017-05-23"), isbn13: "9780316471855",
            format: .print, edition: annEdition,
            sourceLink: URL(string: "https://www.animenewsnetwork.com/encyclopedia/manga.php?id=17164"),
            alsoFrom: [.openLibrary]
        )
        let line = EditionShelvesSection.creditLine(
            for: EditionShelf(edition: annEdition, volumes: [volume])
        )
        #expect(line.contains("Anime News Network"))
        #expect(
            line.contains(BookEdition.Source.openLibrary.credit),
            "Open Library's own wording, read from `BookEdition.Source.credit` — got \(line)"
        )
    }

    /// NDL's credit is mandatory under their API terms, and it is their own
    /// Japanese wording, not a translation of it.
    @Test("An NDL group carries the National Diet Library's own credit")
    func ndlGroupIsCredited() {
        let edition = VolumeEdition(
            catalogue: .nationalDietLibrary, language: "ja", languageRole: .original,
            editionTitle: "KADOKAWA"
        )
        let volume = EditionVolume(
            number: 1, title: "ダンジョン飯 1", releaseDate: PartialDate.parse("2015-01-15"),
            isbn13: "9784047301535", format: .print, edition: edition, sourceLink: nil
        )
        let line = EditionShelvesSection.creditLine(
            for: EditionShelf(edition: edition, volumes: [volume])
        )
        #expect(line == BookEdition.Source.nationalDietLibrary.credit)
    }

    // MARK: - Forthcoming copy

    /// The rule `ForthcomingVolume` puts in the type: no source surveyed can
    /// say a series has finished, so no wording here may imply one. ANN's
    /// Apothecary Diaries stops at 2026-03-17 while the series is still
    /// running in English because nobody entered the next date; a finished
    /// series looks identical on the wire.
    @Test("No 'nothing is coming' wording exists for any kind of unknown")
    func noUnknownReadsAsAnEnding() {
        let reasons: [ForthcomingVolume.UnknownReason] = [
            .noneListed, .notCatalogued, .notAsked, .couldNotAsk(.offline)
        ]
        // Phrases a reader would take as a statement about the publisher
        // rather than about this app's sources.
        let forbidden = ["no more volumes", "nothing is coming", "has finished", "has ended",
                         "complete", "final volume"]
        for reason in reasons {
            let words = EditionShelvesSection.unknownWording(reason).lowercased()
            for phrase in forbidden {
                #expect(!words.contains(phrase), "\"\(words)\" reads as an ending for \(reason)")
            }
            #expect(!words.isEmpty, "Silence is read as an ending too — every case says something")
        }
    }

    /// A forthcoming volume is shown as what it is: announced, with the date,
    /// and named to the source that announced it.
    @Test("An announced volume says announced, with its date and its source")
    func announcedVolumeSaysSo() {
        let text = EditionShelvesSection.announcementText(
            number: 113, date: PartialDate.parse("2026-11-10"), source: "Anime News Network"
        )
        #expect(text.contains("Vol. 113"))
        #expect(text.lowercased().contains("announced"))
        // Locale-independent, for the reason `yearPrecisionPrintsAYear`
        // records: the arrangement is the device's, the facts are ours.
        #expect(text.contains("November") && text.contains("2026") && text.contains("10"))
        #expect(text.contains("Anime News Network"))
    }

    /// A date is printed to exactly the precision the catalogue stated.
    /// `PartialDate` exists because Open Library answers `2021-03-02`,
    /// `Apr 07, 2021` and a bare `2012` in one response (measured 2026-09-14);
    /// printing "1 January 2012" for the third is a fact nobody asserted.
    @Test("A year-precision date prints a year, never 1 January")
    func yearPrecisionPrintsAYear() throws {
        let year = try #require(PartialDate.parse("2012"))
        #expect(EditionShelvesSection.wording(year) == "2012")

        // The month and day forms go through `Date.FormatStyle`, which orders
        // and punctuates by the device's locale ("2 March 2021" here, "March 2,
        // 2021" on a US simulator). The assertion is on what is *present*, not
        // on the arrangement: the point is that a month-precision date names no
        // day and a day-precision one does.
        let month = try #require(PartialDate.parse("2021-04"))
        let monthText = EditionShelvesSection.wording(month)
        #expect(monthText.contains("April") && monthText.contains("2021"))
        // The day is the thing that must be absent. Checked as "no digit run
        // other than the year", because "April 2021" contains the character
        // "1" inside its own year.
        #expect(
            monthText.filter(\.isNumber) == "2021",
            "A month-precision date must not print a day — \(monthText)"
        )

        let day = try #require(PartialDate.parse("2021-03-02"))
        let dayText = EditionShelvesSection.wording(day)
        #expect(dayText.contains("March") && dayText.contains("2021") && dayText.contains("2"))
    }

    /// An absent answer is never rendered as "there is nothing" — but it is
    /// also never rendered as silence, which a reader reads the same way. A
    /// section with a failure and no rows still draws.
    @Test("A section with nothing but a failure still draws, so the reason is visible")
    func aFailureAloneIsWorthTheSection() {
        let answer = VolumeEditionAnswer(
            shelves: [], credits: [], failures: [.animeNewsNetwork: .offline],
            unaskedReason: .couldNotAsk(.offline)
        )
        #expect(EditionShelvesSection.shows(answer: answer, isLoading: false))
        #expect(!EditionShelvesSection.shows(answer: .empty, isLoading: false),
                "Nothing asked, nothing failed, nothing found: no header over an empty box")
    }

    // MARK: - Headings

    @Test("A group's heading names the language and the publisher that printed it")
    func headingNamesLanguageAndPublisher() {
        #expect(EditionShelvesSection.heading(for: annEdition) == "English · Delicious in Dungeon")
        let bare = VolumeEdition(
            catalogue: .openLibrary, language: "en", languageRole: .english, editionTitle: nil
        )
        #expect(EditionShelvesSection.heading(for: bare) == "English")
    }

    // MARK: - Helpers

    private var annEdition: VolumeEdition {
        VolumeEdition(
            catalogue: .animeNewsNetwork, language: "en", languageRole: .english,
            editionTitle: "Delicious in Dungeon"
        )
    }

    private func annVolume(_ number: Int) -> EditionVolume {
        EditionVolume(
            number: number, title: "Delicious in Dungeon (GN \(number))",
            releaseDate: PartialDate.parse("2017-05-23"), isbn13: nil, format: .print,
            edition: annEdition,
            sourceLink: URL(string: "https://www.animenewsnetwork.com/encyclopedia/manga.php?id=17164")
        )
    }
}

/// A title marked `ja` is not always written in Japanese, and NDL's SRU
/// answers a Latin query with the wrong series.
@Suite("Only a Japanese-script title reaches NDL")
@MainActor
struct NDLTitleScriptTests {
    /// Measured 2026-09-14: `title="ONE PIECE" AND mediatype=books` answered
    /// 935 records whose titles were 俺だけレベルアップな件 — Solo Leveling.
    /// One Piece's own `ja` title in MangaBaka is the Latin string "ONE
    /// PIECE", so before this guard the app asked NDL a question that
    /// returned another series' volumes. Expected to fail before the fix
    /// with: `japaneseTitle(of:)` returning "ONE PIECE" rather than nil.
    @Test("A Latin title marked ja is not sent to NDL")
    func latinJapaneseTitleIsRefused() {
        let series = SeriesFactory.make(
            id: 377, title: "One Piece",
            titles: [
                SeriesTitle(language: "en", traits: [], title: "One Piece", isPrimary: true),
                SeriesTitle(language: "ja", traits: [], title: "ONE PIECE", isPrimary: false)
            ],
            type: "manga"
        )
        #expect(SeriesDetailView.japaneseTitle(of: series) == nil)
    }

    /// The control: a real Japanese title still goes through, or the guard
    /// would have turned NDL off altogether rather than fixed it.
    @Test("A kana or kanji title is sent")
    func japaneseScriptTitleIsSent() {
        let series = SeriesFactory.make(
            id: 1, title: "The Apothecary Diaries",
            titles: [
                SeriesTitle(language: "en", traits: [], title: "The Apothecary Diaries", isPrimary: true),
                SeriesTitle(language: "ja", traits: [], title: "薬屋のひとりごと", isPrimary: false)
            ],
            type: "manga"
        )
        #expect(SeriesDetailView.japaneseTitle(of: series) == "薬屋のひとりごと")
    }

    /// A mixed title keeps its Japanese part, which is what NDL keys on.
    @Test("A mixed-script title is sent")
    func mixedScriptTitleIsSent() {
        #expect(SeriesDetailView.isJapaneseScript("ONE PIECE 巻一"))
        #expect(!SeriesDetailView.isJapaneseScript("ONE PIECE"))
        #expect(!SeriesDetailView.isJapaneseScript("12345"))
    }
}
