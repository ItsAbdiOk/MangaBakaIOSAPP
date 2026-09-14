import Compression
import Foundation
import Testing
@testable import MangaBaka

/// Tests for the review's F11 fix (persistence review, 2026-09-14):
/// `OfflineCatalogue.load` used to report a missing or corrupt bundled
/// resource as an empty index through three `try?` in a row, with no logger
/// — a packaging mistake read as "offline browse has nothing" with nothing
/// in the console. It also decoded `Wire.version` and never checked it, so a
/// version-2 export would decode to nonsense (or fail `Wire` decoding and
/// read as "missing") silently.
///
/// What this file can and cannot prove, honestly: it proves the *behavioural*
/// half — a missing or version-mismatched resource still answers an empty,
/// non-crashing index — since that is observable through `OfflineCatalogue`'s
/// public methods. It does **not** prove the *logging* half (a
/// `Logger.error` call actually fires): `os.Logger` has no readback API a
/// unit test can assert against, and this project has no logging
/// abstraction the tests would need to fake `Logger.error` out through. So
/// "logs once" from the work list's TEST note is verified by reading
/// `OfflineCatalogue.swift`'s `catch` block (one `logger.error` call, no
/// loop, no per-caller repeat) rather than by an assertion here — recorded
/// as unverified-by-test, not silently assumed.
///
/// Kept separate from `OfflineCatalogueTests` (this lane owns
/// `OfflineCatalogue.swift` but not the existing test file).
@Suite("Offline catalogue: load failures (F11)")
struct OfflineCatalogueLoadFailureTests {
    // MARK: - Missing resource

    @Test("A resource name matching nothing in the bundle answers an empty, non-crashing index")
    func missingResourceAnswersEmpty() async {
        let catalogue = OfflineCatalogue(
            resourceName: "ThisResourceDoesNotExist_\(UUID().uuidString)",
            resourceExtension: "json.gz",
            bundle: .main
        )
        let total = await catalogue.totalCount()
        #expect(total == nil, "totalCount() distinguishes 'failed to load' (nil) from 'genuinely empty' (0)")
        let built = await catalogue.builtDate()
        #expect(built == nil)
        let titles = await catalogue.titles(for: [3397])
        #expect(titles.isEmpty)
    }

    // MARK: - Version mismatch

    /// Builds a real, valid gzip file (via `Compression`'s own encoder, the
    /// mirror image of what `Gunzip` decodes, plus a CRC32 from `Gunzip`
    /// itself — the same table-driven implementation added for F3, reused
    /// here rather than re-derived) whose JSON payload declares
    /// `"version": 2`. This is the shape F11 says decodes to nonsense or
    /// silence today; after the fix it must be refused outright.
    @Test("A well-formed export declaring an unsupported version answers an empty index, not nonsense")
    func unsupportedVersionAnswersEmpty() async throws {
        let json = """
        {"version":2,"built":"2099-01-01","source":"test","series":[]}
        """
        let gzipped = Self.gzip(Data(json.utf8))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("OfflineIndexV2.json.gz")
        try gzipped.write(to: fileURL)

        // `Bundle(url:)` wraps an arbitrary directory as a resource bundle;
        // `url(forResource:withExtension:)` on it searches that directory's
        // own top level, which is where the file above was just written.
        let bundle = try #require(Bundle(url: directory))
        let catalogue = OfflineCatalogue(
            resourceName: "OfflineIndexV2", resourceExtension: "json.gz", bundle: bundle
        )

        let total = await catalogue.totalCount()
        #expect(total == nil, "a version this reader does not understand must not report a count")
        let built = await catalogue.builtDate()
        #expect(built == nil, "not \"2099-01-01\" — that would mean the mismatched version was used anyway")
    }

    // MARK: - Gzip fixture builder

    /// The inverse of `Gunzip.decompress`, built only for this test: a
    /// minimal but real gzip stream (no optional header sections) with a
    /// correct CRC32 and ISIZE, so the fixture exercises `OfflineCatalogue`
    /// through the real `Gunzip.decompress` call rather than bypassing it.
    private static func gzip(_ payload: Data) -> Data {
        let bytes = [UInt8](payload)
        let bufferSize = bytes.count + 128
        var destination = [UInt8](repeating: 0, count: bufferSize)
        let compressedSize = bytes.withUnsafeBufferPointer { source -> Int in
            destination.withUnsafeMutableBufferPointer { dest -> Int in
                guard let sourceBase = source.baseAddress, let destBase = dest.baseAddress else { return 0 }
                return compression_encode_buffer(
                    destBase, bufferSize, sourceBase, source.count, nil, COMPRESSION_ZLIB
                )
            }
        }
        var gzipBytes: [UInt8] = [0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff]
        gzipBytes.append(contentsOf: destination.prefix(compressedSize))
        appendLE(Gunzip.crc32(bytes), to: &gzipBytes)
        appendLE(UInt32(bytes.count), to: &gzipBytes)
        return Data(gzipBytes)
    }

    private static func appendLE(_ value: UInt32, to bytes: inout [UInt8]) {
        for shift in stride(from: 0, to: 32, by: 8) {
            bytes.append(UInt8((value >> shift) & 0xFF))
        }
    }
}
