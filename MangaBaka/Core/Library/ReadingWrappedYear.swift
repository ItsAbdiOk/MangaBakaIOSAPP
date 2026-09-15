import Foundation

extension Calendar {
    /// A Gregorian calendar fixed to UTC.
    ///
    /// Every date this app receives that is a *calendar day* rather than an
    /// instant arrives as UTC midnight: `finish_date`/`start_date` as
    /// `YYYY-MM-DDT00:00:00.000Z` (`docs/schemas/mangabaka_openapi.json:29915-29927`),
    /// and MangaUpdates' `release_date` as a bare `yyyy-MM-dd` this app parses
    /// with a UTC formatter (`MangaUpdatesClient.Release.formatter`). Reading
    /// any of those through `Calendar.current` west of UTC moves every one of
    /// them to the previous local day — a 1 January finish lands in the year
    /// before, and a 5 September release reads as 4 September for every reader
    /// in the Americas, on every row, every time.
    ///
    /// Lived on `ReadingWrapped` as `utcCalendar` until 2026-09-14, where only
    /// the year-in-review could reach it; `Cadence` needed exactly the same
    /// thing and had `.current`.
    static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }()
}

extension ReadingWrapped {
    /// See `Calendar.utc`, which this now names.
    static var utcCalendar: Calendar { .utc }

    // MARK: - The year itself

    /// What the reader finished in one calendar year.
    ///
    /// Everything here depends on `finishDate`, which the reader may never
    /// have set — MangaBaka fills it when a series is marked completed through
    /// the site, and not when it is marked completed some other way. So every
    /// figure reports how many entries it could actually see, and the screen
    /// is expected to say so rather than present a year built from four
    /// entries as though it were the whole of one.
    struct Year: Equatable, Sendable {
        let year: Int
        /// Series finished in the year, newest first.
        let finished: [LibraryEntry]
        /// Chapters in those series, counting a completed series' whole run
        /// where no progress number was set.
        let chapters: Int
        /// How many library entries carry a finish date at all.
        let dated: Int
        /// How many entries there are in total.
        let total: Int

        /// Whether there is enough here to show a year at all.
        ///
        /// **A guess.** Three finishes is the point below which a "year in
        /// review" is a list rather than a review.
        var isWorthShowing: Bool { finished.count >= 3 }

        /// What share of the library the dates cover, for the screen's own
        /// honesty line.
        var coverage: Double { total > 0 ? Double(dated) / Double(total) : 0 }
    }

    static func year(
        _ year: Int,
        in entries: [LibraryEntry],
        calendar: Calendar = utcCalendar
    ) -> Year {
        let dated = entries.filter { $0.finishDate != nil }
        // Not "has a finish date in the year": a dropped series may carry one
        // on some trackers, and the card says *finished*.
        let finished = dated
            .filter { $0.state != .dropped }
            .filter { calendar.component(.year, from: $0.finishDate ?? .distantPast) == year }
            .sorted { ($0.finishDate ?? .distantPast) > ($1.finishDate ?? .distantPast) }
        let chapters = finished.reduce(0) { total, entry in
            total + Int(wholeOrClamped: ReadingInsights.chaptersCounted(for: entry))
        }
        return Year(
            year: year,
            finished: finished,
            chapters: chapters,
            dated: dated.count,
            total: entries.count
        )
    }

    /// The month the reader finished the most, and how many.
    ///
    /// Nil on a tie at the top: "your busiest month was March, or possibly
    /// July" is not a fact worth printing, and picking one of them at random
    /// is worse.
    static func busiestMonth(
        in year: Year,
        calendar: Calendar = utcCalendar
    ) -> (month: Int, count: Int)? {
        var counts: [Int: Int] = [:]
        for entry in year.finished {
            guard let date = entry.finishDate else { continue }
            counts[calendar.component(.month, from: date), default: 0] += 1
        }
        let ranked = counts.sorted { $0.value > $1.value }
        guard let top = ranked.first else { return nil }
        guard ranked.count == 1 || ranked[1].value < top.value else { return nil }
        return (top.key, top.value)
    }

    /// A series the reader went through unusually fast.
    struct Sprint: Equatable, Sendable {
        let entry: LibraryEntry
        let chapters: Int
        let days: Int
        /// Start and finish on one calendar day — a binge, or an import.
        var isSameDay = false

        /// Chapters a day, rounded. Never zero: a series finished the day it
        /// was started took one day, not none.
        var perDay: Int { max(1, Int((Double(chapters) / Double(max(days, 1))).rounded())) }
    }

    // `plausibleHoursPerDay: Double = 16` used to live here, for the
    // multi-day branch of `isPlausible`. Deleted 2026-09-14 (item 42): it is
    // the reason the two ceilings disagreed by 5-6x. Sixteen hours at
    // `ReadingTime`'s calibrated ~2.8 minutes a chapter for manga is ~343
    // chapters a day, against 60 for a same-day span — so an import stamped
    // start=yesterday finish=today walked through at 80 chapters, and 600
    // over two days passed at 300 a day. Its own comment (kept below, it
    // records a real measurement) explains the same-day figure; there is now
    // one figure for both.

    /// The reading ceiling, in chapters a day, for any span.
    ///
    /// **A guess, restated by R8.** This used to be an hours figure
    /// (`hoursPerDay <= 8`) built on `ReadingInsights.minutesPerChapter`'s old,
    /// unlabelled 11-minutes-a-chapter guess: an 80-chapter manga stamped on
    /// one day came to 14.7 hours and was rejected. R8 replaced that rate with
    /// `ReadingTime`'s calibrated ~2.8 minutes/chapter for manga, and at that
    /// pace the same 80 chapters is 3.8 hours — comfortably inside any hour
    /// ceiling, so the stamped import it was written to catch would have
    /// walked straight through. A same-day sprint is judged by chapter count
    /// instead, which the rate correction does not move: a genuine 40-chapter
    /// manhwa afternoon still survives, a stamped 80-chapter import still does
    /// not.
    /// **One ceiling for every span, since 2026-09-14** — see the deleted
    /// `plausibleHoursPerDay` above for what having two of them cost. No test
    /// sat at either boundary, which is why the disagreement survived.
    static let plausibleChaptersPerDay = 60

    /// Fewer chapters than this is not a sprint worth naming. **A guess**:
    /// enough that a one-shot or a short series finished in a sitting does
    /// not become "the fastest read of your life".
    static let minimumSprintChapters = 20

    /// The fastest thing the reader got through, of those with both dates.
    ///
    /// Two things are rejected, and both are the same mistake in different
    /// clothes — treating a date field as though it recorded reading.
    ///
    /// **A oneshot.** One chapter finished the day it was started is
    /// technically the fastest reading anybody has ever done.
    ///
    /// **A backfill.** Found on a real 939-entry library: the first version of
    /// this screen announced "700 chapters a day — NARUTO, 700 chapters in 1
    /// day". Nobody read Naruto in a day. What happened is that a series was
    /// marked completed and its start and finish dates were both set to that
    /// moment, which is what every importer and most bulk edits do. The guard
    /// uses the app's own per-format minutes — themselves a labelled guess —
    /// to ask whether the claim would fit in a waking day, and drops it when
    /// it would not.
    static func fastestFinish(
        in entries: [LibraryEntry],
        calendar: Calendar = utcCalendar,
        minimumChapters: Int = minimumSprintChapters
    ) -> Sprint? {
        entries
            .compactMap { entry -> Sprint? in
                guard let start = entry.startDate, let finish = entry.finishDate else { return nil }
                guard finish >= start else { return nil }
                let chapters = Int(wholeOrClamped: ReadingInsights.chaptersCounted(for: entry))
                guard chapters >= minimumChapters else { return nil }
                let days = calendar.dateComponents([.day], from: start, to: finish).day ?? 0
                let sprint = Sprint(
                    entry: entry, chapters: chapters, days: max(days, 1), isSameDay: days == 0
                )
                guard isPlausible(sprint) else { return nil }
                return sprint
            }
            .max { $0.perDay < $1.perDay }
    }

    /// Whether a sprint could have been read rather than merely recorded.
    ///
    /// A sprint and an import are told apart by nothing but size, whatever
    /// span they claim — so both are judged the same way, by chapters a day.
    /// `Sprint.perDay` already floors the span at one day, so a same-day
    /// sprint is simply the case where `perDay == chapters`.
    static func isPlausible(_ sprint: Sprint) -> Bool {
        sprint.perDay <= plausibleChaptersPerDay
    }

    /// The series the reader has been part-way through the longest.
    ///
    /// The most quietly accurate thing this screen can say about somebody.
    static func longestRunning(in entries: [LibraryEntry]) -> LibraryEntry? {
        entries
            .filter { $0.state == .reading || $0.state == .rereading || $0.state == .paused }
            .filter { $0.finishDate == nil }
            .compactMap { $0.startDate == nil ? nil : $0 }
            .min { ($0.startDate ?? .distantFuture) < ($1.startDate ?? .distantFuture) }
    }

    // MARK: - What it is made of

    /// A share of the library by some grouping — format, decade, origin.
    struct Slice: Identifiable, Equatable, Sendable {
        let label: String
        let count: Int
        var id: String { label }
    }

    /// The formats the reader actually reads, largest first.
    static func formats(in entries: [LibraryEntry]) -> [Slice] {
        tally(readAtAll(entries).compactMap { $0.series?.type?.capitalized })
    }

    // `decades(in:)` (grouped the library by the decade its series were
    // published in) was deleted here (R17/P17-libraryui): it was tested
    // (`ReadingWrappedTests`) but `WrappedView` never built a card from it —
    // either a card was planned and dropped, or it was dead from the start.
    // No Wrapped card exists in the current mockups for "decades", so this
    // is deletion, not a missing presenter; a decade card can be reintroduced
    // from `LibraryEntry.series.year` if a future design asks for one.

    /// The people the reader reads most.
    ///
    /// Authors and artists together, because on a manhwa they are usually
    /// different people and a reader following an artist is following them
    /// just as much.
    static func creators(in entries: [LibraryEntry], limit: Int = 5) -> [Slice] {
        let names = readAtAll(entries).flatMap { entry -> [String] in
            let series = entry.series
            return Array(Set((series?.authors ?? []) + (series?.artists ?? [])))
        }
        return Array(tally(names).filter { $0.count > 1 }.prefix(limit))
    }

    private static func tally(_ values: [String]) -> [Slice] {
        var counts: [String: Int] = [:]
        for value in values where !value.isEmpty { counts[value, default: 0] += 1 }
        return counts
            .map { Slice(label: $0.key, count: $0.value) }
            .sorted { ($0.count, $1.label) > ($1.count, $0.label) }
    }
}
