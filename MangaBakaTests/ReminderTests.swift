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
    private func defaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "reminders.tests.\(UUID().uuidString)"))
    }

    /// - Parameter from: the reference "now" the date is relative to. Real
    ///   `Date()` for tests with no injected clock; a `TestClock`'s `now` for
    ///   tests that also move time deliberately — otherwise a work "dated
    ///   today" against the real calendar could sit years away from a fixed
    ///   `TestClock`'s epoch, and every date-gated assertion would fail for
    ///   the wrong reason.
    private func work(
        _ id: String, series: Int, daysFromNow: Int, from now: Date = Date()
    ) throws -> UpcomingWork {
        let date = Calendar.current.date(byAdding: .day, value: daysFromNow, to: now) ?? now
        let iso = DateFormatter()
        iso.locale = Locale(identifier: "en_US_POSIX")
        iso.timeZone = TimeZone(secondsFromGMT: 0)
        iso.dateFormat = "yyyy-MM-dd"
        return try JSONDecoder.snakeCased.decode(UpcomingWork.self, from: Data("""
        {"id": "\(id)", "series_id": \(series), "release_date": "\(iso.string(from: date))",
         "sequence_string": "3", "collections": [{"title": "A Series"}]}
        """.utf8))
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

    @Test("Nothing is scheduled until the reader asks")
    func offByDefault() async throws {
        let centre = FakeCentre()
        let reminders = ReleaseReminders(defaults: try defaults(), centre: centre)
        #expect(!reminders.isEnabled)

        await reminders.reschedule(announced: [try work("a", series: 1, daysFromNow: 0)])
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

    @Test("A confirmed release notifies once; asking again does not repeat it")
    func confirmedReleaseNotifiesOnce() async throws {
        let centre = FakeCentre()
        let reminders = ReleaseReminders(defaults: try defaults(), centre: centre)
        await reminders.enable()

        await reminders.reschedule(announced: [try work("a", series: 1, daysFromNow: 0)])
        #expect(centre.added.map(\.id) == ["release-work-a"])

        await reminders.reschedule(announced: [try work("a", series: 1, daysFromNow: 0)])
        #expect(centre.added.map(\.id) == ["release-work-a"], "the same confirmed release is not repeated")
    }

    @Test("An unreadable or incomplete library read schedules nothing this pass")
    func failedOrIncompleteReadSchedulesNothing() async throws {
        let centre = FakeCentre()
        let reminders = ReleaseReminders(defaults: try defaults(), centre: centre)
        await reminders.enable()

        await reminders.reschedule(
            announced: [try work("a", series: 1, daysFromNow: 0)], libraryFailure: .offline
        )
        #expect(centre.added.isEmpty)

        await reminders.reschedule(announced: [try work("a", series: 1, daysFromNow: 0)], isComplete: false)
        #expect(centre.added.isEmpty)
    }

    @Test("A completed series is told once, and not told again next time")
    func completedSeriesNotifiedOnce() async throws {
        let centre = FakeCentre()
        let reminders = ReleaseReminders(defaults: try defaults(), centre: centre)
        await reminders.enable()
        let library = [entry(id: 7, status: "releasing")]

        // First sighting: only a baseline is recorded, per `NotificationPolicy`.
        await reminders.reschedule(announced: [], library: library)
        #expect(centre.added.isEmpty)

        // The status flips to completed.
        await reminders.reschedule(announced: [], library: [entry(id: 7, status: "completed")])
        #expect(centre.added.map(\.id) == ["finished-7"])

        // Asked again with the same completed status: not repeated.
        await reminders.reschedule(announced: [], library: [entry(id: 7, status: "completed")])
        #expect(centre.added.map(\.id) == ["finished-7"], "told once, not on every subsequent check")
    }

    @Test("At most three notifications a day; the fourth waits for tomorrow morning")
    func dailyCapDefersTheFourth() async throws {
        let clock = TestClock()
        let centre = FakeCentre()
        let reminders = ReleaseReminders(defaults: try defaults(), centre: centre, now: { clock.now })
        await reminders.enable()

        let works = try (1...4).map { try work("w\($0)", series: $0, daysFromNow: 0, from: clock.now) }
        await reminders.reschedule(announced: works)

        #expect(centre.added.count == 4, "all four are scheduled, just not all for today")
        let today = centre.added.filter { $0.date <= clock.now }
        let deferred = centre.added.filter { $0.date > clock.now }
        #expect(today.count == ReleaseReminders.dailyLimit)
        #expect(deferred.count == 1)
        let calendar = Calendar.current
        #expect(calendar.component(.hour, from: try #require(deferred.first?.date)) == 9)
        #expect(!calendar.isDate(try #require(deferred.first?.date), inSameDayAs: clock.now))
    }

    @Test("Two events for the same series within 24 hours: only the first is sent")
    func sameSeriesCooldownHolds() async throws {
        let clock = TestClock()
        let centre = FakeCentre()
        let reminders = ReleaseReminders(defaults: try defaults(), centre: centre, now: { clock.now })
        await reminders.enable()

        // Series 1 gets a confirmed release today, and — on the same pass —
        // its status also flips to completed. Both are true at once, but
        // Abdi's fatigue guard allows only one notification per series a day.
        await reminders.reschedule(
            announced: [try work("a", series: 1, daysFromNow: 0, from: clock.now)],
            library: [entry(id: 1, status: "releasing")]
        )
        #expect(centre.added.map(\.id) == ["release-work-a"])

        clock.advance(by: 60 * 60) // one hour later, same day
        await reminders.reschedule(
            announced: [],
            library: [entry(id: 1, status: "completed")]
        )
        #expect(centre.added.map(\.id) == ["release-work-a"], "series 1 already had its notification today")

        clock.advance(by: 25 * 60 * 60) // now past the 24h cooldown
        await reminders.reschedule(announced: [], library: [entry(id: 1, status: "completed")])
        #expect(centre.added.map(\.id) == ["release-work-a", "finished-1"])
    }

    @Test("forget() clears the ledger, so a new account's own flip can still notify")
    func forgetClearsTheLedger() async throws {
        let centre = FakeCentre()
        let reminders = ReleaseReminders(defaults: try defaults(), centre: centre)
        await reminders.enable()

        // Account A: series 7 flips to completed and is told once.
        await reminders.reschedule(announced: [], library: [entry(id: 7, status: "releasing")])
        await reminders.reschedule(announced: [], library: [entry(id: 7, status: "completed")])
        #expect(centre.added.map(\.id) == ["finished-7"], "control: it has already fired once")

        await reminders.forget()
        #expect(centre.added.isEmpty, "forget() cancels what was pending too")

        // Account B has an unrelated series 7 that only shares the id. If
        // `forget()` left account A's "completed" baseline in place, account
        // B's own releasing → completed flip below would read as "no change"
        // and never notify — the bug this test is for.
        await reminders.reschedule(announced: [], library: [entry(id: 7, status: "releasing")])
        #expect(centre.added.isEmpty, "first sighting after forget only baselines")

        await reminders.reschedule(announced: [], library: [entry(id: 7, status: "completed")])
        #expect(centre.added.map(\.id) == ["finished-7"], "account B's own flip notifies independently")
    }

    @Test("Turning it off cancels what was pending")
    func disableClears() async throws {
        let centre = FakeCentre()
        let reminders = ReleaseReminders(defaults: try defaults(), centre: centre)
        await reminders.enable()
        await reminders.reschedule(announced: [try work("a", series: 1, daysFromNow: 0)])

        await reminders.disable()
        #expect(!reminders.isEnabled)
        #expect(centre.removeAllCount >= 1)
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
