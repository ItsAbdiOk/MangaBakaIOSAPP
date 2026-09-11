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

    /// The ten weighted tags the blend was derived from.
    private(set) var dna: BlendDNA = .empty
    /// How the weights moved on the last run, so an edit can show its effect.
    private(set) var moves: [BlendDNA.Move] = []
    /// Strands the reader has switched off. Sent as `tag_not`.
    private(set) var excludedTags: Set<Int> = []
    /// The excluded strands as they last appeared, kept so they can still be
    /// shown and switched back on.
    ///
    /// Necessary because excluding one removes it from what the API returns:
    /// the chip simply vanished and the only way back was "Start over", which
    /// makes the control one-way. Remembering the name and its last weight is
    /// the only way to offer the reverse.
    private(set) var excludedStrands: [BlendDNA.Strand] = []

    /// Whether the DNA has been edited away from what the seeds produced.
    var isDNAEdited: Bool { !excludedTags.isEmpty }
    var filters = SearchQuery()

    /// Seeds beyond this are refused rather than silently dropped, so the UI
    /// never has to guess which one lost.
    static let maxSeeds = 3

    /// How long a strand edit waits for the next one before re-blending. Long
    /// enough to absorb a run of taps, short enough that a single tap still
    /// feels immediate. A guess; nobody has measured tap cadence on the chips.
    static let strandDebounce: Duration = .milliseconds(350)
    private var pendingBlend: Task<Void, Never>?
    /// Bumped by every run. A blend that returns for an older generation was
    /// overtaken by a later edit and must not replace the newer answer.
    private var generation = 0

    /// Not private, so the seed picker can run its own search against the same
    /// repository rather than being handed a second one.
    let repository: any SeriesRepositoryProtocol
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

        let previous = dna
        generation += 1
        let mine = generation
        let blended = await repository.mix(
            seeds: seeds.map(\.id),
            filters: filters,
            excludedTags: Array(excludedTags)
        )
        guard mine == generation else { return }
        results = blended.recommendations
        dna = blended.dna
        // Only meaningful against a previous blend; the first run has nothing
        // to compare with and shows no movement rather than fake movement.
        moves = previous.isEmpty ? [] : BlendDNA.moves(from: previous, to: blended.dna)
        message = results.isEmpty ? "Nothing matched. Try loosening the filters." : nil
        isRunning = false
    }

    /// Switches a strand off, or back on, and re-blends.
    ///
    /// Binary by necessity: `/v1/series/mix` has no weight or boost parameter,
    /// only `tag` and `tag_not`, so a strand is either in or out.
    func toggleStrand(_ tagId: Int) async {
        if excludedTags.contains(tagId) {
            excludedTags.remove(tagId)
            excludedStrands.removeAll { $0.tagId == tagId }
        } else {
            // Captured before the blend re-runs, because afterwards the API no
            // longer returns it and there would be nothing left to remember.
            if let strand = dna.strands.first(where: { $0.tagId == tagId }) {
                excludedStrands.append(strand)
            }
            excludedTags.insert(tagId)
        }
        await blendAfterEdits()
    }

    /// Re-blends once the taps stop. Every strand tap used to be its own
    /// request, and the requests raced: the screen showed whichever blend
    /// answered last, not the one for the strands actually switched off.
    private func blendAfterEdits() async {
        pendingBlend?.cancel()
        let task = Task {
            try? await Task.sleep(for: Self.strandDebounce)
            guard !Task.isCancelled else { return }
            await run()
        }
        pendingBlend = task
        await task.value
    }

    /// Back to what the seeds alone produce.
    func resetDNA() async {
        guard isDNAEdited else { return }
        excludedTags.removeAll()
        excludedStrands.removeAll()
        await run()
    }

    /// Stale output must never sit under seeds that no longer produced it.
    private func clearStaleResults() {
        results = []
        dna = .empty
        moves = []
        excludedTags.removeAll()
        excludedStrands.removeAll()
        message = nil
    }
}
