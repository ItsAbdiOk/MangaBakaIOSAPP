import Foundation
import Testing
@testable import MangaBaka

/// Fields the v1 series record carries that `Series` never decoded until now:
/// `popularity`, `published`, `is_licensed`, `romanized_title`,
/// `native_title`, `secondary_titles`, `genres`, `relationships_v2`.
///
/// Every value below was read out of `series-2060-record-2026-09-15.json`
/// (`data`, series 2060 — Omniscient Reader) by hand, not guessed. Without
/// the new stored properties and `init(from:)` cases, every one of these
/// `#expect`s fails with "value of type 'Series' has no member" at compile
/// time — there is no runtime path where the old code even builds.
@Suite("Series — v1 record fields")
struct SeriesRecordFieldsTests {
    private func decodeRecord() throws -> Series {
        let envelope = try Fixture.decoder()
            .decode(APIEnvelope<Series>.self, from: Fixture.data("series-2060-record-2026-09-15"))
        return try #require(envelope.data)
    }

    @Test("popularity decodes both leaderboards and their history")
    func popularityDecodes() throws {
        let series = try decodeRecord()
        let popularity = try #require(series.popularity)

        let global = try #require(popularity.global)
        #expect(global.current == 14)
        #expect(global.history?["1d"] == 14)
        #expect(global.history?["1w"] == 14)
        #expect(global.history?["1mo"] == 14)
        #expect(global.history?["3mo"] == 11)
        #expect(global.history?["6mo"] == 11)
        #expect(global.history?["1y"] == 18)

        let type = try #require(popularity.type)
        #expect(type.current == 2)
        #expect(type.history?["1d"] == 2)
        #expect(type.history?["1y"] == 2)
    }

    @Test("published decodes the raw dates and estimate flags")
    func publishedDecodes() throws {
        let series = try decodeRecord()
        let published = try #require(series.published)

        #expect(published.startDate == "2020-05-26")
        #expect(published.endDate == nil)
        #expect(published.startDateIsEstimated == false)
        #expect(published.endDateIsEstimated == nil)
    }

    @Test("is_licensed decodes true")
    func isLicensedDecodes() throws {
        let series = try decodeRecord()
        #expect(series.isLicensed == true)
    }

    @Test("romanized_title and native_title decode")
    func titleFieldsDecode() throws {
        let series = try decodeRecord()
        #expect(series.romanizedTitle == "Jeonjijeok Dokja Sijeom")
        #expect(series.nativeTitle == "전지적 독자 시점")
    }

    @Test("secondary_titles decodes its group and every entry")
    func secondaryTitlesDecode() throws {
        let series = try decodeRecord()
        let secondary = try #require(series.secondaryTitles)
        let unknown = try #require(secondary["unknown"])

        #expect(unknown.count == 19)
        #expect(unknown.first?.type == "unknown")
        #expect(unknown.first?.title == "전지적 독자 시점")
        #expect(unknown.first?.note == nil)
        #expect(unknown.contains { $0.title == "ORV" })
        #expect(unknown.contains { $0.title == "Omniscient Reader" })
    }

    @Test("genres decodes as plain strings")
    func genresDecode() throws {
        let series = try decodeRecord()
        #expect(series.genres == [
            "action", "adventure", "fantasy", "drama", "mystery", "psychological", "supernatural"
        ])
    }

    @Test("relationships_v2 decodes both entries, including chronology")
    func relationshipsV2Decode() throws {
        let series = try decodeRecord()
        let relationships = try #require(series.relationshipsV2)
        #expect(relationships.count == 2)

        let other = try #require(relationships.first { $0.toSeriesId == 5911 })
        #expect(other.id == "019e41ed-22ed-7cf6-aa7d-f5c310f04302")
        #expect(other.relationType == "other")
        #expect(other.chronology == "unknown")
        #expect(other.note == nil)

        let source = try #require(relationships.first { $0.toSeriesId == 84728 })
        #expect(source.relationType == "source")
        #expect(source.chronology == "unknown")
    }
}

@Suite("Popularity.trendLine / yearAgoLine")
struct PopularityTrendLineTests {
    @Test("Both ranks present reads as \"overall\" and \"among <type>\"")
    func bothRanksPresent() {
        let popularity = Popularity(
            global: .init(current: 14, history: ["1y": 18]),
            type: .init(current: 2, history: nil)
        )
        #expect(popularity.trendLine(typeWord: "manhwa") == "#14 overall · #2 among manhwa")
    }

    @Test("No type word falls back to \"in its category\" — a guess at wording")
    func noTypeWordGuess() {
        let popularity = Popularity(
            global: .init(current: 14, history: nil),
            type: .init(current: 2, history: nil)
        )
        #expect(popularity.trendLine(typeWord: nil) == "#14 overall · #2 in its category")
    }

    @Test("Only a global rank omits the \"among\" clause entirely")
    func onlyGlobalRank() {
        let popularity = Popularity(global: .init(current: 14, history: nil), type: nil)
        #expect(popularity.trendLine(typeWord: "manhwa") == "#14 overall")
    }

    @Test("Nil when neither rank is present")
    func neitherRankPresent() {
        let popularity = Popularity(global: .init(current: nil, history: nil), type: nil)
        #expect(popularity.trendLine(typeWord: "manhwa") == nil)
    }

    @Test("yearAgoLine reads the 1y history entry when it differs from today")
    func yearAgoDiffers() {
        let popularity = Popularity(global: .init(current: 14, history: ["1y": 18]), type: nil)
        #expect(popularity.yearAgoLine == "was #18 a year ago")
    }

    @Test("yearAgoLine is nil when the rank has not moved in a year")
    func yearAgoUnchanged() {
        let popularity = Popularity(global: .init(current: 14, history: ["1y": 14]), type: nil)
        #expect(popularity.yearAgoLine == nil)
    }

    @Test("yearAgoLine is nil with no 1y history at all")
    func yearAgoMissing() {
        let popularity = Popularity(global: .init(current: 14, history: [:]), type: nil)
        #expect(popularity.yearAgoLine == nil)
    }
}

@Suite("Published.rangeLine")
struct PublishedRangeLineTests {
    @Test("An open-ended series reads \"<year> – ongoing\"")
    func ongoing() {
        let published = Published(
            startDate: "2020-05-26", endDate: nil,
            startDateIsEstimated: false, endDateIsEstimated: nil
        )
        #expect(published.rangeLine == "2020 – ongoing")
    }

    @Test("A finished series reads \"<start> – <end>\"")
    func finished() {
        let published = Published(
            startDate: "2015-01-01", endDate: "2021-12-31",
            startDateIsEstimated: false, endDateIsEstimated: false
        )
        #expect(published.rangeLine == "2015 – 2021")
    }

    @Test("An estimated start date is prefixed \"c.\" — a guess at wording")
    func estimatedStart() {
        let published = Published(
            startDate: "2020-05-26", endDate: nil,
            startDateIsEstimated: true, endDateIsEstimated: nil
        )
        #expect(published.rangeLine == "c. 2020 – ongoing")
    }

    @Test("An estimated end date is prefixed \"c.\" on the end year only")
    func estimatedEnd() {
        let published = Published(
            startDate: "2015-01-01", endDate: "2021-12-31",
            startDateIsEstimated: false, endDateIsEstimated: true
        )
        #expect(published.rangeLine == "2015 – c. 2021")
    }

    @Test("Nil with no start date to anchor the line on")
    func noStartDate() {
        let published = Published(
            startDate: nil, endDate: "2021-12-31",
            startDateIsEstimated: nil, endDateIsEstimated: nil
        )
        #expect(published.rangeLine == nil)
    }
}

/// De-duplication for `AlternativeTitlesButton.merging`, the feed from
/// `romanized_title`/`native_title`/`secondary_titles` into the titles list.
@Suite("AlternativeTitlesButton.merging")
struct AlternativeTitlesMergingTests {
    private static let baseTitles = [
        SeriesTitle(language: "ko", traits: ["native"], title: "전지적 독자 시점", isPrimary: true),
        SeriesTitle(language: "en", traits: ["official"], title: "Omniscient Reader", isPrimary: true)
    ]

    @Test("A record whose extra fields fully duplicate titles adds nothing")
    func fullOverlapAddsNothing() {
        let merged = AlternativeTitlesButton.merging(
            romanizedTitle: nil,
            nativeTitle: "전지적 독자 시점",
            secondaryTitles: ["unknown": [.init(type: "unknown", title: "Omniscient Reader", note: nil)]],
            into: Self.baseTitles, shown: nil
        )
        #expect(merged.count == Self.baseTitles.count)
    }

    @Test("A genuinely new secondary title is added")
    func newSecondaryTitleIsAdded() {
        let merged = AlternativeTitlesButton.merging(
            romanizedTitle: nil, nativeTitle: nil,
            secondaryTitles: ["unknown": [.init(type: "unknown", title: "Brand New Name", note: nil)]],
            into: Self.baseTitles, shown: nil
        )
        #expect(merged.contains { $0.title == "Brand New Name" })
        #expect(merged.count == Self.baseTitles.count + 1)
    }

    @Test("De-duplication is case-insensitive")
    func dedupeIsCaseInsensitive() {
        let merged = AlternativeTitlesButton.merging(
            romanizedTitle: "OMNISCIENT READER", nativeTitle: nil, secondaryTitles: nil,
            into: Self.baseTitles, shown: nil
        )
        #expect(merged.count == Self.baseTitles.count)
    }

    @Test("A new romanized title also excludes whatever is already on screen")
    func excludesShown() {
        let merged = AlternativeTitlesButton.merging(
            romanizedTitle: "already shown", nativeTitle: nil, secondaryTitles: nil,
            into: Self.baseTitles, shown: "Already Shown"
        )
        #expect(merged.count == Self.baseTitles.count)
    }
}

/// An old-shaped record — the bare body `SeriesRepositoryFetchedTests`
/// (`bareSeriesBody`) already uses to prove partial-cache behaviour, with
/// none of this file's new fields present. Mirrors that shape by hand since
/// `bareSeriesBody` itself is private to that suite.
@Suite("Old-shaped record")
struct OldShapedRecordTests {
    @Test("A record with none of the new fields still decodes, all nil")
    func decodesWithNewFieldsNil() throws {
        let body = Data("""
        {"status":200,"data":{"id":1,"state":"active","merged_with":null,"titles":null,
         "cover":{"raw":null,"x150":null,"x250":null,"x350":null,"blurhash":null,"width":null,"height":null},
         "description":null,"authors":null,"artists":null,"status":null,"rating":null,"type":null,
         "content_rating":null,"total_chapters":null,"final_volume":null,
         "publishers":null,"anime":null,"source":null}}
        """.utf8)

        let envelope = try Fixture.decoder().decode(APIEnvelope<Series>.self, from: body)
        let series = try #require(envelope.data)

        #expect(series.popularity == nil)
        #expect(series.published == nil)
        #expect(series.isLicensed == nil)
        #expect(series.romanizedTitle == nil)
        #expect(series.nativeTitle == nil)
        #expect(series.secondaryTitles == nil)
        #expect(series.genres == nil)
        #expect(series.relationshipsV2 == nil)
        #expect(series.popularityTrendLine == nil)
    }
}
