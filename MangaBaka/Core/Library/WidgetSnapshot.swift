import Foundation
import WidgetKit

/// Everything a Home Screen widget shows, written to the App Group container
/// so the widget extension — a separate process with no access to the app's
/// own sandboxed container, database, or `URLCache` — has something to read.
///
/// A widget's `TimelineProvider` runs on the system's own schedule, not the
/// app's, so this is written eagerly by the app itself right after the two
/// pipelines that produce its contents finish: the library walk (for
/// `pickBackUp`) and a schedule build (for `dueThisWeek`). `write(...)` merges
/// rather than replaces, because those two finish independently and neither
/// should blank out what the other already wrote.
///
/// Kept to exactly what the widget draws — a title, one subtitle line, and a
/// cover URL — so a change to how `Series` or `ScheduledWork` are shaped
/// elsewhere in the app cannot silently break the widget's JSON decode.
struct WidgetSnapshot: Codable, Sendable, Equatable {
    struct Item: Codable, Sendable, Equatable, Identifiable, Hashable {
        let seriesID: Int
        let title: String
        /// e.g. "Due Thursday" or "Ch. 88 of 120". Built by whichever `Item`
        /// factory below produced this row — the widget renders exactly this
        /// string rather than reformatting a date or a chapter number itself,
        /// the same reason `SpotlightIndex.description(for:)` is built once
        /// and handed over as text instead of recomputed per presentation.
        let subtitle: String
        let coverURL: URL?

        var id: Int { seriesID }
    }

    var dueThisWeek: [Item] = []
    var pickBackUp: [Item] = []
    var writtenAt: Date

    /// The App Group both the app and `MangaBakaWidgets` are entitled to.
    ///
    /// **A guess at signing, not at the spelling** — the identifier mirrors
    /// `PRODUCT_BUNDLE_IDENTIFIER`'s own prefix (`dev.abdirahmanmohamed.mangabaka`),
    /// which is exact. What is unconfirmed is provisioning: App Groups is a
    /// capability the profile must carry, and if Xcode Cloud's first archive
    /// fails on entitlements, the fix is enabling "App Groups" for this App ID
    /// in the developer portal — automatic signing on a local build adds it
    /// without asking, but Xcode Cloud does not carry that same door.
    static let appGroupID = "group.dev.abdirahmanmohamed.mangabaka"

    private static let fileName = "widget-snapshot.json"

    private static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Merges whichever of the two lists changed into whatever is already on
    /// disk, so the library walk finishing does not blank out the last
    /// schedule build's `dueThisWeek` (or vice versa), and asks WidgetKit to
    /// redraw every widget on the Home Screen.
    ///
    /// Silent on failure — a missing App Group entitlement or a full disk
    /// leaves the widget showing whatever it last had (or the "Open
    /// MangaBaka to load" placeholder on a fresh install), rather than the
    /// app surfacing an error for a screen it does not own.
    static func write(
        dueThisWeek: [Item]? = nil,
        pickBackUp: [Item]? = nil,
        clock: any Clock = SystemClock()
    ) {
        guard let containerURL else { return }
        var snapshot = read() ?? WidgetSnapshot(writtenAt: clock.now)
        if let dueThisWeek { snapshot.dueThisWeek = dueThisWeek }
        if let pickBackUp { snapshot.pickBackUp = pickBackUp }
        snapshot.writtenAt = clock.now
        guard let data = try? encoder.encode(snapshot) else { return }
        try? data.write(to: containerURL.appendingPathComponent(fileName), options: .atomic)
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// What the widget extension reads. Nil before the app has ever written
    /// (fresh install) or if the file cannot be read or decoded — both cases
    /// the provider shows as the placeholder rather than an error, since a
    /// widget has no way to retry on its own.
    static func read() -> WidgetSnapshot? {
        guard let containerURL,
              let data = try? Data(contentsOf: containerURL.appendingPathComponent(fileName))
        else { return nil }
        return try? decoder.decode(WidgetSnapshot.self, from: data)
    }

    // MARK: - Building the two lists

    /// Due within the next seven days, soonest first — feed-sourced real
    /// dates (`DueThisWeekIntent.feedDueWorks`) ahead of MangaUpdates
    /// estimates for the same window, matching the order `DueThisWeek`
    /// speaks them in so the widget and Siri never disagree about what is
    /// due first.
    static func dueThisWeekItems(
        dated: [ScheduledWork],
        feedWorks: [DueThisWeek.FeedDueWork] = [],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [Item] {
        let today = calendar.startOfDay(for: now)
        guard let end = calendar.date(byAdding: .day, value: DueThisWeek.window, to: today) else { return [] }

        var seen: Set<Int> = []
        var items: [(item: Item, due: Date)] = []

        for work in feedWorks.sorted(by: { $0.due < $1.due }) {
            let day = calendar.startOfDay(for: work.due)
            guard day < end, seen.insert(work.seriesId).inserted else { continue }
            items.append((
                Item(
                    seriesID: work.seriesId, title: work.title,
                    subtitle: "Due \(weekday(day)) · \(work.sourceName)",
                    coverURL: nil
                ),
                day
            ))
        }

        let sortedDated = dated
            .compactMap { work -> (ScheduledWork, Date)? in
                guard let cadence = work.cadence else { return nil }
                return (work, calendar.startOfDay(for: cadence.due))
            }
            .sorted { $0.1 < $1.1 }
        for (work, day) in sortedDated {
            guard day < end, seen.insert(work.series.id).inserted else { continue }
            items.append((
                Item(
                    seriesID: work.series.id,
                    title: work.series.displayTitle ?? "Untitled series",
                    subtitle: "Due \(weekday(day))",
                    coverURL: work.series.cover.x250 ?? work.series.cover.x350 ?? work.series.cover.raw
                ),
                day
            ))
        }

        return items.sorted { $0.due < $1.due }.map(\.item)
    }

    /// **A guess at the threshold** — fourteen days chosen because it is
    /// roughly two weeks of ordinary reading without an obvious measurement
    /// to derive it from. Reading, and either never opened on this device or
    /// not opened in at least that long — a series opened yesterday is not
    /// something the reader needs reminding of.
    static let pickBackUpThreshold: TimeInterval = 14 * 86_400

    /// - Parameter lastOpened: from `HistoryStore`, keyed by series id. A
    ///   series with no entry has never been opened on this device and is
    ///   treated as eligible, the same as one opened long enough ago.
    static func pickBackUpItems(
        from entries: [LibraryEntry],
        lastOpened: [Int: Date],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [Item] {
        entries
            .filter { $0.state == .reading }
            .compactMap { entry -> (Item, Date)? in
                let opened = lastOpened[entry.seriesId]
                if let opened, now.timeIntervalSince(opened) < pickBackUpThreshold { return nil }
                guard let series = entry.series else { return nil }
                let subtitle: String
                if let chapter = entry.progressChapter, chapter > 0 {
                    let total = series.totalChapters.map { " of \(Int(wholeOrClamped: $0))" } ?? ""
                    subtitle = "Ch. \(Int(wholeOrClamped: chapter))\(total)"
                } else {
                    subtitle = "Pick back up"
                }
                let item = Item(
                    seriesID: entry.seriesId,
                    title: series.displayTitle ?? "Untitled series",
                    subtitle: subtitle,
                    coverURL: series.cover.x250 ?? series.cover.x350 ?? series.cover.raw
                )
                // Never-opened entries sort last: there is no date to rank
                // them by, and a series the reader has actually let sit is a
                // stronger "pick this back up" candidate than one with no
                // signal either way.
                return (item, opened ?? .distantPast)
            }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }

    /// Matches `DueThisWeek.when`'s own formatting, so a date the widget and
    /// Siri both mention reads the same way in both places.
    private static func weekday(_ day: Date) -> String {
        day.formatted(.dateTime.weekday(.wide))
    }
}
