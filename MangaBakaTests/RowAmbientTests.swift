import Foundation
import Testing
@testable import MangaBaka

/// The covers' colour on the ground behind a row.
@Suite("Row ambient colour")
struct RowAmbientTests {
    /// The DC term of a BlurHash is the image's average colour. "LEHV6nWB"
    /// begins the blurha.sh reference image; its DC decodes to a known
    /// warm grey, and a hash whose DC is all zero is black.
    @Test("The average colour is read from the hash without rendering")
    func averageColour() throws {
        let black = try #require(BlurHash.averageColour(of: "L00000fQfQfQfQfQfQfQfQfQfQfQ"))
        #expect(black.red == 0 && black.green == 0 && black.blue == 0)
        let reference = try #require(BlurHash.averageColour(of: "LEHV6nWB2yk8pyo0adR*.7kCMdnj"))
        #expect(reference.red > reference.blue, "The reference image is warm")
        #expect(BlurHash.averageColour(of: "LEH") == nil)
    }

    private func series(_ id: Int, hash: String?) -> Series {
        SeriesFactory.make(id: id, cover: Cover(
            raw: nil, x150: nil, x250: nil, x350: nil, blurhash: hash, width: nil, height: nil
        ))
    }

    @Test("No hashes, no tint; one hash is enough; the first six are what count")
    func tintRules() {
        #expect(RowAmbient.tint(for: [series(1, hash: nil)]) == nil)
        let black = "L00000fQfQfQfQfQfQfQfQfQfQfQ"
        #expect(RowAmbient.tint(for: [series(1, hash: nil), series(2, hash: black)]) != nil)
        // Six black covers, then a seventh that is not sampled: the tint
        // of the six is black whatever the seventh says.
        let six = (1...6).map { series($0, hash: black) }
        let seventh = series(7, hash: "LEHV6nWB2yk8pyo0adR*.7kCMdnj")
        #expect(RowAmbient.tint(for: six + [seventh]) == RowAmbient.tint(for: six))
    }
}
