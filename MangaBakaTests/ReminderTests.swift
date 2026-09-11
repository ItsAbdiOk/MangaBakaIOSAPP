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

extension JSONDecoder {
    static var snakeCased: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}
