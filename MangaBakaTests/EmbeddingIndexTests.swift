import Foundation
import Testing
@testable import MangaBaka

/// `EmbeddingIndex` reads `MangaBaka/Resources/OfflineEmbeddings.bin` — a
/// bundled export, magic `MBE1`, 19,203 series at 384 dims each, quantised
/// Int8. See `EmbeddingIndex.swift` for the exact layout.
@Suite("EmbeddingIndex")
struct EmbeddingIndexTests {
    @Test("header parses to the known shape of the bundled export")
    func headerParsesRealFile() async throws {
        let index = EmbeddingIndex()
        // There is no header accessor on the actor by design — the only
        // externally visible fact about a loaded file is what it answers.
        // Asking for a real id's neighbours and getting a full page back is
        // itself proof the header parsed: a bad magic, a truncated file or a
        // size mismatch all fail to load and every `neighbours(of:)` answers
        // nil forever after.
        let firstID = try #require(await Self.firstBundledID(in: index))
        let result = try #require(await index.neighbours(of: firstID))
        #expect(result.count == 12)
    }

    @Test("neighbours excludes the query series itself and is sorted by score descending")
    func neighboursOfFirstID() async throws {
        let index = EmbeddingIndex()
        let firstID = try #require(await Self.firstBundledID(in: index))
        let result = try #require(await index.neighbours(of: firstID, limit: 12))
        #expect(result.count == 12)
        #expect(!result.contains { $0.id == firstID })
        let scores = result.map(\.score)
        #expect(scores == scores.sorted(by: >))
    }

    @Test("a series id absent from the file answers nil")
    func missingIDIsNil() async {
        let index = EmbeddingIndex()
        // Not a real MangaBaka id space (ids are positive and far smaller);
        // chosen simply to be outside the 19,203 the file carries.
        let result = await index.neighbours(of: -1)
        #expect(result == nil)
    }

    /// Measured 2026-09-13 with numpy over the bundled file: for 201 evenly
    /// spaced rows, the top neighbour reciprocates within its top 50 for
    /// 156 (78%) and within its top 200 for 187 (93%); the median rank back
    /// is 7. So "within 50" is NOT a property every row has — the first
    /// attempt at this test picked the lowest id with a vector and failed.
    /// The file's first row (series 3397, Solo Leveling) reciprocates at
    /// rank 1, and that is what this pins: the Swift ranking agrees with the
    /// reference implementation on a known pair.
    @Test("The first row's top neighbour ranks it first in return (measured pair)")
    func knownReciprocalPair() async throws {
        let index = EmbeddingIndex()
        let aTop = try #require(await index.neighbours(of: 3397, limit: 1))
        let bID = try #require(aTop.first?.id)
        #expect(bID == 48465, "numpy's answer for the same file, 2026-09-13")
        let bTop = try #require(await index.neighbours(of: bID, limit: 1))
        #expect(bTop.first?.id == 3397)
    }

    @Test("a synthetic fixture ranks a parallel vector above an orthogonal one")
    func syntheticRankingMath() async throws {
        // Three 4-dim vectors, ids 1, 2, 3: id 1 is the query, id 2 is exactly
        // parallel to it (same direction, different magnitude), id 3 is
        // orthogonal. The dot product must rank 2 above 3.
        let fileURL = try Self.writeFixture(
            ids: [1, 2, 3],
            dims: 4,
            scale: 1,
            vectors: [
                [10, 0, 0, 0],
                [5, 0, 0, 0],
                [0, 10, 0, 0]
            ]
        )
        let index = EmbeddingIndex(fileURL: fileURL)
        let result = try #require(await index.neighbours(of: 1, limit: 2))
        #expect(result.map(\.id) == [2, 3])
        #expect(result[0].score == 50)
        #expect(result[1].score == 0)
    }

    @Test("a corrupt magic fails to load, answering nil rather than crashing")
    func badMagicAnswersNil() async throws {
        var bytes = [UInt8]("XXXX".utf8)
        bytes.append(contentsOf: [0, 0, 0, 0]) // count = 0
        bytes.append(contentsOf: [0, 0, 0, 0]) // dims = 0
        bytes.append(contentsOf: [0, 0, 0, 0]) // scale = 0
        let url = try Self.writeBytes(bytes)
        let index = EmbeddingIndex(fileURL: url)
        let result = await index.neighbours(of: 1)
        #expect(result == nil)
    }

    // MARK: - Fixtures

    /// The export ids are opaque MangaBaka series ids with no published
    /// "first" one to hardcode; probing a small, plausible low range for the
    /// first hit keeps this test independent of the exact id chosen when the
    /// file was generated.
    private static func firstBundledID(in index: EmbeddingIndex) async -> Int? {
        for candidate in 1...200 where await index.neighbours(of: candidate) != nil {
            return candidate
        }
        return nil
    }

    private static func writeFixture(
        ids: [Int32], dims: Int, scale: Float, vectors: [[Int8]]
    ) throws -> URL {
        var bytes = [UInt8]("MBE1".utf8)
        func appendLE(_ value: UInt32) {
            bytes.append(UInt8(value & 0xFF))
            bytes.append(UInt8((value >> 8) & 0xFF))
            bytes.append(UInt8((value >> 16) & 0xFF))
            bytes.append(UInt8((value >> 24) & 0xFF))
        }
        appendLE(UInt32(ids.count))
        appendLE(UInt32(dims))
        appendLE(scale.bitPattern)
        for id in ids { appendLE(UInt32(bitPattern: id)) }
        for vector in vectors {
            for value in vector { bytes.append(UInt8(bitPattern: value)) }
        }
        return try writeBytes(bytes)
    }

    private static func writeBytes(_ bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("bin")
        try Data(bytes).write(to: url)
        return url
    }
}
