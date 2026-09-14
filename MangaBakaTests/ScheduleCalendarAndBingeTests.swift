import Testing
import Foundation
@testable import MangaBaka

/// Item 29: MangaUpdates release dates are UTC midnights, and `Cadence` read
/// them through `Calendar.current`.
///
/// `startOfDay` in a zone west of UTC moves every one of those instants to the
/// previous local day, so "last release", "due" and "late" were a day early
/// for every reader in the Americas, on every row, every time. `CadenceTests`
/// pins GMT, which is exactly why it agreed with the bug instead of catching
/// it — so this suite forces a western calendar in.
@Suite("Release dates are read in UTC")
struct ReleaseDateCalendarTests {
    private static var losAngeles: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles") ?? .current
        return calendar
    }

    /// A bare `yyyy-MM-dd` from MangaUpdates, parsed the way
    /// `MangaUpdatesClient.Release.formatter` parses it: UTC midnight.
    private func utcMidnight(_ day: String) throws -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return try #require(formatter.date(from: day))
    }

    /// Expected failure before the fix: `Cadence.estimate` defaulted to
    /// `Calendar.current`, so a test running on a machine in Los Angeles read
    /// 2026-09-05T00:00Z as 4 September and `lastRelease` came back a day
    /// early. The default is now `Calendar.utc`.
    @Test("A weekly series' last release is the day the publisher stated")
    func lastReleaseIsNotADayEarly() throws {
        let days = ["2026-08-15", "2026-08-22", "2026-08-29", "2026-09-05"]
        let dates = try days.map { try utcMidnight($0) }

        let cadence = try #require(Cadence.estimate(from: dates))
        #expect(cadence.lastRelease == (try utcMidnight("2026-09-05")))
        #expect(cadence.medianGapDays == 7)
    }

    /// The control, and the reason the bug was invisible: the same call with
    /// a Los Angeles calendar forced in still gives 4 September, which is what
    /// every reader in the Americas used to see.
    @Test("Control: forcing a western calendar still reproduces the old, wrong day")
    func westernCalendarStillShiftsTheDay() throws {
        let days = ["2026-08-15", "2026-08-22", "2026-08-29", "2026-09-05"]
        let dates = try days.map { try utcMidnight($0) }

        let cadence = try #require(Cadence.estimate(from: dates, calendar: Self.losAngeles))
        #expect(cadence.lastRelease != (try utcMidnight("2026-09-05")),
                "this is the behaviour the default no longer has")
    }

    /// `overdueDays` had the same default and therefore the same shift: a
    /// series due today read as one day late for anyone west of UTC.
    @Test("Something due today is not reported as a day late")
    func dueTodayIsNotLate() throws {
        let due = try utcMidnight("2026-09-05")
        let cadence = Cadence(
            medianGapDays: 7, spreadDays: 0,
            lastRelease: try utcMidnight("2026-08-29"), due: due,
            samples: 10, gaps: 9, isRegular: true
        )
        // Mid-morning UTC on the day itself, which is the previous evening in
        // Los Angeles — the window where the two calendars disagree.
        let now = due.addingTimeInterval(10 * 3600)

        #expect(cadence.overdueDays(asOf: now) == 0)
        #expect(cadence.state(asOf: now) == .due)
    }
}

/// Item 42: the two binge ceilings disagreed by 5-6x.
///
/// A same-day span was capped at 60 chapters; a multi-day span was capped by
/// hours — 16 hours at `ReadingTime`'s calibrated ~2.8 minutes a chapter is
/// about 343 chapters a day. So an import stamped start=yesterday
/// finish=today walked 80 chapters through, and 600 over two days passed at
/// 300 a day. No test sat at either boundary, which is how they drifted apart.
@Suite("One binge ceiling for every span")
struct BingeCeilingTests {
    private func sprint(chapters: Int, days: Int) -> ReadingWrapped.Sprint {
        ReadingWrapped.Sprint(
            entry: LibraryEntry(
                id: 1, seriesId: 1, state: .completed, progressChapter: Double(chapters),
                progressVolume: nil, rating: nil, note: nil, startDate: nil,
                finishDate: nil, numberOfRereads: nil, priority: nil, isPrivate: nil,
                readLink: nil, series: SeriesFactory.make(id: 1, title: "S", type: "Manga")
            ),
            chapters: chapters, days: max(days, 1), isSameDay: days == 0
        )
    }

    /// Expected failure before the fix: 80 chapters over a one-day span is
    /// 80 a day, which at 2.8 minutes a chapter is 3.7 hours — comfortably
    /// inside the 16-hour ceiling, so `isPlausible` returned true and the
    /// year-in-review announced a stamped import as the reader's fastest read.
    @Test("An import stamped yesterday-to-today is rejected, not called a binge")
    func stampedImportAcrossOneNightIsRejected() {
        #expect(!ReadingWrapped.isPlausible(sprint(chapters: 80, days: 1)))
    }

    /// The same number over the same span, judged by the same ceiling as a
    /// same-day binge — which is the whole point of collapsing the two.
    @Test("The same chapter count is judged the same way whatever the span claims")
    func theCeilingDoesNotDependOnTheSpan() {
        #expect(!ReadingWrapped.isPlausible(sprint(chapters: 80, days: 0)))
        #expect(!ReadingWrapped.isPlausible(sprint(chapters: 600, days: 2)))
    }

    /// The control: a genuine afternoon still survives. A ceiling that
    /// rejected everything would pass the three tests above for the wrong
    /// reason.
    @Test("Control: a real 40-chapter manhwa afternoon is still plausible")
    func aRealBingeSurvives() {
        #expect(ReadingWrapped.isPlausible(sprint(chapters: 40, days: 0)))
        #expect(ReadingWrapped.isPlausible(sprint(chapters: 300, days: 10)))
    }
}
