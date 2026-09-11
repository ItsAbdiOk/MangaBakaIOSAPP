import Foundation

/// When the next chapter of a series is likely due, inferred from how often it
/// has actually shipped.
///
/// **This is an estimate, and the type is shaped so a caller cannot forget
/// that.** No source publishes real manga release schedules. Every date here is
/// derived from the median gap between past scanlation releases, and carries a
/// confidence earned from how regular that gap has been. The UI must say
/// "likely" or "loose", never print a bare date as though it were fact.
struct Cadence: Equatable, Sendable, Codable {
    /// The typical gap between releases, in days.
    let medianGapDays: Int
    /// Median absolute deviation of the gaps. Small means a real schedule.
    let spreadDays: Int
    let lastRelease: Date
    /// `lastRelease` plus the median gap.
    let due: Date
    /// How many distinct release *days* were seen. Not releases: three
    /// chapters on one Saturday are one day here. Not what the median was
    /// taken over either — that is `gaps`.
    let samples: Int
    /// How many gaps the median was actually taken over. Nil on a row cached
    /// by a build before this existed; the screen then says "release days".
    var gaps: Int?

    /// Which season the series is currently releasing, where it has seasons.
    ///
    /// MangaUpdates tags a webtoon's releases with a volume number that is
    /// really the season — Tower of God's latest are `v.3 c.235`. It does not
    /// say which it means, so this is only set where the release history shows
    /// chapters restarting. See `SeasonReading`.
    var season: Int?

    /// How much to trust the rhythm. Derived from spread, never from the clock.
    enum Confidence: String, Equatable, Sendable, Codable {
        case likely
        case loose
    }

    /// Where the estimate sits relative to now. Derived from the clock, never
    /// from the spread.
    enum State: String, Equatable, Sendable, Codable {
        case due
        case late
    }

    /// Whether the gaps were tight enough to call the schedule real.
    ///
    /// Separate from `state`, and conflating the two is a bug that has already
    /// shipped once elsewhere: a single field that could be "overdue" produced
    /// "LIKELY - expected 6 days ago", a healthy green pill on a late chapter.
    /// They are orthogonal. A very regular series can still be late, and that
    /// combination is the most informative thing the card can say.
    var confidence: Confidence { isRegular ? .likely : .loose }

    let isRegular: Bool

    /// Everything below is clock-derived, so it is computed on read rather than
    /// stored. An estimate measured an hour ago must not still claim the
    /// lateness it had then.
    func state(asOf now: Date, calendar: Calendar = .current) -> State {
        overdueDays(asOf: now, calendar: calendar) > 0 ? .late : .due
    }

    func overdueDays(asOf now: Date, calendar: Calendar = .current) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: due),
                                to: calendar.startOfDay(for: now)).day ?? 0
    }

    // MARK: - The estimate

    /// Minimum distinct release dates before an estimate is attempted.
    static let minimumDates = 4
    /// Minimum positive gaps between those dates.
    static let minimumGaps = 3

    /// Builds a cadence from release dates, or returns nil when there is not
    /// enough history to say anything honest.
    ///
    /// - Parameter dates: release dates in any order; duplicates are expected
    ///   and removed, because a series can ship several chapters the same day
    ///   and that is one release event, not several.
    static func estimate(
        from dates: [Date],
        calendar: Calendar = .current
    ) -> Cadence? {
        // Distinct days, newest first.
        let days = Set(dates.map { calendar.startOfDay(for: $0) })
            .sorted(by: >)
        guard days.count >= minimumDates else { return nil }

        // Group consecutive days into one release session before measuring.
        //
        // Plenty of series ship two or three chapters across consecutive days
        // and then wait a week. Measuring every day as its own tick makes most
        // of the gaps one day, which drags the median to 1 AND the spread to 0
        // — the worst possible pairing, because it reports a daily schedule
        // with maximum confidence.
        //
        // Measured on real data (2026-09-09): "Best Devil Housekeeper" and
        // "Hwasan Gwihwan" both read as "1 day, likely" per-day, and as
        // "7 days, likely" per-session, which is what they actually do. It
        // sharpens honest cases too — Omniscient Reader went from 6 days with
        // a spread of 1 to exactly 7 with a spread of 0.
        let sessionStarts = Self.sessionStarts(from: days, calendar: calendar)

        // A genuinely daily series collapses into a single session, which would
        // leave nothing to measure. Fall back to raw days rather than refuse to
        // estimate something that really does ship every day.
        //
        // Only for that case. The fallback used to take anything under the
        // minimum, so three bursts of four consecutive days — three sessions —
        // were measured as twelve days with nine one-day gaps: "every 1 day,
        // exactly", the pathology the session grouping exists to prevent. Two
        // or three sessions is too little history, and refusing is the answer.
        let measured: [Date]
        if sessionStarts.count >= minimumDates {
            measured = sessionStarts
        } else if sessionStarts.count == 1 {
            measured = days
        } else {
            return nil
        }

        let gaps: [Int] = zip(measured, measured.dropFirst()).compactMap { newer, older in
            let days = calendar.dateComponents([.day], from: older, to: newer).day ?? 0
            // Zero-length gaps cannot happen after the de-duplication above, but
            // a negative one would mean the sort was wrong; drop rather than
            // let it drag the median.
            return days > 0 ? days : nil
        }
        // `last` is the most recent actual release, not the most recent session
        // start: the reader wants the next chapter counted from the last one
        // they got.
        guard gaps.count >= minimumGaps, let last = days.first else { return nil }

        // Median, not mean. A series that ran weekly for a year and then paused
        // for eight months has a mean describing neither state; the median
        // survives the outlier and keeps describing the rhythm.
        let median = Self.median(of: gaps.map(Double.init))
        let spread = Self.median(of: gaps.map { abs(Double($0) - median) })

        // A quarter of the median, floored at a day so a daily series is not
        // held to an impossible standard.
        let isRegular = spread <= max(1.0, median * 0.25)

        guard let due = calendar.date(byAdding: .day, value: Int(median.rounded()), to: last)
        else { return nil }

        return Cadence(
            medianGapDays: Int(median.rounded()),
            spreadDays: Int(spread.rounded()),
            lastRelease: last,
            due: due,
            samples: days.count,
            gaps: gaps.count,
            isRegular: isRegular
        )
    }

    /// The oldest day of each run of consecutive days, newest run first.
    ///
    /// A run is one release session. Taking its oldest day means the gap
    /// between sessions is measured from when the session began, so a two-day
    /// session does not shorten the gap that follows it.
    private static func sessionStarts(from days: [Date], calendar: Calendar) -> [Date] {
        var starts: [Date] = []
        for (index, day) in days.enumerated() {
            let isEndOfRun: Bool
            if index == days.count - 1 {
                isEndOfRun = true
            } else {
                let gap = calendar.dateComponents([.day], from: days[index + 1], to: day).day ?? 0
                isEndOfRun = gap > 1
            }
            if isEndOfRun { starts.append(day) }
        }
        return starts
    }

    private static func median(of values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }
}
