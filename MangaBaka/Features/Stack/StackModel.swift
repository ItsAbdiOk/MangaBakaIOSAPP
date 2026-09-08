import Foundation

/// Backing state for the swipe stack.
@MainActor
@Observable
final class StackModel {
    private(set) var queue: [Series] = []
    private(set) var isLoading = false
    private(set) var message: String?

    private let repository: any SeriesRepositoryProtocol
    private let shelf: ShelfStore
    private var reacted: Set<Int> = []

    init(repository: any SeriesRepositoryProtocol, shelf: ShelfStore) {
        self.repository = repository
        self.shelf = shelf
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

        // Seeded from what the reader has already saved, so the stack sharpens
        // with use. With no saves yet, an unseeded mix is still a real
        // recommendation set rather than a placeholder.
        let seeds = Array(((try? await shelf.entries(.saved)) ?? []).prefix(3).map(\.id))
        // mix rejects a seedless request outright, so a reader with an empty
        // shelf gets a random surprise queue instead of an error screen.
        let feed: FeedKind = seeds.isEmpty ? .surprise : .mix(seeds: seeds)
        let result = await repository.feed(feed, forceRefresh: queue.isEmpty)

        let fresh = result.series.filter { !reacted.contains($0.id) }
        queue = fresh
        message = fresh.isEmpty ? result.blockingError?.userFacingMessage : nil
    }

    func react(_ kind: ShelfEntry.Kind) async {
        guard let series = current else { return }
        queue.removeFirst()
        reacted.insert(series.id)
        try? await shelf.record(series, as: kind)
        if queue.count <= 2 { await refill() }
    }
}
