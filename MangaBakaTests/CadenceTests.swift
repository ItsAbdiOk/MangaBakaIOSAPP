import Foundation
import Testing
@testable import MangaBaka

/// The estimate is the whole feature, so it is tested as arithmetic rather than
/// through the network.
@Suite("Cadence estimate")
struct CadenceTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }()

    /// Days before a fixed reference date, newest first.
    private func dates(
        daysAgo: [Int],
        from reference: Date = Date(timeIntervalSince1970: 1_756_000_000)
    ) -> [Date] {
        daysAgo.map { reference.addingTimeInterval(-Double($0) * 86_400) }
    }

    @Test("A weekly series reads as weekly, and confidently")
    func weeklySeries() throws {
        let cadence = try #require(
            Cadence.estimate(from: dates(daysAgo: [0, 7, 14, 21, 28]), calendar: calendar)
        )
        #expect(cadence.medianGapDays == 7)
        #expect(cadence.spreadDays == 0)
        #expect(cadence.isRegular)
        #expect(cadence.confidence == .likely)
        #expect(cadence.samples == 5)
    }

    /// A day either side of weekly is still weekly. The tolerance is a quarter
    /// of the median, floored at a day.
    @Test("A nearly-weekly series is still confident")
    func nearlyWeekly() throws {
        let cadence = try #require(
            Cadence.estimate(from: dates(daysAgo: [0, 7, 15, 21, 29]), calendar: calendar)
        )
        #expect(cadence.isRegular)
    }

    @Test("An erratic series is estimated, but loosely")
    func erraticSeries() throws {
        let cadence = try #require(
            Cadence.estimate(from: dates(daysAgo: [0, 3, 40, 44, 120]), calendar: calendar)
        )
        #expect(!cadence.isRegular)
        #expect(cadence.confidence == .loose)
    }

    /// The reason the median is used rather than the mean. A series that ran
    /// weekly and then paused for eight months has a mean describing neither
    /// state.
    @Test("A long hiatus does not drag the rhythm")
    func medianSurvivesAHiatus() throws {
        // Weekly for five releases, then an eight-month gap.
        let cadence = try #require(
            Cadence.estimate(from: dates(daysAgo: [0, 7, 14, 21, 28, 268]), calendar: calendar)
        )
        #expect(cadence.medianGapDays == 7, "the median should still describe the weekly rhythm")
        // The mean of those gaps is 53 days, which describes nothing.
    }

    @Test("Too little history produces no estimate at all")
    func refusesToGuess() {
        #expect(Cadence.estimate(from: dates(daysAgo: [0, 7, 14]), calendar: calendar) == nil)
        #expect(Cadence.estimate(from: [], calendar: calendar) == nil)
    }

    /// Several chapters shipped the same day is one release event, not several.
    /// Counting them separately would create zero-length gaps and drag the
    /// median towards zero.
    @Test("Same-day releases count once")
    func deduplicatesSameDay() throws {
        let cadence = try #require(
            Cadence.estimate(
                from: dates(daysAgo: [0, 0, 0, 7, 14, 21, 28]),
                calendar: calendar
            )
        )
        #expect(cadence.samples == 5)
        #expect(cadence.medianGapDays == 7)
    }

    /// The bug this prevents is the worst kind: maximum confidence, wrong
    /// answer. A series that ships two or three chapters across consecutive
    /// days and then waits a week has mostly one-day gaps, so a per-day median
    /// reads "1 day" with a spread of 0 — a daily schedule, reported as
    /// certain.
    ///
    /// Measured on real data 2026-09-09: "Best Devil Housekeeper" read as
    /// "1 day, likely" per-day and "7 days, likely" per-session, which is what
    /// it actually does.
    @Test("Chapters bunched across consecutive days read as one weekly session")
    func clustersConsecutiveDays() throws {
        // Three weeks of "two chapters, then wait a week".
        let bunched = [0, 1, 7, 8, 14, 15, 21, 22, 28, 29]
        let cadence = try #require(
            Cadence.estimate(from: dates(daysAgo: bunched), calendar: calendar)
        )
        #expect(cadence.medianGapDays == 7, "the rhythm is weekly, not daily")
        #expect(cadence.isRegular)
    }

    /// The fallback. Clustering a genuinely daily series would collapse it to a
    /// single session and produce no estimate at all, which is worse than the
    /// bug it prevents.
    @Test("A genuinely daily series still gets a daily estimate")
    func trulyDailySeriesSurvives() throws {
        let cadence = try #require(
            Cadence.estimate(from: dates(daysAgo: [0, 1, 2, 3, 4, 5, 6]), calendar: calendar)
        )
        #expect(cadence.medianGapDays == 1)
    }

    /// A session that runs two days must not shorten the gap that follows it.
    @Test("The gap is measured from when a session began")
    func gapMeasuredFromSessionStart() throws {
        let cadence = try #require(
            Cadence.estimate(from: dates(daysAgo: [0, 1, 10, 11, 20, 21, 30, 31]), calendar: calendar)
        )
        #expect(cadence.medianGapDays == 10)
    }

    // MARK: - Confidence and state are orthogonal

    /// This pairing is the bug the reference implementation shipped: one field
    /// that could be "overdue" produced "LIKELY - expected 6 days ago", a
    /// healthy green pill on a late chapter. A very regular series can be very
    /// late, and that combination is the most informative thing on the card.
    @Test("A regular series that is late stays 'likely' and reads 'late'")
    func regularAndLate() throws {
        let reference = Date(timeIntervalSince1970: 1_756_000_000)
        let cadence = try #require(
            Cadence.estimate(from: dates(daysAgo: [0, 7, 14, 21, 28], from: reference),
                             calendar: calendar)
        )
        // Thirty days after the last release: a weekly series is three weeks late.
        let now = reference.addingTimeInterval(30 * 86_400)

        #expect(cadence.confidence == .likely, "the rhythm is still regular")
        #expect(cadence.state(asOf: now, calendar: calendar) == .late)
        #expect(cadence.overdueDays(asOf: now, calendar: calendar) == 23)
    }

    /// Everything clock-derived is computed on read. Storing it means an
    /// estimate measured an hour ago still claims the lateness it had then —
    /// which is how a reference build reported "past due: 0" while 45 dates sat
    /// in the past.
    @Test("Lateness is recomputed against now, not baked in")
    func latenessIsRecomputed() throws {
        let reference = Date(timeIntervalSince1970: 1_756_000_000)
        let cadence = try #require(
            Cadence.estimate(from: dates(daysAgo: [0, 7, 14, 21], from: reference),
                             calendar: calendar)
        )

        // On the due date it is not late.
        #expect(cadence.state(asOf: cadence.due, calendar: calendar) == .due)
        // A year later, the same stored estimate is very late.
        let later = cadence.due.addingTimeInterval(365 * 86_400)
        #expect(cadence.state(asOf: later, calendar: calendar) == .late)
        #expect(cadence.overdueDays(asOf: later, calendar: calendar) == 365)
    }

    @Test("A cadence survives the cache round trip")
    func codableRoundTrip() throws {
        let original = try #require(
            Cadence.estimate(from: dates(daysAgo: [0, 7, 14, 21, 28]), calendar: calendar)
        )
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(Cadence.self, from: data) == original)
    }
}

/// The id conversion, which fails silently and expensively when wrong.
@Suite("MangaUpdates id")
struct MangaUpdatesIDTests {
    /// The real value MangaBaka publishes for series 2 (Shingetsutan Tsukihime),
    /// and the number their API answers to. Verified live 2026-09-09.
    @Test("A base-36 id decodes to the number the API expects")
    func decodesRealID() {
        #expect(MangaUpdatesID.number(from: "7s905mh") == 16_945_653_113)
        #expect(MangaUpdatesID.number(from: "n50wl4o") == 50_369_844_984)
    }

    /// The API returns ids as strings on some trackers and numbers on others.
    /// An all-digit id is already the number — and this is checked before the
    /// base-36 decode, because "12345" is also valid base-36 and would decode
    /// to 1,776,965, a completely different series.
    @Test("An all-digit id is taken as a number, not decoded as base 36")
    func numericIDPassesThrough() {
        #expect(MangaUpdatesID.number(from: "12345") == 12_345)
        #expect(MangaUpdatesID.number(from: "12345") != 1_776_965)
    }

    @Test("Case and whitespace do not change the answer")
    func normalises() {
        #expect(MangaUpdatesID.number(from: " 7S905MH ") == 16_945_653_113)
    }

    /// Guessing would send a malformed search, and a malformed search on this
    /// API returns wrong data rather than an error.
    @Test("An id that is not base 36 is refused rather than guessed at")
    func refusesNonsense() {
        #expect(MangaUpdatesID.number(from: "") == nil)
        #expect(MangaUpdatesID.number(from: "not-an-id") == nil)
        #expect(MangaUpdatesID.number(from: "7s905mh!") == nil)
    }
}
