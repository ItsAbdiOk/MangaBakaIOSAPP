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
    ///
    /// `mix.json` was captured from `GET /v1/series/mix` on 2026-09-09 (the
    /// commit that added it, 79f8254) and then redacted: series ids rewritten
    /// to 2000 and 2001, `shared_tags` emptied. The tracker ids, thumbhashes
    /// and the `score`/`cosine` pair are the real response's. It was the one
    /// fixture with no date on it, which is how a shape change on the stack's
    /// only source would have gone unnoticed for as long as the fixture lived.
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

    /// The sweep's job is the series-shaped endpoints: the ones whose payload
    /// carries a `Series`, which is where the v1/v2 type split lives. The list
    /// is read out of the app's own source rather than typed here, so a new
    /// series endpoint fails this test until the sweep knows about it. It used
    /// to be seven names typed by hand, which is how the claim "covers every
    /// endpoint" stayed true while the app grew to twenty-six.
    ///
    /// The other endpoints decode other shapes and are covered by their own
    /// decode tests: works and upcoming (SeriesWorkTests, ReleaseCalendarTests),
    /// links/news/relationships (SeriesExtrasTests), images
    /// (CoverGalleryTests), genres/tags/publishers (CatalogueTests),
    /// top-genres and recommendations (LibraryTests), and the nullable fields
    /// of each (WireNullabilityTests).
    @Test("The shape sweep covers every series-shaped endpoint in the source",
          .enabled(if: SourceTree.isAvailable))
    func sweepCoversEverySeriesEndpoint() throws {
        let script = try SourceTree.read("Scripts/api-shape-sweep.py")
        let inSource = try Self.seriesEndpoints(in: SourceTree.swiftFiles(under: "MangaBaka"))
        #expect(inSource.count >= 7, "Fewer endpoints found than the old hand-typed list had")
        for endpoint in inSource {
            #expect(script.contains(endpoint), "\(endpoint) is decoded by the app and not in the sweep")
        }
    }

    /// Every `"/vN/..."` literal in the given files whose response carries a
    /// `Series`, with interpolated ids replaced by the sweep's sample id.
    static func seriesEndpoints(in files: [String]) throws -> Set<String> {
        var found: Set<String> = []
        for file in files {
            let text = try SourceTree.read(file)
            for match in text.matches(of: /"(\/v[0-9]\/[^"]*)"/) {
                let path = String(match.1).replacing(/\\\([a-zA-Z]+\)/, with: "2")
                let isSeriesShaped = path.hasPrefix("/v2/series/")
                    || path == "/v1/series/mix"
                    || path == "/v1/my/library"
                if isSeriesShaped { found.insert(path) }
            }
        }
        return found
    }
}
