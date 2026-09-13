import Foundation

/// Mirrors the JSON shape `WidgetSnapshot` (`MangaBaka/Core/Library/WidgetSnapshot.swift`)
/// writes to the App Group container — declared separately here rather than
/// shared by compiling that file into this target too.
///
/// `WidgetSnapshot` pulls in `ScheduledWork`, `LibraryEntry`, `Series` and
/// `DueThisWeek.FeedDueWork` to build its two lists; those pull in the whole
/// schedule/library/intents graph in turn. A widget extension only ever needs
/// to decode four fields it was handed — linking all of that just to read
/// JSON would make this target's own build cost track the app's, for no
/// benefit to what it draws. The two are kept honest against each other by
/// `WidgetSnapshotTests` (app target), which round-trips the real type
/// through the same field names and the same ISO-8601 date strategy this
/// decodes with.
struct WidgetSnapshotData: Codable {
    struct Item: Codable, Identifiable, Hashable {
        let seriesID: Int
        let title: String
        let subtitle: String
        let coverURL: URL?
        var id: Int { seriesID }
    }

    var dueThisWeek: [Item] = []
    var pickBackUp: [Item] = []
    var writtenAt: Date

    /// Must match `WidgetSnapshot.appGroupID` exactly — see that type's doc
    /// comment for the signing risk (App Groups is a capability the
    /// provisioning profile must carry).
    static let appGroupID = "group.dev.abdirahmanmohamed.mangabaka"
    private static let fileName = "widget-snapshot.json"

    /// Nil when the app has never written (fresh install) or the read or
    /// decode fails — the provider shows the "Open MangaBaka to load"
    /// placeholder for both, since a widget has no way to retry on its own.
    static func read() -> WidgetSnapshotData? {
        guard let containerURL = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID),
            let data = try? Data(contentsOf: containerURL.appendingPathComponent(fileName))
        else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(WidgetSnapshotData.self, from: data)
    }
}
