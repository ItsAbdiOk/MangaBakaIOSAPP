import Foundation
import Testing
@testable import MangaBaka

/// Reading NDL Search's SRU catalogue.
///
/// Two recorded responses, both saved verbatim on 2026-09-14 from
/// `https://ndlsearch.ndl.go.jp/api/sru?operation=searchRetrieve&
/// recordSchema=dcndl&recordPacking=xml&query=title="…" AND mediatype=books`:
///
/// - `ndl-solo-leveling.xml` — `maximumRecords=3`, 27 held. Contains the
///   forthcoming volume (`dcterms:issued 2026-09-18`), which is the whole
///   reason this client exists.
/// - `ndl-apothecary-diaries.xml` — `maximumRecords=8`, 84 held. The
///   manga-versus-light-novel test, and the noise that comes with it: an anime
///   soundtrack, an art book and a mook all match the same title search.
@Suite("NDL Search")
struct NDLClientTests {
    private func records(_ fixture: String) throws -> [NDLRecordParser.Record] {
        let data = try Fixture.data(fixture, extension: "xml")
        return try #require(NDLRecordParser.parse(data))
    }

    // MARK: - The parser

    /// The nesting test. `dcndl` wraps a genre's real value in an
    /// `rdf:Description` next to its kana transcription, and wraps a
    /// publisher's name in a `foaf:Agent` identical to the creator's — so a
    /// flat reader files マンガ as the genre and the author as the publisher.
    @Test("A record's nested fields are read from the right container")
    func readsNestedFields() throws {
        let record = try #require(records("ndl-solo-leveling").first { $0.volume == "10" })
        #expect(record.title == "俺だけレベルアップな件. 10")
        #expect(record.genre == "漫画")
        #expect(record.publisher == "KADOKAWA")
        #expect(record.seriesTitle == "MFC")
        #expect(record.language == "jpn")
        // The work was translated from Korean. This is *not* the language of
        // this printing, and reading it as one would file a Japanese book as
        // a Korean edition.
        #expect(record.originalLanguage == "kor")
    }

    /// Hyphenated on one record and not on another, in the same response.
    @Test("ISBNs arrive with and without hyphens and are stored one way")
    func normalisesISBN() throws {
        let isbns = try records("ndl-solo-leveling").compactMap(\.isbn)
        #expect(isbns.contains("9784046604873"))
        #expect(isbns.contains("9784046816351"))
        #expect(isbns.allSatisfy { $0.allSatisfy(\.isNumber) })
    }

    /// The headline capability: a volume NDL has catalogued that nobody can
    /// buy yet. The fixture was recorded on 2026-09-14, four days before.
    @Test("A forthcoming volume is read as forthcoming")
    func readsForthcomingVolume() throws {
        let record = try #require(
            records("ndl-solo-leveling").first { $0.isbn == "9784046604873" }
        )
        let issued = try #require(PartialDate.parse(record.issued))
        #expect(issued.precision == .day)
        #expect(issued.isForthcoming(now: Self.recordedAt))
        // The control: its published sibling, from the same response, must
        // not be forthcoming — otherwise the assertion above is only testing
        // that the clock is wrong.
        let older = try #require(records("ndl-solo-leveling").first { $0.volume == "10" })
        let olderIssued = try #require(PartialDate.parse(older.issued))
        #expect(!olderIssued.isForthcoming(now: Self.recordedAt))
        #expect(olderIssued.precision == .year)
    }

    /// 2026-09-14T00:00Z, the day the fixtures were recorded. The forthcoming
    /// assertion is about a date four days later, so it must not be compared
    /// against `Date()` — that test would quietly stop testing anything on
    /// 2026-09-19 and would then start failing for the wrong reason.
    private static let recordedAt = Date(timeIntervalSince1970: 1_789_344_000)

    // MARK: - The filter

    /// The Apothecary Diaries test, which is the one that decides whether this
    /// source is worth having. One title search returns the manga, the light
    /// novel, an art book, a mook and an anime soundtrack.
    @Test("The light novel, the soundtrack and the art book are all dropped")
    func filtersToManga() throws {
        let all = try records("ndl-apothecary-diaries")
        let query = NDLClient.Query(title: "薬屋のひとりごと", format: .comic)
        let rows = query.rows(from: all)

        #expect(rows.contains { $0.title == "薬屋のひとりごと : 猫猫の後宮謎解き手帳. 1" })
        #expect(rows.contains { $0.title == "薬屋のひとりごと外伝小蘭回想録. 1" })
        // 主婦の友社 / ヒーロー文庫 — the light novel, and the exact row that a
        // format-blind integration puts on the comic shelf.
        #expect(!rows.contains { $0.publisher == "主婦の友社" })
        #expect(!rows.contains { $0.publisher == "東宝" })
        #expect(!rows.contains { $0.title == "薬屋のひとりごと画集" })
        #expect(rows.allSatisfy { $0.format == .comic })
    }

    /// The control for the test above: with no format asked for, the same
    /// records produce the soundtrack and the light novel too. Without this,
    /// "the soundtrack is dropped" would also pass if the filter dropped
    /// everything.
    @Test("Asking for no format keeps the rows the comic filter removes")
    func unfilteredControl() throws {
        let all = try records("ndl-apothecary-diaries")
        let rows = NDLClient.Query(title: "薬屋のひとりごと", format: .unknown).rows(from: all)
        #expect(rows.contains { $0.publisher == "主婦の友社" })
        #expect(rows.contains { $0.publisher == "東宝" })
        // Both of those come through as `.unknown` — no genre field, so no
        // claim. The manga volumes in the same list still say `.comic`,
        // because NDL stated it; asking for no format switches the filter
        // off, not the cataloguer's own answer.
        let novel = try #require(rows.first { $0.publisher == "主婦の友社" })
        #expect(novel.format == .unknown)
        #expect(novel.formatEvidence == .unstated)
        #expect(rows.contains { $0.format == .comic })
    }

    /// The rule that lets a 近刊 record through: it states no genre, but its
    /// imprint is one the genre-stating records in the same answer carry.
    @Test("A forthcoming record with no genre is admitted on its imprint")
    func imprintCorroboration() throws {
        let rows = NDLClient.Query(title: "俺だけレベルアップな件", format: .comic)
            .rows(from: try records("ndl-solo-leveling"))
        let forthcoming = try #require(rows.first { $0.isbn13 == "9784046604873" })
        #expect(forthcoming.format == .comic)
        #expect(forthcoming.formatEvidence == .imprintCorroborated(imprint: "MFC"))
        #expect(forthcoming.isForthcoming(now: Self.recordedAt))

        // And its evidence is weaker than its siblings', on purpose.
        let published = try #require(rows.first { $0.volume == "10" })
        #expect(published.formatEvidence == .catalogueGenre("漫画"))
    }

    /// `title=` is a keyword match. The research pass' `ダンジョン飯` query
    /// returned `引退したSランク冒険者は辺境でダンジョン飯を作ることにした` — a
    /// different series that merely mentions this one.
    @Test("A title that only contains the series name is not a match")
    func prefixMatchOnly() {
        let query = NDLClient.Query(title: "ダンジョン飯", format: .comic)
        var mentioned = NDLRecordParser.Record()
        mentioned.title = "引退したSランク冒険者は辺境でダンジョン飯を作ることにした"
        #expect(!query.titleMatches(mentioned))

        var volume = NDLRecordParser.Record()
        volume.title = "ダンジョン飯 1"
        #expect(query.titleMatches(volume))
    }

    /// The forthcoming record uses U+3000 IDEOGRAPHIC SPACE where its
    /// published siblings use an ASCII one.
    @Test("Full-width and ASCII spacing compare equal")
    func normalisesWidth() {
        let query = NDLClient.Query(title: "俺だけレベルアップな件", format: .comic)
        var record = NDLRecordParser.Record()
        record.title = "俺だけレベルアップな件外伝　01"
        #expect(query.titleMatches(record))
    }

    /// NDL sends each catalogue item as two sibling `dcndl:BibResource`
    /// elements carrying the same `rdf:about` — 16 of them for the 8 records
    /// this fixture asked for. One row each, not two.
    @Test("A catalogue item sent twice becomes one row")
    func deduplicatesByURI() throws {
        let all = try records("ndl-apothecary-diaries")
        #expect(all.count == 8)
        #expect(Set(all.compactMap(\.uri)).count == 8)
        let rows = NDLClient.Query(title: "薬屋のひとりごと", format: .unknown).rows(from: all)
        #expect(Set(rows.map(\.id)).count == rows.count)
    }

    // MARK: - Request shape

    /// Three parameters, each of which broke the integration when wrong.
    @Test("The request carries the three parameters NDL needs")
    func requestShape() throws {
        let url = try #require(NDLClient.requestURL(japaneseTitle: "ダンジョン飯"))
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let values = Dictionary(
            items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first }
        )
        // Without this, `recordData` is an escaped string and the parser sees
        // zero records.
        #expect(values["recordPacking"] == "xml")
        #expect(values["recordSchema"] == "dcndl")
        // Unquoted, and not `mediatype="1"`, which NDL rejects outright.
        #expect(values["query"]?.hasSuffix("AND mediatype=books") == true)
    }

    /// The cache key is a filename. Swift seeds `Hashable` per process, so a
    /// `hashValue`-derived name would never hit after a relaunch.
    @Test("The cache key is stable across processes")
    func stableCacheKey() {
        #expect(NDLClient.cacheKey("薬屋のひとりごと") == NDLClient.cacheKey("薬屋のひとりごと"))
        #expect(NDLClient.cacheKey("薬屋のひとりごと") != NDLClient.cacheKey("ダンジョン飯"))
        // FNV-1a over the UTF-8 bytes, computed independently of the
        // implementation: if this number changes, every cached file is
        // orphaned and the constant below must be re-derived deliberately.
        #expect(NDLClient.cacheKey("") == "cbf29ce484222325")
    }
}
