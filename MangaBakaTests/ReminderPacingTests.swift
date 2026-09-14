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
    /// Item 35. Day 0 at noon: three releases from yesterday fill the day
    /// (dated earlier, so they are placed first), and series 7's own release
    /// is deferred to day 1 at 09:00. Twenty-five hours later
    /// series 7 also finishes. The cooldown used to compare `now` (day 1,
    /// 13:00) against the *queue* time of the deferred one (day 0, noon) —
    /// twenty-five hours, so the completion was allowed through and landed
    /// on day 1 four hours after the release it was meant to be spaced from.
    ///
    /// Expected to fail before the fix with: `centre.added.map(\.id)`
    /// contains "finished-7" — two notifications about series 7 on day 1.
    @Test("Two facts about one series are 24 hours apart on the lock screen, not at queue time")
    func cooldownIsMeasuredFromArrival() async throws {
        let clock = TestClock(now: try noonToday())
        let centre = FakeCentre()
        let reminders = ReleaseReminders(defaults: try defaults(), centre: centre, now: { clock.now })
        await reminders.enable()

        let fillers = try (1...3).map { try work("w\($0)", series: $0, daysFromNow: -1, from: clock.now) }
        let seventh = try work("w7", series: 7, daysFromNow: 0, from: clock.now)
        let releasing = entry(id: 7, state: .reading, status: "releasing")
        let completed = entry(id: 7, state: .reading, status: "completed")
        await reminders.reschedule(
            announced: fillers + [seventh], library: (1...3).map { reading($0) } + [releasing]
        )
        let deferred = try #require(centre.added.first { $0.id == "release-work-w7" })
        #expect(!Calendar.current.isDate(deferred.date, inSameDayAs: clock.now), "control: w7 was deferred")

        clock.advance(by: 25 * 60 * 60)
        await reminders.reschedule(announced: [], library: [completed])

        #expect(
            !centre.added.map(\.id).contains("finished-7"),
            "series 7's release arrives at 09:00 on day 1; a completion four hours later is the fatigue"
        )
        let seriesSeven = centre.added.filter { $0.id.hasSuffix("7") }
        #expect(seriesSeven.count == 1)

        // And once a full day has passed since the deferred one *arrived*,
        // the completion is told after all — the cooldown delays, it does
        // not drop.
        clock.advance(by: 24 * 60 * 60)
        await reminders.reschedule(announced: [], library: [completed])
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
        store.set(["release-work-old": stale, "release-work-recent": recent], forKey: "reminders.fired")

        let reminders = ReleaseReminders(defaults: store, centre: FakeCentre(), now: { clock.now })
        await reminders.enable()
        await reminders.reschedule(announced: [], library: [reading(1)])

        let ledger = store.dictionary(forKey: "reminders.fired") ?? [:]
        #expect(ledger["release-work-recent"] != nil, "control: ten days old is well inside the window")
        #expect(ledger["release-work-old"] == nil, "ninety days is past the sixty-day window")
        let deferral = TimeInterval(ReleaseReminders.maxDeferralDays * 24 * 60 * 60)
        #expect(ReleaseReminders.firedRetention > deferral, "nothing still deferred can be pruned")
    }

    /// Item 36, the other half. `as? [String: Date]` over the whole ledger
    /// was all-or-nothing: one value that was not a `Date` read the ledger
    /// as `[:]`, and every notification ever sent became eligible again.
    ///
    /// Expected to fail before the fix with: `centre.added.map(\.id) ==
    /// ["release-work-a"]` — the already-fired release is sent a second time.
    @Test("One bad value in the ledger does not re-fire every notification")
    func oneBadLedgerValueIsNotAmnesia() async throws {
        let clock = TestClock(now: try noonToday())
        let store = try defaults()
        store.set(["release-work-a": clock.now.addingTimeInterval(-3600), "junk": "not a date"],
                  forKey: "reminders.fired")
        let centre = FakeCentre()
        let reminders = ReleaseReminders(defaults: store, centre: centre, now: { clock.now })
        await reminders.enable()

        await reminders.reschedule(
            announced: [try work("a", series: 1, daysFromNow: 0, from: clock.now)], library: [reading(1)]
        )
        #expect(centre.added.isEmpty, "release-work-a already fired an hour ago")
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

    /// The same recorded shape `ReminderTests.work` uses, dated in the
    /// reader's own zone for the reason given there.
    private func work(_ id: String, series: Int, daysFromNow: Int, from now: Date) throws -> UpcomingWork {
        let date = Calendar.current.date(byAdding: .day, value: daysFromNow, to: now) ?? now
        let iso = DateFormatter()
        iso.locale = Locale(identifier: "en_US_POSIX")
        iso.timeZone = Calendar.current.timeZone
        iso.dateFormat = "yyyy-MM-dd"
        return try JSONDecoder.snakeCased.decode(UpcomingWork.self, from: Data("""
        {"id": "\(id)", "series_id": \(series), "release_date": "\(iso.string(from: date))",
         "sequence_string": "3", "collections": [{"title": "A Series"}]}
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
