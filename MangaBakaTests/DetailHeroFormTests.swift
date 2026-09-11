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

    @Test("A full column no taller than the cover is shown in full")
    func fitsIsFull() {
        #expect(DetailHero.form(fullHeight: cover - 40, coverHeight: cover) == .full)
        #expect(DetailHero.form(fullHeight: cover, coverHeight: cover) == .full)
    }

    /// One point over is a gap of one point, and a five-line title is many.
    @Test("A full column taller than the cover is compressed")
    func overflowIsCompact() {
        #expect(DetailHero.form(fullHeight: cover + 1, coverHeight: cover) == .compact)
        #expect(DetailHero.form(fullHeight: cover + 160, coverHeight: cover) == .compact)
    }

    /// The first frame has no measurement. A gap that opens and then closes
    /// is worse than a byline that appears.
    @Test("Unmeasured is compact")
    func unmeasuredIsCompact() {
        #expect(DetailHero.form(fullHeight: nil, coverHeight: cover) == .compact)
    }
}

/// The measurement must not be able to grow the column it measures.
@Suite("The hero measures the full column off-screen", .enabled(if: SourceTree.isAvailable))
struct DetailHeroMeasurementTests {
    @Test("The full column is a hidden background, so its height never lays out")
    func measurerIsBackground() throws {
        let source = try SourceTree.read("MangaBaka/Features/Detail/DetailHero.swift")
        let measurer = ".background {\n                column(.full)\n                    .hidden()"
        #expect(source.contains(measurer))
        #expect(source.contains("onGeometryChange(for: CGFloat.self)"))
    }

    /// The parts the compact form drops are exactly the ones that wrapped.
    @Test("The full form carries the byline and the expanded schedule; compact neither")
    func fullCarriesTheExtras() throws {
        let source = try SourceTree.read("MangaBaka/Features/Detail/DetailHero.swift")
        #expect(source.contains("isExpanded: form == .full"))
        #expect(source.contains("if form == .full, let byline"))
        let block = try SourceTree.read("MangaBaka/Features/Detail/DetailScheduleBlock.swift")
        #expect(block.contains("if isExpanded {\n                Text(ScheduleRow.cadenceLine(estimate))"))
    }
}
