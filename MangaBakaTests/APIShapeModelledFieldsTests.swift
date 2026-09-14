import Foundation
import Testing
@testable import MangaBaka

/// Keeps `Scripts/api-shape-sweep.py`'s field list from silently drifting
/// away from `Series`'s real fields.
///
/// docs/reviews/full/SUMMARY.md item 135: the script's `MODELLED` array was a
/// hand-typed copy of `Series`'s properties, with nothing tying the two
/// together — a field renamed, or added and never added here, left the sweep
/// silently comparing the wrong (or an incomplete) set of names against the
/// live API, the one place this project has already lost a shape divergence
/// to before `RequestSpacing`/`Cover`'s dual-shape decoding existed. This test
/// writes the real set to disk instead, so the script can read it, dated
/// 2026-09-14.
///
/// Skipped where the checkout is not on disk (`SourceTree.isAvailable`) — the
/// same reason `BlockedTagsDiscoverabilityTests` skips there; the sweep
/// script itself is a local/CI developer tool, never run on device, so there
/// is no case where this file needs to exist but the checkout does not.
@Suite("Series fields, for the API shape sweep", .enabled(if: SourceTree.isAvailable))
struct APIShapeModelledFieldsTests {
    /// A `CodingKey` built from a runtime string, so a property's own Swift
    /// name (from `Mirror`, not a literal) can be run through the exact same
    /// `JSONEncoder.keyEncodingStrategy` production decoding relies on,
    /// rather than a second, hand-rolled camelCase-to-snake_case function that
    /// could itself drift from Foundation's.
    private struct DynamicKey: CodingKey {
        var stringValue: String
        init?(stringValue: String) { self.stringValue = stringValue }
        var intValue: Int? { nil }
        init?(intValue: Int) { nil }
    }

    private struct SingleKeyEncodable: Encodable {
        let label: String
        func encode(to encoder: Encoder) throws {
            // `DynamicKey.init?(stringValue:)` never actually fails — every
            // `String` is a valid `stringValue` — but the protocol still
            // spells it as failable, so this is `guard let`, not `!`.
            guard let key = DynamicKey(stringValue: label) else {
                throw EncodingError.invalidValue(label, .init(
                    codingPath: [], debugDescription: "Not a valid coding key: \(label)"
                ))
            }
            var container = encoder.container(keyedBy: DynamicKey.self)
            try container.encode(1, forKey: key)
        }
    }

    /// The wire name Foundation's `.convertToSnakeCase` gives a Swift property
    /// name — `mergedWith` -> `merged_with`, `x150` -> `x150` unchanged.
    private func snakeCaseKey(for label: String) throws -> String {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(SingleKeyEncodable(label: label))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(object.keys.first)
    }

    /// `Mirror`, not an encoded instance's own JSON: an `Optional` property
    /// left `nil` is a real stored property that `Series`'s synthesised
    /// `encode(to:)` (via `encodeIfPresent`) would simply omit from the JSON,
    /// which would make this list only as complete as whichever placeholder
    /// values happened to be filled in above — silently dropping any future
    /// optional field nobody remembered to give a non-nil value in a test.
    /// `Mirror` reports every stored property regardless of its value, so a
    /// new field costs nothing here.
    @Test("Series's own field names are written for Scripts/api-shape-sweep.py to read")
    func writesModelledFields() throws {
        let series = SeriesFactory.make(cover: .sized)
        let topLevel = Mirror(reflecting: series).children.compactMap(\.label)
        let coverFields = Mirror(reflecting: series.cover).children.compactMap(\.label)

        var fields = try topLevel.map(snakeCaseKey(for:))
        let coverKeys = try coverFields.map(snakeCaseKey(for:))
        fields += coverKeys.map { "cover.\($0)" }
        fields.sort()

        // Sanity: fields that must be in the list, or the encoder above has
        // silently stopped doing its job.
        #expect(fields.contains("content_rating"))
        #expect(fields.contains("merged_with"))
        #expect(fields.contains("cover.blurhash"))
        #expect(fields.contains("cover.x150"))

        let payload = try JSONEncoder().encode(fields)
        let directory = URL(fileURLWithPath: "\(SourceTree.root)/Scripts/generated")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try payload.write(to: directory.appendingPathComponent("series-modelled-fields.json"))
    }
}
