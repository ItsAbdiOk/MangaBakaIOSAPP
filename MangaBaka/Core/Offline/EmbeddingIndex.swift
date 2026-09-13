import Foundation
import os

/// Nearest-neighbour search over the bundled sentence-embedding file.
///
/// No model runs on device. The 19,203 vectors in `OfflineEmbeddings.bin` are
/// pre-computed (all-MiniLM-L6-v2 over title + tags + synopsis, from the
/// MangaBaka dump's Tags Gen, CC BY-NC-SA 4.0) and a "similar to X" query is
/// just another series' row from the same file — so this only ever answers
/// for a series among those 19,203. Everyone else gets `nil`, which is not a
/// failure; the caller shows nothing.
///
/// An actor because the file is loaded once, lazily, off the main actor —
/// `Data(contentsOf:)` on a 7.3 MB file has no business blocking a screen —
/// and the matrix it produces (an `[Int8]` and an `[Int32]`) is read-only
/// after that, so every subsequent `neighbours(of:)` call is free to run
/// concurrently with the load already in flight.
actor EmbeddingIndex {
    struct Neighbour: Equatable, Sendable {
        let id: Int
        /// Raw Int8 dot product. Vectors were L2-normalised before
        /// quantisation, so this is cosine similarity up to a constant
        /// factor — enough to rank by, not a probability or a percentage.
        let score: Int32
    }

    private enum LoadError: Error {
        case missingFile
        case tooShort
        case badMagic
        case sizeMismatch
    }

    private struct LoadedIndex {
        let ids: [Int32]
        let dims: Int
        /// One contiguous buffer, `ids.count * dims` long — row `i` is
        /// `vectors[i * dims ..< (i + 1) * dims]`. Kept flat rather than as
        /// `[[Int8]]` so the dot-product loop below walks one allocation
        /// instead of chasing 19,203 separate array headers.
        let vectors: [Int8]
        let rowOf: [Int32: Int]
    }

    private static let logger = Logger(
        subsystem: "dev.abdirahmanmohamed.mangabaka", category: "embeddingIndex"
    )

    private let fileURL: URL?
    private var loaded: LoadedIndex?
    /// Set once loading has been tried and failed, so a broken bundle is
    /// logged once rather than on every series page opened afterwards.
    private var loadFailed = false

    /// `fileURL` is only for tests — production callers take the default,
    /// which resolves the bundled resource. A production build where that
    /// resolves to `nil` means the resource is missing from the bundle,
    /// which is a broken build, not a runtime condition to design around.
    init(fileURL: URL? = nil) {
        self.fileURL = fileURL
            ?? Bundle.main.url(forResource: "OfflineEmbeddings", withExtension: "bin")
    }

    /// `nil` when the series has no vector in the file, or the file could
    /// not be loaded at all (bundled, so that means a broken build — logged,
    /// never surfaced as a failure state).
    func neighbours(of seriesID: Int, limit: Int = 12) async -> [Neighbour]? {
        await loadIfNeeded()
        guard let loaded, let row = loaded.rowOf[Int32(seriesID)] else { return nil }
        return Self.topNeighbours(in: loaded, row: row, limit: limit)
    }

    /// A plain loop, not vDSP — Accelerate has no Int8 dot product, and
    /// 19,203 × 384 multiply-adds is small enough that reaching for SIMD
    /// intrinsics here would be guessing at a bottleneck without measuring
    /// one. (Guess: comfortably under a frame at 60fps; not measured.)
    private static func topNeighbours(
        in loaded: LoadedIndex, row: Int, limit: Int
    ) -> [Neighbour] {
        let dims = loaded.dims
        var scored: [Neighbour] = []
        scored.reserveCapacity(loaded.ids.count)
        loaded.vectors.withUnsafeBufferPointer { vectors in
            guard let base = vectors.baseAddress else { return }
            let query = base + row * dims
            for otherRow in 0..<loaded.ids.count where otherRow != row {
                let candidate = base + otherRow * dims
                var accumulator: Int32 = 0
                for dim in 0..<dims {
                    accumulator &+= Int32(query[dim]) &* Int32(candidate[dim])
                }
                scored.append(Neighbour(id: Int(loaded.ids[otherRow]), score: accumulator))
            }
        }
        scored.sort { $0.score > $1.score }
        return Array(scored.prefix(limit))
    }

    private func loadIfNeeded() async {
        guard loaded == nil, !loadFailed else { return }
        do {
            loaded = try Self.load(from: fileURL)
        } catch {
            loadFailed = true
            Self.logger.error(
                "EmbeddingIndex failed to load bundled file: \(String(describing: error))"
            )
        }
    }

    /// Parses the `MBE1` header described in the export: magic, `count`,
    /// `dims`, a `Float32` scale (unused for ranking — raw Int8 dot product
    /// preserves cosine order without dequantising), `count` little-endian
    /// `Int32` series ids, then `count * dims` `Int8` values.
    private static func load(from fileURL: URL?) throws -> LoadedIndex {
        guard let fileURL else { throw LoadError.missingFile }
        let data = try Data(contentsOf: fileURL)
        let headerSize = 16
        guard data.count >= headerSize else { throw LoadError.tooShort }

        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard raw[0] == UInt8(ascii: "M"), raw[1] == UInt8(ascii: "B"),
                  raw[2] == UInt8(ascii: "E"), raw[3] == UInt8(ascii: "1")
            else { throw LoadError.badMagic }
        }

        let count = Int(readUInt32LE(data, at: 4))
        let dims = Int(readUInt32LE(data, at: 8))
        // `scale` (bytes 12..<16) is read only to document its position —
        // ranking uses the raw quantised dot product, no dequantisation.
        _ = Float(bitPattern: readUInt32LE(data, at: 12))

        let idsStart = headerSize
        let vectorsStart = idsStart + count * 4
        let expectedSize = vectorsStart + count * dims
        guard data.count == expectedSize else { throw LoadError.sizeMismatch }

        var ids = [Int32](repeating: 0, count: count)
        for index in 0..<count {
            ids[index] = Int32(bitPattern: readUInt32LE(data, at: idsStart + index * 4))
        }

        var vectors = [Int8](repeating: 0, count: count * dims)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let source = UnsafeRawBufferPointer(rebasing: raw[vectorsStart..<expectedSize])
            vectors.withUnsafeMutableBytes { dest in
                dest.copyBytes(from: source)
            }
        }

        var rowOf: [Int32: Int] = [:]
        rowOf.reserveCapacity(count)
        for (row, id) in ids.enumerated() { rowOf[id] = row }

        return LoadedIndex(ids: ids, dims: dims, vectors: vectors, rowOf: rowOf)
    }

    /// Manual little-endian read via raw bytes rather than `load(as:)`,
    /// which requires alignment this buffer does not promise.
    private static func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> UInt32 in
            let b0 = UInt32(raw[offset])
            let b1 = UInt32(raw[offset + 1])
            let b2 = UInt32(raw[offset + 2])
            let b3 = UInt32(raw[offset + 3])
            return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
        }
    }
}
