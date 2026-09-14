import Foundation
import os
import UIKit

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
/// `Data(contentsOf:)` on a 7.3 MB file has no business blocking a screen.
/// The matrix it produces is read-only after that, and `neighbours(of:)` is
/// `nonisolated`: the only actor-isolated hop it makes is the quick
/// `snapshot()` call that ensures the file is loaded and returns the
/// `Sendable` result, so the 7.4M-multiply-add search itself runs off the
/// actor's executor. (Review F10, 2026-09-14: this doc used to claim
/// `neighbours(of:)` callers "run concurrently with the load already in
/// flight" while the search itself ran as a direct, actor-isolated call —
/// true concurrency needed this restructure, not just the claim.)
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

    /// `Sendable` so `topNeighbours` can run outside the actor on a value
    /// handed across the one `snapshot()` hop — see the type's own doc.
    private struct LoadedIndex: Sendable {
        let ids: [Int32]
        let dims: Int
        /// The vector block of the mapped file (`vectorsStart..<expectedSize`
        /// of the `Data` `load(from:)` reads with `.alwaysMapped`), sliced
        /// rather than copied into an `[Int8]`. `Data` slicing shares
        /// storage — this is the OS's mapped pages themselves, `ids.count *
        /// dims` bytes long, row `i` at `vectors[i * dims ..< (i + 1) *
        /// dims]` once read through `withUnsafeBytes`. Before this it was
        /// copied into a fresh `[Int8]` and held for the process lifetime:
        /// ~7.37 MB resident with no way for the OS to reclaim it under
        /// memory pressure (review F10). Mapped, the OS pages it in per
        /// access and can evict clean pages instead.
        let vectors: Data
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
    /// Removed in `deinit`. `NSObjectProtocol?` defaults to `nil` (Swift
    /// auto-initialises unset Optional stored properties), so it needs no
    /// explicit assignment before `init` captures `self` in the observer
    /// closure below.
    /// `nonisolated(unsafe)`: it is written exactly once, in this
    /// actor's nonisolated `init`, and read once in `deinit` — neither of
    /// which can touch isolated state, and nothing else ever touches it.
    nonisolated(unsafe) private var memoryWarningObserver: NSObjectProtocol?

    /// `fileURL` is only for tests — production callers take the default,
    /// which resolves the bundled resource. A production build where that
    /// resolves to `nil` means the resource is missing from the bundle,
    /// which is a broken build, not a runtime condition to design around.
    init(fileURL: URL? = nil) {
        self.fileURL = fileURL
            ?? Bundle.main.url(forResource: "OfflineEmbeddings", withExtension: "bin")
        // Every stored property has a value as of the line above, so `self`
        // may now be captured. Dropping `loaded` on a memory warning trades
        // one more mapped-file open (cheap — `.alwaysMapped` does not copy)
        // for not being a jetsam candidate over a single row on one screen
        // (review F10).
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil
        ) { [weak self] _ in
            Task { await self?.releaseLoadedIndex() }
        }
    }

    deinit {
        if let memoryWarningObserver {
            NotificationCenter.default.removeObserver(memoryWarningObserver)
        }
    }

    /// `nil` when the series has no vector in the file, or the file could
    /// not be loaded at all (bundled, so that means a broken build — logged,
    /// never surfaced as a failure state).
    ///
    /// `nonisolated`: the only actor-isolated work is `snapshot()`, a quick
    /// hop to ensure the file is loaded and hand back the `Sendable` result.
    /// The dot-product search runs here, off the actor's executor, so two
    /// series pages opened together compute concurrently instead of taking
    /// turns on the actor (review F10 — see this type's own doc comment).
    nonisolated func neighbours(of seriesID: Int, limit: Int = 12) async -> [Neighbour]? {
        guard let loaded = await snapshot(), let row = loaded.rowOf[Int32(seriesID)] else { return nil }
        return Self.topNeighbours(in: loaded, row: row, limit: limit)
    }

    /// A plain loop, not vDSP — Accelerate has no Int8 dot product, and
    /// 19,203 × 384 multiply-adds is small enough that reaching for SIMD
    /// intrinsics here would be guessing at a bottleneck without measuring
    /// one. (Guess: comfortably under a frame at 60fps; not measured.)
    /// `nonisolated` because it takes only the `Sendable` snapshot, never
    /// `self` — see `neighbours(of:)`.
    nonisolated private static func topNeighbours(
        in loaded: LoadedIndex, row: Int, limit: Int
    ) -> [Neighbour] {
        let dims = loaded.dims
        var scored: [Neighbour] = []
        scored.reserveCapacity(loaded.ids.count)
        loaded.vectors.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let vectors = raw.bindMemory(to: Int8.self)
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

    /// The one actor-isolated hop `neighbours(of:)` makes: ensure the file
    /// is loaded (mutates `loaded`/`loadFailed`, actor-isolated state) and
    /// return the `Sendable` snapshot for the caller to search off-actor.
    private func snapshot() async -> LoadedIndex? {
        await loadIfNeeded()
        return loaded
    }

    /// Cleared on a memory warning (see `init`); `neighbours(of:)` reloads
    /// on its next call via `loadIfNeeded()`.
    private func releaseLoadedIndex() {
        loaded = nil
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
        // `.alwaysMapped`: map the file instead of copying its bytes into
        // process memory. The header and ids below are still small explicit
        // reads (`readUInt32LE`, the `ids` loop); the 7.37 MB vector block
        // is never copied at all — see `LoadedIndex.vectors`.
        let data = try Data(contentsOf: fileURL, options: .alwaysMapped)
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

        // A `Data` slice shares storage with its parent rather than copying
        // — this is still the mapped pages of `data`, not a fresh 7.37 MB
        // allocation. `withUnsafeBytes` on the slice below yields a buffer
        // indexed from this region's own start regardless of the slice's
        // (non-zero) `startIndex` in `data`'s own index space.
        let vectors = data[vectorsStart..<expectedSize]

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
