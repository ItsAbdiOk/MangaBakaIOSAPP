import Testing
import Foundation
@testable import MangaBaka

/// `SeriesWork.Trim.wMm`/`hMm` and `Image.image` were typed from three rows
/// of one series with `images: []` and an ordinary trim — wire review
/// W9/W12/P9/P12, 2026-09-15. These cover the shapes that fixture never
/// exercised: an out-of-range trim value, a null trim field, and an `image`
/// object `Cover` cannot parse.
@Suite("SeriesWork decode leniency after W9/W12")
struct SeriesWorkWireFixTests {
    private func decode(_ json: String) throws -> SeriesWork {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(SeriesWork.self, from: Data(json.utf8))
    }

    private func rowJSON(extra: String) -> String {
        """
        {"id": "1", "sequence_string": "1", "sequence_numeric": 1,
         "release_date": null, "pages": null, "price": null,
         "identifiers": null\(extra)}
        """
    }

    /// Fails on the pre-fix code with a trap: `Int(_:)` on a `Double`
    /// outside roughly ±9.2e18 is a fatal error, not a catchable one, so this
    /// is verified by reading `Int(_:)`'s documented precondition rather than
    /// by re-running the old code (that would crash the whole test process,
    /// same as `BlendDNAWireFixTests`). `Int(wholeOrClamped:)` clamps to
    /// `.max` instead.
    @Test("A trim value far outside Int's range does not crash trimLine")
    func absurdTrimValueClampsInsteadOfTrapping() throws {
        let work = try decode(rowJSON(extra: #", "trim": {"w_mm": 1e300, "h_mm": 209.5}"#))
        #expect(work.trimLine == "\(Int.max) × 210 mm")
    }

    /// Fails on the pre-fix code — `Trim.wMm`/`hMm` were non-optional
    /// `Double`, so a `null` in either field threw a `DecodingError` decoding
    /// `Trim` itself, which (since `SeriesWork.trim` is optional but `Trim`'s
    /// own decode is not lenient) failed the whole `SeriesWork` and dropped
    /// the edition via `LossyArray` rather than just losing one dimension.
    @Test("A null trim dimension decodes as nil in that field, not a dropped edition")
    func nullTrimDimensionDecodesLeniently() throws {
        let work = try decode(rowJSON(extra: #", "trim": {"w_mm": null, "h_mm": 209.5}"#))
        #expect(work.trim?.wMm == nil)
        #expect(work.trim?.hMm == 209.5)
        // Half a trim is not enough to show a line — both dimensions are
        // required for the sentence to read correctly.
        #expect(work.trimLine == nil)
    }

    /// The ordinary case, still exact — `SeriesWorkFieldsTests.trimDecodesAndRounds`
    /// already covers the live fixture; this is the same shape via
    /// hand-written JSON to isolate it from the fixture's other fields.
    @Test("An ordinary trim still decodes and rounds")
    func ordinaryTrimStillWorks() throws {
        let work = try decode(rowJSON(extra: #", "trim": {"w_mm": 146.05, "h_mm": 209.55}"#))
        #expect(work.trimLine == "146 × 210 mm")
    }

    /// Fails on the pre-fix code — `Image` used the synthesised decoder, so
    /// an `image` value `Cover.init(from:)` cannot parse threw a
    /// `DecodingError` that propagated out through `images: [Image]?` and
    /// failed the whole `SeriesWork`, dropping the edition. Leniently
    /// decoded, only the malformed `image` field is lost. `Cover`'s own
    /// decoder tolerates a malformed *object* (every field is optional and
    /// individually wrapped in `try?`, see `Cover.swift:42-48`), so the shape
    /// that actually reaches `Cover.init(from:)`'s own throw is a JSON value
    /// that is not an object at all — `decoder.container(keyedBy:)` itself
    /// throws a type mismatch pulling a keyed container from a bare string.
    @Test("An image value Cover cannot parse at all decodes as nil, not a dropped edition")
    func malformedImageDecodesLeniently() throws {
        let work = try decode(rowJSON(extra: #", "images": [{"image": "not-an-object", "type": "cover"}]"#))
        let image = try #require(work.images?.first)
        #expect(image.image == nil)
        #expect(image.type == "cover")
    }

    /// The absent case, matching the only shape actually seen live
    /// (`images: []` in `series-2060-works-2026-09-15.json`).
    @Test("An empty images array still decodes to no cover")
    func emptyImagesArrayDecodes() throws {
        let work = try decode(rowJSON(extra: #", "images": []"#))
        #expect(work.images?.isEmpty == true)
        #expect(work.cover == nil)
    }
}
