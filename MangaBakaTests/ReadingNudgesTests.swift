import Testing
import Foundation
@testable import MangaBaka

/// "Back to it": the pure rule over the library, tested with a fixed clock.
/// Scheduling (spacing, the weekly cap, the 30-day repeat block once
/// something has actually fired) is `ReleaseReminders.backToIt`, covered in
/// `ReminderTests`; this suite is only about who is eligible and what the
/// notification says.
@Suite("Back to it")
struct ReadingNudgesTests {
    private func entry(
        id: Int, progress: Double, totalChapters: Double?, state: LibraryEntry.State = .reading,
        startDate: Date? = nil
    ) -> LibraryEntry {
        LibraryEntry(
            id: id, seriesId: id, state: state, progressChapter: progress,
            progressVolume: nil, rating: nil, note: nil, startDate: startDate,
            finishDate: nil, numberOfRereads: nil, priority: nil, isPrivate: nil,
            readLink: nil,
            series: SeriesFactory.make(id: id, title: "Series \(id)", totalChapters: totalChapters)
        )
    }

    private let now = Date(timeIntervalSince1970: 1_757_000_000)

    @Test("Under 21 days since it was last opened is not nudged")
    func belowBoundaryIsSilent() {
        let opened = now.addingTimeInterval(-20 * 86_400)
        let library = [entry(id: 1, progress: 10, totalChapters: 20)]

        let candidates = ReadingNudges.candidates(in: library, now: now, lastOpened: { _ in opened })
        #expect(candidates.isEmpty)
    }

    @Test("Exactly 21 days since it was last opened is nudged")
    func atBoundaryQualifies() {
        let opened = now.addingTimeInterval(-21 * 86_400)
        let library = [entry(id: 1, progress: 10, totalChapters: 20)]

        let candidates = ReadingNudges.candidates(in: library, now: now, lastOpened: { _ in opened })
        #expect(candidates.map(\.seriesID) == [1])
    }

    @Test("No chapter gap means no nudge, however stale it is")
    func noGapNoNudge() {
        let opened = now.addingTimeInterval(-90 * 86_400)
        let library = [entry(id: 1, progress: 20, totalChapters: 20)]

        let candidates = ReadingNudges.candidates(in: library, now: now, lastOpened: { _ in opened })
        #expect(candidates.isEmpty, "nothing new is out, so there is nothing to come back for")
    }

    @Test("A paused series is never nudged, however stale and however far behind")
    func pausedIsExcluded() {
        let opened = now.addingTimeInterval(-90 * 86_400)
        let library = [entry(id: 1, progress: 10, totalChapters: 40, state: .paused)]

        let candidates = ReadingNudges.candidates(in: library, now: now, lastOpened: { _ in opened })
        #expect(candidates.isEmpty, "pausing is a decision the reader already made")
    }

    @Test("No history and no start date means nothing to measure staleness from")
    func nothingToMeasureFrom() {
        let library = [entry(id: 1, progress: 10, totalChapters: 40, startDate: nil)]
        let candidates = ReadingNudges.candidates(in: library, now: now, lastOpened: { _ in nil })
        #expect(candidates.isEmpty, "guessing at staleness would be worse than staying quiet")
    }

    @Test("The entry's own start date stands in when history has nothing")
    func fallsBackToStartDate() {
        let started = now.addingTimeInterval(-40 * 86_400)
        let library = [entry(id: 1, progress: 10, totalChapters: 40, startDate: started)]
        let candidates = ReadingNudges.candidates(in: library, now: now, lastOpened: { _ in nil })
        #expect(candidates.map(\.seriesID) == [1])
    }

    @Test("An injected latest-known chapter can be ahead of the library's own total")
    func latestKnownChapterOverride() {
        let opened = now.addingTimeInterval(-30 * 86_400)
        // The library says the series has only 20 chapters catalogued, but a
        // release feed already knows about 22.
        let library = [entry(id: 1, progress: 20, totalChapters: 20)]
        let candidates = ReadingNudges.candidates(
            in: library, now: now, lastOpened: { _ in opened }, latestKnownChapter: { _ in 22 }
        )
        #expect(candidates.map(\.chaptersWaiting) == [2])
    }

    @Test("Most chapters waiting first")
    func ranksByChaptersWaiting() {
        let opened = now.addingTimeInterval(-30 * 86_400)
        let library = [
            entry(id: 1, progress: 10, totalChapters: 15),
            entry(id: 2, progress: 10, totalChapters: 50)
        ]
        let candidates = ReadingNudges.candidates(in: library, now: now, lastOpened: { _ in opened })
        #expect(candidates.map(\.seriesID) == [2, 1])
    }

    @Test("The sentence says '1 more' for a single chapter, and the count otherwise")
    func sentenceGrammar() {
        let opened = now.addingTimeInterval(-30 * 86_400)
        let one = [entry(id: 1, progress: 10, totalChapters: 11)]
        let many = [entry(id: 2, progress: 10, totalChapters: 18)]

        let oneLine = ReadingNudges.candidates(in: one, now: now, lastOpened: { _ in opened }).first?.line
        let manyLine = ReadingNudges.candidates(in: many, now: now, lastOpened: { _ in opened }).first?.line

        #expect(oneLine == "You left Series 1 at ch. 10 — 1 more is out")
        #expect(manyLine == "You left Series 2 at ch. 10 — 8 more are out")
    }
}

/// The scheduling half of "back to it": spacing, the weekly cap, and the
/// 30-day repeat block, which need a persisted-date dictionary the pure rule
/// does not hold.
@Suite("Back to it scheduling")
struct BackToItSchedulingTests {
    private func entry(id: Int, progress: Double, totalChapters: Double?) -> LibraryEntry {
        LibraryEntry(
            id: id, seriesId: id, state: .reading, progressChapter: progress,
            progressVolume: nil, rating: nil, note: nil, startDate: nil,
            finishDate: nil, numberOfRereads: nil, priority: nil, isPrivate: nil,
            readLink: nil,
            series: SeriesFactory.make(id: id, title: "Series \(id)", totalChapters: totalChapters)
        )
    }

    private let now = Date(timeIntervalSince1970: 1_757_000_000)
    private let opened: (Int) -> Date?

    init() {
        let stale = Date(timeIntervalSince1970: 1_757_000_000).addingTimeInterval(-30 * 86_400)
        opened = { _ in stale }
    }

    @Test("At most three candidates a week, one a day apart")
    func capsAtThreePerWeek() {
        let library = (1...5).map { entry(id: $0, progress: 10, totalChapters: Double(10 + $0)) }
        let requests = ReleaseReminders.backToIt(in: library, now: now, lastOpened: opened)

        #expect(requests.count == ReadingNudges.maxPerWeek)
        let sorted = requests.sorted { $0.date < $1.date }
        for pair in zip(sorted, sorted.dropFirst()) {
            #expect(pair.1.date.timeIntervalSince(pair.0.date) >= 23 * 3_600, "roughly a day apart")
        }
    }

    @Test("Nudged in the last 30 days is not nudged again")
    func repeatBlockHolds() {
        let library = [entry(id: 1, progress: 10, totalChapters: 20)]
        let recentlyFired = now.addingTimeInterval(-1 * 86_400)

        let requests = ReleaseReminders.backToIt(
            in: library, now: now, lastOpened: opened,
            previous: ["backtoit-1": recentlyFired]
        )
        #expect(requests.isEmpty)
    }

    @Test("Once the 30 days have passed, the same series is eligible again")
    func repeatBlockExpires() {
        let library = [entry(id: 1, progress: 10, totalChapters: 20)]
        let firedLongAgo = now.addingTimeInterval(-31 * 86_400)

        let requests = ReleaseReminders.backToIt(
            in: library, now: now, lastOpened: opened,
            previous: ["backtoit-1": firedLongAgo]
        )
        #expect(requests.map(\.id) == ["backtoit-1"])
    }

    @Test("A nudge still pending keeps its date rather than being pushed back")
    func pendingNudgeKeepsItsDate() {
        let library = [entry(id: 1, progress: 10, totalChapters: 20)]
        let stillAhead = now.addingTimeInterval(2 * 3_600)

        let requests = ReleaseReminders.backToIt(
            in: library, now: now, lastOpened: opened,
            previous: ["backtoit-1": stillAhead]
        )
        #expect(requests.first?.date == stillAhead)
    }
}
