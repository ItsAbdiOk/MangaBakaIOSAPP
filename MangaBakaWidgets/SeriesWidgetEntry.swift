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
    /// How old a snapshot may be before the widget stops claiming to know
    /// anything. Seven days, matching `DueThisWeek.window` — past that every
    /// row in `dueThisWeek` is about a week that has already happened.
    ///
    /// The widget reloads hourly, which made a stale snapshot look freshly
    /// computed: it kept drawing "Due Thursday" from a string baked during
    /// whatever manual schedule build last ran, pointing at a day that had
    /// passed. The date is now carried as a `Date` (`Item.due`) and rows in
    /// the past are dropped; this is the backstop for a snapshot so old that
    /// dropping the past rows would leave a misleadingly confident "nothing
    /// due" instead of "I have not been told lately".
    static let staleAfter: TimeInterval = 7 * 86_400

    /// UTC, not the device's calendar: `due` is a UTC midnight all the way
    /// back to MangaUpdates' `release_date`, and reading it in a local
    /// calendar west of UTC names the previous weekday.
    private static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }

    /// What a row's second line says.
    ///
    /// A row with a `due` gets its weekday formatted here, now, from the date
    /// — never from a string the app baked days ago. `subtitle` then carries
    /// only what cannot go stale: the feed's name, or a chapter number.
    static func subtitle(for item: WidgetSnapshotData.Item) -> String {
        guard let due = item.due else { return item.subtitle }
        let day = due.formatted(Date.FormatStyle(timeZone: .gmt).weekday(.wide))
        return item.subtitle.isEmpty ? "Due \(day)" : "Due \(day) · \(item.subtitle)"
    }

    static func makeEntry(
        items keyPath: (WidgetSnapshotData) -> [WidgetSnapshotData.Item],
        now: Date = .now,
        isPreview: Bool = false
    ) async -> SeriesWidgetEntry {
        guard let snapshot = WidgetSnapshotData.read() else { return .placeholder() }
        guard now.timeIntervalSince(snapshot.writtenAt) < staleAfter else { return .placeholder() }
        let today = utc.startOfDay(for: now)
        // A dated row whose day has passed is not news; an undated row
        // (`pickBackUp`) has no day to have passed.
        let items = keyPath(snapshot).filter { item in
            guard let due = item.due else { return true }
            return utc.startOfDay(for: due) >= today
        }
        // The gallery preview is drawn repeatedly while the reader scrolls the
        // widget picker; it has no business fetching four covers each time.
        let covers = isPreview ? [:] : await CoverLoader.covers(for: items)
        return SeriesWidgetEntry(date: now, items: items, covers: covers, hasData: true)
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
