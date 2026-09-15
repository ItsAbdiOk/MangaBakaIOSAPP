import Foundation
import SwiftUI
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
    /// The three measurers moved out of the `.background` closure into a
    /// `measurers` property, which mounts them only while their answer for the
    /// current series, width and type size is not already known. The old pin
    /// spelled the closure's literal contents and broke on that; it is now
    /// stated as the rule it was standing for — the measurers are a
    /// background, and every one of them is hidden.
    @Test("The full column is a hidden background, so its height never lays out")
    func measurerIsBackground() throws {
        let source = try SourceTree.read("MangaBaka/Features/Detail/DetailHero.swift")
        #expect(SourceTree.containsRun(source, ".background { measurers(rows: rows) }"))
        #expect(SourceTree.containsRun(source, "column(.full, fill: false, rows: rows) .hidden()"))
        #expect(SourceTree.containsRun(source, "column(.byline, fill: false, rows: rows) .hidden()"))
        #expect(SourceTree.containsRun(source, "column(.chapters, fill: false, rows: rows) .hidden()"))
        // The measurers are mounted behind a key, so a settled hero stops
        // re-measuring. The key has to carry everything that changes the
        // answer, or a swipe to the next series would keep the old heights.
        #expect(SourceTree.containsRun(source, "let key = Self.measureKey( series: series, scheduleShape:"))
        #expect(SourceTree.containsRun(source, "if columnWidth > 0, measuredFor != key {"))
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
        #expect(SourceTree.containsRun(block, "if isExpanded { Text(ScheduleRow.cadenceLine(estimate))"))
    }
}

/// Item 66 (second-pass review, 2026-09-14). The measurers retired once
/// `measuredFor` matched a key of series id, width and type size — but the
/// chapter line, the kicker, the byline, the "Also known as" count and the
/// schedule block all arrive *after* the first layout, and each changes the
/// column's height. The key now carries them, so a chapter count landing
/// from `extras` puts the measurers back.
///
/// Expected to fail before the fix: `DetailHero.measureKey` does not exist
/// — a compile failure, not a wrong value. The old `MeasureKey` had no
/// field a chapter count could be expressed in, so no assertion against it
/// could have failed for the right reason; this is stated rather than
/// dressed up.
@Suite("The hero re-measures when the column's inputs land")
struct DetailHeroMeasureKeyTests {
    private func key(_ series: Series, scheduleShape: Int = 0) -> DetailHero.MeasureKey {
        DetailHero.measureKey(series: series, scheduleShape: scheduleShape, width: 175, typeSize: .large)
    }

    @Test("A chapter count arriving from extras changes the key")
    func chapterCountChangesTheKey() {
        let lean = SeriesFactory.make(id: 7, title: "Regressed")
        let filled = SeriesFactory.make(id: 7, title: "Regressed", totalChapters: 212)
        #expect(key(lean) != key(filled))
        #expect(key(filled).chapterCount == "212 chapters")
    }

    @Test("A status and type arriving changes the key; a rating does not")
    func kickerChangesTheKeyRatingDoesNot() {
        let lean = SeriesFactory.make(id: 7, title: "Regressed")
        let withKicker = SeriesFactory.make(id: 7, title: "Regressed", status: "completed", type: "manhwa")
        #expect(key(lean) != key(withKicker))
        #expect(key(withKicker).kicker == "Manhwa · Completed")
        // The rating is on the stats strip, not in the column: no re-measure.
        let rated = SeriesFactory.make(id: 7, title: "Regressed", rating: 8.6)
        #expect(key(lean) == key(rated))
    }

    @Test("The schedule block's shape is part of the key")
    func scheduleShapeIsInTheKey() {
        let series = SeriesFactory.make(id: 7, title: "Regressed")
        let loading = DetailHero.scheduleShape(hasSchedule: false, isLoading: true, failed: false)
        let none = DetailHero.scheduleShape(hasSchedule: false, isLoading: false, failed: false)
        let estimate = DetailHero.scheduleShape(hasSchedule: true, isLoading: false, failed: false)
        #expect(Set([none, loading, estimate]).count == 3)
        // Measured while the ask was out, then it answered "none": the
        // block leaves and the column is shorter than measured.
        #expect(key(series, scheduleShape: loading) != key(series, scheduleShape: none))
        // An estimate outranks a loading flag still set beside it.
        #expect(DetailHero.scheduleShape(hasSchedule: true, isLoading: true, failed: false) == estimate)
    }
}
