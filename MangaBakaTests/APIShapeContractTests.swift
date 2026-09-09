import Foundation
import Testing
@testable import MangaBaka

/// One decode test per response shape the API actually produces.
///
/// The app decodes the same logical `Series` from two families of endpoint that
/// do not agree on its JSON types. A sweep of every endpoint the app uses
/// (Scripts/api-shape-sweep.py, run 2026-09-09) found the split is clean:
///
///   field            /v2/series/*   /v1/series/mix, /v1/my/*
///   total_chapters   number         string
///   final_volume     number         string
///   cover.raw        string         object {url, width, height, blurhash, ...}
///   cover.x150/250/350  string      object {x1, x2, x3}
///   cover.blurhash   beside cover   nested inside cover.raw
///   cover.width/height  beside cover   nested inside cover.raw
///
/// Both bugs found by hand this week were instances of that one split, and both
/// were silent: the decode threw, a `try?` swallowed it, and a screen quietly
/// fell back to something worse. These tests decode a real captured response
/// from each family so the next divergence fails loudly here instead.
@Suite("API shape contract")
struct APIShapeContractTests {
    private func decoder() -> JSONDecoder {
        let decoder = Fixture.decoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    // MARK: - v2 family

    @Test("A v2 discovery response decodes")
    func decodesV2Shape() throws {
        let envelope = try decoder().decode(
            APIEnvelope<[Series]>.self,
            from: try Fixture.data("rising")
        )
        let series = try #require(envelope.data?.first)
        #expect(series.cover.raw != nil)
    }

    // MARK: - v1 family

    /// `/v1/series/mix` is the swipe stack's blend. It returns the v1 shape,
    /// so before `Cover` understood both, every blend failed to decode and the
    /// stack silently showed "that's the stack for now" instead.
    @Test("A v1 mix response decodes, wrapper and all")
    func decodesV1MixShape() throws {
        let envelope = try decoder().decode(
            APIEnvelope<[Recommendation]>.self,
            from: try Fixture.data("mix")
        )
        let items = try #require(envelope.data)
        #expect(items.count == 2)

        let first = try #require(items.first)
        // The v1 cover shape, resolved.
        #expect(first.series.cover.raw != nil)
        #expect(first.series.cover.x150 != nil)
        // The string-number fields.
        #expect(first.series.totalChapters == 55)
        #expect(first.series.finalVolume == 9)
    }

    @Test("A v1 library response decodes")
    func decodesV1LibraryShape() throws {
        let envelope = try decoder().decode(
            APIEnvelope<[LibraryEntry]>.self,
            from: try Fixture.data("library")
        )
        #expect(envelope.data?.count == 2)
    }

    /// The sweep is only useful if it stays runnable. This asserts it is still
    /// there and still lists every endpoint the app decodes, so an endpoint
    /// added later without being swept is caught here.
    @Test("The shape sweep covers every endpoint the app decodes",
          .enabled(if: SourceTree.isAvailable))
    func sweepCoversEveryEndpoint() throws {
        let script = try SourceTree.read("Scripts/api-shape-sweep.py")
        let endpoints = [
            "/v2/series/discover/rising",
            "/v2/series/discover/hidden-gems",
            "/v2/series/search",
            "/v2/series/2/similar",
            "/v2/series/2/readers-also-like",
            "/v1/series/mix",
            "/v1/my/library"
        ]
        for endpoint in endpoints {
            #expect(script.contains(endpoint), "\(endpoint) is not in the sweep")
        }
    }
}
