import Foundation
import Testing
@testable import MangaBaka

/// The hero compresses only when it has to.
///
/// The first fix for the gap under the cover on a long title compressed the
/// column for every series, which threw away the byline and the cadence
/// sentence on the short titles that had room for them. The rule now: the full
/// column, measured at its real width, is shown when it is no taller than the
/// cover; otherwise the compact one.
@Suite("The hero compresses only when it has to")
struct DetailHeroFormTests {
    private let cover = Metrics.coverDetailHeroWidth / Metrics.coverAspect

    /// Defaults the chapters measurement to "does not fit", so the existing
    /// cases keep asking exactly what they asked before.
    private func form(
        _ full: CGFloat?, _ byline: CGFloat?, chapters: CGFloat? = .greatestFiniteMagnitude
    ) -> DetailHero.Form {
        DetailHero.form(
            chaptersHeight: chapters, fullHeight: full, bylineHeight: byline, coverHeight: cover
        )
    }

    @Test("A full column no taller than the cover is shown in full")
    func fitsIsFull() {
        #expect(form(cover - 40, cover - 80) == .full)
        #expect(form(cover, cover - 30) == .full)
    }

    /// A short column has height to spare, and the chapter count goes in it.
    @Test("A column short enough to take the chapter count gets it")
    func shortColumnGainsChapters() {
        #expect(form(cover - 40, cover - 80, chapters: cover - 20) == .chapters)
        #expect(form(cover - 40, cover - 80, chapters: cover) == .chapters)
    }

    /// The count is the first thing given up, not the byline: it is the one
    /// piece of this column repeated verbatim on the stats strip below.
    @Test("A column that fits only without the chapter count keeps the full form")
    func chaptersYieldFirst() {
        #expect(form(cover - 5, cover - 40, chapters: cover + 1) == .full)
        #expect(form(nil, cover - 5, chapters: cover + 30) == .byline)
    }

    /// The middle form: a three-line title has room for the byline but not
    /// the cadence sentence, and used to go straight to compact.
    @Test("A column that fits only without the cadence sentence keeps the byline")
    func middleKeepsByline() {
        #expect(form(cover + 30, cover - 5) == .byline)
        #expect(form(cover + 30, cover) == .byline)
    }

    /// One point over is a gap of one point, and a five-line title is many.
    @Test("A column taller than the cover in both forms is compressed")
    func overflowIsCompact() {
        #expect(form(cover + 60, cover + 1) == .compact)
        #expect(form(cover + 160, cover + 120) == .compact)
    }

    /// The first frame has no measurement. A gap that opens and then closes
    /// is worse than a byline that appears.
    @Test("Unmeasured is compact")
    func unmeasuredIsCompact() {
        #expect(form(nil, nil, chapters: nil) == .compact)
        #expect(form(nil, cover - 5, chapters: nil) == .byline)
    }
}

/// The measurement must not be able to grow the column it measures.
@Suite("The hero measures the full column off-screen", .enabled(if: SourceTree.isAvailable))
struct DetailHeroMeasurementTests {
    @Test("The full column is a hidden background, so its height never lays out")
    func measurerIsBackground() throws {
        let source = try SourceTree.read("MangaBaka/Features/Detail/DetailHero.swift")
        let measurer = ".background {\n                column(.full, fill: false)\n"
        #expect(source.contains(measurer))
        #expect(source.contains("column(.byline, fill: false)\n                    .hidden()"))
        #expect(source.contains("column(.chapters, fill: false)\n                    .hidden()"))
        // And the visible column is stretched to the cover, never the measurer.
        #expect(source.contains(".frame(minHeight: coverHeight, alignment: .top)"))
        #expect(source.contains("onGeometryChange(for: CGFloat.self)"))
    }

    /// The parts the compact form drops are exactly the ones that wrapped.
    @Test("The full form carries the byline and the expanded schedule; compact neither")
    func fullCarriesTheExtras() throws {
        let source = try SourceTree.read("MangaBaka/Features/Detail/DetailHero.swift")
        #expect(source.contains("isExpanded: form.isExpanded"))
        #expect(source.contains("if form.hasByline, let byline"))
        let block = try SourceTree.read("MangaBaka/Features/Detail/DetailScheduleBlock.swift")
        #expect(block.contains("if isExpanded {\n                Text(ScheduleRow.cadenceLine(estimate))"))
    }
}
