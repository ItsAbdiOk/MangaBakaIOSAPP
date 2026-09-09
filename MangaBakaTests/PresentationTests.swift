import Foundation
import Testing
@testable import MangaBaka

/// The strings the screens actually put in front of a reader.
///
/// These were written after being asked whether everything added had tests. The
/// answer was no: the logic was well covered and the presentation layer was
/// covered only by source-reading assertions and manual QA — which is exactly
/// where a wrong number reads as a real one.
@Suite("What the screens say")
@MainActor
struct PresentationTests {
    // MARK: - The cache pill

    /// Absent rather than invented when nothing has been cached.
    @Test("No cache means no pill")
    func noCacheNoPill() {
        #expect(AppTopBar.cacheLabel(for: nil) == nil)
        // A negative age means the clock moved; not something to report.
        #expect(AppTopBar.cacheLabel(for: -60) == nil)
    }

    @Test("Cache age reads in the largest sensible unit")
    func cacheAgeUnits() {
        #expect(AppTopBar.cacheLabel(for: 5) == "Cached now")
        #expect(AppTopBar.cacheLabel(for: 120) == "Cached 2m")
        #expect(AppTopBar.cacheLabel(for: 3 * 3600) == "Cached 3h")
        #expect(AppTopBar.cacheLabel(for: 50 * 3600) == "Cached 2d")
    }

    // MARK: - The stack card's meta line

    /// No endpoint carries year, rating count and tags together, so each part
    /// renders only when its source supplied it.
    @Test("The meta line degrades to whatever arrived")
    func metaLineDegrades() {
        let full = SeriesFactory.make(id: 1, rating: 78, type: "manhwa", year: 2022, ratingCount: 6400)
        #expect(StackCaption.metaLine(for: full) == "Manhwa · 2022 · 7.8 from 6.4k")

        // The v1 blend has the year but no count.
        let noCount = SeriesFactory.make(id: 1, rating: 78, type: "manhwa", year: 2022)
        #expect(StackCaption.metaLine(for: noCount) == "Manhwa · 2022 · 7.8")

        // The personalised recommender has only the type and the year.
        let sparse = SeriesFactory.make(id: 1, type: "manga", year: 2020)
        #expect(StackCaption.metaLine(for: sparse) == "Manga · 2020")

        // Nothing at all is nothing, not an empty separator string.
        #expect(StackCaption.metaLine(for: SeriesFactory.make(id: 1)) == nil)
    }

    @Test("Vote counts compact only above a thousand")
    func compactCounts() {
        #expect(StackCaption.compact(999) == "999")
        #expect(StackCaption.compact(6400) == "6.4k")
        #expect(StackCaption.compact(1000) == "1.0k")
    }

    // MARK: - Library rows

    private func entry(chapter: Double?) throws -> LibraryEntry {
        try Fixture.decoder().decode(LibraryEntry.self, from: Data("""
        {"id":1,"series_id":1,"state":"dropped",
         "progress_chapter":\(chapter.map { String($0) } ?? "null")}
        """.utf8))
    }

    @Test("Progress reads as a fraction and a percentage")
    func progressLine() throws {
        let series = SeriesFactory.make(id: 1, totalChapters: 112)
        #expect(
            LibraryRow.progressLine(try entry(chapter: 18), series: series)
                == "left at 18/112 · 16%"
        )
    }

    /// An ongoing series has no denominator, and a chapter number is still more
    /// use than nothing.
    @Test("With no chapter count, the chapter still shows")
    func progressWithoutTotal() throws {
        #expect(
            LibraryRow.progressLine(try entry(chapter: 17), series: SeriesFactory.make(id: 1))
                == "left at ch 17"
        )
    }

    @Test("Never started reads as the shelf it is on, not as zero progress")
    func progressUnstarted() throws {
        #expect(
            LibraryRow.progressLine(try entry(chapter: nil), series: SeriesFactory.make(id: 1))
                == "Dropped"
        )
    }

    // MARK: - Schedule rows

    private func cadence(dueDaysFromNow days: Int, gap: Int = 7, spread: Int = 0) -> Cadence {
        Cadence(
            medianGapDays: gap,
            spreadDays: spread,
            lastRelease: Date(timeIntervalSince1970: 1_756_000_000),
            due: Date().addingTimeInterval(Double(days) * 86_400),
            samples: 25,
            isRegular: spread == 0
        )
    }

    @Test("Lateness is phrased in the unit that fits")
    func stateText() {
        let now = Date()
        #expect(ScheduleRow.stateText(cadence(dueDaysFromNow: 3), isLate: false, now: now)
            == "Due in 3 days")
        #expect(ScheduleRow.stateText(cadence(dueDaysFromNow: 1), isLate: false, now: now)
            == "Due in 1 day")
        #expect(ScheduleRow.stateText(cadence(dueDaysFromNow: -5), isLate: true, now: now)
            == "5 days overdue")
    }

    /// The worst real case measured was 1,893 days. "1893 days overdue" is
    /// technically true and unreadable.
    @Test("Years overdue read as years")
    func yearsOverdue() {
        let text = ScheduleRow.stateText(cadence(dueDaysFromNow: -800), isLate: true, now: Date())
        #expect(text == "2 years overdue")
    }

    @Test("An even rhythm says so; an uneven one gives the spread")
    func cadenceLine() {
        #expect(ScheduleRow.cadenceLine(cadence(dueDaysFromNow: 1))
            == "About every 7 days, very evenly")
        #expect(ScheduleRow.cadenceLine(cadence(dueDaysFromNow: 1, gap: 30, spread: 9))
            == "About every 30 days, give or take 9")
        #expect(ScheduleRow.cadenceLine(cadence(dueDaysFromNow: 1, gap: 1))
            == "About every 1 day, very evenly")
    }

    /// An estimate that will not say what it was built from is asking to be
    /// trusted rather than checked.
    @Test("Every estimate states its own provenance")
    func provenance() {
        let text = ScheduleRow.provenance(cadence(dueDaysFromNow: 1))
        #expect(text.contains("25 releases"))
        #expect(text.contains("MangaUpdates"))
        #expect(text.contains("last"))
    }

    // MARK: - Discover

    @Test("A cover's meta line drops the half the API did not send")
    func discoverMeta() {
        #expect(DiscoverView.meta(for: SeriesFactory.make(id: 1, rating: 86, type: "manhwa"))
            == "Manhwa · 8.6")
        #expect(DiscoverView.meta(for: SeriesFactory.make(id: 1, type: "novel")) == "Novel")
        #expect(DiscoverView.meta(for: SeriesFactory.make(id: 1)) == nil)
    }
}

/// Sort keys are query-string values, not words for a screen. At the largest
/// text size "popularity_desc" broke across four lines mid-word.
@Suite("Sort orders read as words")
struct SortOrderTests {
    @Test("Every sort key has a human label")
    func everyKeyHasALabel() {
        for order in SortOrder.all {
            #expect(SortOrder.label(for: order.value) == order.label)
            #expect(!order.label.contains("_"), "\(order.label) is still a query value")
        }
    }

    @Test("An unset or unknown sort has no label rather than a raw key")
    func unknownSortHasNoLabel() {
        #expect(SortOrder.label(for: nil) == nil)
        #expect(SortOrder.label(for: "something_else_desc") == nil)
    }

    /// The filter sheet used to carry its own copy of this list, which is how
    /// two places drift apart.
    @Test("The sort list is defined once")
    func definedOnce() throws {
        // The filter sheet is the only place that renders the list; the search
        // heading uses SortOrder.label. Neither may hold its own copy.
        for path in [
            "MangaBaka/Features/Search/FilterSheet.swift",
            "MangaBaka/Features/Search/SearchView.swift"
        ] {
            let source = try SourceTree.read(path)
            #expect(
                !source.contains("(\"relevance_desc\", \"Relevance\")"),
                "\(path) carries its own copy of the sort list"
            )
        }
        let sheet = try SourceTree.read("MangaBaka/Features/Search/FilterSheet.swift")
        #expect(sheet.contains("SortOrder.all"))
    }
}
