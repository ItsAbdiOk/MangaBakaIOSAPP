import Foundation
import Testing
@testable import MangaBaka

/// Item 69 (wire review, `docs/reviews/full/wire.md` finding 4, 2026-09-14):
/// `Series.tagsV2` used to decode through a private `lenientElements` +
/// `AnyDecodable` pair that dropped a bad row silently — `lenientElements`
/// returns `[Element]?`, with no count of what it skipped, so there was no
/// value here to write a test against in the first place. `LossyArray`
/// (`LossyArray.swift`) does the same per-element skip and also reports
/// `dropped`, which `Series.init(from:)` now logs when non-zero. `os.Logger`
/// output cannot be read back in-process, so this test checks the fact the
/// log line reports: decoding the same `tags_v2` shape `Series` decodes,
/// directly through the same `LossyArray<SeriesTag>` type it now uses,
/// yields a `dropped` count of exactly one for one malformed row among three.
///
/// The companion control, `WireNullabilityTests.swift`'s
/// `WireResilienceTests.oneBadTagCostsOneTag` (unchanged, not owned here),
/// proves the visible-to-the-reader half: `richTags` still comes out
/// `["Action", "Murim"]`, before and after this fix — that part of the
/// behaviour was never broken.
///
/// **Honesty about what this test can and cannot show.** The bug the finding
/// describes is a silent *count*, produced only by a log line inside
/// `Series.init(from:)` (`Self.logger.error(...)`), and `os.Logger` output
/// cannot be captured in-process — there is no supported way to assert "a log
/// line was or was not emitted" from a Swift Testing suite. So this does not,
/// and cannot, fail against the pre-fix `Series.swift`: `LossyArray` itself
/// (`LossyArray.swift`) is untouched and already reported `dropped` before
/// this change: only `Series.init(from:)`'s use of it is new. What this test
/// does instead: pins down, for the exact JSON shape `Series.tagsV2` decodes,
/// that `LossyArray<SeriesTag>` — the type `Series.init(from:)` now calls
/// directly — reports `dropped == 1`, so the count `Series.init(from:)` logs
/// is provably the right number and not a guess. Proving the log line itself
/// fires would need a custom `os.Logger` sink or a source-level diff of
/// `Series.swift`, not a unit test.
@Suite("tags_v2's dropped rows are counted, not just skipped")
struct SeriesTagsV2DropCountTests {
    @Test("One malformed tags_v2 row is counted as one drop")
    func oneBadTagRowIsCountedAsDropped() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let json = Data("""
        [{"id": 1, "name": "Action"}, {"id": 2, "name": null}, {"id": 3, "name": "Murim"}]
        """.utf8)

        let decoded = try decoder.decode(LossyArray<SeriesTag>.self, from: json)

        #expect(decoded.elements.map(\.name) == ["Action", "Murim"])
        #expect(decoded.dropped == 1)
    }

    /// A well-formed tags_v2 payload drops nothing, so the fixed decoder
    /// must not log a phantom loss for the common case.
    @Test("A clean tags_v2 payload drops nothing")
    func cleanPayloadDropsNothing() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let json = Data("""
        [{"id": 1, "name": "Action"}, {"id": 3, "name": "Murim"}]
        """.utf8)

        let decoded = try decoder.decode(LossyArray<SeriesTag>.self, from: json)

        #expect(decoded.elements.map(\.name) == ["Action", "Murim"])
        #expect(decoded.dropped == 0)
    }
}
