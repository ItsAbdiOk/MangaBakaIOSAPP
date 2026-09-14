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
        // `Calendar.current`'s zone, not GMT. `NotificationPolicy.confirmedReleases`
        // compares `UpcomingWork.localDay(calendar: .current)` against
        // `Calendar.current.startOfDay(for: now)`, so the fixture day has to be
        // the *local* day of `now + daysFromNow` or the two disagree by one.
        // `now` is 2025-09-04T16:53:20Z; formatted in GMT it reads 09-04, but
        // on a simulator at UTC+7:07 or further east the local day is already
        // 09-05, which makes `daysFromNow: 1` — the "tomorrow it is not, yet"
        // case — land on today and fire. Invisible in Europe/London, a flake
        // for anyone east of there. Fixed 2026-09-14 (review item 133).
        iso.timeZone = Calendar.current.timeZone
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

    private func feed(episode: Int) -> ReleaseFeed {
        let entry = ReleaseEntry(title: "Episode \(episode)", published: now, number: episode, season: nil)
        return ReleaseFeed(title: "Feed", entries: [entry], source: .webtoons)
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
        // Both series must be in a notifiable state now — `library: []` used
        // to be enough, which was the bug (item 34): 1a filtered by date only.
        let library = [
            entry(id: 1, state: .reading, status: "releasing"),
            entry(id: 2, state: .reading, status: "releasing")
        ]

        let planned = NotificationPolicy.decide(announced: [today, tomorrow], library: library, now: now)
        #expect(planned.map(\.id) == ["release-work-a"])
    }

    @Test("A date already past is confirmed too — it came out and was not caught yet")
    func announcedPastDateStillFires() throws {
        let yesterday = try work("y", series: 1, daysFromNow: -1)
        let library = [entry(id: 1, state: .reading, status: "releasing")]
        let planned = NotificationPolicy.decide(announced: [yesterday], library: library, now: now)
        #expect(planned.map(\.id) == ["release-work-y"])
    }

    /// Item 34 / Abdi's Q1 answer (2026-09-14). 1a filtered by date alone, so
    /// the next print volume of a series the reader dropped months ago arrived
    /// as "Vol. 12 · out now" — against this type's own "something they are
    /// waiting for".
    ///
    /// Expected failure before the fix: `planned.map(\.id)` is
    /// `["release-work-d", "release-work-p", "release-work-c"]`, so all four
    /// `#expect`s below fail.
    @Test("A confirmed release only notifies for reading, rereading and paused")
    func confirmedReleaseRespectsLibraryState() throws {
        let library = [
            entry(id: 1, state: .dropped, status: "releasing"),
            entry(id: 2, state: .planToRead, status: "releasing"),
            entry(id: 3, state: .completed, status: "completed"),
            entry(id: 4, state: .rereading, status: "releasing"),
            entry(id: 5, state: .paused, status: "releasing")
        ]
        let announced = [
            try work("d", series: 1, daysFromNow: 0),
            try work("p", series: 2, daysFromNow: 0),
            try work("c", series: 3, daysFromNow: 0),
            try work("r", series: 4, daysFromNow: 0),
            try work("z", series: 5, daysFromNow: 0)
        ]
        let planned = NotificationPolicy.decide(announced: announced, library: library, now: now)
        #expect(planned.map(\.id).sorted() == ["release-work-r", "release-work-z"])
    }

    /// A series MangaBaka announces a release for that is not in the library
    /// at all cannot be in a notifiable state, so it says nothing — there is
    /// no reader intent to infer.
    @Test("An announced work for a series not in the library notifies nothing")
    func announcedOutsideTheLibraryIsSilent() throws {
        let planned = NotificationPolicy.decide(
            announced: [try work("a", series: 99, daysFromNow: 0)], library: [], now: now
        )
        #expect(planned.isEmpty)
    }

    /// Condition 1b, same rule. Expected failure before the fix: `["release-feed-1-11"]`.
    @Test("A newer feed episode for a dropped series notifies nothing")
    func feedEpisodeRespectsLibraryState() {
        let library = [entry(id: 1, state: .dropped, status: "releasing")]
        let planned = NotificationPolicy.decide(
            announced: [], feeds: [1: feed(episode: 11)], library: library, now: now,
            lastKnownEpisode: [1: 10]
        )
        #expect(planned.isEmpty)
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

    // `feedFinishedFlagNeverNotifies` was here. It pinned the deletion of
    // condition 2c by building a feed with `finished: true` and asserting
    // nothing was planned. `ReleaseFeed.finished` itself was deleted on
    // 2026-09-14 — its only populator was Naver's private endpoint — so the
    // test can no longer state its own premise, and the guarantee is now
    // structural: there is no flag to read. See the tombstone in
    // `ReleaseFeedService.swift`. The catalogue-status route below is
    // unaffected and still covered.

    /// The catalogue-status route (2a) is what covers "this series is
    /// finished" now that 2c is gone: an empty result here would mean
    /// completions had broken outright, not merely that 2c was removed.
    @Test("The catalogue status flip still notifies alongside a release feed")
    func catalogueCompletionStillNotifies() {
        let library = [entry(id: 1, state: .reading, status: "completed")]
        let planned = NotificationPolicy.decide(
            announced: [], feeds: [1: feed(episode: 100)], library: library,
            now: now, previousStatus: [1: "releasing"]
        )
        #expect(planned.map(\.id) == ["finished-1"])
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
