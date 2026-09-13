import SwiftUI
import WidgetKit

struct DueThisWeekProvider: TimelineProvider {
    func placeholder(in context: Context) -> SeriesWidgetEntry { .placeholder() }

    func getSnapshot(in context: Context, completion: @escaping (SeriesWidgetEntry) -> Void) {
        let done = Completion(call: completion)
        Task { done.call(await makeEntry()) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SeriesWidgetEntry>) -> Void) {
        let done = Completion(call: completion)
        Task {
            done.call(Timeline(entries: [await makeEntry()], policy: .after(WidgetRefresh.nextReload())))
        }
    }

    private func makeEntry() async -> SeriesWidgetEntry {
        await SeriesWidgetEntryBuilder.makeEntry { $0.dueThisWeek }
    }
}

struct DueThisWeekWidget: Widget {
    let kind = "DueThisWeekWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: DueThisWeekProvider()) { entry in
            SeriesWidgetView(entry: entry, emptyMessage: "Nothing due this week.")
        }
        .configurationDisplayName("Due This Week")
        .description("Series with a chapter or volume due in the next seven days.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
