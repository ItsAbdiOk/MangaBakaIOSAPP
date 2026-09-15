import Foundation
import Testing
@testable import MangaBaka

/// Fields on `SeriesEdition` (from `/v1/series/{id}/collections`) and
/// `NewsItem` (from `/v1/series/{id}/news`) that were already on the wire but
/// unread. Fixtures are live captures of series 2060 from 2026-09-15.
@Suite("Edition and news fields")
struct EditionAndNewsFieldsTests {
    private func decodeCollectionsRow() throws -> SeriesEdition {
        let json = try Fixture.data("series-2060-collections-2026-09-15")
        let envelope = try Fixture.decoder().decode(Envelope<[SeriesEdition]>.self, from: json)
        return try #require(envelope.data.first)
    }

    private func decodeNewsRows() throws -> [NewsItem] {
        let json = try Fixture.data("series-2060-news-2026-09-15")
        let envelope = try Fixture.decoder().decode(Envelope<[NewsItem]>.self, from: json)
        return envelope.data
    }

    // MARK: - Part A: collections row -> SeriesEdition

    /// Fails without the fix: these six fields do not exist on `SeriesEdition`
    /// yet, so the row fails to add anything beyond what already decoded.
    @Test("Every new collections field decodes from the live fixture")
    func decodesCollectionsFields() throws {
        let row = try decodeCollectionsRow()

        #expect(row.reading == "ltr")
        #expect(row.format == "paged")
        #expect(row.edition?.name == "Standard Edition")
        #expect(row.edition?.description == "Standard")
        #expect(row.edition?.overrideText == nil)
        #expect(row.countOther == 0)
        #expect(row.note == nil)
        #expect(row.description?.desc?.hasPrefix("As a struggling office worker") == true)
        let link = try #require(row.links?.first)
        #expect(link.type == "publisher")
        #expect(link.link == URL(string: "https://yenpress.com/series/omniscient-reader-s-viewpoint"))
        #expect(link.language == "en")
    }

    @Test("The row's publisher link opens as a safe URL")
    func publisherLinkIsOfferable() throws {
        let row = try decodeCollectionsRow()
        let expected = "https://yenpress.com/series/omniscient-reader-s-viewpoint"
        #expect(row.publisherLinkURL?.absoluteString == expected)
    }

    /// "Standard Edition" is the API's own default label and adds nothing a
    /// reader did not already know from language + publisher.
    @Test("A default edition name is left out of the headline")
    func defaultEditionNameOmitted() throws {
        let row = try decodeCollectionsRow()
        #expect(row.headline == "EN · Ize Press")
    }

    @Test("A non-default edition name is appended to the headline")
    func nonDefaultEditionNameShown() {
        let named = SeriesEdition(
            id: "x", title: nil,
            language: .init(iso: "en", language: nil),
            publisher: .init(id: nil, name: "Ize Press", type: nil),
            medium: nil, status: nil, licensed: nil, countMain: nil, countExtra: nil,
            startDate: nil, endDate: nil,
            edition: .init(id: nil, name: "Deluxe Edition", language: nil,
                            description: nil, overrideText: nil)
        )
        #expect(named.headline == "EN · Ize Press · Deluxe Edition")
    }

    @Test("Reading direction reads as words, not the wire code")
    func readingLabels() {
        #expect(edition(reading: "ltr").readingLabel == "Left to right")
        #expect(edition(reading: "rtl").readingLabel == "Right to left")
        #expect(edition(reading: "unknown").readingLabel == nil, "An unrecognised value is not guessed at")
        #expect(edition(reading: nil).readingLabel == nil)
    }

    @Test("Format reads capitalised only for the two values seen on the wire")
    func formatLabels() {
        #expect(edition(format: "paged").formatLabel == "Paged")
        #expect(edition(format: "webtoon").formatLabel == "Webtoon")
        #expect(edition(format: "print").formatLabel == nil, "Not a value the API has been seen to send")
        #expect(edition(format: nil).formatLabel == nil)
    }

    @Test("Reading and format labels fold into the summary line")
    func labelsJoinDetailLine() {
        let row = edition(format: "paged", reading: "ltr", countMain: 12, status: "completed")
        #expect(row.detail == "12 volumes · Paged · Completed · Left to right")
    }

    /// A cached row from before these fields existed has no keys for them at
    /// all. Fails without the fix: a non-optional or a hand-written
    /// `init(from:)` that requires the keys would throw on this fixture.
    @Test("An old-shape collections row decodes with the new fields nil")
    func oldShapeRowDecodesWithNils() throws {
        let json = Data("""
        {"id":"a","series_id":1,"title":"Old","language":null,"publisher":null,
         "type":"volume","medium":"paperback","status":"unknown","licensed":true,
         "start_date":null,"end_date":null,"related_collection_id":null,
         "count_main":1,"count_extra":0,"updated_at":"2020-01-01T00:00:00.000Z"}
        """.utf8)
        let row = try Fixture.decoder().decode(SeriesEdition.self, from: json)
        #expect(row.reading == nil)
        #expect(row.format == nil)
        #expect(row.edition == nil)
        #expect(row.links == nil)
        #expect(row.countOther == nil)
        #expect(row.note == nil)
        #expect(row.description == nil)
    }

    // MARK: - Part B: news row -> NewsItem

    /// Fails without the fix: `author`, `type` and `mentioned_series` do not
    /// exist on `NewsItem` yet.
    @Test("Every new news field decodes from the live fixture")
    func decodesNewsFields() throws {
        let rows = try decodeNewsRows()
        let first = try #require(rows.first)
        #expect(first.author == "Wonhee Cho")
        #expect(first.type == "default")
        #expect(first.mentionedSeries == [3397, 2060])
    }

    @Test("An article with no byline decodes author as nil")
    func missingAuthorIsNil() throws {
        let rows = try decodeNewsRows()
        // series-2060-news fixture, id 165826: "author":null.
        let row = try #require(rows.first { $0.id == "165826" })
        #expect(row.author == nil)
    }

    @Test("An old-shape news row decodes with the new fields nil")
    func oldShapeNewsRowDecodesWithNils() throws {
        let json = Data("""
        {"id":1,"source_id":"1","source_name":"ann","title":"Old news",
         "url":"https://www.animenewsnetwork.com/x","primary":true,
         "published_at":"2020-01-01T00:00:00.000Z","created_at":"2020-01-01T00:00:00.000Z",
         "updated_at":"2020-01-01T00:00:00.000Z"}
        """.utf8)
        let row = try Fixture.decoder().decode(NewsItem.self, from: json)
        #expect(row.author == nil)
        #expect(row.type == nil)
        #expect(row.mentionedSeries == nil)
    }

    // MARK: - NewsSection: "Also mentions N other series"

    private func newsItem(mentions: [Int]?) -> NewsItem {
        NewsItem(
            newsID: 1, title: "T", url: nil, sourceName: nil, publishedAt: nil, primary: nil,
            author: nil, type: nil, mentionedSeries: mentions
        )
    }

    /// With the current series id in hand, only the *other* ids count.
    @Test("Mentions label counts every id except the current series")
    func mentionsLabelExcludesCurrentSeries() {
        let label = NewsSection.otherMentionsLabel(newsItem(mentions: [3397, 2060]), currentSeriesID: 2060)
        #expect(label == "Also mentions 1 other series")
    }

    @Test("No mentions label when the article only mentions the current series")
    func noMentionsLabelForSingleSeries() {
        #expect(NewsSection.otherMentionsLabel(newsItem(mentions: [2060]), currentSeriesID: 2060) == nil)
    }

    /// Without a current series id, the unsure fallback: every id minus one.
    @Test("Without a current series id, the fallback counts all ids minus one")
    func mentionsLabelFallsBackWithoutCurrentSeriesID() {
        let item = newsItem(mentions: [3397, 2060, 84728])
        let label = NewsSection.otherMentionsLabel(item, currentSeriesID: nil)
        #expect(label == "Also mentions 2 other series")
    }

    @Test("A nil mentioned_series array shows no label")
    func nilMentionsShowsNoLabel() {
        #expect(NewsSection.otherMentionsLabel(newsItem(mentions: nil), currentSeriesID: nil) == nil)
    }

    private func edition(
        format: String? = nil, reading: String? = nil,
        countMain: Int? = nil, status: String? = nil
    ) -> SeriesEdition {
        SeriesEdition(
            id: "1", title: nil, language: nil, publisher: nil, medium: nil,
            status: status, licensed: nil, countMain: countMain, countExtra: nil,
            startDate: nil, endDate: nil,
            reading: reading, format: format
        )
    }
}

/// The `/v1/...` envelope every endpoint wraps its payload in.
private struct Envelope<Payload: Decodable>: Decodable {
    let status: Int
    let data: Payload
}
