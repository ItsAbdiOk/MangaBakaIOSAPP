import Foundation
import Testing
@testable import MangaBaka

/// "What's due this week", as Siri says it.
@Suite("Due this week")
struct DueThisWeekTests {
    private let now = Date(timeIntervalSince1970: 1_789_000_000) // a Wednesday, 2026-09-09

    private func work(_ id: Int, _ title: String, dueIn days: Int) -> ScheduledWork {
        let due = now.addingTimeInterval(Double(days) * 86_400)
        let cadence = Cadence(
            medianGapDays: 7, spreadDays: 0, lastRelease: due.addingTimeInterval(-7 * 86_400),
            due: due, samples: 10, gaps: 9, isRegular: true
        )
        return ScheduledWork(series: SeriesFactory.make(id: id, title: title), cadence: cadence, reason: nil)
    }

    @Test("Within seven days, soonest first; late counts; beyond the week does not")
    func estimates() {
        let sentence = DueThisWeek.sentence(
            dated: [work(1, "A", dueIn: -2), work(2, "B", dueIn: 0), work(3, "C", dueIn: 1),
                    work(4, "D", dueIn: 6), work(5, "E", dueIn: 9)],
            announced: [], measured: true, now: now
        )
        #expect(sentence.hasPrefix("4 due this week: A, 2 days overdue; B, today; C, tomorrow; D, "))
        #expect(!sentence.contains("E"))
    }

    @Test("Nothing due says so; nothing measured says that instead")
    func empty() {
        #expect(DueThisWeek.sentence(dated: [], announced: [], measured: true, now: now)
                == "Nothing due in the next 7 days.")
        #expect(DueThisWeek.sentence(dated: [], announced: [], measured: false, now: now)
                .hasPrefix("The schedule hasn't been measured yet"))
    }

    @Test("One thing is singular")
    func singular() {
        let sentence = DueThisWeek.sentence(
            dated: [work(1, "A", dueIn: 3)], announced: [], measured: true, now: now
        )
        #expect(sentence.hasPrefix("One thing due this week: A, "))
    }
}

@Suite("Intents are wired", .enabled(if: SourceTree.isAvailable))
struct IntentWiringTests {
    @Test("The app hands the bridge its services and the root opens what an intent asks")
    func wiring() throws {
        let app = try SourceTree.read("MangaBaka/App/MangaBakaApp.swift")
        #expect(app.contains("IntentBridge.shared.services = services"))
        let root = try SourceTree.read("MangaBaka/App/RootView.swift")
        #expect(root.contains(".task(id: bridge.pendingSeriesID)"))
        #expect(root.contains("bridge.pendingSeriesID = nil\n                await openSeries(id: id)"))
    }
}
