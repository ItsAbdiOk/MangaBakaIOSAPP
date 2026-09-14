import SwiftUI
import UIKit
import WidgetKit

/// One rendered timeline entry for `NextVolumeWidget`.
///
/// Its own type rather than reusing `SeriesWidgetEntry`: that type's `items`
/// is `[WidgetSnapshotData.Item]` — the due/pick-back-up shape, one bare
/// subtitle string — and a volume row needs a label and a date formatted
/// fresh, the same way `dueThisWeek` needed its own `due` field rather than a
/// baked string (`SeriesWidgetEntryBuilder`'s doc comment).
struct NextVolumeWidgetEntry: TimelineEntry {
    let date: Date
    let items: [WidgetSnapshotData.NextVolumeEntry]
    let covers: [Int: UIImage]
    /// False only when the app has never written a snapshot, or the last one
    /// it wrote is stale (`NextVolumeEntryBuilder.staleAfter`). An empty
    /// `items` with `hasData: true` is a real answer — nothing in the window,
    /// or nothing cached — not a failure to load.
    let hasData: Bool

    static func placeholder() -> NextVolumeWidgetEntry {
        NextVolumeWidgetEntry(date: .now, items: [], covers: [:], hasData: false)
    }
}

enum NextVolumeEntryBuilder {
    /// Same threshold and the same reasoning as
    /// `SeriesWidgetEntryBuilder.staleAfter`: past this, the app itself has
    /// not run recently enough for anything it wrote to be shown as current,
    /// independent of `WidgetSnapshot.nextVolumeWindowDays`, which governs
    /// what counts as "next", not how old the snapshot may be.
    static let staleAfter = SeriesWidgetEntryBuilder.staleAfter

    /// UTC, not the device's calendar — same reasoning as
    /// `SeriesWidgetEntryBuilder.utc`: `NextVolumeEntry.date` is a UTC
    /// midnight all the way back to `SeriesWork.date`'s fixed-zone parse, and
    /// a local calendar west of UTC would read it as the previous day.
    private static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }

    /// "Vol. 12 · 3 Oct" — the volume's own label plus the day, formatted now
    /// from `date` rather than baked into a string at write time. No year: a
    /// date inside the 60-day window this list is built from is never more
    /// than two months out, so the year adds nothing a widget row has room
    /// to spend on.
    static func subtitle(for item: WidgetSnapshotData.NextVolumeEntry) -> String {
        let day = item.date.formatted(Date.FormatStyle(timeZone: .gmt).day().month(.abbreviated))
        return "\(item.volumeLabel) · \(day)"
    }

    static func makeEntry(now: Date = .now, isPreview: Bool = false) async -> NextVolumeWidgetEntry {
        guard let snapshot = WidgetSnapshotData.read() else { return .placeholder() }
        guard now.timeIntervalSince(snapshot.writtenAt) < staleAfter else { return .placeholder() }
        let today = utc.startOfDay(for: now)
        // A volume dated in the past by the time this reloads is not "next"
        // any more — the same staleness filter
        // `SeriesWidgetEntryBuilder.makeEntry` applies to `dueThisWeek`.
        let items = snapshot.nextVolumes.filter { utc.startOfDay(for: $0.date) >= today }
        // The gallery preview is drawn repeatedly while the reader scrolls the
        // widget picker; see `SeriesWidgetEntryBuilder.makeEntry`'s identical
        // guard for why that has no business fetching covers each time.
        let covers = isPreview ? [:] : await CoverLoader.covers(for: items)
        return NextVolumeWidgetEntry(date: now, items: items, covers: covers, hasData: true)
    }
}

struct NextVolumeProvider: TimelineProvider {
    func placeholder(in context: Context) -> NextVolumeWidgetEntry { .placeholder() }

    func getSnapshot(in context: Context, completion: @escaping (NextVolumeWidgetEntry) -> Void) {
        let done = Completion(call: completion)
        let isPreview = context.isPreview
        Task { done.call(await NextVolumeEntryBuilder.makeEntry(isPreview: isPreview)) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NextVolumeWidgetEntry>) -> Void) {
        let done = Completion(call: completion)
        Task {
            done.call(Timeline(
                entries: [await NextVolumeEntryBuilder.makeEntry()],
                policy: .after(WidgetRefresh.nextReload())
            ))
        }
    }
}

/// Visually matches `SeriesWidgetView` (same fonts, spacing, cover frame) —
/// not literally reused, because a volume row's second line is composed from
/// a label and a date rather than read as one bare `subtitle` string, and an
/// ANN-sourced row owes a second, independent tap target `SeriesWidgetView`
/// has no reason to carry.
struct NextVolumeWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: NextVolumeWidgetEntry

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

    /// Honest about *why* the list is empty, per this widget's own brief:
    /// coverage is "series opened in the last few hours", not "the library",
    /// per `WidgetSnapshot.nextVolumeCandidates`'s measured coverage — so
    /// "nothing coming up" would be a confident wrong answer for a library
    /// that has real dates the app simply has not looked at lately. Distinct
    /// from `entry.hasData == false` above, which is "no snapshot at all";
    /// this is a real, current snapshot whose list is genuinely empty.
    private var emptyMessage: String {
        "Open a series you're tracking to see its next volume here."
    }

    private func row(_ item: WidgetSnapshotData.NextVolumeEntry) -> some View {
        let subtitle = NextVolumeEntryBuilder.subtitle(for: item)
        return HStack(alignment: .center, spacing: 8) {
            seriesLink(item, subtitle: subtitle)
            // ANN's API terms require a link to *its own* Encyclopedia entry
            // on any page that shows their details
            // (`VolumeCatalogue.requiresPerEntryLink`) — the row's own deep
            // link above opens the series in MangaBaka, which does not
            // satisfy that on its own, so this is a second, sibling `Link`
            // rather than the attribution folded into the row above (widget
            // tap targets can sit beside one another; they cannot nest).
            // `sourceURL` is nil for every candidate this build can actually
            // produce — see `NextVolumeEntry.sourceURL`'s doc comment — so
            // this branch exists for the shape, not for anything reachable
            // today.
            if let sourceURL = item.sourceURL {
                Link(destination: sourceURL) {
                    Text(item.sourceName)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .accessibilityLabel("Source: \(item.sourceName)")
            }
        }
    }

    private func seriesLink(_ item: WidgetSnapshotData.NextVolumeEntry, subtitle: String) -> some View {
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
        // open — same reasoning as `SeriesWidgetView.row(_:)`.
        if let url = SeriesWidgetEntryBuilder.deepLink(for: item.seriesID) {
            return AnyView(Link(destination: url) { content })
        }
        return AnyView(content)
    }

    /// Same fixed 32x44 thumbnail as `SeriesWidgetView.cover(for:)` — see
    /// that type's doc comment for why a widget canvas does not flow with
    /// Dynamic Type the way the rest of the app does.
    @ViewBuilder
    private func cover(for item: WidgetSnapshotData.NextVolumeEntry) -> some View {
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

struct NextVolumeWidget: Widget {
    let kind = "NextVolumeWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NextVolumeProvider()) { entry in
            NextVolumeWidgetView(entry: entry)
        }
        .configurationDisplayName("Next Volume")
        .description("The next volume due for series you've opened recently.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
