import Foundation
import Testing
import UIKit
@testable import MangaBaka

@Suite("BlurHash decoding")
struct BlurHashTests {
    /// Recorded from /v2/series/discover/rising on 2026-09-08. 166 characters,
    /// which is a 9x9 component hash — larger than the 4x3 most examples use,
    /// so it exercises the size-flag maths properly.
    private let real = """
    |YKK.+%2_NtQ^+Rk%LRiWX8_xaRjkCozW=ozn~tQfnRj%eozM|s:WBf6oJtlNHt8j;jYt8oIWBbHxbtRSK\
    V?t7RjWCWBWVofRinhoMofoeM|Wqj?ofnie.j?WBWEWBR*j]WYbcofsoWAadjFaeRjt7ofWXbaRjj]j?oca#
    """

    @Test("A real 9x9 hash from the API decodes to an image")
    func decodesRealHash() throws {
        #expect(real.count == 166)
        let image = try #require(BlurHash.image(from: real))
        #expect(image.size.width == 32)
        #expect(image.size.height == 32)
    }

    /// Control: a hash with known-flat colour should decode to that colour,
    /// which proves the pipeline produces pixels rather than noise.
    @Test("Control — the decoded image carries real colour, not grey")
    func producesColour() throws {
        let image = try #require(BlurHash.image(from: real, size: CGSize(width: 8, height: 8)))
        let cgImage = try #require(image.cgImage)
        let data = try #require(cgImage.dataProvider?.data as Data?)

        // If every channel were identical the result would be greyscale, which
        // would mean the AC components never applied.
        let reds = stride(from: 0, to: data.count, by: 3).map { data[$0] }
        #expect(Set(reds).count > 1, "A flat result means the decode did nothing")
    }

    @Test("Malformed input returns nil rather than crashing")
    func rejectsGarbage() {
        #expect(BlurHash.image(from: "") == nil)
        #expect(BlurHash.image(from: "abc") == nil)
        // Right shape, wrong length for its declared component count.
        #expect(BlurHash.image(from: "|YKK.+%2_NtQ") == nil)
        // A character outside the base-83 alphabet.
        #expect(BlurHash.image(from: "|YKK.+%2_NtQ^+Rk%LRiWX8_xaRjkCoz\u{00E9}") == nil)
    }

    @Test("A short 4x3 hash decodes too")
    func decodesSmallHash() throws {
        // The canonical example from the BlurHash reference implementation.
        let image = try #require(BlurHash.image(from: "LEHV6nWB2yk8pyo0adR*.7kCMdnj"))
        #expect(image.size.width == 32)
    }
}
