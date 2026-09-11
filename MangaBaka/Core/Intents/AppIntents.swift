import AppIntents
import Foundation

/// "Open <series> in MangaBaka."
struct OpenSeriesIntent: AppIntent {
    static let title: LocalizedStringResource = "Open a series"
    static let description = IntentDescription("Opens a series from your library.")
    static let openAppWhenRun = true

    @Parameter(title: "Series")
    var series: LibrarySeriesEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$series)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentBridge.shared.pendingSeriesID = series.id
        return .result()
    }
}

/// "What's due this week in MangaBaka?"
struct DueThisWeekIntent: AppIntent {
    static let title: LocalizedStringResource = "What's due this week"
    static let description = IntentDescription(
        "Which of your series have a chapter or a volume due in the next seven days."
    )

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let services = IntentBridge.shared.services else {
            return .result(dialog: "Open MangaBaka first, then ask again.")
        }
        let snapshot = await services.schedule.snapshot()
        let announced = await services.calendar.mine(seriesIDs: await services.librarySnapshot.seriesIDs())
        let answer = DueThisWeek.sentence(
            dated: snapshot.dated,
            announced: announced,
            measured: snapshot.measuredAt != nil,
            now: Date()
        )
        return .result(dialog: "\(answer)")
    }
}

/// The sentence, kept out of the intent so it can be tested.
enum DueThisWeek {
    static let window = 7

    /// Announced volumes first — they are facts — then the estimates,
    /// soonest first, each once. Late estimates are due too: a chapter three
    /// days overdue is still the one the reader is waiting for.
    static func sentence(
        dated: [ScheduledWork],
        announced: [UpcomingWork],
        measured: Bool,
        now: Date,
        calendar: Calendar = .current
    ) -> String {
        let today = calendar.startOfDay(for: now)
        guard let end = calendar.date(byAdding: .day, value: window, to: today) else { return "" }

        var lines: [String] = []
        var seen: Set<Int> = []
        for work in announced {
            guard let day = work.localDay(calendar: calendar), day >= today, day < end,
                  let title = work.title, let id = work.seriesId, seen.insert(id).inserted
            else { continue }
            let volume = work.sequenceString.map { "volume \($0)" } ?? "a volume"
            lines.append("\(title), \(volume), \(when(day, today: today, calendar: calendar))")
        }
        for work in dated {
            guard let cadence = work.cadence, seen.insert(work.series.id).inserted else { continue }
            let day = calendar.startOfDay(for: cadence.due)
            guard day < end else { continue }
            let title = work.series.displayTitle ?? "Untitled series"
            lines.append("\(title), \(when(day, today: today, calendar: calendar))")
        }

        if lines.isEmpty {
            return measured || !announced.isEmpty
                ? "Nothing due in the next \(window) days."
                : "The schedule hasn't been measured yet. Open MangaBaka to build it."
        }
        let head = lines.count == 1 ? "One thing due this week: " : "\(lines.count) due this week: "
        return head + lines.joined(separator: "; ") + "."
    }

    private static func when(_ day: Date, today: Date, calendar: Calendar) -> String {
        let days = calendar.dateComponents([.day], from: today, to: day).day ?? 0
        return switch days {
        case ..<0: "\(-days) day\(days == -1 ? "" : "s") overdue"
        case 0: "today"
        case 1: "tomorrow"
        default: day.formatted(.dateTime.weekday(.wide))
        }
    }
}

struct MangaBakaShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: DueThisWeekIntent(),
            phrases: [
                "What's due this week in \(.applicationName)",
                "What's due in \(.applicationName)"
            ],
            shortTitle: "Due this week",
            systemImageName: "calendar"
        )
        AppShortcut(
            intent: OpenSeriesIntent(),
            phrases: ["Open a series in \(.applicationName)"],
            shortTitle: "Open a series",
            systemImageName: "book"
        )
    }
}
