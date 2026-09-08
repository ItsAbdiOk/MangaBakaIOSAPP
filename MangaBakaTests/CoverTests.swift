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

    @Test("Picks the variant matching the requested height")
    func picksVariant() {
        #expect(cover.url(forHeight: 100, scale: 1)?.absoluteString.contains("x150") == true)
        #expect(cover.url(forHeight: 250, scale: 1)?.absoluteString.contains("x250") == true)
        #expect(cover.url(forHeight: 400, scale: 1)?.absoluteString.contains("x350") == true)
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
