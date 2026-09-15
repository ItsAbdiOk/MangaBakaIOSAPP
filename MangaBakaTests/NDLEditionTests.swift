import Foundation
import Testing
@testable import MangaBaka

/// The night review's two open NDL issues (`docs/reviews/night/shelf.md` §A
/// and §A′) and its Serious 2, against the page it measured them on.
///
/// `ndl-apothecary-diaries-50.xml` — saved verbatim 2026-09-15 01:10 from
/// `https://ndlsearch.ndl.go.jp/api/sru?operation=searchRetrieve&
/// recordSchema=dcndl&recordPacking=xml&maximumRecords=50&query=title="薬屋の
/// ひとりごと" AND mediatype=books`, the app's own page size. 84 held, 50
/// returned. Volume 13 and 14 each arrive twice under Square Enix with two
/// ISBNs; the side story `薬屋のひとりごと外伝小蘭回想録. 1` shares its imprint and
/// publisher with the main run; Square Enix volumes 2–9 are on page 2.
@Suite("NDL editions and work titles")
struct NDLEditionTests {
    private static let title = "薬屋のひとりごと"

    private func page() throws -> Data {
        try Fixture.data("ndl-apothecary-diaries-50", extension: "xml")
    }

    private func rows() throws -> [BookEdition] {
        let answer = try #require(NDLClient.answer(title: Self.title, format: .comic, from: try page()))
        return answer.answer.rows
    }

    /// A `ja` native title, so `BookEditionShelf` tags the rows `.original`
    /// — the language filter itself is merge's and is not under test here.
    private func series() -> Series {
        SeriesFactory.make(
            id: 1,
            titles: [
                SeriesTitle(language: "en", traits: ["official"], title: "The Apothecary Diaries",
                            isPrimary: true),
                SeriesTitle(language: "ja", traits: ["native"], title: Self.title, isPrimary: true)
            ],
            type: "manga"
        )
    }

    // MARK: - §A: dcndl:edition

    /// EXPECTED TO FAIL before the change: `record.edition` did not exist
    /// (compile error); with the field but no `flat` mapping, `edition == nil`
    /// on both records.
    @Test("The special printing's edition note is read, and the regular one's is nil")
    func readsEditionNote() throws {
        let records = try #require(NDLRecordParser.parse(try page()))
        let special = try #require(records.first { $0.isbn == "9784757590281" })
        let regular = try #require(records.first { $0.isbn == "9784757590274" })
        #expect(special.edition == "特装版小冊子付き")
        #expect(regular.edition == nil)
        #expect(special.volume == "13" && regular.volume == "13", "Both are volume 13 — that is the problem")
    }

    /// The fix's shape: the special printing goes on its own shelf, the plain
    /// shelf counts one row per volume, and the special row still exists with
    /// its own ISBN for the reader who owns it.
    ///
    /// EXPECTED TO FAIL before the change on the first `#expect`: both vol.
    /// 13 rows had `editionTitle == "スクウェア・エニックス"` and the plain shelf
    /// held 13 twice (`plain.filter { $0.number == 13 }.count == 2`).
    @Test("A row with an edition note sits on its own shelf with the right ISBN")
    func specialEditionHasItsOwnShelf() throws {
        let volumes = BookEditionShelf.editionVolumes(from: try rows(), in: series())
        let squareEnix = volumes.filter { $0.edition.editionTitle?.hasPrefix("スクウェア・エニックス") == true }
        let plain = squareEnix.filter { $0.edition.editionTitle == "スクウェア・エニックス" }
        let special = squareEnix.filter { $0.edition.editionTitle == "スクウェア・エニックス · 特装版" }

        #expect(plain.filter { $0.number == 13 }.map(\.isbn13) == ["9784757590274"])
        #expect(special.filter { $0.number == 13 }.map(\.isbn13) == ["9784757590281"])
        #expect(plain.filter { $0.number == 14 }.count == 1)
        #expect(special.filter { $0.number == 14 }.count == 1)
        // Control: the plain shelf is one row per volume across the page.
        let numbers = plain.compactMap(\.number)
        #expect(Set(numbers).count == numbers.count, "Duplicate numbers on the plain shelf: \(numbers)")
    }

    /// Five Shogakukan notes name five different extras; one shelf, not five.
    @Test("Every measured edition note folds to one label")
    func editionNotesFold() {
        for note in ["特装版小冊子付き", "[マスキングテープ付特装版]", "ドラマCD付き限定特装版",
                     "オリジナル描き下ろし扇子付き特装版", "[ピルケース&巾着袋付特装版]"] {
            #expect(BookEditionShelf.editionLabel(note) == "特装版", Comment(rawValue: note))
        }
        // A note without the word is kept, brackets off — not silently 特装版.
        #expect(BookEditionShelf.editionLabel("[新装版]") == "新装版")
    }

    // MARK: - §A′: the work title

    /// EXPECTED TO FAIL before the change: `workTitle(title:volume:)` did not
    /// exist.
    @Test("The catalogued volume suffix is stripped in each of NDL's spellings")
    func stripsVolumeSuffix() {
        // A local wrapper: a bare function reference drops its labels.
        func work(title: String, volume: String?) -> String? {
            NDLClient.Query.workTitle(title: title, volume: volume)
        }
        #expect(work(title: "薬屋のひとりごと. 13", volume: "13") == "薬屋のひとりごと")
        #expect(work(title: "薬屋のひとりごと １３", volume: "１３") == "薬屋のひとりごと")
        #expect(work(title: "薬屋のひとりごと [1]", volume: "[1]") == "薬屋のひとりごと")
        #expect(work(title: "薬屋のひとりごと : 猫猫の後宮謎解き手帳. 22", volume: "22")
            == "薬屋のひとりごと : 猫猫の後宮謎解き手帳")
        // No suffix, no volume: the title is the work.
        #expect(work(title: "薬屋のひとりごと～猫猫の後宮謎解き手帳～", volume: "22")
            == "薬屋のひとりごと～猫猫の後宮謎解き手帳～")
        #expect(work(title: "俺だけレベルアップな件外伝　01", volume: nil) == "俺だけレベルアップな件外伝　01")
    }

    /// The side story lands on a shelf named for it; the main run does not.
    ///
    /// EXPECTED TO FAIL before the change with the 外伝 row's `editionTitle ==
    /// "スクウェア・エニックス"` — the same shelf as `薬屋のひとりごと. 1`, and a
    /// second "vol. 1" on it.
    @Test("The side story admitted by the prefix match gets its own shelf")
    func sideStoryHasItsOwnShelf() throws {
        let rows = try rows()
        let sideStory = try #require(rows.first { $0.title == "薬屋のひとりごと外伝小蘭回想録. 1" })
        let main = try #require(rows.first { $0.title == "薬屋のひとりごと. 1" })
        #expect(sideStory.workTitle == "薬屋のひとりごと外伝小蘭回想録")
        #expect(main.workTitle == nil)
        #expect(BookEditionShelf.editionTitle(for: sideStory) == "スクウェア・エニックス · 薬屋のひとりごと外伝小蘭回想録")
        #expect(BookEditionShelf.editionTitle(for: main) == "スクウェア・エニックス")
        // The prefix admission itself is untouched — the row is still here.
        #expect(NDLClient.Query(title: Self.title, format: .comic).titleMatches(
            NDLRecordParser.Record(title: sideStory.title)
        ))
    }

    /// The 近刊 record spells the Shogakukan work with `～…～` where the 26
    /// catalogued volumes use ` : `. One work, the majority spelling.
    @Test("Two punctuations of one work resolve to the spelling most records use")
    func workSpellingsUnify() throws {
        let rows = try rows()
        let forthcoming = try #require(rows.first { $0.title == "薬屋のひとりごと～猫猫の後宮謎解き手帳～" })
        let catalogued = try #require(rows.first { $0.title == "薬屋のひとりごと : 猫猫の後宮謎解き手帳. 1" })
        #expect(forthcoming.workTitle == "薬屋のひとりごと : 猫猫の後宮謎解き手帳")
        #expect(forthcoming.workTitle == catalogued.workTitle)
    }

    /// Abdi's call, 2026-09-15 (shelf.md "Needs Abdi", third item): the 近刊
    /// record states no publisher, so its shelf was named by the work alone
    /// and sat beside Shogakukan's 1–17. Fails on the old code with the
    /// forthcoming row's `publisher == nil` and two shelf names.
    @Test("The forthcoming row takes the publisher every catalogued row of its work states")
    func forthcomingInheritsPublisher() throws {
        let raw = try rows()
        let rawForthcoming = try #require(raw.first { $0.title == "薬屋のひとりごと～猫猫の後宮謎解き手帳～" })
        #expect(rawForthcoming.publisher == nil, "control: NDL states none on the wire")

        let rows = BookEditionShelf.withInheritedPublishers(raw)
        let forthcoming = try #require(rows.first { $0.title == rawForthcoming.title })
        let catalogued = try #require(rows.first { $0.title == "薬屋のひとりごと : 猫猫の後宮謎解き手帳. 1" })
        #expect(forthcoming.publisher == catalogued.publisher)
        let shelfName = BookEditionShelf.editionTitle(for: forthcoming)
        #expect(shelfName == BookEditionShelf.editionTitle(for: catalogued))
        // The rows of the queried work itself are untouched.
        #expect(rows.count == raw.count)
    }

    /// Two publishers for one work is a guess this refuses to make.
    @Test("A work printed by two houses leaves the publisher-less row alone")
    func ambiguousPublisherIsNotInherited() {
        func row(_ id: String, publisher: String?) -> BookEdition {
            BookEdition(
                id: id, title: "X. \(id)", isbn13: nil, publisher: publisher, language: "jpn",
                published: nil, coverID: nil, volume: nil, source: .nationalDietLibrary,
                format: .comic, formatEvidence: .catalogueGenre("漫画")
            )
        }
        let rows = BookEditionShelf.withInheritedPublishers([
            row("1", publisher: "A"), row("2", publisher: "B"), row("3", publisher: nil)
        ])
        #expect(rows[2].publisher == nil)
    }

    // MARK: - Serious 2: a partial page

    /// EXPECTED TO FAIL before the change: `NDLClient.answer(title:format:
    /// from:)` and `Answer.isPartial` did not exist; `volumes()` handed the
    /// view `isPartial: false` unconditionally.
    @Test("Fifty of eighty-four is partial; a page that is the whole answer is not")
    func partialPage() throws {
        let data = try page()
        let answer = try #require(NDLClient.answer(title: Self.title, format: .comic, from: data))
        #expect(answer.isPartial)

        // The control: the same page with the envelope claiming exactly what
        // it carried. Anything else this asserts would pass on a flag that
        // is always true.
        let text = try #require(String(data: data, encoding: .utf8))
        let complete = Data(text.replacingOccurrences(
            of: "<numberOfRecords>84</numberOfRecords>", with: "<numberOfRecords>50</numberOfRecords>"
        ).utf8)
        let whole = try #require(NDLClient.answer(title: Self.title, format: .comic, from: complete))
        #expect(!whole.isPartial)
        #expect(whole.answer.rows == answer.answer.rows, "The rows are the same page")
    }

    // MARK: - Minor 4, 5, 13

    /// Asked for a series NDL holds records of, with every one filtered out:
    /// `.editions([])`, not "no record of this series".
    ///
    /// EXPECTED TO FAIL before the change with `.notCatalogued`.
    @Test("A held series whose every record fails the filter is an empty list, not not-catalogued")
    func filteredToNothingIsNotNotCatalogued() throws {
        let answer = try #require(NDLClient.answer(title: "ダンジョン飯", format: .comic, from: try page()))
        #expect(answer.answer == .editions([]))
        // Control: no records at all is `.notCatalogued`.
        let empty = Data(
            "<searchRetrieveResponse><numberOfRecords>0</numberOfRecords></searchRetrieveResponse>".utf8
        )
        #expect(NDLClient.answer(title: "ダンジョン飯", format: .comic, from: empty)?.answer == .notCatalogued)
    }

    /// EXPECTED TO FAIL before the change with the query reading
    /// `title="薬屋の"ひとりごと"" AND mediatype=books`.
    @Test("A quote inside the title cannot end the CQL phrase early")
    func quotesAreDropped() throws {
        let url = try #require(NDLClient.requestURL(japaneseTitle: "薬屋の\"ひとりごと\""))
        let query = try #require(
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first { $0.name == "query" }?.value
        )
        #expect(query == "title=\"薬屋のひとりごと\" AND mediatype=books")
    }

    /// EXPECTED TO FAIL before the change with `nil` — `Int("１３")` is nil.
    @Test("A full-width volume number is read")
    func fullWidthVolumeNumber() {
        #expect(BookEditionShelf.number(from: "１３") == 13)
        #expect(BookEditionShelf.number(from: "[1]") == 1)
        #expect(BookEditionShelf.number(from: "13") == 13, "The control: half-width still reads")
        #expect(BookEditionShelf.number(from: "[第1期]") == nil, "A season is not a volume")
    }
}
