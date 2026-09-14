import SwiftUI
import WidgetKit

/// The body both widgets share — they differ only in which list, an empty
/// message, and a display name.
struct SeriesWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SeriesWidgetEntry
    let emptyMessage: String

    private var visibleCount: Int {
        family == .systemMedium ? 3 : 1
    }

    var body: some View {
        Group {
            if !entry.hasData {
                placeholder
            } else if entry.items.isEmpty {
                Text(emptyMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(entry.items.prefix(visibleCount)) { item in
                        row(item)
                    }
                }
            }
        }
        .padding()
        .containerBackground(for: .widget) { Color(.systemBackground) }
    }

    private var placeholder: some View {
        Text("Open MangaBaka to load")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
    }

    private func row(_ item: WidgetSnapshotData.Item) -> some View {
        // Composed now, from `item.due`, not read out of a string the app
        // baked — see `SeriesWidgetEntryBuilder.subtitle(for:)`.
        let subtitle = SeriesWidgetEntryBuilder.subtitle(for: item)
        let content = HStack(alignment: .center, spacing: 8) {
            cover(for: item)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.title). \(subtitle)")

        // Each row is its own tap target when there is a real deep link to
        // open — `widgetURL` alone only covers the whole widget once, which
        // would make every row in a medium widget open the same series.
        if let url = SeriesWidgetEntryBuilder.deepLink(for: item.seriesID) {
            return AnyView(Link(destination: url) { content })
        }
        return AnyView(content)
    }

    /// A fixed thumbnail size, unlike the rest of the app's Dynamic
    /// Type-driven layout: WidgetKit families are themselves fixed canvases,
    /// so a cover here has no "natural" size to flow with the way a series
    /// page's cover does.
    @ViewBuilder
    private func cover(for item: WidgetSnapshotData.Item) -> some View {
        if let image = entry.covers[item.seriesID] {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 32, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            RoundedRectangle(cornerRadius: 4)
                .fill(.secondary.opacity(0.2))
                .frame(width: 32, height: 44)
        }
    }
}
