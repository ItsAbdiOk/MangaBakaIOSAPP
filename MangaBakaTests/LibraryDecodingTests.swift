import Foundation
import Testing
@testable import MangaBaka

/// Decodes a real `/v1/my/library` response, captured from the live API on
/// 2026-09-09.
///
/// The shape is untouched — that is the whole point of the fixture — but every
/// identifying value is replaced: ids, titles, description, authors, tags,
/// links and the user id. A library is a reading history, and this repository
/// is public.
///
/// This exists because the stack's personalisation is only as good as this
/// decode: if a library entry fails to decode, `library()` returns an empty
/// array through a `try?` and the stack silently falls back to a random queue.
/// The reader sees a working app that has quietly stopped using their taste.
///
/// Extended 2026-09-13 (F12) with two more entries, redacted the same way:
/// both original captures were `state: reading`, `rating: null`,
/// `finish_date: null` — every rule that turns on a rating, a finish date or
/// a terminal state had nothing recorded to decode against. Entry 1002 is
/// `completed`, rated, and finished; 1003 is `dropped`. Shapes only, not
/// live-recaptured — the reader-identifying values were never real to begin
/// with in the first two entries either.
@Suite("Library decoding")
struct LibraryDecodingTests {
    private func entries() throws -> [LibraryEntry] {
        // `Fixture.decoder()` is `APIClient.makeDecoder()` itself now, not a
        // second hand-rolled decoder — it already accepts `library.json`'s
        // `"2026-08-27T00:00:00.000Z"` (fractional seconds) through the
        // with-fraction/plain/date-only chain production uses. Overriding it
        // to `.iso8601` here, as this used to, meant "a real response
        // decodes" measured a decoder nothing in the app ever runs.
        let decoder = Fixture.decoder()
        let envelope = try decoder.decode(
            APIEnvelope<[LibraryEntry]>.self,
            from: try Fixture.data("library")
        )
        return envelope.data ?? []
    }

    @Test("A real library response decodes")
    func decodesRealResponse() throws {
        let all = try entries()
        #expect(all.count == 4)
    }

    /// The seed the stack blends from. If this is wrong every recommendation
    /// is built from the wrong series, which no test of the blend itself would
    /// catch.
    @Test("Each entry carries the series id the stack seeds from")
    func carriesSeriesID() throws {
        #expect(try entries().map(\.seriesId) == [1000, 1001, 1002, 1003])
    }

    /// F12: the first two captures were both `reading`, unrated and
    /// unfinished — a rating, a finish date, and a terminal state had nothing
    /// recorded to decode against.
    @Test("A completed, rated, finished entry decodes its rating and finish date")
    func decodesCompletedRatedFinished() throws {
        let entry = try #require(try entries().first { $0.seriesId == 1002 })
        #expect(entry.state == .completed)
        #expect(entry.rating == 92)
        #expect(entry.finishDate != nil)
        #expect(entry.progressVolume == 20)
    }

    @Test("A dropped entry decodes as dropped, with no rating or finish date")
    func decodesDropped() throws {
        let entry = try #require(try entries().first { $0.seriesId == 1003 })
        #expect(entry.state == .dropped)
        #expect(entry.rating == nil)
        #expect(entry.finishDate == nil)
    }

    /// The capitalised key. With `convertFromSnakeCase` active it survives
    /// untouched while every other key becomes camelCase, so it is the one
    /// field that has to be spelled out.
    @Test("The nested series decodes despite its capitalised key")
    func decodesNestedSeries() throws {
        let first = try #require(try entries().first)
        #expect(first.series?.id == 1000)
        #expect(first.series?.displayTitle != nil)
    }

    /// The bug that made all of this fail: `/v1/my/*` returns each cover
    /// variant as an object, `/v2/series/*` as a plain string, and only the
    /// second is in the published spec.
    @Test("A cover in the v1 object shape decodes, dimensions and all")
    func decodesObjectShapedCover() throws {
        let cover = try #require(try entries().first?.series?.cover)
        #expect(cover.raw != nil)
        #expect(cover.x150 != nil)
        #expect(cover.blurhash != nil)
        // Nested inside `raw` in this shape rather than beside it.
        #expect(cover.width == 460)
        #expect(cover.height == 690)
    }

    /// Picking `x2` as the base would silently double every image request on a
    /// 3x screen, because `url(forHeight:scale:)` then swaps @2 for @3 on a URL
    /// that was already the 2x rendering.
    @Test("The 1x rendering is the base, so scaling still works")
    func usesOneXAsBase() throws {
        let cover = try #require(try entries().first?.series?.cover)
        let base = try #require(cover.x150)
        #expect(base.absoluteString.contains("@1"))

        let scaled = try #require(cover.url(forHeight: 150, scale: 3))
        #expect(scaled.absoluteString.contains("@3"))
    }

    @Test("Reading state and progress survive")
    func decodesState() throws {
        let first = try #require(try entries().first)
        #expect(first.state == .reading)
        #expect(first.progressChapter == 17)
        #expect(first.priority == 20)
    }

    /// Both shapes of the same field, side by side. The v1 form is what threw.
    /// Solo Leveling (3397), live: `ko`, `ko-Latn`, `ja-Latn` and `ja` titles
    /// all tagged `native`, in an order the API does not document as stable.
    /// Fails without the fix: first-match on the `native` trait alone returns
    /// "ko-latn" when a romanised native title sorts first, which then
    /// narrows `coverLanguages` to `["en", "ko-latn"]` and drops every Korean
    /// cover — `"ko".hasPrefix("ko-latn")` is false.
    @Test("A native language is never a romanisation, whatever order the titles arrive in")
    func nativeLanguageSkipsRomanisations() {
        let series = SeriesFactory.make(titles: [
            SeriesTitle(
                language: "ko-Latn", traits: ["native"], title: "Naega Choego-Rank", isPrimary: false
            ),
            SeriesTitle(language: "ko", traits: ["native"], title: "나 혼자만 레벨업", isPrimary: true)
        ])
        #expect(series.nativeLanguage == "ko")
    }

    @Test("A chapter count decodes whether it is a number or a string")
    func lenientNumbers() throws {
        func series(_ chapters: String) throws -> Series {
            try Fixture.decoder().decode(Series.self, from: Data("""
            {"id":1,"state":"active","cover":{},"total_chapters":\(chapters)}
            """.utf8))
        }

        #expect(try series("87").totalChapters == 87)
        #expect(try series("\"87\"").totalChapters == 87)
        // Genuinely unusable values leave the field absent rather than
        // discarding the whole series.
        #expect(try series("\"unknown\"").totalChapters == nil)
    }

    /// Two captured shapes of the same fact, both from series 3397 live,
    /// 2026-09-13. `/v2/series/3397` (schema=full) sends
    /// `anime: {exists: true, start, end}` and no `has_anime`. `/v1/series/3397`
    /// — what fills every library entry's gaps — sends `anime: {start, end}`
    /// with **no `exists` key**, plus a sibling `has_anime: true`. Fails
    /// without `hasAnimeAdaptation`: reading `anime?.exists` alone answers
    /// false for the v1 shape, even though the series plainly has two anime
    /// seasons.
    @Test("An anime adaptation is recognised whether the wire says exists or has_anime")
    func hasAnimeAdaptationReconcilesBothShapes() throws {
        let v2Shape = try Fixture.decoder().decode(Series.self, from: Data("""
        {"id":3397,"state":"active","cover":{},
         "anime":{"exists":true,"start":"Chap 0 (S1)","end":"Chap 46 (S2)"}}
        """.utf8))
        #expect(v2Shape.hasAnimeAdaptation == true)

        let v1Shape = try Fixture.decoder().decode(Series.self, from: Data("""
        {"id":3397,"state":"active","cover":{},"has_anime":true,
         "anime":{"start":"Chap 0 (S1)","end":"Chap 46 (S2)"}}
        """.utf8))
        #expect(v1Shape.hasAnimeAdaptation == true)

        let neither = try Fixture.decoder().decode(Series.self, from: Data("""
        {"id":1,"state":"active","cover":{}}
        """.utf8))
        #expect(neither.hasAnimeAdaptation == false)
    }

    /// `Int(_: Double)` traps on NaN, infinity, or anything past Int's range.
    /// `Double("inf")` and a JSON number like `1e19` both parse as finite
    /// Swift `Double`s, so nothing before this stopped them reaching an
    /// unguarded `Int(_:)`. Fails without the fix: decoding either payload
    /// crashes the process instead of returning a `Series` with the field
    /// absent — expected to fail with a fatal trap, not a thrown error.
    @Test("A non-finite or oversized number decodes as absent rather than trapping")
    func nonFiniteNumbersDoNotTrap() throws {
        let withInfiniteYear = try Fixture.decoder().decode(Series.self, from: Data("""
        {"id":1,"state":"active","cover":{},"year":"inf"}
        """.utf8))
        #expect(withInfiniteYear.year == nil)

        let withHugeRatingCount = try Fixture.decoder().decode(Series.self, from: Data("""
        {"id":1,"state":"active","cover":{},"rating_count":1e19}
        """.utf8))
        #expect(withHugeRatingCount.ratingCount == nil)
    }
}
