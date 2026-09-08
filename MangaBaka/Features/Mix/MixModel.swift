import Foundation

/// Backing state for the Mix screen: pick up to three seed series you love,
/// tune a few filters, and blend recommendations with the reason each matched.
///
/// Seeds are capped at three because that mirrors the API's own spirit for
/// `/v1/series/mix` — a handful of strong signals, not a wishlist — and it
/// keeps the seed row a fixed, glanceable shape.
@MainActor
@Observable
final class MixModel {
    private(set) var seeds: [Series] = []
    private(set) var results: [Recommendation] = []
    private(set) var isRunning = false
    private(set) var message: String?

    var filters = SearchQuery()

    /// Seeds beyond this are refused rather than silently dropped, so the UI
    /// never has to guess which one lost.
    static let maxSeeds = 3

    private let repository: any SeriesRepositoryProtocol
    private let shelf: ShelfStore

    init(repository: any SeriesRepositoryProtocol, shelf: ShelfStore) {
        self.repository = repository
        self.shelf = shelf
    }

    func addSeed(_ series: Series) {
        guard seeds.count < Self.maxSeeds else { return }
        guard !seeds.contains(where: { $0.id == series.id }) else { return }
        seeds.append(series)
        clearStaleResults()
    }

    func removeSeed(id: Int) {
        seeds.removeAll { $0.id == id }
        clearStaleResults()
    }

    /// A head start for someone who has already used the Stack: their saved
    /// series make honest seeds, since they are things this reader chose.
    func suggestedSeeds() async -> [Series] {
        (try? await shelf.entries(.saved)) ?? []
    }

    func run() async {
        guard !seeds.isEmpty else {
            // The API rejects a seedless request with HTTP 400, so this is
            // caught here rather than spent on a request known to fail.
            message = "Add at least one series to blend from."
            return
        }
        isRunning = true
        message = nil
        let blended = await repository.mix(seeds: seeds.map(\.id), filters: filters)
        results = blended
        message = blended.isEmpty ? "Nothing matched. Try loosening the filters." : nil
        isRunning = false
    }

    /// Stale output must never sit under seeds that no longer produced it.
    private func clearStaleResults() {
        results = []
        message = nil
    }
}
