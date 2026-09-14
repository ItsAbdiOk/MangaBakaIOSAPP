import SwiftUI
import WidgetKit

struct PickBackUpProvider: TimelineProvider {
    func placeholder(in context: Context) -> SeriesWidgetEntry { .placeholder() }

    func getSnapshot(in context: Context, completion: @escaping (SeriesWidgetEntry) -> Void) {
        let done = Completion(call: completion)
        let isPreview = context.isPreview
        Task { done.call(await makeEntry(isPreview: isPreview)) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SeriesWidgetEntry>) -> Void) {
        let done = Completion(call: completion)
        Task {
            done.call(Timeline(entries: [await makeEntry()], policy: .after(WidgetRefresh.nextReload())))
        }
    }

    private func makeEntry(isPreview: Bool = false) async -> SeriesWidgetEntry {
        await SeriesWidgetEntryBuilder.makeEntry(items: { $0.pickBackUp }, isPreview: isPreview)
    }
}

struct PickBackUpWidget: Widget {
    let kind = "PickBackUpWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: PickBackUpProvider()) { entry in
            SeriesWidgetView(entry: entry, emptyMessage: "Nothing waiting to be picked back up.")
        }
        .configurationDisplayName("Pick Back Up")
        .description("Series you're reading that you haven't opened in a while.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
