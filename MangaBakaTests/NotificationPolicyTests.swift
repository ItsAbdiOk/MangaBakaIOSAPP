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
        let planned = NotificationPolicy.decide(library: overdueByAnyCadence, now: now)
        #expect(planned.isEmpty)
    }

    // MARK: - Releases never notify (2026-09-15)

    /// Abdi, 2026-09-15: "NOTIFICATIONS ONLY FOR FINISHED OR SEASON ENDING
    /// OR SERIES THAT HAVE JUST COME BACK FROM HIATUS." Conditions 1a and 1b
    /// are deleted; these stand for the negative, over the exact inputs that
    /// used to fire them. Each fails on the 2026-09-14 code with the ids
    /// named in its own comment.
    @Test("A publisher-dated release out today notifies nothing, whatever the state")
    func announcedReleaseIsSilent() throws {
        // Used to yield ["release-work-a", "release-work-y"].
        let library = [
            entry(id: 1, state: .reading, status: "releasing"),
            entry(id: 2, state: .paused, status: "releasing")
        ]
        // The two works that used to fire are no longer even an input:
        // `decide` takes no `announced` (review perf R3).
        _ = [try work("a", series: 1, daysFromNow: 0), try work("y", series: 2, daysFromNow: -1)]
        let planned = NotificationPolicy.decide(library: library, now: now)
        #expect(planned.isEmpty)
    }

    @Test("A newer feed episode notifies nothing, whatever the state")
    func feedEpisodeIsSilent() {
        // Used to yield ["release-feed-1-11"].
        let library = [entry(id: 1, state: .reading, status: "releasing")]
        let planned = NotificationPolicy.decide(feeds: [1: feed(episode: 11)], library: library, now: now
        )
        #expect(planned.isEmpty)
    }

    // MARK: - Back from hiatus

    @Test("A status flip from hiatus to releasing for a reading entry yields one notification")
    func backFromHiatus() {
        let library = [entry(id: 1, state: .reading, status: "releasing")]
        let planned = NotificationPolicy.decide(library: library, now: now, previousStatus: [1: "hiatus"]
        )
        #expect(planned.map(\.id) == ["back-1"])
        #expect(planned.first?.title.hasSuffix("is back") == true)
    }

    /// Review perf R1 (2026-09-15): every test above starts the series
    /// already on hiatus. This is the common case — it goes on hiatus after
    /// the app first saw it — and it depends on `ReleaseReminders`
    /// recording the status on every pass; `ReminderTests` pins that end to
    /// end. Here: a baseline of "releasing", then "hiatus", then a return.
    @Test("releasing → hiatus → releasing is one return, given the hiatus was recorded")
    func returnAfterAnObservedHiatus() {
        let library = [entry(id: 1, state: .reading, status: "releasing")]
        let planned = NotificationPolicy.decide(
            library: library, now: now, previousStatus: [1: "on_hiatus"]
        )
        #expect(planned.map(\.id) == ["back-1"], "the API's other spelling counts too (R9)")
    }

    @Test("Hiatus to completed is the finished notification, not a return")
    func hiatusToCompletedIsFinished() {
        let library = [entry(id: 1, state: .reading, status: "completed")]
        let planned = NotificationPolicy.decide(library: library, now: now, previousStatus: [1: "hiatus"]
        )
        #expect(planned.map(\.id) == ["finished-1"])
    }

    @Test("A return is silent for a dropped entry, a still-hiatus series, and a first sighting")
    func backFromHiatusGuards() {
        let dropped = NotificationPolicy.decide(
            library: [entry(id: 1, state: .dropped, status: "releasing")], now: now,
            previousStatus: [1: "hiatus"]
        )
        #expect(dropped.isEmpty)
        let still = NotificationPolicy.decide(
            library: [entry(id: 1, state: .reading, status: "hiatus")], now: now,
            previousStatus: [1: "hiatus"]
        )
        #expect(still.isEmpty)
        let first = NotificationPolicy.decide(
            library: [entry(id: 1, state: .reading, status: "releasing")], now: now
        )
        #expect(first.isEmpty, "no baseline, no claim it was ever on hiatus")
    }

    // MARK: - Completed / season ended

    @Test("A status flip to completed for a reading entry yields one notification")
    func statusFlipReading() {
        let library = [entry(id: 1, state: .reading, status: "completed")]
        let planned = NotificationPolicy.decide(library: library, now: now, previousStatus: [1: "releasing"]
        )
        #expect(planned.map(\.id) == ["finished-1"])
    }

    @Test("A status flip to completed for a dropped entry is never notified")
    func statusFlipDropped() {
        let library = [entry(id: 1, state: .dropped, status: "completed")]
        let planned = NotificationPolicy.decide(library: library, now: now, previousStatus: [1: "releasing"]
        )
        #expect(planned.isEmpty, "dropping is a decision the reader already made")
    }

    @Test("The first time a series' status is ever seen only records a baseline")
    func statusFirstSightingIsBaselineOnly() {
        let library = [entry(id: 1, state: .reading, status: "completed")]
        let planned = NotificationPolicy.decide(library: library, now: now)
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
            feeds: [1: ended], library: library, now: now, lastKnownSeason: [1: 1]
        )
        #expect(newSeason.map(\.id) == ["season-1-2"])

        let sameSeasonAgain = NotificationPolicy.decide(
            feeds: [1: ended], library: library, now: now, lastKnownSeason: [1: 2]
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
        let planned = NotificationPolicy.decide(feeds: [1: feed(episode: 100)], library: library,
            now: now, previousStatus: [1: "releasing"]
        )
        #expect(planned.map(\.id) == ["finished-1"])
    }

    @Test("Completed and season-ended are ignored outside reading and paused")
    func onlyReadingAndPausedTracked() {
        let library = [entry(id: 1, state: .planToRead, status: "completed")]
        let planned = NotificationPolicy.decide(library: library, now: now, previousStatus: [1: "releasing"]
        )
        #expect(planned.isEmpty)
    }
}
