import Foundation
import Testing
@testable import MangaBaka

/// The cross-target contract for `nextVolumes`, split from
/// `NextVolumeSnapshotTests` for the lint's ceiling on that type.
@Suite("Next volume snapshot — the widget contract")
struct NextVolumeContractTests {
    private let now = Date(timeIntervalSince1970: 1_789_000_000) // a Wednesday, 2026-09-09

    // MARK: - The cross-target contract, extended for nextVolumes

    /// Mirrors `WidgetSnapshotTests.appBytesDecodeAsWidgetData`: proves the
    /// app's bytes decode into the type the widget extension actually reads,
    /// now including `nextVolumes`. Expected to fail before
    /// `WidgetSnapshotData.NextVolumeEntry` existed with a compile error —
    /// the widget target had no field to decode this into at all.
    @Test("nextVolumes crosses into the type the widget extension uses")
    func nextVolumesCrossesTheSeam() throws {
        let entry = WidgetSnapshot.NextVolumeEntry(
            seriesID: 42, title: "Delicious in Dungeon", volumeLabel: "Vol. 12",
            date: now, coverURL: URL(string: "https://example.com/cover.jpg"),
            sourceName: "MangaBaka", sourceURL: nil
        )
        let snapshot = WidgetSnapshot(nextVolumes: [entry], writtenAt: now)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let widgetSide = try decoder.decode(WidgetSnapshotData.self, from: data)

        #expect(widgetSide.nextVolumes.map(\.seriesID) == [42])
        #expect(widgetSide.nextVolumes.map(\.title) == ["Delicious in Dungeon"])
        #expect(widgetSide.nextVolumes.map(\.volumeLabel) == ["Vol. 12"])
        #expect(widgetSide.nextVolumes.first?.date == now)
        #expect(widgetSide.nextVolumes.first?.coverURL == URL(string: "https://example.com/cover.jpg"))
        #expect(widgetSide.nextVolumes.first?.sourceName == "MangaBaka")
        #expect(widgetSide.nextVolumes.first?.sourceURL == nil)
    }

    /// Expected to fail before `WidgetSnapshot.init(from:)` was hand-written
    /// with: `DecodingError.keyNotFound` for `nextVolumes` — a plain
    /// `= []`-defaulted stored property is not consulted by Foundation's
    /// synthesized `Decodable` for a missing key (measured with a throwaway
    /// `Codable` struct, see `WidgetSnapshot.init(from:)`'s doc comment), so
    /// before the hand-written decoder this JSON — exactly what an older
    /// build of the app actually wrote — would have failed the whole decode,
    /// not just left `nextVolumes` empty.
    @Test("A snapshot written before nextVolumes existed still decodes")
    func oldSnapshotStillDecodes() throws {
        let json = """
            {
                "dueThisWeek": [],
                "pickBackUp": [],
                "writtenAt": "\(ISO8601DateFormatter().string(from: now))"
            }
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(WidgetSnapshot.self, from: Data(json.utf8))
        #expect(decoded.nextVolumes.isEmpty)
        #expect(decoded.writtenAt == now)

        // Control: the same file decodes on the widget side too, which reads
        // a separate `Codable` type compiled into a different target.
        let widgetSide = try decoder.decode(WidgetSnapshotData.self, from: Data(json.utf8))
        #expect(widgetSide.nextVolumes.isEmpty)
    }
}
