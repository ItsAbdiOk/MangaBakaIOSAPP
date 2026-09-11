import Foundation
import Testing
@testable import MangaBaka

@Suite("Cover variant selection")
struct CoverTests {
    private let cover = Cover(
        raw: URL(string: "https://example.invalid/raw.jpg"),
        x150: URL(string: "https://example.invalid/x150@1/a.jpg"),
        x250: URL(string: "https://example.invalid/x250@1/a.jpg"),
        x350: URL(string: "https://example.invalid/x350@1/a.jpg"),
        blurhash: nil,
        width: 200,
        height: 300
    )

    /// Pixel height of the rendering a URL names: `x250@3` is 750 px tall.
    private func pixels(_ url: URL?) -> Int? {
        guard let text = url?.absoluteString,
              let match = text.firstMatch(of: /x(\d+)@(\d)/),
              let base = Int(match.1), let ratio = Int(match.2)
        else { return nil }
        return base * ratio
    }

    @Test("Picks the variant matching the requested height")
    func picksVariant() {
        #expect(cover.url(forHeight: 100, scale: 1)?.absoluteString.contains("x150") == true)
        #expect(cover.url(forHeight: 250, scale: 1)?.absoluteString.contains("x250") == true)
        #expect(pixels(cover.url(forHeight: 400, scale: 1)) == 450)
    }

    /// The variant used to be picked by point height and then scaled by the
    /// screen regardless, so a 78pt thumbnail on a 3x screen fetched the 150pt
    /// variant at @3 — 450 px for 234 px drawn, 3.7x the pixels. The rendering
    /// is now the smallest one that covers the pixels actually drawn.
    @Test("Fetches the smallest rendering that covers the drawn pixels")
    func smallestSufficientRendering() throws {
        let sizes: [(points: Double, scale: Double)] = [
            (Metrics.coverUpcomingThumb / Metrics.coverAspect, 3),
            (Metrics.coverSavedStripWidth / Metrics.coverAspect, 3),
            (Metrics.coverSeedWidth / Metrics.coverAspect, 3),
            (Metrics.coverRowWidth / Metrics.coverAspect, 3),
            (Metrics.coverDetailHeroWidth / Metrics.coverAspect, 3),
            (Metrics.coverRowWidth / Metrics.coverAspect, 2)
        ]
        for size in sizes {
            let drawn = size.points * size.scale
            let fetched = try #require(pixels(cover.url(forHeight: size.points, scale: size.scale)))
            #expect(Double(fetched) >= drawn, "\(size) fetched \(fetched) px for \(drawn) drawn")
            #expect(
                Double(fetched) / drawn < 1.5,
                "\(size) fetched \(fetched) px for \(drawn) drawn: more than half again"
            )
        }
    }

    @Test("Nothing larger than the largest rendering is ever asked for")
    func capsAtLargestRendering() {
        #expect(pixels(cover.url(forHeight: 2000, scale: 3)) == 1050)
    }

    /// The API documents swapping `@1` for `@2`/`@3` to request higher DPR.
    @Test("Requests a higher DPR rendering on retina screens")
    func swapsDevicePixelRatio() {
        #expect(cover.url(forHeight: 250, scale: 3)?.absoluteString.contains("x250@3") == true)
        #expect(cover.url(forHeight: 250, scale: 2)?.absoluteString.contains("x250@2") == true)
    }

    @Test("Caps device pixel ratio at the 3x the API supports")
    func capsDevicePixelRatio() {
        #expect(cover.url(forHeight: 250, scale: 4)?.absoluteString.contains("@3") == true)
    }

    @Test("Falls back to the raw image when no variant exists")
    func fallsBackToRaw() {
        let sparse = Cover(
            raw: URL(string: "https://example.invalid/raw.jpg"),
            x150: nil, x250: nil, x350: nil,
            blurhash: nil, width: nil, height: nil
        )
        #expect(sparse.url(forHeight: 250, scale: 2)?.absoluteString.hasSuffix("raw.jpg") == true)
        #expect(sparse.aspectRatio == nil)
    }
}
