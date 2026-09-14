import Foundation
import Testing
import UIKit
@testable import MangaBaka

/// Tests for the review's F10 fix (persistence review, 2026-09-14):
/// `EmbeddingIndex.load` used to read the bundled file with plain
/// `Data(contentsOf:)` and copy its 7.37 MB vector block into a fresh
/// `[Int8]`, held for the process lifetime with no response to memory
/// pressure. The fix maps the file (`.alwaysMapped`) and keeps the vector
/// block as a `Data` slice over the mapped pages instead of copying it, and
/// releases the loaded index on `UIApplication.didReceiveMemoryWarningNotification`.
///
/// What this file can and cannot prove, honestly: it proves the *mapped
/// storage still computes correct answers* (the ranking is unaffected by
/// reading through `withUnsafeBytes` on a `Data` slice instead of an
/// `[Int8]`) and that the *memory-warning path doesn't break the index* (it
/// reloads correctly afterwards). It does **not** measure the actual memory
/// win — that needs a device, not the simulator, per the review's own note.
/// A device measurement would be: Xcode's memory gauge (or
/// `os_proc_available_memory`) immediately before and after the first call
/// to `neighbours(of:)` on a real device, compared before/after this change;
/// the review's estimate is ~15 MB peak / ~8 MB resident today, expected to
/// drop to a few hundred KB (`ids` + `rowOf`) plus whatever pages the OS
/// chooses to keep resident for the vectors actually touched.
///
/// Kept separate from `EmbeddingIndexTests` (this lane owns
/// `EmbeddingIndex.swift` but not the existing test file).
@Suite("EmbeddingIndex: memory mapping and pressure response (F10)")
struct EmbeddingIndexMemoryTests {
    /// Same fixture shape as `EmbeddingIndexTests.syntheticRankingMath`:
    /// three 4-dim vectors, id 1 the query, id 2 exactly parallel (must rank
    /// first), id 3 orthogonal (must rank last, score 0). Rebuilt here
    /// rather than shared because the writer is `private` in that suite.
    private static func writeFixture() throws -> URL {
        var bytes = [UInt8]("MBE1".utf8)
        func appendLE(_ value: UInt32) {
            bytes.append(UInt8(value & 0xFF))
            bytes.append(UInt8((value >> 8) & 0xFF))
            bytes.append(UInt8((value >> 16) & 0xFF))
            bytes.append(UInt8((value >> 24) & 0xFF))
        }
        let ids: [Int32] = [1, 2, 3]
        let vectors: [[Int8]] = [[10, 0, 0, 0], [5, 0, 0, 0], [0, 10, 0, 0]]
        appendLE(UInt32(ids.count))
        appendLE(4) // dims
        appendLE(Float(1).bitPattern) // scale, unused for ranking
        for id in ids { appendLE(UInt32(bitPattern: id)) }
        for vector in vectors {
            for value in vector { bytes.append(UInt8(bitPattern: value)) }
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("bin")
        try Data(bytes).write(to: url)
        return url
    }

    @Test("Ranking through the memory-mapped vectors matches the pre-fix, copied-array answer")
    func mappedVectorsRankCorrectly() async throws {
        let fileURL = try Self.writeFixture()
        let index = EmbeddingIndex(fileURL: fileURL)
        let result = try #require(await index.neighbours(of: 1, limit: 2))
        // Same expected values `EmbeddingIndexTests.syntheticRankingMath`
        // asserts against the old `[Int8]`-copy implementation: id 2
        // (parallel) ranks first with score 50, id 3 (orthogonal) last
        // with score 0. Reading through `withUnsafeBytes` on a `Data`
        // slice instead of `withUnsafeBufferPointer` on an `[Int8]` must
        // not change this.
        #expect(result.map(\.id) == [2, 3])
        #expect(result[0].score == 50)
        #expect(result[1].score == 0)
    }

    @Test("A memory warning does not corrupt subsequent lookups; the index reloads and still answers")
    func survivesMemoryWarning() async throws {
        let fileURL = try Self.writeFixture()
        let index = EmbeddingIndex(fileURL: fileURL)

        let before = try #require(await index.neighbours(of: 1, limit: 2))
        #expect(before.map(\.id) == [2, 3])

        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        // The observer hops onto the actor via an unstructured `Task`; give
        // it a beat to run before asserting the index still works. This is
        // inherently a little racy (there is no signal to await instead),
        // which is exactly why the actual reload correctness — not just "no
        // crash" — is asserted below rather than assumed.
        try await Task.sleep(for: .milliseconds(50))

        let after = try #require(await index.neighbours(of: 1, limit: 2))
        #expect(after.map(\.id) == [2, 3])
        #expect(after[0].score == 50)
        #expect(after[1].score == 0)
    }
}
