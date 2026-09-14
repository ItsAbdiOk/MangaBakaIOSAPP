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
    /// Set when the blend request itself failed — offline, rate-limited, a
    /// server error — as opposed to succeeding with nothing to recommend.
    /// `run()` used to overwrite `results`/`dna`/`moves` on every answer,
    /// `MixResult.failure` included, so a throttled reader lost the blend and
    /// DNA chips they were looking at and was told "Nothing matched. Try
    /// loosening the filters." for a request that never reached the server
    /// (gap 11, FAILURES-SUMMARY.md).
    private(set) var failure: APIError?

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

    /// What the strand debounce sleeps against. Injected so a test can move
    /// time rather than sleep through 350 ms of it (item 129).
    ///
    /// Spelled with its module because this one does not: `MangaBaka` has its
    /// own `Clock` protocol (`Core/Persistence/Clock.swift`, a source of
    /// "now" for cache expiry), and an unqualified `Clock` resolves to that.
    nonisolated let clock: any _Concurrency.Clock<Duration>

    /// Tag name → tag id, for the names `filters.tags` holds.
    ///
    /// `/v1/series/mix` ignores a tag *name* outright — measured 2026-09-14:
    /// `tag=Isekai` returns the unfiltered blend, `tag=94` filters — so
    /// "Require tags" lit a chip up and changed nothing. Every answer's DNA
    /// carries both halves (`BlendDNA.Strand.tagId`) and the picker hands
    /// back whole `Tag`s, so both are recorded here and `run()` sends ids.
    /// A name with no id known is simply not sent, rather than sent as a
    /// name the API will ignore (item 18).
    private(set) var tagIDsByName: [String: Int] = [:]

    init(
        repository: any SeriesRepositoryProtocol,
        shelf: ShelfStore,
        clock: any _Concurrency.Clock<Duration> = ContinuousClock()
    ) {
        self.repository = repository
        self.shelf = shelf
        self.clock = clock
    }

    /// Remembers a tag's id against its name, so a tag picked before any
    /// blend has run still reaches the wire as an id.
    func noteTagID(_ tag: Tag) {
        tagIDsByName[tag.name] = tag.id
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
    /// Capped: the row shows six, a non-lazy `HStack` draws every one it is
    /// given, and a reader with 300 saves paid 300 payload decodes on the
    /// `ShelfStore` actor, 300 view bodies, 300 arrival springs and 300 cover
    /// requests in one frame — on every appearance of the Mix screen. 24 is a
    /// guess: four screens' worth of scrolling for a row nobody is meant to
    /// scroll far (item 52).
    func suggestedSeeds() async -> [Series] {
        Array(((try? await shelf.entries(.saved).series) ?? []).prefix(24))
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
            excludedTags: Array(excludedTags),
            tagIDs: filters.tags.compactMap { tagIDsByName[$0] }
        )
        guard mine == generation else { return }
        defer { isRunning = false }

        if let error = blended.failure {
            // The request itself failed. The last-good blend and its DNA are
            // still true — they just have not been refreshed — so they stay
            // on screen rather than being wiped and replaced with a sentence
            // that blames the reader's filters for a request that never
            // reached the server.
            // A blend superseded by a later edit dies with `.cancelled`, and
            // the replacement is still asleep in its debounce when it does —
            // so the generation guard above passes and this used to draw a
            // "Cancelled" `FailureState` with a Retry button for 350 ms
            // between two taps on the same chip (C2, item 47).
            if case .cancelled = error { return }
            failure = error
            return
        }
        failure = nil
        results = blended.recommendations
        dna = blended.dna
        // Every strand carries its own id; recording them is what lets
        // "Require tags" send ids rather than names (item 18).
        for strand in blended.dna.strands {
            tagIDsByName[strand.name] = strand.tagId
        }
        // A strand switched back on stays in `excludedStrands`, drawn as
        // included, until a blend actually returns it — see `toggleStrand`.
        excludedStrands.removeAll { !excludedTags.contains($0.tagId) }
        // Only meaningful against a previous blend; the first run has nothing
        // to compare with and shows no movement rather than fake movement.
        moves = previous.isEmpty ? [] : BlendDNA.moves(from: previous, to: blended.dna)
        message = results.isEmpty ? "Nothing matched. Try loosening the filters." : nil
    }

    /// Switches a strand off, or back on, and re-blends.
    ///
    /// Binary by necessity: `/v1/series/mix` has no weight or boost parameter,
    /// only `tag` and `tag_not`, so a strand is either in or out.
    func toggleStrand(_ tagId: Int) async {
        if excludedTags.contains(tagId) {
            excludedTags.remove(tagId)
            // Deliberately still in `excludedStrands`: the API has not
            // returned it yet, so dropping it here made the chip vanish for
            // the debounce plus the request, and permanently if the re-blend
            // failed. `run()` clears it once a blend brings it back, and
            // `BlendDNAView` draws it as included meanwhile (item 46).
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
        let task = Task { [clock] in
            try? await clock.sleep(for: Self.strandDebounce)
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
        failure = nil
    }
}
