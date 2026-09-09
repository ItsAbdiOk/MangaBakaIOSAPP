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
@Suite("Library decoding")
struct LibraryDecodingTests {
    private func entries() throws -> [LibraryEntry] {
        let decoder = Fixture.decoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(
            APIEnvelope<[LibraryEntry]>.self,
            from: try Fixture.data("library")
        )
        return envelope.data ?? []
    }

    @Test("A real library response decodes")
    func decodesRealResponse() throws {
        let all = try entries()
        #expect(all.count == 2)
    }

    /// The seed the stack blends from. If this is wrong every recommendation
    /// is built from the wrong series, which no test of the blend itself would
    /// catch.
    @Test("Each entry carries the series id the stack seeds from")
    func carriesSeriesID() throws {
        #expect(try entries().map(\.seriesId) == [1000, 1001])
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
}
