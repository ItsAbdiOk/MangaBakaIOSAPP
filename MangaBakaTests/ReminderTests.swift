import Testing
import Foundation
import UserNotifications
@testable import MangaBaka

/// Release reminders: local only, asked for rather than assumed, and limited
/// to the two conditions Abdi asked for (2026-09-13) — "release notifications
/// for something that has just come out, confirmed" and "a series they're
/// reading or have paused has either completed or finished the end of a
/// season." What counts as either condition is `NotificationPolicyTests`;
/// this suite covers permission handling and the pacing/dedup this type adds
/// on top: the daily cap, the same-series cooldown, and the persisted ledger
/// that survives a relaunch.
@Suite("Release reminders")
@MainActor
struct ReminderTests {
    @Test("Nothing is scheduled until the reader asks")
    func offByDefault() async throws {
        let centre = FakeCentre()
        let reminders = ReleaseReminders(defaults: try defaults(), centre: centre)
        #expect(!reminders.isEnabled)

        // A series that has completed — a fact that would fire were the
        // switch on — still notifies nothing while it is off.
        await reminders.reschedule(library: [entry(id: 1, status: "completed")])
        #expect(centre.added.isEmpty, "a notification nobody asked for is the worst kind")
    }

    @Test("A refusal leaves the switch off rather than on with nothing behind it")
    func refusalIsHonest() async throws {
        let centre = FakeCentre()
        centre.grants = false
        let reminders = ReleaseReminders(defaults: try defaults(), centre: centre)

        let granted = await reminders.enable()
        #expect(!granted)
        #expect(!reminders.isEnabled)
    }

    @Test("A denied system permission overrides an enabled switch")
    func deniedSystemPermissionOverridesTheSwitch() async throws {
        let centre = FakeCentre()
        let reminders = ReleaseReminders(defaults: try defaults(), centre: centre)

        _ = await reminders.enable()
        #expect(reminders.isEnabled)
        #expect(reminders.effectiveEnabled)

        centre.grants = false
        await reminders.refreshStatus()

        #expect(reminders.isEnabled, "the reader's own ask has not changed")
        #expect(!reminders.effectiveEnabled, "but iOS will not deliver anything")
    }

    @Test("A series back from hiatus notifies once; asking again does not repeat it")
    func backFromHiatusNotifiesOnce() async throws {
        let centre = FakeCentre()
        let reminders = ReleaseReminders(defaults: try defaults(), centre: centre)
        await reminders.enable()

        // First sighting: only a baseline (hiatus) is recorded.
        await reminders.reschedule(library: [entry(id: 1, status: "hiatus")])
        #expect(centre.added.isEmpty, "control: first sighting only baselines")

        await reminders.reschedule(library: [entry(id: 1, status: "releasing")])
        #expect(centre.added.map(\.id) == ["back-1"])

        await reminders.reschedule(library: [entry(id: 1, status: "releasing")])
        #expect(centre.added.map(\.id) == ["back-1"], "the same return from hiatus is not repeated")
    }

    @Test("An unreadable or incomplete library read schedules nothing this pass")
    func failedOrIncompleteReadSchedulesNothing() async throws {
        let centre = FakeCentre()
        let reminders = ReleaseReminders(defaults: try defaults(), centre: centre)
        await reminders.enable()

        await reminders.reschedule(libraryFailure: .offline)
        #expect(centre.added.isEmpty)

        await reminders.reschedule(library: [reading(1)], isComplete: false)
        #expect(centre.added.isEmpty)
    }

    /// Review perf R1 (2026-09-15). Fails on the old code with
    /// `centre.added.isEmpty`: the baseline advanced only on a `finished-`
    /// send, so pass two never recorded "hiatus" and pass three saw
    /// `previous == "releasing"`.
    @Test("A series that goes on hiatus after first sighting is told when it comes back")
    func returnAfterObservedHiatus() async throws {
        let centre = FakeCentre()
        let reminders = ReleaseReminders(defaults: try defaults(), centre: centre)
        await reminders.enable()
        await reminders.reschedule(library: [entry(id: 7, status: "releasing")])
        await reminders.reschedule(library: [entry(id: 7, status: "hiatus")])
        #expect(centre.added.isEmpty, "going on hiatus is not news")
        await reminders.reschedule(library: [entry(id: 7, status: "releasing")])
        #expect(centre.added.map(\.id) == ["back-7"])
        // R2: a sent return advances the baseline, so it is not repeated.
        await reminders.reschedule(library: [entry(id: 7, status: "releasing")])
        #expect(centre.added.map(\.id) == ["back-7"])
    }

    @Test("A completed series is told once, and not told again next time")
    func completedSeriesNotifiedOnce() async throws {
        let centre = FakeCentre()
        let reminders = ReleaseReminders(defaults: try defaults(), centre: centre)
        await reminders.enable()
        let library = [entry(id: 7, status: "releasing")]

        // First sighting: only a baseline is recorded, per `NotificationPolicy`.
        await reminders.reschedule(library: library)
        #expect(centre.added.isEmpty)

        // The status flips to completed.
        await reminders.reschedule(library: [entry(id: 7, status: "completed")])
        #expect(centre.added.map(\.id) == ["finished-7"])

        // Asked again with the same completed status: not repeated.
        await reminders.reschedule(library: [entry(id: 7, status: "completed")])
        #expect(centre.added.map(\.id) == ["finished-7"], "told once, not on every subsequent check")
    }

    @Test("At most three notifications a day; the fourth waits for tomorrow morning")
    func dailyCapDefersTheFourth() async throws {
        let clock = TestClock()
        let centre = FakeCentre()
        let reminders = ReleaseReminders(defaults: try defaults(), centre: centre, now: { clock.now })
        await reminders.enable()

        // Baseline: four series, all hiatus, so their return below is news.
        await reminders.reschedule(library: (1...4).map { entry(id: $0, status: "hiatus") })
        #expect(centre.added.isEmpty, "control: baseline pass fires nothing")

        await reminders.reschedule(library: (1...4).map { entry(id: $0, status: "releasing") })

        #expect(centre.added.count == 4, "all four are scheduled, just not all for today")
        let today = centre.added.filter { $0.date <= clock.now }
        let deferred = centre.added.filter { $0.date > clock.now }
        #expect(today.count == ReleaseReminders.dailyLimit)
        #expect(deferred.count == 1)
        let calendar = Calendar.current
        #expect(calendar.component(.hour, from: try #require(deferred.first?.date)) == 9)
        #expect(!calendar.isDate(try #require(deferred.first?.date), inSameDayAs: clock.now))
    }

    /// **Item 10 — the cap is the point of this whole feature.** `sentToday`
    /// was a local starting at zero on every pass, so the daily allowance was
    /// per-call, not per-day: a launch refresh plus one Settings toggle sent
    /// six, and a relaunch bought three more. The persisted `fired` ledger is
    /// now what the count is derived from, so it survives both.
    ///
    /// Expected failure before the fix: `centre.added.filter { today }.count`
    /// is 6, not 3 — three from the first pass and three more from the second,
    /// because nothing carried the first pass's count into the second.
    @Test("Three a day is three a day across repeated passes in one session")
    func dailyCapHoldsAcrossPasses() async throws {
        let clock = TestClock()
        let centre = FakeCentre()
        let store = try defaults()
        let reminders = ReleaseReminders(defaults: store, centre: centre, now: { clock.now })
        await reminders.enable()

        // Baseline: six series, all hiatus, so their return is news below.
        await reminders.reschedule(library: (1...6).map { entry(id: $0, status: "hiatus") })
        #expect(centre.added.isEmpty, "control: baseline pass fires nothing")

        // Six distinct series, all back from hiatus today, asked about in two
        // passes an hour apart — the shape of "the app launched, then the
        // reader toggled the switch".
        await reminders.reschedule(library: (1...3).map { entry(id: $0, status: "releasing") })
        clock.advance(by: 60 * 60)
        await reminders.reschedule(library: (4...6).map { entry(id: $0, status: "releasing") })

        let sentToday = centre.added.filter { Calendar.current.isDate($0.date, inSameDayAs: clock.now) }
        #expect(sentToday.count == ReleaseReminders.dailyLimit, "the cap is per day, not per call")
        #expect(centre.added.count == 6, "the other three are deferred, not dropped")
    }

    /// The same guarantee across a relaunch: a second `ReleaseReminders` over
    /// the same `UserDefaults` is what a cold launch actually looks like.
    ///
    /// Expected failure before the fix: `sentToday.count` is 6.
    @Test("Three a day is three a day across a relaunch")
    func dailyCapHoldsAcrossRelaunch() async throws {
        let clock = TestClock()
        let centre = FakeCentre()
        let store = try defaults()
        let first = ReleaseReminders(defaults: store, centre: centre, now: { clock.now })
        await first.enable()
        await first.reschedule(library: (1...6).map { entry(id: $0, status: "hiatus") })
        await first.reschedule(library: (1...3).map { entry(id: $0, status: "releasing") })

        let relaunched = ReleaseReminders(defaults: store, centre: centre, now: { clock.now })
        #expect(relaunched.isEnabled, "control: the switch survived the relaunch")
        await relaunched.reschedule(library: (4...6).map { entry(id: $0, status: "releasing") }
        )

        let sentToday = centre.added.filter { Calendar.current.isDate($0.date, inSameDayAs: clock.now) }
        #expect(sentToday.count == ReleaseReminders.dailyLimit)
    }

    /// Overflow used to be re-dated to tomorrow 09:00 unconditionally, with
    /// nothing counting that day either — so seven candidates put four on one
    /// morning, which is the lock screen reading as spam that the cap exists
    /// to prevent.
    ///
    /// Expected failure before the fix: every one of the four deferred
    /// requests carries the same date, so `Set(deferred.map(\.date)).count`
    /// is 1 rather than 2.
    @Test("Overflow walks forward day by day; no day exceeds the cap")
    func overflowRespectsTheCapOnLaterDaysToo() async throws {
        let clock = TestClock()
        let centre = FakeCentre()
        let reminders = ReleaseReminders(defaults: try defaults(), centre: centre, now: { clock.now })
        await reminders.enable()

        // Baseline: seven series, all hiatus, so their return is news below.
        await reminders.reschedule(library: (1...7).map { entry(id: $0, status: "hiatus") })
        #expect(centre.added.isEmpty, "control: baseline pass fires nothing")

        await reminders.reschedule(library: (1...7).map { entry(id: $0, status: "releasing") })

        let calendar = Calendar.current
        var perDay: [Date: Int] = [:]
        for request in centre.added {
            perDay[calendar.startOfDay(for: request.date), default: 0] += 1
        }
        #expect(centre.added.count == 7)
        #expect(perDay.values.allSatisfy { $0 <= ReleaseReminders.dailyLimit },
                "three today, three tomorrow, one the day after")
        #expect(perDay.count == 3)
    }

    /// Gap 35. `effectiveEnabled` consults `systemStatus`, which is
    /// `.notDetermined` until something calls `refreshStatus()` — and its only
    /// caller was the Settings section's `.task`. A reader who revoked
    /// permission in iOS Settings therefore had every `add` dropped by iOS
    /// while `fired` recorded the ids as sent, so re-granting would never
    /// bring the missed ones back.
    ///
    /// Expected failure before the fix: `centre.added` is non-empty on the
    /// first pass (the request is made and silently dropped by iOS), and the
    /// second pass then adds nothing because `fired` already has the id.
    @Test("A permission revoked in iOS Settings is noticed before anything is recorded as sent")
    func revokedPermissionIsSeenBeforeScheduling() async throws {
        let centre = FakeCentre()
        let store = try defaults()
        let reminders = ReleaseReminders(defaults: store, centre: centre)
        await reminders.enable()
        #expect(reminders.effectiveEnabled, "control: it is on and allowed")

        // Baseline, while still granted: series 1 seen releasing.
        await reminders.reschedule(library: [entry(id: 1, status: "releasing")])
        #expect(centre.added.isEmpty, "control: first sighting only baselines")

        // The reader turns notifications off in iOS Settings. Nothing tells
        // the app; the next status read is the only way to find out.
        centre.grants = false
        await reminders.reschedule(library: [entry(id: 1, status: "completed")])
        #expect(centre.added.isEmpty, "nothing is scheduled, and nothing is recorded as fired")

        // Re-granted: the completion the reader never heard about still arrives.
        centre.grants = true
        await reminders.reschedule(library: [entry(id: 1, status: "completed")])
        #expect(centre.added.map(\.id) == ["finished-1"])
    }

    @Test("Two events for the same series within 24 hours: only the first is sent")
    func sameSeriesCooldownHolds() async throws {
        let clock = TestClock()
        let centre = FakeCentre()
        let reminders = ReleaseReminders(defaults: try defaults(), centre: centre, now: { clock.now })
        await reminders.enable()

        // Baseline: series 1 seen hiatus, season 1 already known.
        await reminders.reschedule(library: [entry(id: 1, status: "hiatus")],
            feeds: [1: feed(season: 1, publishedAt: clock.now)]
        )
        #expect(centre.added.isEmpty, "control: baseline pass fires nothing")

        // Series 1's feed reports season 2 has ended today.
        await reminders.reschedule(library: [entry(id: 1, status: "hiatus")],
            feeds: [1: feed(season: 2, publishedAt: clock.now)]
        )
        #expect(centre.added.map(\.id) == ["season-1-2"])

        // One hour later, series 1 also comes back from hiatus — a different
        // fact about the same series, but Abdi's fatigue guard allows only
        // one notification per series a day.
        clock.advance(by: 60 * 60)
        await reminders.reschedule(library: [entry(id: 1, status: "releasing")],
            feeds: [1: feed(season: 2, publishedAt: clock.now)]
        )
        #expect(centre.added.map(\.id) == ["season-1-2"], "series 1 already had its notification today")

        clock.advance(by: 25 * 60 * 60) // now past the 24h cooldown
        await reminders.reschedule(library: [entry(id: 1, status: "releasing")],
            feeds: [1: feed(season: 2, publishedAt: clock.now)]
        )
        #expect(centre.added.map(\.id) == ["season-1-2", "back-1"])
    }

    @Test("forget() clears the ledger, so a new account's own flip can still notify")
    func forgetClearsTheLedger() async throws {
        let centre = FakeCentre()
        let reminders = ReleaseReminders(defaults: try defaults(), centre: centre)
        await reminders.enable()

        // Account A: series 7 flips to completed and is told once.
        await reminders.reschedule(library: [entry(id: 7, status: "releasing")])
        await reminders.reschedule(library: [entry(id: 7, status: "completed")])
        #expect(centre.added.map(\.id) == ["finished-7"], "control: it has already fired once")

        await reminders.forget()
        #expect(centre.added.isEmpty, "forget() cancels what was pending too")

        // Account B has an unrelated series 7 that only shares the id. If
        // `forget()` left account A's "completed" baseline in place, account
        // B's own releasing → completed flip below would read as "no change"
        // and never notify — the bug this test is for.
        await reminders.reschedule(library: [entry(id: 7, status: "releasing")])
        #expect(centre.added.isEmpty, "first sighting after forget only baselines")

        await reminders.reschedule(library: [entry(id: 7, status: "completed")])
        #expect(centre.added.map(\.id) == ["finished-7"], "account B's own flip notifies independently")
    }

    @Test("Turning it off cancels what was pending")
    func disableClears() async throws {
        let centre = FakeCentre()
        let reminders = ReleaseReminders(defaults: try defaults(), centre: centre)
        await reminders.enable()
        await reminders.reschedule(library: [reading(1)])

        await reminders.disable()
        #expect(!reminders.isEnabled)
        #expect(centre.removeAllCount >= 1)
    }

}

/// Fixtures and the fake notification centre, in an extension so the suite
/// body itself stays inside SwiftLint's 250-line limit.
extension ReminderTests {
    private func defaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "reminders.tests.\(UUID().uuidString)"))
    }

    private func entry(
        id: Int, state: LibraryEntry.State = .reading, status: String? = "completed"
    ) -> LibraryEntry {
        LibraryEntry(
            id: id, seriesId: id, state: state, progressChapter: 10,
            progressVolume: nil, rating: nil, note: nil, startDate: nil,
            finishDate: nil, numberOfRereads: nil, priority: nil, isPrivate: nil,
            readLink: nil,
            series: SeriesFactory.make(id: id, title: "S\(id)", status: status)
        )
    }

    /// A library entry in a state the reader is actually waiting on. Since
    /// item 34 (Abdi's Q1, 2026-09-14) conditions 1a/1b consult library state,
    /// so an `announced:` work with no matching entry notifies nothing — every
    /// test here that expects a release to fire has to say who is reading it.
    private func reading(_ id: Int) -> LibraryEntry {
        entry(id: id, state: .reading, status: "releasing")
    }

    /// A one-entry feed whose finale marks a season ended — the same shape
    /// `NotificationPolicyTests` uses to test condition 2b directly.
    private func feed(season: Int, publishedAt: Date) -> ReleaseFeed {
        let finale = ReleaseEntry(
            title: "Episode \(season * 10) (Season \(season) Finale)",
            published: publishedAt, number: season * 10, season: season
        )
        return ReleaseFeed(title: "Feed", entries: [finale], source: .webtoons)
    }

    private final class FakeCentre: NotificationScheduling, @unchecked Sendable {
        var grants = true
        var added: [ReminderRequest] = []
        var removeAllCount = 0

        func authorizationStatus() async -> UNAuthorizationStatus {
            grants ? .authorized : .denied
        }
        func requestAuthorization() async -> Bool { grants }
        func add(_ request: ReminderRequest) async { added.append(request) }
        func removeAll() async {
            removeAllCount += 1
            added = []
        }
    }
}

/// When a reminder actually goes off. Nine in the morning, local time, on the
/// day — except that a trigger already in the past is refused by iOS, and the
/// refusal was hidden behind `try?`, so a chapter due at three this afternoon
/// was scheduled for nine this morning and never arrived.
@Suite("Reminder trigger time")
struct ReminderTriggerTests {
    private let calendar = Calendar(identifier: .gregorian)

    private func date(_ hour: Int, dayOffset: Int = 0, from now: Date) -> Date {
        var day = calendar.startOfDay(for: now)
        day = calendar.date(byAdding: .day, value: dayOffset, to: day) ?? day
        return calendar.date(byAdding: .hour, value: hour, to: day) ?? day
    }

    @Test("A date on a later day fires at nine that morning")
    func laterDayIsNine() {
        let now = date(14, from: Date())
        let due = date(3, dayOffset: 2, from: now)
        let trigger = ReminderRequest.triggerDate(for: due, now: now, calendar: calendar)
        #expect(calendar.component(.hour, from: trigger) == 9)
        #expect(calendar.isDate(trigger, inSameDayAs: due))
    }

    @Test("A date later today, after nine, fires at that time rather than in the past")
    func laterTodayIsNotInThePast() {
        let now = date(10, from: Date())
        let due = date(15, from: now)
        let trigger = ReminderRequest.triggerDate(for: due, now: now, calendar: calendar)
        #expect(trigger > now)
        #expect(trigger == due)
    }

    @Test("A date that has already passed fires shortly, not never")
    func pastIsSoon() {
        let now = date(10, from: Date())
        let due = date(8, from: now)
        let trigger = ReminderRequest.triggerDate(for: due, now: now, calendar: calendar)
        #expect(trigger > now)
        #expect(trigger.timeIntervalSince(now) <= 120)
    }
}

extension JSONDecoder {
    static var snakeCased: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}
