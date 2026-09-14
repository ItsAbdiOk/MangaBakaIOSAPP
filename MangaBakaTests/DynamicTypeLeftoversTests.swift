import SwiftUI
import Testing
@testable import MangaBaka

/// The 2026-09-11 accessibility audit's four remaining findings on the series
/// detail page and library: the stats strip's uppercase labels, the synopsis
/// at accessibility text sizes, the hero title, and the library search
/// field's hit area. These assert the shape of each fix rather than the
/// symptom, the same way `DynamicTypeLayoutTests` does for the earlier round.
/// Gated per test, not per suite (2026-09-14): the gate on the suite also
/// skipped the tests below that assert on a value and never touch the
/// checkout, so they did not run on Xcode Cloud at all — and nothing
/// reports the difference between a local run and a cloud one.
@Suite("Dynamic Type leftovers")
struct DynamicTypeLeftoversTests {
    private static let ownedFiles = [
        "MangaBaka/Features/Detail/DetailStatsStrip.swift",
        "MangaBaka/Features/Detail/DetailSynopsis.swift",
        "MangaBaka/Features/Detail/DetailHero.swift",
        "MangaBaka/Features/Shared/InlineSearchField.swift"
    ]

    private func source(_ path: String) throws -> String {
        try SourceTree.read(path)
    }

    /// A hard-coded point size does not grow with the reader's text size
    /// setting. Every one of these four files should reach for a text style
    /// or `scaledFont`/`@ScaledMetric` instead.
    @Test("No fixed-point fonts on the audited files", .enabled(if: SourceTree.isAvailable))
    func noFixedPointFonts() throws {
        for path in Self.ownedFiles {
            let text = try source(path)
            #expect(
                !text.contains("font(.system(size:"),
                "\(path) has a fixed-point font that will not scale"
            )
        }
    }

    /// A fixed height around scaled text clips it once Dynamic Type grows
    /// past whatever the height was measured at. `frame(minHeight:` is fine —
    /// it is `frame(height:` that clips.
    @Test("No fixed heights on the audited files", .enabled(if: SourceTree.isAvailable))
    func noFixedHeights() throws {
        for path in Self.ownedFiles {
            let text = try source(path)
            #expect(
                !text.contains(".frame(height:"),
                "\(path) has a fixed height that will clip scaled text"
            )
        }
    }

    /// The stats strip's uppercase labels use `Palette.textMuted`, which is
    /// the only one of the muted/secondary tokens that clears 4.5:1 against
    /// the ground (measured: textMuted 4.66:1, textSecondary 6.2-6.3:1,
    /// textTertiary ~4.0:1, textQuaternary ~2.6:1 — see Palette.swift for the
    /// opacities). Guards against a future edit reaching for the fainter
    /// tokens that read as "more subtle" but fail contrast.
    @Test("Stats strip labels use a token that passes contrast", .enabled(if: SourceTree.isAvailable))
    func statsStripLabelUsesPassingToken() throws {
        let text = try source("MangaBaka/Features/Detail/DetailStatsStrip.swift")
        #expect(text.contains("stat.label.uppercased())"))
        #expect(
            !text.contains("textTertiary") && !text.contains("textQuaternary"),
            "These tokens measure under 4.5:1 against the ground"
        )
    }

    /// The synopsis collapses to fewer lines at accessibility sizes, so
    /// "View more" appears without a long scroll of enlarged text first.
    @Test("Synopsis collapses to 8 lines normally, 4 at accessibility sizes")
    func synopsisCollapsedLines() {
        #expect(DetailSynopsis.collapsedLines(for: .large) == 8)
        #expect(DetailSynopsis.collapsedLines(for: .xxxLarge) == 8)
        #expect(DetailSynopsis.collapsedLines(for: .accessibility1) == 4)
        #expect(DetailSynopsis.collapsedLines(for: .accessibility5) == 4)
    }

    /// The search field grows to at least Apple's 44pt minimum tap height
    /// instead of the mockup's fixed 40 (`Metrics.field`), so it clears the
    /// hit-area audit and still grows if the row's content ever needs more.
    @Test("The library search field has no fixed height", .enabled(if: SourceTree.isAvailable))
    func searchFieldMinimumHeight() throws {
        let text = try source("MangaBaka/Features/Shared/InlineSearchField.swift")
        #expect(text.contains("frame(minHeight: Metrics.tapTarget)"))
    }
}
