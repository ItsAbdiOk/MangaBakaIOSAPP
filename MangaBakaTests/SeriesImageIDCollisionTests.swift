import Foundation
import Testing
@testable import MangaBaka

/// Item 118 (wire review, `docs/reviews/full/wire.md` finding 17, 2026-09-14):
/// `SeriesImage.id` fell back to `"\(index)-\(language)"` when both the
/// wire's `id` and the cover's `raw` URL were nil, so two such rows in the
/// same language collided on the same fallback string and `ForEach`
/// misbehaved (skipped rows, wrong identity across diffs). `indexNumeric` and
/// `type` are the two remaining fields that can still separate such rows, so
/// both were folded into the fallback key.
@Suite("SeriesImage.id does not collide")
struct SeriesImageIDCollisionTests {
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    /// Two rows with no `id` and no `raw` cover URL, same language, same
    /// `index` text — the exact shape that collided before the fix.
    /// `indexNumeric` is the only field left that differs between them.
    ///
    /// Expected failure before the fix: `images[0].id != images[1].id`
    /// fails — both were `"1-en"`.
    @Test("Two null-id rows in the same language get distinct ids")
    func distinctIndexNumericGivesDistinctIDs() throws {
        let images = try decoder.decode([SeriesImage].self, from: Data("""
        [{"id": null, "series_id": 1, "type": "volume", "index": "1", "index_numeric": 1.0,
          "language": "en", "content_rating": "safe", "image": {}},
         {"id": null, "series_id": 1, "type": "other", "index": "1", "index_numeric": 1.5,
          "language": "en", "content_rating": "safe", "image": {}}]
        """.utf8))

        #expect(images.count == 2)
        #expect(images[0].id != images[1].id)
    }

    /// Same `index`, same `indexNumeric`, same language — a volume cover next
    /// to an "other" (promotional) image at the same numbering. `type` is the
    /// only field left that tells them apart.
    ///
    /// Expected failure before the fix: `images[0].id != images[1].id` fails
    /// — both were `"1-en"`, and the fix's own `indexNumeric` alone (both
    /// nil, since neither row sets it) would not have separated these either,
    /// which is why `type` joins the key too.
    @Test("A volume and an 'other' image at the same index get distinct ids")
    func distinctTypeGivesDistinctIDs() throws {
        let images = try decoder.decode([SeriesImage].self, from: Data("""
        [{"id": null, "series_id": 1, "type": "volume", "index": "1", "index_numeric": null,
          "language": "en", "content_rating": "safe", "image": {}},
         {"id": null, "series_id": 1, "type": "other", "index": "1", "index_numeric": null,
          "language": "en", "content_rating": "safe", "image": {}}]
        """.utf8))

        #expect(images.count == 2)
        #expect(images[0].id != images[1].id)
    }
}
