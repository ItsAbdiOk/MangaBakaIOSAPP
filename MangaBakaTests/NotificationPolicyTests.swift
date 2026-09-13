import Testing
import Foundation
@testable import MangaBaka

/// The two conditions Abdi asked for (2026-09-13) and nothing else: "release
/// notifications for something that has just come out, confirmed" and "a
/// series they're reading or have paused has either completed or finished the
/// end of a season." Pure over `NotificationPolicy.decide` — pacing (the daily
/// cap, the same-series cooldown) and the persisted dedup ledger are
/// `ReleaseReminders`, covered in `ReminderTests`.
@Suite("Notification policy")
struct NotificationPolicyTests {
    private func work(_ id: String, series: Int, daysFromNow: Int) throws -> UpcomingWork {
        let date = Calendar.current.date(byAdding: .day, value: daysFromNow, to: now) ?? now
        let iso = DateFormatter()
        iso.locale = Locale(identifier: "en_US_POSIX")
        iso.timeZone = TimeZone(secondsFromGMT: 0)
        iso.dateFormat = "yyyy-MM-dd"
        return try JSONDecoder.snakeCased.decode(UpcomingWork.self, from: Data("""
        {"id": "\(id)", "series_id": \(series), "release_date": "\(iso.string(from: date))",
         "sequence_string": "12", "collections": [{"title": "A Series"}]}
        """.utf8))
    }

    private func entry(id: Int, state: LibraryEntry.State, status: String?) -> LibraryEntry {
        LibraryEntry(
            id: id, seriesId: id, state: state, progressChapter: 10,
            progressVolume: nil, rating: nil, note: nil, startDate: nil,
            finishDate: nil, numberOfRereads: nil, priority: nil, isPrivate: nil,
            readLink: nil,
            series: SeriesFactory.make(id: id, title: "S\(id)", status: status)
        )
    }

    private func feed(episode: Int, finished: Bool? = nil) -> ReleaseFeed {
        let entry = ReleaseEntry(title: "Episode \(episode)", published: now, number: episode, season: nil)
        return ReleaseFeed(title: "Feed", entries: [entry], source: .webtoons, finished: finished)
    }

    private let now = Date(timeIntervalSince1970: 1_757_000_000)

    // MARK: - Never a prediction

    /// The old `ReleaseReminders.reschedule(predicted: [ScheduledWork])` used
    /// a `Cadence`'s `due` date to produce a "probably due" notification —
    /// `#expect(centre.added.isEmpty)` would have failed against that code for
    /// any series with a due cadence, because it always added one. `decide`
    /// has no `predicted`/`Cadence`/`ScheduledWork` parameter at all, so there
    /// is no call that can reach that branch; this test stands for the
    /// negative: whatever a cadence might have guessed, nothing here notifies
    /// from it.
    @Test("A cadence prediction has no path into a notification")
    func noPredictionPath() {
        let overdueByAnyCadence = [entry(id: 1, state: .reading, status: "releasing")]
        let planned = NotificationPolicy.decide(announced: [], library: overdueByAnyCadence, now: now)
        #expect(planned.isEmpty)
    }

    // MARK: - Confirmed releases

    @Test("An announced work dated today is confirmed; dated tomorrow it is not, yet")
    func announcedDateGating() throws {
        let today = try work("a", series: 1, daysFromNow: 0)
        let tomorrow = try work("b", series: 2, daysFromNow: 1)

        let planned = NotificationPolicy.decide(announced: [today, tomorrow], library: [], now: now)
        #expect(planned.map(\.id) == ["release-work-a"])
    }

    @Test("A date already past is confirmed too — it came out and was not caught yet")
    func announcedPastDateStillFires() throws {
        let yesterday = try work("y", series: 1, daysFromNow: -1)
        let planned = NotificationPolicy.decide(announced: [yesterday], library: [], now: now)
        #expect(planned.map(\.id) == ["release-work-y"])
    }

    // MARK: - Feed-confirmed episodes

    @Test("A feed entry newer than the last one notified yields one; an older one none")
    func feedEpisodeProgression() {
        let library = [entry(id: 1, state: .reading, status: "releasing")]

        let older = NotificationPolicy.decide(
            announced: [], feeds: [1: feed(episode: 5)], library: library, now: now,
            lastKnownEpisode: [1: 10]
        )
        #expect(older.isEmpty, "5 is not newer than the 10 already known")

        let newer = NotificationPolicy.decide(
            announced: [], feeds: [1: feed(episode: 11)], library: library, now: now,
            lastKnownEpisode: [1: 10]
        )
        #expect(newer.map(\.id) == ["release-feed-1-11"])
    }

    @Test("The first time a feed is seen only sets the baseline, without notifying")
    func feedFirstSightingIsBaselineOnly() {
        // A guess, and a deliberate one: without a prior baseline, a series
        // with twenty existing episodes would otherwise read as twenty new
        // ones the moment its feed is first fetched.
        let library = [entry(id: 1, state: .reading, status: "releasing")]
        let planned = NotificationPolicy.decide(
            announced: [], feeds: [1: feed(episode: 40)], library: library, now: now
        )
        #expect(planned.isEmpty)
    }

    // MARK: - Completed / season ended

    @Test("A status flip to completed for a reading entry yields one notification")
    func statusFlipReading() {
        let library = [entry(id: 1, state: .reading, status: "completed")]
        let planned = NotificationPolicy.decide(
            announced: [], library: library, now: now, previousStatus: [1: "releasing"]
        )
        #expect(planned.map(\.id) == ["finished-1"])
    }

    @Test("A status flip to completed for a dropped entry is never notified")
    func statusFlipDropped() {
        let library = [entry(id: 1, state: .dropped, status: "completed")]
        let planned = NotificationPolicy.decide(
            announced: [], library: library, now: now, previousStatus: [1: "releasing"]
        )
        #expect(planned.isEmpty, "dropping is a decision the reader already made")
    }

    @Test("The first time a series' status is ever seen only records a baseline")
    func statusFirstSightingIsBaselineOnly() {
        let library = [entry(id: 1, state: .reading, status: "completed")]
        let planned = NotificationPolicy.decide(announced: [], library: library, now: now)
        #expect(planned.isEmpty, "no previous status to have flipped from yet")
    }

    @Test("A season ending yields one notification per season, not a repeat of the same season")
    func seasonEndedPerSeason() {
        let library = [entry(id: 1, state: .paused, status: "releasing")]
        let finale = ReleaseEntry(
            title: "Episode 20 (Season 2 Finale)", published: now, number: 20, season: 2
        )
        let ended = ReleaseFeed(title: "Feed", entries: [finale], source: .webtoons)

        let newSeason = NotificationPolicy.decide(
            announced: [], feeds: [1: ended], library: library, now: now, lastKnownSeason: [1: 1]
        )
        #expect(newSeason.map(\.id) == ["season-1-2"])

        let sameSeasonAgain = NotificationPolicy.decide(
            announced: [], feeds: [1: ended], library: library, now: now, lastKnownSeason: [1: 2]
        )
        #expect(sameSeasonAgain.isEmpty, "season 2 was already reported")
    }

    @Test("Naver's finished flag notifies the first time it is seen, not only on a flip")
    func naverFinishedFiresOnFirstSeen() {
        let library = [entry(id: 1, state: .reading, status: "releasing")]
        let finished = feed(episode: 100, finished: true)
        let planned = NotificationPolicy.decide(
            announced: [], feeds: [1: finished], library: library, now: now
        )
        #expect(planned.map(\.id) == ["original-finished-1"])
    }

    @Test("Completed and season-ended are ignored outside reading and paused")
    func onlyReadingAndPausedTracked() {
        let library = [entry(id: 1, state: .planToRead, status: "completed")]
        let planned = NotificationPolicy.decide(
            announced: [], library: library, now: now, previousStatus: [1: "releasing"]
        )
        #expect(planned.isEmpty)
    }
}
