import Foundation

extension ReadingWrapped {
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
        calendar: Calendar = .current
    ) -> Year {
        let dated = entries.filter { $0.finishDate != nil }
        // Not "has a finish date in the year": a dropped series may carry one
        // on some trackers, and the card says *finished*.
        let finished = dated
            .filter { $0.state != .dropped }
            .filter { calendar.component(.year, from: $0.finishDate ?? .distantPast) == year }
            .sorted { ($0.finishDate ?? .distantPast) > ($1.finishDate ?? .distantPast) }
        return Year(
            year: year,
            finished: finished,
            chapters: finished.reduce(0) { $0 + Int(ReadingInsights.chaptersCounted(for: $1)) },
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
        calendar: Calendar = .current
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

        /// Chapters a day, rounded. Never zero: a series finished the day it
        /// was started took one day, not none.
        var perDay: Int { max(1, Int((Double(chapters) / Double(max(days, 1))).rounded())) }
    }

    /// The longest a person could plausibly spend reading in one day.
    ///
    /// **A guess, and the point of it is to catch logging rather than to
    /// model a reader.** Sixteen hours is already an extraordinary day; it is
    /// set high on purpose so that a genuine binge survives and only an
    /// impossible one is rejected.
    static let plausibleHoursPerDay: Double = 16

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
        calendar: Calendar = .current,
        minimumChapters: Int = 20
    ) -> Sprint? {
        entries
            .compactMap { entry -> Sprint? in
                guard let start = entry.startDate, let finish = entry.finishDate else { return nil }
                guard finish >= start else { return nil }
                let chapters = Int(ReadingInsights.chaptersCounted(for: entry))
                guard chapters >= minimumChapters else { return nil }
                let days = calendar.dateComponents([.day], from: start, to: finish).day ?? 0
                let sprint = Sprint(entry: entry, chapters: chapters, days: max(days, 1))
                guard isPlausible(sprint) else { return nil }
                return sprint
            }
            .max { $0.perDay < $1.perDay }
    }

    /// Whether a sprint could have been read rather than merely recorded.
    static func isPlausible(_ sprint: Sprint) -> Bool {
        let minutes = ReadingInsights.minutesPerChapter(sprint.entry.series?.type)
        let hoursPerDay = Double(sprint.perDay) * minutes / 60
        return hoursPerDay <= plausibleHoursPerDay
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

    /// The decades the reader's library comes from, largest first.
    static func decades(in entries: [LibraryEntry]) -> [Slice] {
        tally(readAtAll(entries).compactMap { entry -> String? in
            guard let year = entry.series?.year, year > 1900 else { return nil }
            return "\(year / 10 * 10)s"
        })
        .sorted { $0.label < $1.label }
    }

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
