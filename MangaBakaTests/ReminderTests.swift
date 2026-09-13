import Testing
import Foundation
import UserNotifications
@testable import MangaBaka

/// Release reminders: local only, asked for rather than assumed, and honest
/// about which half of what they say is a guess.
@Suite("Release reminders")
@MainActor
struct ReminderTests {
    private func defaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "reminders.tests.\(UUID().uuidString)"))
    }

    private func work(_ id: String, series: Int, daysFromNow: Int) throws -> UpcomingWork {
        let date = Calendar.current.date(byAdding: .day, value: daysFromNow, to: Date()) ?? Date()
        let iso = DateFormatter()
        iso.locale = Locale(identifier: "en_US_POSIX")
        iso.timeZone = TimeZone(secondsFromGMT: 0)
        iso.dateFormat = "yyyy-MM-dd"
        return try JSONDecoder.snakeCased.decode(UpcomingWork.self, from: Data("""
        {"id": "\(id)", "series_id": \(series), "release_date": "\(iso.string(from: date))",
         "sequence_string": "3", "collections": [{"title": "A Series"}]}
        """.utf8))
    }

    @Test("Nothing is scheduled until the reader asks")
    func offByDefault() async throws {
        let centre = FakeCentre()
        let reminders = ReleaseReminders(defaults: try defaults(), centre: centre)
        #expect(!reminders.isEnabled)

        await reminders.reschedule(announced: [try work("a", series: 1, daysFromNow: 3)], predicted: [])
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

    @Test("Rescheduling replaces rather than accumulates")
    func replacesPending() async throws {
        // A date moves, a series leaves the library, a reader changes their
        // mind. Adding to what is there leaves notifications for things that
        // are no longer true, and no way to tell which is which.
        let centre = FakeCentre()
        let reminders = ReleaseReminders(defaults: try defaults(), centre: centre)
        await reminders.enable()

        await reminders.reschedule(announced: [try work("a", series: 1, daysFromNow: 3)], predicted: [])
        await reminders.reschedule(announced: [try work("b", series: 2, daysFromNow: 4)], predicted: [])

        #expect(centre.removeAllCount == 2, "once per reschedule")
        #expect(
            centre.added.map(\.id) == ["announced-b"],
            "the first batch is gone, not sitting behind the second"
        )
    }

    /// The release date is parsed as midnight UTC. Compared against now, a
    /// release dated today was already "past" for every reader once UTC
    /// midnight had gone — the "out today" reminder was dropped on the only
    /// day it could fire.
    @Test("A release dated today is scheduled, whatever the hour")
    func todayIsNotPast() async throws {
        let centre = FakeCentre()
        let reminders = ReleaseReminders(defaults: try defaults(), centre: centre)
        await reminders.enable()

        await reminders.reschedule(announced: [try work("today", series: 1, daysFromNow: 0)], predicted: [])
        #expect(centre.added.map(\.id) == ["announced-today"])
    }

    @Test("A date already past is not scheduled")
    func skipsThePast() async throws {
        let centre = FakeCentre()
        let reminders = ReleaseReminders(defaults: try defaults(), centre: centre)
        await reminders.enable()

        await reminders.reschedule(
            announced: [try work("old", series: 1, daysFromNow: -2)],
            predicted: []
        )
        #expect(centre.added.isEmpty)
    }

    @Test("Only the soonest fit, because iOS drops the rest silently")
    func capsAtTheSystemLimit() async throws {
        // iOS keeps 64 pending local notifications per app and discards the
        // rest without saying so, which would make the far end of the list
        // quietly stop working.
        let centre = FakeCentre()
        let reminders = ReleaseReminders(defaults: try defaults(), centre: centre)
        await reminders.enable()

        let many = try (1...60).map { try work("w\($0)", series: $0, daysFromNow: $0) }
        await reminders.reschedule(announced: many, predicted: [])

        #expect(centre.added.count == ReleaseReminders.limit)
        #expect(centre.added.first?.id == "announced-w1", "soonest first")
    }

    /// Coming back to the app offline used to wipe every pending reminder: the
    /// library read as empty, so there was "nothing" to remind about. A
    /// reminder set from a library that was there yesterday is still right.
    @Test("An unreadable library leaves the pending reminders alone")
    func unreadableLibraryKeepsPending() async throws {
        let centre = FakeCentre()
        let reminders = ReleaseReminders(defaults: try defaults(), centre: centre)
        await reminders.enable()
        await reminders.reschedule(announced: [try work("a", series: 1, daysFromNow: 3)], predicted: [])
        #expect(centre.added.map(\.id) == ["announced-a"])

        await reminders.reschedule(announced: [], predicted: [], libraryFailure: .offline)

        #expect(centre.removeAllCount == 1, "Nothing may be removed on the strength of a failed read")
        #expect(centre.added.map(\.id) == ["announced-a"])
    }

    private func nearlyFinished(_ id: Int) -> LibraryEntry {
        LibraryEntry(
            id: id, seriesId: id, state: .reading, progressChapter: 196,
            progressVolume: nil, rating: nil, note: nil, startDate: nil,
            finishDate: nil, numberOfRereads: nil, priority: nil, isPrivate: nil,
            readLink: nil,
            series: SeriesFactory.make(id: id, title: "S\(id)", status: "completed", totalChapters: 200)
        )
    }

    /// The two library nudges were re-added at now+24h and now+30d on every
    /// foreground. Open the app daily and neither ever fired: the date was
    /// always tomorrow.
    @Test("A nudge keeps its date across foregrounds, and then fires once")
    func nudgeKeepsItsDate() async throws {
        let clock = TestClock()
        let centre = FakeCentre()
        let reminders = ReleaseReminders(defaults: try defaults(), centre: centre, now: { clock.now })
        await reminders.enable()
        let library = [nearlyFinished(7)]

        await reminders.reschedule(announced: [], predicted: [], library: library)
        let first = try #require(centre.added.first { $0.id == "finished-7" }?.date)

        clock.advance(by: 6 * 3_600)
        await reminders.reschedule(announced: [], predicted: [], library: library)
        let second = try #require(centre.added.first { $0.id == "finished-7" }?.date)
        #expect(second == first, "Six hours later the nudge is still set for the same moment")

        // Past its date it has fired. A series can only end once.
        clock.advance(by: 30 * 3_600)
        await reminders.reschedule(announced: [], predicted: [], library: library)
        #expect(!centre.added.contains { $0.id == "finished-7" })
    }

    @Test("The backlog nudge comes round again a month after it fired")
    func backlogNudgeIsMonthly() async throws {
        let clock = TestClock()
        let centre = FakeCentre()
        let reminders = ReleaseReminders(defaults: try defaults(), centre: centre, now: { clock.now })
        await reminders.enable()
        var behind = nearlyFinished(3)
        behind = LibraryEntry(
            id: 3, seriesId: 3, state: .reading, progressChapter: 10,
            progressVolume: nil, rating: nil, note: nil, startDate: nil,
            finishDate: nil, numberOfRereads: nil, priority: nil, isPrivate: nil,
            readLink: nil,
            series: SeriesFactory.make(id: 3, title: "S3", status: "releasing", totalChapters: 60)
        )

        await reminders.reschedule(announced: [], predicted: [], library: [behind])
        let first = try #require(centre.added.first { $0.id == "catch-up" }?.date)

        clock.advance(by: 31 * 86_400)
        await reminders.reschedule(announced: [], predicted: [], library: [behind])
        let next = try #require(centre.added.first { $0.id == "catch-up" }?.date)
        #expect(next > first)
        #expect(next.timeIntervalSince(clock.now) > 29 * 86_400, "Roughly a month from now, not from then")
    }

    /// `cancelAll()` — what an account change used to call — clears the
    /// pending requests but leaves `nudgeDates` on disk, keyed only by series
    /// id. A `finished-<seriesId>` the previous account was already nudged
    /// about then reads as already-fired for the next account too, and it
    /// never fires for them. `forget()` has to clear that memory as well.
    @Test("An account change forgets a nudge it already sent, not just the pending copy")
    func accountChangeForgetsNudgeMemory() async throws {
        let clock = TestClock()
        let centre = FakeCentre()
        let store = try defaults()
        let reminders = ReleaseReminders(defaults: store, centre: centre, now: { clock.now })
        await reminders.enable()
        let library = [nearlyFinished(7)]

        // Account A sees the nudge, and it fires: past its one-off date.
        await reminders.reschedule(announced: [], predicted: [], library: library)
        clock.advance(by: 30 * 3_600)
        await reminders.reschedule(announced: [], predicted: [], library: library)
        #expect(!centre.added.contains { $0.id == "finished-7" }, "control: it has already fired once")

        // The app forgets account A. The same `ReleaseReminders` instance and
        // the same on-disk `nudgeDates` are what account B's session reuses.
        await reminders.forget()

        // Account B has its own series 7 nearly finished — an unrelated
        // series that only happens to share the id. It has never been told.
        await reminders.reschedule(announced: [], predicted: [], library: library)
        #expect(
            centre.added.contains { $0.id == "finished-7" },
            "forgetting the previous account must clear its nudge memory too"
        )
    }

    /// Gap 102: `isEnabled` alone said nothing about whether iOS would
    /// actually deliver anything — a reader who denied the system prompt (or
    /// revoked it later in Settings) still saw the in-app switch reading On.
    /// Expected to fail before the fix with: no `effectiveEnabled` property
    /// existed on `ReleaseReminders` at all.
    @Test("A denied system permission overrides an enabled switch")
    func deniedSystemPermissionOverridesTheSwitch() async throws {
        let centre = FakeCentre()
        let reminders = ReleaseReminders(defaults: try defaults(), centre: centre)

        // The reader turned it on while the app still had permission.
        _ = await reminders.enable()
        #expect(reminders.isEnabled)
        #expect(reminders.effectiveEnabled)

        // iOS takes the permission away behind the app's back — Settings, not
        // this app. `isEnabled` (the reader's own ask) does not move on its
        // own; only a fresh `refreshStatus()` learns of it.
        centre.grants = false
        await reminders.refreshStatus()

        #expect(reminders.isEnabled, "the reader's own ask has not changed")
        #expect(!reminders.effectiveEnabled, "but iOS will not deliver anything")
    }

    /// Gap 103: a walk that stopped at the page cap is not `libraryFailure` —
    /// nothing failed, as far as this call knows — but it is still a partial
    /// answer, and re-deriving reminders from it used to drop every series
    /// past wherever the walk stopped, silently, the next time this ran.
    /// Expected to fail before the fix with: `centre.removeAllCount == 2` and
    /// the announced-b reminder replacing announced-a, because nothing told
    /// `reschedule` the second library was incomplete.
    @Test("An incomplete walk is treated like a failure for removals, not a real answer")
    func incompleteWalkKeepsPendingReminders() async throws {
        let centre = FakeCentre()
        let reminders = ReleaseReminders(defaults: try defaults(), centre: centre)
        await reminders.enable()

        await reminders.reschedule(announced: [try work("a", series: 1, daysFromNow: 3)], predicted: [])
        #expect(centre.added.map(\.id) == ["announced-a"])

        await reminders.reschedule(
            announced: [try work("b", series: 2, daysFromNow: 4)], predicted: [], isComplete: false
        )

        #expect(centre.removeAllCount == 1, "an incomplete walk must not touch what is pending")
        #expect(centre.added.map(\.id) == ["announced-a"])
    }

    @Test("Turning it off clears what was pending")
    func disableClears() async throws {
        let centre = FakeCentre()
        let reminders = ReleaseReminders(defaults: try defaults(), centre: centre)
        await reminders.enable()
        await reminders.reschedule(announced: [try work("a", series: 1, daysFromNow: 3)], predicted: [])

        await reminders.disable()
        #expect(!reminders.isEnabled)
        #expect(centre.removeAllCount >= 2)
    }

    private func stale(_ id: Int, chapters: Double) -> LibraryEntry {
        LibraryEntry(
            id: id, seriesId: id, state: .reading, progressChapter: 10,
            progressVolume: nil, rating: nil, note: nil, startDate: nil,
            finishDate: nil, numberOfRereads: nil, priority: nil, isPrivate: nil,
            readLink: nil,
            series: SeriesFactory.make(id: id, title: "S\(id)", totalChapters: chapters)
        )
    }

    @Test("Back-to-it nudges: off by default, nothing is scheduled")
    func backToItOffByDefault() async throws {
        let centre = FakeCentre()
        let reminders = ReleaseReminders(defaults: try defaults(), centre: centre)
        await reminders.enable()
        let veryStale = Date.distantPast

        await reminders.reschedule(
            announced: [], predicted: [], library: [stale(1, chapters: 30)],
            lastOpened: { _ in veryStale }
        )
        #expect(!centre.added.contains { $0.id == "backtoit-1" }, "the switch was never turned on")
    }

    @Test("Back-to-it nudges work independently of the calendar toggle")
    func backToItIndependentOfMainToggle() async throws {
        let centre = FakeCentre()
        let reminders = ReleaseReminders(defaults: try defaults(), centre: centre)
        // The calendar toggle is left off; only "back to it" is turned on.
        await reminders.setBackToIt(true)
        #expect(!reminders.isEnabled)

        await reminders.reschedule(
            announced: [try work("a", series: 9, daysFromNow: 1)], predicted: [],
            library: [stale(1, chapters: 30)],
            lastOpened: { _ in Date.distantPast }
        )

        #expect(centre.added.contains { $0.id == "backtoit-1" })
        #expect(!centre.added.contains { $0.id == "announced-a" }, "the calendar half is still off")
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
