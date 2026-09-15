import Testing
import Foundation
import UserNotifications
@testable import MangaBaka

/// The second-pass review's three findings against `ReleaseReminders`'
/// pacing (2026-09-14, items 35, 36 and 72): the same-series cooldown was
/// measured from the moment a notification was *queued* rather than the
/// moment it *arrives*, the `fired` ledger grew without bound and read as
/// empty on one bad value, and the pass's task handle was never released.
/// Kept apart from `ReminderTests`, whose suite body is at the lint ceiling.
@Suite("Release reminder pacing")
@MainActor
struct ReminderPacingTests {
    /// Item 35. Day 0 at noon: three series come back from hiatus and fill
    /// the day (series 7 is last in the library array, so it is the one that
    /// overflows), and series 7's own return is deferred to day 1 at 09:00.
    /// Twenty-five hours later series 7 also finishes. The cooldown used to
    /// compare `now` (day 1, 13:00) against the *queue* time of the deferred
    /// one (day 0, noon) — twenty-five hours, so the completion was allowed
    /// through and landed on day 1 four hours after the return it was meant
    /// to be spaced from.
    ///
    /// Expected to fail before the fix with: `centre.added.map(\.id)`
    /// contains "finished-7" — two notifications about series 7 on day 1.
    @Test("Two facts about one series are 24 hours apart on the lock screen, not at queue time")
    func cooldownIsMeasuredFromArrival() async throws {
        let clock = TestClock(now: try noonToday())
        let centre = FakeCentre()
        let reminders = ReleaseReminders(defaults: try defaults(), centre: centre, now: { clock.now })
        await reminders.enable()

        // Baseline: four series, all hiatus, so their return below is news.
        await reminders.reschedule(
            announced: [], library: [1, 2, 3, 7].map { entry(id: $0, state: .reading, status: "hiatus") }
        )
        #expect(centre.added.isEmpty, "control: baseline pass fires nothing")

        // Three series come back from hiatus today, filling the day's cap;
        // series 7's own return (last in the array) overflows to day 1.
        await reminders.reschedule(
            announced: [], library: [1, 2, 3, 7].map { entry(id: $0, state: .reading, status: "releasing") }
        )
        let deferred = try #require(centre.added.first { $0.id == "back-7" })
        #expect(
            !Calendar.current.isDate(deferred.date, inSameDayAs: clock.now), "control: series 7 was deferred"
        )

        clock.advance(by: 25 * 60 * 60)
        await reminders.reschedule(
            announced: [], library: [entry(id: 7, state: .reading, status: "completed")]
        )

        #expect(
            !centre.added.map(\.id).contains("finished-7"),
            "series 7's return arrives at 09:00 on day 1; a completion four hours later is the fatigue"
        )
        let seriesSeven = centre.added.filter { $0.id.hasSuffix("7") }
        #expect(seriesSeven.count == 1)

        // And once a full day has passed since the deferred one *arrived*,
        // the completion is told after all — the cooldown delays, it does
        // not drop.
        clock.advance(by: 24 * 60 * 60)
        await reminders.reschedule(
            announced: [], library: [entry(id: 7, state: .reading, status: "completed")]
        )
        #expect(centre.added.map(\.id).contains("finished-7"))
    }

    /// Item 36. Expected to fail before the fix with: the ninety-day-old
    /// key is still in `reminders.fired` after the pass.
    @Test("The fired ledger forgets entries older than the retention window")
    func firedLedgerIsPruned() async throws {
        let clock = TestClock(now: try noonToday())
        let store = try defaults()
        let stale = clock.now.addingTimeInterval(-90 * 24 * 60 * 60)
        let recent = clock.now.addingTimeInterval(-10 * 24 * 60 * 60)
        store.set(["event-old": stale, "event-recent": recent], forKey: "reminders.fired")

        let reminders = ReleaseReminders(defaults: store, centre: FakeCentre(), now: { clock.now })
        await reminders.enable()
        await reminders.reschedule(announced: [], library: [reading(1)])

        let ledger = store.dictionary(forKey: "reminders.fired") ?? [:]
        #expect(ledger["event-recent"] != nil, "control: ten days old is well inside the window")
        #expect(ledger["event-old"] == nil, "ninety days is past the sixty-day window")
        let deferral = TimeInterval(ReleaseReminders.maxDeferralDays * 24 * 60 * 60)
        #expect(ReleaseReminders.firedRetention > deferral, "nothing still deferred can be pruned")
    }

    /// Item 36, the other half. `as? [String: Date]` over the whole ledger
    /// was all-or-nothing: one value that was not a `Date` read the ledger
    /// as `[:]`, and every notification ever sent became eligible again.
    ///
    /// Expected to fail before the fix with: `centre.added.map(\.id) ==
    /// ["back-1"]` — the already-fired return from hiatus is sent a second time.
    @Test("One bad value in the ledger does not re-fire every notification")
    func oneBadLedgerValueIsNotAmnesia() async throws {
        let clock = TestClock(now: try noonToday())
        let store = try defaults()
        let centre = FakeCentre()
        let reminders = ReleaseReminders(defaults: store, centre: centre, now: { clock.now })
        await reminders.enable()

        // Baseline: series 1 seen hiatus, so its return below would
        // otherwise be news.
        await reminders.reschedule(
            announced: [], library: [entry(id: 1, state: .reading, status: "hiatus")]
        )
        #expect(centre.added.isEmpty, "control: baseline pass fires nothing")

        store.set(["back-1": clock.now.addingTimeInterval(-3600), "junk": "not a date"],
                  forKey: "reminders.fired")

        await reminders.reschedule(
            announced: [], library: [entry(id: 1, state: .reading, status: "releasing")]
        )
        #expect(centre.added.isEmpty, "back-1 already fired an hour ago")
    }

    /// Item 72. Expected to fail before the fix with: `rescheduleTask != nil`
    /// — the last pass's task, and everything it captured, was kept for the
    /// life of the app.
    @Test("The pass releases its task handle when it is done")
    func taskHandleIsReleased() async throws {
        let reminders = ReleaseReminders(defaults: try defaults(), centre: FakeCentre())
        await reminders.enable()
        await reminders.reschedule(announced: [], library: [reading(1)])
        #expect(reminders.rescheduleTask == nil)
    }
}

extension ReminderPacingTests {
    private func defaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "reminders.pacing.tests.\(UUID().uuidString)"))
    }

    /// Today at noon, local time, so a test that advances by whole hours
    /// never crosses midnight where it did not mean to — `TestClock`'s
    /// default epoch is 14:53 UTC, which is already tomorrow in Tokyo.
    private func noonToday() throws -> Date {
        try #require(Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date()))
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

    private func reading(_ id: Int) -> LibraryEntry {
        entry(id: id, state: .reading, status: "releasing")
    }

    private final class FakeCentre: NotificationScheduling, @unchecked Sendable {
        var added: [ReminderRequest] = []
        func authorizationStatus() async -> UNAuthorizationStatus { .authorized }
        func requestAuthorization() async -> Bool { true }
        func add(_ request: ReminderRequest) async { added.append(request) }
        func removeAll() async { added = [] }
    }
}
