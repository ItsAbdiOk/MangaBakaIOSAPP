import Compression
import Foundation
import Testing
@testable import MangaBaka

/// Two bundled binaries parsed by hand, and what each does with a value the
/// generator should never have produced.
///
/// Both are *build* hazards rather than network ones — the files ship with the
/// app — but a broken build that traps on every launch is strictly worse than
/// one that logs and shows no "similar by description" row, which is what the
/// rest of both files is carefully built to do. `Gunzip` learned this on
/// 2026-09-14; these two did not (work-list 52, 53).
@Suite("Bundled files fail by throwing, not by trapping")
struct OfflineTrapTests {
    // MARK: - Work-list 52: EmbeddingIndex's header

    /// EXPECTED TO FAIL ON THE OLD CODE by **trapping, not by failing an
    /// assertion**: `count` and `dims` were read straight out of the header
    /// and `vectorsStart + count * dims` computed before any check, so
    /// `4294967295 * 4294967295` ≈ 1.8e19 overflows `Int` (max 9.2e18) and
    /// Swift's `*` traps. That is a crash inside the test runner rather than a
    /// red assertion, which is the whole complaint: the file's own `LoadError`
    /// vocabulary never gets a chance to answer.
    @Test("A header claiming impossible dimensions is refused rather than multiplied")
    func absurdHeaderIsRefused() async throws {
        var bytes = Data("MBE1".utf8)
        for _ in 0..<2 { bytes.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF]) }  // count, dims
        bytes.append(contentsOf: [0x00, 0x00, 0x00, 0x00])                     // scale
        let fileURL = try Self.write(bytes, named: "AbsurdHeader.bin")

        let index = EmbeddingIndex(fileURL: fileURL)
        #expect(await index.neighbours(of: 1) == nil)
    }

    /// The control. A file whose header is *plausible* and whose body is short
    /// already failed correctly — `sizeMismatch` catches it — so the test above
    /// is measuring the multiplication and not the size guard in general.
    @Test("Control: a truncated file with a plausible header already answered nil")
    func truncatedFileWasAlreadyRefused() async throws {
        var bytes = Data("MBE1".utf8)
        Self.appendLE(4, to: &bytes)      // count: 4 series
        Self.appendLE(384, to: &bytes)    // dims: the real export's
        Self.appendLE(0, to: &bytes)      // scale
        bytes.append(Data(repeating: 0, count: 8))  // far short of 4*4 + 4*384
        let fileURL = try Self.write(bytes, named: "Truncated.bin")

        let index = EmbeddingIndex(fileURL: fileURL)
        #expect(await index.neighbours(of: 1) == nil)
    }

    // MARK: - Work-list 53: OfflineCatalogue's rating

    /// EXPECTED TO FAIL ON THE OLD CODE by **trapping** in
    /// `Int(rating.rounded())`: `1e308` is far outside `Int`'s range and
    /// `Int(_:)` on a `Double` traps rather than throwing. The project's rule
    /// (CLAUDE.md, and `Int(wholeOrClamped:)` at `SpotlightIndex.swift:93`) is
    /// that a `Double` the app did not compute does not go through `Int(_:)`;
    /// `rating` is decoded from the bundled `OfflineIndex.json.gz`, which
    /// qualifies.
    ///
    /// JSON has no NaN literal, so the fixture uses the other half of the same
    /// hazard — a magnitude outside `Int` — which traps identically.
    @Test("A rating the export should never emit does not trap the offline filter")
    func absurdRatingDoesNotTrap() async throws {
        let json = """
        {"version":1,"built":"2026-09-14","source":"test","series":[\
        {"id":1,"t":"Trap","k":"Manga","r":1e308,"g":[]},\
        {"id":2,"t":"Ordinary","k":"Manga","r":90.0,"g":[]}]}
        """
        let directory = try Self.directory()
        try Self.gzip(Data(json.utf8)).write(
            to: directory.appendingPathComponent("OfflineTrapIndex.json.gz")
        )
        let bundle = try #require(Bundle(url: directory))
        let catalogue = OfflineCatalogue(
            resourceName: "OfflineTrapIndex", resourceExtension: "json.gz", bundle: bundle
        )

        var query = SearchQuery()
        query.minimumRating = 80
        let hits = await catalogue.matches(
            query, allowedRatings: [], allowedTypes: [], blockedTags: [], limit: 10, offset: 0
        )

        // The clamped value is `Int.max`, which passes a minimum of 80 — the
        // point is that the filter answers at all rather than that it answers
        // any particular way about a value the export cannot legitimately
        // produce. The ordinary row is the control: the query really did run.
        #expect(hits.contains { $0.id == 2 })
    }

    // MARK: - Fixtures

    private static func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func write(_ bytes: Data, named name: String) throws -> URL {
        let fileURL = try directory().appendingPathComponent(name)
        try bytes.write(to: fileURL)
        return fileURL
    }

    private static func appendLE(_ value: UInt32, to bytes: inout Data) {
        for shift in stride(from: 0, to: 32, by: 8) {
            bytes.append(UInt8((value >> shift) & 0xFF))
        }
    }

    /// The inverse of `Gunzip.decompress`, so the fixture goes through the real
    /// decode path. The same builder as
    /// `OfflineCatalogueLoadFailureTests.gzip`; duplicated rather than shared
    /// because these two suites are the only callers and a test helper shared
    /// across files is one more thing to keep in step.
    private static func gzip(_ payload: Data) -> Data {
        let bytes = [UInt8](payload)
        let bufferSize = bytes.count + 128
        var destination = [UInt8](repeating: 0, count: bufferSize)
        let compressedSize = bytes.withUnsafeBufferPointer { source -> Int in
            destination.withUnsafeMutableBufferPointer { dest -> Int in
                guard let sourceBase = source.baseAddress,
                      let destBase = dest.baseAddress else { return 0 }
                return compression_encode_buffer(
                    destBase, bufferSize, sourceBase, source.count, nil, COMPRESSION_ZLIB
                )
            }
        }
        var gzipBytes = Data([0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff])
        gzipBytes.append(contentsOf: destination.prefix(compressedSize))
        appendLE(Gunzip.crc32(bytes), to: &gzipBytes)
        appendLE(UInt32(bytes.count), to: &gzipBytes)
        return gzipBytes
    }
}
