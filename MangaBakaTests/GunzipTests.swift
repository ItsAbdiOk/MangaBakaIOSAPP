import Foundation
import Testing
@testable import MangaBaka

/// `Gunzip` on small, hand-built fixtures rather than only the real 1.4MB
/// resource — a header-parsing bug could easily happen to work on one real
/// file and not on the format's own optional sections.
@Suite("Gunzip")
struct GunzipTests {
    /// gzip of "hello gzip world", produced by Python's `gzip` module
    /// (`mtime=0`, no filename) — the plainest possible header: no FEXTRA, no
    /// FNAME, no FCOMMENT, no FHCRC.
    private static let plain: [UInt8] = [
        0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0xff, 0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0x57,
        0x48, 0xaf, 0xca, 0x2c, 0x50, 0x28, 0xcf, 0x2f, 0xca, 0x49, 0x01, 0x00, 0x6b, 0x7d, 0xe8, 0xb7,
        0x10, 0x00, 0x00, 0x00
    ]

    /// gzip of "named stream payload" with `filename: "test.txt"` set, so the
    /// FNAME bit is on and the header carries a real, non-empty name field —
    /// the branch `plain` above cannot exercise at all.
    private static let named: [UInt8] = [
        0x1f, 0x8b, 0x08, 0x08, 0x00, 0x00, 0x00, 0x00, 0x02, 0xff, 0x74, 0x65, 0x73, 0x74, 0x2e, 0x74,
        0x78, 0x74, 0x00, 0xcb, 0x4b, 0xcc, 0x4d, 0x4d, 0x51, 0x28, 0x2e, 0x29, 0x4a, 0x4d, 0xcc, 0x55,
        0x28, 0x48, 0xac, 0xcc, 0xc9, 0x4f, 0x4c, 0x01, 0x00, 0x29, 0x02, 0x57, 0xc3, 0x14, 0x00, 0x00,
        0x00
    ]

    @Test("A plain gzip stream with no optional header sections decodes")
    func decodesPlainStream() throws {
        let decoded = try Gunzip.decompress(Data(Self.plain))
        #expect(String(data: decoded, encoding: .utf8) == "hello gzip world")
    }

    @Test("A gzip stream carrying a filename (FNAME) still decodes to the payload only")
    func decodesStreamWithName() throws {
        let decoded = try Gunzip.decompress(Data(Self.named))
        #expect(String(data: decoded, encoding: .utf8) == "named stream payload")
    }

    @Test("Data with no gzip magic bytes is refused rather than misread")
    func rejectsNonGzipData() {
        #expect(throws: Gunzip.Failure.notGzip) {
            try Gunzip.decompress(Data("not a gzip file at all, just text".utf8))
        }
    }

    /// Control for the two decode tests above: the same technique this app
    /// uses to build `OfflineIndex.json.gz` (Python's `gzip` module) must be
    /// what these fixtures were made with, or a pass here would prove nothing
    /// about the real resource.
    @Test("The fixtures really are gzip, per the format's own magic bytes")
    func fixturesCarryGzipMagic() {
        #expect(Self.plain.prefix(3) == [0x1f, 0x8b, 0x08])
        #expect(Self.named.prefix(3) == [0x1f, 0x8b, 0x08])
    }
}
