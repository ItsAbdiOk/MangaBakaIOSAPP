import Foundation
import Testing
@testable import MangaBaka

/// The control suite runs first by convention: it decodes a fixture whose
/// answers are known by construction. If the control fails, no other result in
/// this file means anything.
@Suite("Decoding — control")
struct ControlDecodingTests {
    @Test("Control fixture decodes to its known values")
    func controlDecodes() throws {
        let envelope = try Fixture.decoder()
            .decode(APIEnvelope<[Series]>.self, from: Fixture.data("control"))

        #expect(envelope.status == 200)
        let series = try #require(envelope.data)
        #expect(series.count == 2)

        let first = series[0]
        #expect(first.id == 1)
        #expect(first.state == "active")
        #expect(first.rating == 80)
        #expect(first.cover.width == 200)
        #expect(first.cover.height == 300)
        #expect(first.cover.aspectRatio == 200.0 / 300.0)
    }

    @Test("A series with every optional absent still decodes")
    func allOptionalsNull() throws {
        let envelope = try Fixture.decoder()
            .decode(APIEnvelope<[Series]>.self, from: Fixture.data("control"))
        let merged = try #require(envelope.data?[1])

        #expect(merged.titles == nil)
        #expect(merged.displayTitle == nil)
        #expect(merged.cover.aspectRatio == nil)
        #expect(merged.isDiscoverable == false)
        #expect(merged.mergedWith == 1)
    }
}

@Suite("Decoding — real API response")
struct RealResponseDecodingTests {
    /// Recorded from `GET /v2/series/discover/rising?limit=3` on 2026-09-08.
    /// Its purpose is to fail when MangaBaka changes the response shape.
    @Test("Recorded rising response decodes")
    func risingDecodes() throws {
        let envelope = try Fixture.decoder()
            .decode(APIEnvelope<[Series]>.self, from: Fixture.data("rising"))

        #expect(envelope.status == 200)
        let series = try #require(envelope.data)
        #expect(series.count == 3)
        #expect(series.allSatisfy { $0.id > 0 })
        #expect(series.allSatisfy { $0.displayTitle != nil })
    }

    /// The live response carries `canonical_url`, which the published OpenAPI
    /// spec does not document. Decoding must tolerate keys the spec omits.
    @Test("Undocumented response keys do not break decoding")
    func toleratesUndocumentedKeys() throws {
        let raw = try Fixture.data("rising")
        let json = try #require(
            try JSONSerialization.jsonObject(with: raw) as? [String: Any]
        )
        let first = try #require((json["data"] as? [[String: Any]])?.first)
        #expect(first["canonical_url"] != nil, "Fixture no longer exercises the undocumented key")

        // Decoding the same bytes must still succeed.
        _ = try Fixture.decoder().decode(APIEnvelope<[Series]>.self, from: raw)
    }
}
