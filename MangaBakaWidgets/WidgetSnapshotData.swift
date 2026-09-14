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
    struct Item: Codable, Identifiable, Hashable, Sendable {
        let seriesID: Int
        let title: String
        let subtitle: String
        let coverURL: URL?
        /// The day a `dueThisWeek` row is due; nil for `pickBackUp`.
        /// Optional, so a snapshot written by a build of the app that predates
        /// this field still decodes — `decodeIfPresent` is what the synthesized
        /// decoder uses for an `Optional`, and an old file simply has no key.
        let due: Date?
        var id: Int { seriesID }
    }

    /// Mirrors `WidgetSnapshot.NextVolumeEntry` field for field.
    struct NextVolumeEntry: Codable, Identifiable, Hashable, Sendable {
        let seriesID: Int
        let title: String
        let volumeLabel: String
        let date: Date
        let coverURL: URL?
        let sourceName: String
        let sourceURL: URL?
        var id: Int { seriesID }
    }

    var dueThisWeek: [Item] = []
    var pickBackUp: [Item] = []
    var nextVolumes: [NextVolumeEntry] = []
    var writtenAt: Date

    private enum CodingKeys: String, CodingKey {
        case dueThisWeek, pickBackUp, nextVolumes, writtenAt
    }

    /// **Not what it looks like — measured, 2026-09-14.** A non-Optional
    /// stored property's `= []` default is not consulted by Foundation's
    /// synthesized `Decodable` for a missing key; it throws `keyNotFound`
    /// regardless (verified with a throwaway `Codable` struct decoding `{}`
    /// against a `var list: [Int] = []` field). Left as plain synthesis, a
    /// snapshot written by a build that predates `nextVolumes` would fail
    /// this whole decode the moment the field was added as an ordinary
    /// stored property — and `read()`'s `try?` turns that into "no snapshot
    /// at all", silently discarding `dueThisWeek` and `pickBackUp` too, not
    /// just the new field. `decodeIfPresent(...) ?? []` below is what
    /// actually carries an old file through; `Item.due` right above gets
    /// the same leniency for free only because it is `Optional`-typed, which
    /// synthesis does handle specially.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        dueThisWeek = try container.decode([Item].self, forKey: .dueThisWeek)
        pickBackUp = try container.decode([Item].self, forKey: .pickBackUp)
        nextVolumes = try container.decodeIfPresent([NextVolumeEntry].self, forKey: .nextVolumes) ?? []
        writtenAt = try container.decode(Date.self, forKey: .writtenAt)
    }

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
