import Foundation
import Testing
@testable import MangaBaka

/// The year in review: what was finished, when, and how fast.
@Suite("Wrapped year")
struct ReadingWrappedYearTests: WrappedFixtures {
    // MARK: - The year

    /// Dropping a series sets a finish date on some trackers. Whether MangaBaka
    /// does is unverified; either way, a dropped series is not one you
    /// finished, and the card says "finished".
    @Test("A dropped series with a finish date is not a series you finished")
    func droppedIsNotFinished() {
        let entries = [
            libraryEntry(1, state: .completed, total: 100, finish: day("2026-03-04")),
            libraryEntry(2, state: .dropped, total: 50, finish: day("2026-05-05"))
        ]
        let year = ReadingWrapped.year(2026, in: entries, calendar: utc)
        #expect(year.finished.map(\.seriesId) == [1])
        #expect(year.chapters == 100)
    }

    @Test("A year is what you finished in it")
    func yearFiltersByFinishDate() {
        let entries = [
            libraryEntry(1, total: 100, finish: day("2026-03-04")),
            libraryEntry(2, total: 50, finish: day("2026-11-20")),
            libraryEntry(3, total: 999, finish: day("2025-12-31")),
            libraryEntry(4)
        ]
        let year = ReadingWrapped.year(2026, in: entries, calendar: utc)

        #expect(year.finished.map(\.seriesId) == [2, 1], "newest first")
        #expect(year.chapters == 150, "the 2025 finish is not in this year")
        #expect(year.dated == 3)
        #expect(year.total == 4)
    }

    @Test("A year says how much of the library it could see")
    func yearReportsItsCoverage() {
        // Finish dates are set by the site when a series is completed there,
        // and not otherwise. A year built from four of nine hundred entries is
        // a different claim from one built from all of them.
        let entries = (1...10).map { libraryEntry($0, finish: $0 <= 2 ? day("2026-05-05") : nil) }
        let year = ReadingWrapped.year(2026, in: entries, calendar: utc)
        #expect(year.coverage == 0.2)
        #expect(!year.isWorthShowing, "two finishes is a list, not a year")
    }

    @Test("A tied busiest month is not reported")
    func tiedMonthsAreSilent() {
        // "Your busiest month was March, or possibly July" is not a fact worth
        // printing, and picking one at random is worse.
        let entries = [
            libraryEntry(1, finish: day("2026-03-01")),
            libraryEntry(2, finish: day("2026-07-01"))
        ]
        let year = ReadingWrapped.year(2026, in: entries, calendar: utc)
        #expect(ReadingWrapped.busiestMonth(in: year, calendar: utc) == nil)
    }

    @Test("A clear busiest month is")
    func busiestMonthIsFound() throws {
        let entries = [
            libraryEntry(1, finish: day("2026-03-01")),
            libraryEntry(2, finish: day("2026-03-14")),
            libraryEntry(3, finish: day("2026-07-01"))
        ]
        let year = ReadingWrapped.year(2026, in: entries, calendar: utc)
        let month = try #require(ReadingWrapped.busiestMonth(in: year, calendar: utc))
        #expect(month.month == 3)
        #expect(month.count == 2)
    }

    @Test("A oneshot is not the fastest read of your life")
    func sprintsNeedARealRun() {
        // One chapter finished the day it was started is technically the
        // fastest reading anybody has ever done.
        let entries = [
            libraryEntry(1, read: 1, total: 1, start: day("2026-01-01"), finish: day("2026-01-01"))
        ]
        #expect(ReadingWrapped.fastestFinish(in: entries, calendar: utc) == nil)
    }

    @Test("A binge is")
    func sprintIsFound() throws {
        let entries = [
            libraryEntry(1, total: 200, start: day("2026-01-01"), finish: day("2026-01-05")),
            libraryEntry(2, total: 200, start: day("2026-01-01"), finish: day("2026-06-01"))
        ]
        let sprint = try #require(ReadingWrapped.fastestFinish(in: entries, calendar: utc))
        #expect(sprint.entry.seriesId == 1)
        #expect(sprint.perDay == 50)
    }

    @Test("Same-day finishes count as one day, not none")
    func sameDayIsOneDay() throws {
        let entries = [
            libraryEntry(1, total: 60, start: day("2026-02-02"), finish: day("2026-02-02"))
        ]
        let sprint = try #require(ReadingWrapped.fastestFinish(in: entries, calendar: utc))
        #expect(sprint.perDay == 60)
    }

    @Test("A whole series logged on one day is a backfill, not a binge")
    func backfillsAreRejected() {
        // Found on a real 939-entry library: the screen announced "700
        // chapters a day — NARUTO, 700 chapters in 1 day". Nobody read Naruto
        // in a day. A series marked completed with both dates set to that
        // moment is what every importer and most bulk edits produce.
        let entries = [
            libraryEntry(1, total: 700, start: day("2026-01-01"),
                         finish: day("2026-01-01"), type: "manga"),
            libraryEntry(2, total: 120, start: day("2026-02-01"),
                         finish: day("2026-02-03"), type: "manhwa")
        ]
        let sprint = ReadingWrapped.fastestFinish(in: entries, calendar: utc)
        #expect(sprint?.entry.seriesId == 2, "the real binge, not the import")
    }

    @Test("A genuine binge is not rejected with the backfills")
    func realBingesSurvive() {
        // 40 manhwa chapters in a day is four hours. Extraordinary, possible,
        // and exactly the kind of thing this card exists to celebrate.
        let entries = [
            libraryEntry(1, total: 40, start: day("2026-03-01"),
                         finish: day("2026-03-01"), type: "manhwa")
        ]
        #expect(ReadingWrapped.fastestFinish(in: entries, calendar: utc)?.perDay == 40)
    }

    /// An 80-chapter manga stamped with one day is 14.7 hours at 11 minutes:
    /// under the sixteen-hour ceiling, so it used to pass as a binge. Same-day
    /// is also exactly what an importer writes, and size is the only tell.
    @Test("A large same-day sprint is an import, not a binge")
    func largeSameDayIsRejected() {
        let entries = [
            libraryEntry(1, total: 80, start: day("2026-03-01"),
                         finish: day("2026-03-01"), type: "manga")
        ]
        #expect(ReadingWrapped.fastestFinish(in: entries, calendar: utc) == nil)
    }

    @Test("The thing you have been reading longest is still unfinished")
    func longestRunningIsUnfinished() throws {
        let entries = [
            libraryEntry(1, state: .reading, start: day("2019-04-01")),
            libraryEntry(2, state: .completed, start: day("2015-01-01"), finish: day("2016-01-01")),
            libraryEntry(3, state: .reading, start: day("2024-01-01"))
        ]
        #expect(try #require(ReadingWrapped.longestRunning(in: entries)).seriesId == 1)
    }

}
