import UIKit
import WidgetKit

/// One rendered timeline entry, shared by both widgets — they differ only in
/// which half of `WidgetSnapshotData` fills `items`.
struct SeriesWidgetEntry: TimelineEntry {
    let date: Date
    let items: [WidgetSnapshotData.Item]
    let covers: [Int: UIImage]
    /// False only when the app has never written a snapshot at all — the
    /// placeholder case. An empty `items` with `hasData: true` is a real
    /// answer ("nothing due", "nothing to pick back up"), not a failure.
    let hasData: Bool

    static func placeholder() -> SeriesWidgetEntry {
        SeriesWidgetEntry(date: .now, items: [], covers: [:], hasData: false)
    }
}

/// Reloaded on an hourly timer. **A guess** — neither list changes faster
/// than that in practice (a schedule build is a manual, minutes-long action;
/// a release feed refreshes at most daily), so this is chosen only to keep a
/// widget left open on a Home Screen from looking abandoned for a whole day,
/// not derived from how often either source actually changes.
enum WidgetRefresh {
    static let interval: TimeInterval = 3600

    static func nextReload(after date: Date = .now) -> Date {
        date.addingTimeInterval(interval)
    }
}

enum SeriesWidgetEntryBuilder {
    static func makeEntry(
        items keyPath: (WidgetSnapshotData) -> [WidgetSnapshotData.Item]
    ) async -> SeriesWidgetEntry {
        guard let snapshot = WidgetSnapshotData.read() else { return .placeholder() }
        let items = keyPath(snapshot)
        let covers = await CoverLoader.covers(for: items)
        return SeriesWidgetEntry(date: .now, items: items, covers: covers, hasData: true)
    }

    /// `mangabaka://series/<id>` — built rather than force-unwrapped, since a
    /// series id ultimately comes from the reader's own library data and this
    /// file follows the same no-force-unwrap rule as the app.
    static func deepLink(for seriesID: Int) -> URL? {
        URL(string: "mangabaka://series/\(seriesID)")
    }
}

/// WidgetKit's completion handlers are documented as callable from any
/// thread, but their type is not `Sendable`, so handing one into a `Task`
/// is a Swift 6 error. This box carries the promise the framework already
/// makes. `TimelineProvider` has no async variant to reach for (only
/// `AppIntentTimelineProvider` does).
struct Completion<Value>: @unchecked Sendable {
    let call: (Value) -> Void
}
