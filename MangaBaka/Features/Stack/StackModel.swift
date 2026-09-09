import Foundation

/// Backing state for the swipe stack.
@MainActor
@Observable
final class StackModel {
    /// What the current queue is actually built from.
    ///
    /// Exposed so the screen can say so. "Are you sure it's using my tastes?"
    /// is a fair question to ask of any recommender, and the honest answer
    /// depends entirely on which of these it is — a random queue is not
    /// personalised at all, and the app should not imply otherwise.
    enum Source: Equatable {
        /// Blended from series saved on this device.
        case yourSaves
        /// Blended from the reader's MangaBaka library.
        case yourLibrary
        /// A random sample. Nothing to personalise from yet.
        case random

        var caption: String {
            switch self {
            case .yourSaves: "Based on what you've saved"
            case .yourLibrary: "Based on your MangaBaka library"
            case .random: "A random sample — save a few to make this yours"
            }
        }
    }

    private(set) var queue: [Series] = []
    private(set) var isLoading = false
    private(set) var message: String?
    private(set) var source: Source = .random

    private let repository: any SeriesRepositoryProtocol
    private let shelf: ShelfStore
    private let library: LibraryService?
    private var reacted: Set<Int> = []

    /// Every series that could seed a blend, and where we are in it.
    ///
    /// `mix` takes no page parameter, so a single set of seeds yields one
    /// batch of at most 50 and then repeats itself forever. Rotating the seeds
    /// is the only way to keep going, and it also keeps the stack from
    /// narrowing onto whichever three series happened to be saved first.
    private var seedPool: [Int] = []
    private var seedCursor = 0
    private static let seedsPerBlend = 3

    init(
        repository: any SeriesRepositoryProtocol,
        shelf: ShelfStore,
        library: LibraryService? = nil
    ) {
        self.repository = repository
        self.shelf = shelf
        self.library = library
    }

    var current: Series? { queue.first }
    var next: Series? { queue.count > 1 ? queue[1] : nil }

    func loadIfNeeded() async {
        guard queue.isEmpty, !isLoading else { return }
        await refill()
    }

    func refill() async {
        isLoading = true
        defer { isLoading = false }

        reacted = (try? await shelf.reactedIDs()) ?? []
        await buildSeedPoolIfNeeded()

        // Two attempts, not one. The first can come back entirely composed of
        // series already reacted to, which used to empty the stack and show
        // "that's the stack for now" while more was plainly available.
        for _ in 0..<2 {
            let fresh = await fetchBatch()
            if !fresh.isEmpty {
                queue = fresh
                message = nil
                return
            }
            guard advanceSeeds() else { break }
        }

        // Nothing left to offer. `message` is whatever the last fetch set: an
        // error if one occurred, nil if the queue is genuinely exhausted. The
        // empty state reads those two cases differently.
        queue = []
    }

    func react(_ kind: ShelfEntry.Kind) async {
        guard let series = current else { return }
        queue.removeFirst()
        reacted.insert(series.id)
        try? await shelf.record(series, as: kind)

        // A save changes what the next blend should be built from, so the pool
        // is rebuilt rather than left pointing at the shelf as it was on load.
        if kind == .saved { seedPool = [] }

        if queue.count <= 2 { await refill() }
    }

    // MARK: - Seeds

    /// Local saves first, then the reader's MangaBaka library, then nothing.
    ///
    /// The library step is what makes a first run personalised for someone who
    /// has a MangaBaka account: without it, a reader with three hundred series
    /// on the site still got a random queue on their first launch, because the
    /// on-device shelf was empty. The token is only present if they entered
    /// one, so this is silently skipped for everyone else.
    private func buildSeedPoolIfNeeded() async {
        guard seedPool.isEmpty else { return }
        seedCursor = 0

        let saved = ((try? await shelf.entries(.saved)) ?? []).map(\.id)
        if !saved.isEmpty {
            seedPool = saved
            source = .yourSaves
            return
        }

        if let library {
            // Highest priority first, then the ones being read: a series
            // someone dropped says as much about what they don't want.
            let entries = await library.library(limit: 50)
            let ids = entries
                .filter { $0.state != .dropped }
                .sorted { ($0.priority ?? 0) > ($1.priority ?? 0) }
                .map(\.seriesId)
            if !ids.isEmpty {
                seedPool = ids
                source = .yourLibrary
                return
            }
        }

        seedPool = []
        source = .random
    }

    /// Moves to the next group of seeds. False when the pool is exhausted.
    private func advanceSeeds() -> Bool {
        guard !seedPool.isEmpty else { return false }
        let next = seedCursor + Self.seedsPerBlend
        guard next < seedPool.count else { return false }
        seedCursor = next
        return true
    }

    private var currentSeeds: [Int] {
        guard seedCursor < seedPool.count else { return [] }
        return Array(seedPool[seedCursor...].prefix(Self.seedsPerBlend))
    }

    private func fetchBatch() async -> [Series] {
        let seeds = currentSeeds
        // mix rejects a seedless request outright ("At least one seed series
        // or one include tag is required", HTTP 400), so an empty pool has to
        // take the random path rather than fail.
        let feed: FeedKind = seeds.isEmpty ? .surprise : .mix(seeds: seeds)
        let result = await repository.feed(feed, forceRefresh: queue.isEmpty)
        message = result.blockingError?.userFacingMessage
        return result.series.filter { !reacted.contains($0.id) }
    }
}
