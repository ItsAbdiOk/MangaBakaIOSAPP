import Foundation
import Testing
@testable import MangaBaka

/// A blend stub that can be told to fail, and that remembers what it was
/// asked for.
private final class BlendRepository: StubRepositoryBase, @unchecked Sendable {
    var dna: BlendDNA = .empty
    var failure: APIError?
    private(set) var mixCalls = 0

    override func mix(
        seeds: [Int],
        filters: SearchQuery,
        excludedTags: [Int]
    ) async -> MixResult {
        mixCalls += 1
        return MixResult(recommendations: [], dna: dna, failure: failure)
    }
}

/// A shelf with more saves than the suggested row could ever show.
private func seededShelf(saves: Int) async throws -> ShelfStore {
    let shelf = ShelfStore(database: try AppDatabase.inMemory(), clock: TestClock())
    for id in 1...saves {
        try await shelf.record(SeriesFactory.make(id: id, title: "S\(id)"), as: .saved)
    }
    return shelf
}

/// A clock that does not wait, so the model's debounce fires on the next
/// hop or was never booked — the two outcomes the hold tests tell apart.
private struct ImmediateClock: _Concurrency.Clock {
    typealias Instant = ContinuousClock.Instant

    var now: Instant { ContinuousClock().now }
    var minimumResolution: Duration { .zero }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        try Task.checkCancellation()
    }
}

/// Yields until `condition` holds or `hops` have passed — far past what
/// scheduling needs, so a blend that never comes ends the test.
@MainActor
private func settle(hops: Int = 1_000, until condition: () -> Bool) async {
    for _ in 0..<hops where !condition() {
        await Task.yield()
    }
}

/// The DNA chips, the tag ids the blend is actually filtered by, and what a
/// superseded blend is allowed to say.
@Suite("Mix blend state")
@MainActor
struct MixBlendStateTests {
    private func strand(_ id: Int, _ name: String, weight: Double = 0.1) -> BlendDNA.Strand {
        BlendDNA.Strand(tagId: id, name: name, weight: weight)
    }

    private static func tag(_ id: Int, _ name: String) -> MangaBaka.Tag {
        MangaBaka.Tag(
            id: id, name: name, namePath: name, parentId: nil, level: nil,
            description: nil, seriesCount: nil, isGenre: nil, isSpoiler: nil,
            mergedWith: nil, contentRating: nil
        )
    }

    private func model(_ repository: BlendRepository) async throws -> MixModel {
        let shelf = ShelfStore(database: try AppDatabase.inMemory(), clock: TestClock())
        let model = MixModel(repository: repository, shelf: shelf)
        model.addSeed(SeriesFactory.make(id: 1, title: "Seed"))
        return model
    }

    // MARK: Item 46 — one chip per tag

    /// `toggleStrand` adds to `excludedTags` while the last answer's `dna`
    /// still lists the strand, so for the debounce plus the request — and
    /// permanently if the re-blend failed — one `tagId` appeared in both
    /// lists. Two chips then shared one `ForEach` id and one
    /// `matchedGeometryEffect` id.
    @Test("Excluding a strand leaves exactly one chip for it")
    func excludingLeavesOneChip() {
        let dna = BlendDNA(strands: [strand(94, "Isekai"), strand(1180, "Regression")], seedCount: 1)
        let view = BlendDNAView(
            dna: dna,
            excluded: [94],
            excludedStrands: [strand(94, "Isekai")],
            moves: [],
            isEdited: true,
            onToggle: { _ in },
            onReset: {}
        )

        #expect(view.chips.filter { $0.tagId == 94 }.count == 1)
        #expect(view.chips.count == 2, "Both tags are still offered")
    }

    /// The mirror case: a strand switched back on stays in `excludedStrands`
    /// until a blend actually returns it, so for that window it can be in
    /// both lists too.
    @Test("Re-including a strand leaves exactly one chip for it")
    func reincludingLeavesOneChip() {
        let dna = BlendDNA(strands: [strand(94, "Isekai")], seedCount: 1)
        let view = BlendDNAView(
            dna: dna,
            excluded: [],
            excludedStrands: [strand(94, "Isekai")],
            moves: [],
            isEdited: false,
            onToggle: { _ in },
            onReset: {}
        )

        #expect(view.chips.map(\.tagId) == [94])
    }

    /// The model half: the strand has to survive the round trip, or the chip
    /// disappears the moment it is switched back on and the control is
    /// one-way again.
    @Test("A re-included strand is kept until a blend brings it back")
    func reincludedStrandSurvivesUntilTheBlendLands() async throws {
        let repository = BlendRepository()
        repository.dna = BlendDNA(strands: [strand(94, "Isekai")], seedCount: 1)
        let model = try await model(repository)
        await model.run()

        repository.dna = BlendDNA(strands: [], seedCount: 1)
        await model.toggleStrand(94)
        #expect(model.excludedStrands.map(\.tagId) == [94], "Still shown, struck through")

        repository.failure = .offline
        await model.toggleStrand(94)
        #expect(
            model.excludedStrands.map(\.tagId) == [94],
            "The re-blend failed, so the only copy of the strand must not be dropped"
        )

        repository.failure = nil
        repository.dna = BlendDNA(strands: [strand(94, "Isekai")], seedCount: 1)
        await model.run()
        #expect(model.excludedStrands.isEmpty, "The blend returned it; the spare copy goes")
    }

    // MARK: Item 47 — a superseded blend is not a failure

    /// A blend superseded by a later edit dies with `.cancelled` while the
    /// replacement is still asleep in its debounce, so the generation guard
    /// passes and a "Cancelled" `FailureState` with a Retry was drawn.
    @Test("A cancelled blend shows no failure")
    func cancelledBlendShowsNoFailure() async throws {
        let repository = BlendRepository()
        repository.failure = .cancelled
        let model = try await model(repository)

        await model.run()

        #expect(model.failure == nil)
    }

    /// The control: a real failure still reaches the screen.
    @Test("A real blend failure is still shown")
    func realBlendFailureIsShown() async throws {
        let repository = BlendRepository()
        repository.failure = .offline
        let model = try await model(repository)

        await model.run()

        #expect(model.failure == .offline)
    }

    // MARK: Item 18 — tags reach the wire as ids

    /// `/v1/series/mix` ignores a tag name outright (measured 2026-09-14:
    /// `tag=Isekai` returns the unfiltered blend, `tag=94` filters), so a
    /// chip that only knew a name changed nothing.
    @Test("Every DNA strand's id is remembered against its name")
    func strandIDsAreRemembered() async throws {
        let repository = BlendRepository()
        repository.dna = BlendDNA(strands: [strand(94, "Isekai"), strand(1180, "Regression")], seedCount: 1)
        let model = try await model(repository)

        await model.run()

        #expect(model.tagIDsByName["Isekai"] == 94)
        #expect(model.tagIDsByName["Regression"] == 1180)
    }

    /// The bundle holds 2,686 of the API's 7,146 tags, so a tag picked from
    /// the sheet before any blend has run is the case that matters most.
    @Test("A tag picked from the sheet is remembered by id")
    func pickedTagIDIsRemembered() async throws {
        let model = try await model(BlendRepository())
        model.noteTagID(Self.tag(94, "Isekai"))

        #expect(model.tagIDsByName["Isekai"] == 94)
    }

    // MARK: Item 52 — the suggested row is capped

    /// A non-lazy `HStack` drew every save: 300 payload decodes on the
    /// `ShelfStore` actor, 300 view bodies, 300 arrival springs and 300 cover
    /// requests in one frame, on every appearance, for a row showing six.
    @Test("The suggested seed row is capped")
    func suggestedSeedsAreCapped() async throws {
        let shelf = try await seededShelf(saves: 60)
        let model = MixModel(repository: BlendRepository(), shelf: shelf)

        let suggested = await model.suggestedSeeds()

        #expect(suggested.count == 24)
    }
}

/// Screens F20 (2026-09-14): every toggle in the tag picker was a blend
/// 350 ms later while the sheet still covered the grid.
@Suite("Blends while the tag picker is up")
@MainActor
struct MixTagPickerHoldTests {
    private func model(_ repository: BlendRepository) async throws -> MixModel {
        let shelf = ShelfStore(database: try AppDatabase.inMemory(), clock: TestClock())
        let model = MixModel(repository: repository, shelf: shelf, clock: ImmediateClock())
        model.addSeed(SeriesFactory.make(id: 1, title: "Seed"))
        return model
    }

    /// Three tags picked with the sheet up, then the sheet closed. Expected
    /// to fail before the fix with: `repository.mixCalls == 0` → `3` (each
    /// write blended; `holdBlends` did not exist — before it does, the call
    /// does not compile, which proves nothing about behaviour).
    @Test("Three picks with the sheet up are no requests; closing it is one")
    func picksAreHeldUntilDismiss() async throws {
        let repository = BlendRepository()
        let model = try await model(repository)

        model.holdBlends()
        for tag in ["Isekai", "Regression", "Revenge"] {
            model.filters.tags.append(tag)
            model.filtersDidChange()
        }
        await settle(hops: 100) { false }
        #expect(repository.mixCalls == 0)

        model.releaseBlends()
        await settle { repository.mixCalls == 1 }
        #expect(repository.mixCalls == 1)
        #expect(model.isHoldingBlends == false)
    }

    /// The control, and the other half: a sheet closed with nothing picked
    /// owes nothing, and a filter written with no sheet up blends as before.
    @Test("Closing the sheet with nothing picked is no request")
    func nothingPickedIsNoRequest() async throws {
        let repository = BlendRepository()
        let model = try await model(repository)

        model.holdBlends()
        model.releaseBlends()
        await settle(hops: 100) { false }
        #expect(repository.mixCalls == 0)

        model.filters.types = ["manhwa"]
        model.filtersDidChange()
        await settle { repository.mixCalls == 1 }
        #expect(repository.mixCalls == 1)
    }
}

/// Screens F22 (2026-09-14): `MixView`'s `.task` decoded the shelf on every
/// appearance for a row shown only while `seeds` is empty.
@Suite("Suggested seeds")
@MainActor
struct MixSuggestedSeedsTests {
    /// Expected to fail before the fix with: `suggested.isEmpty` → 24 rows
    /// (the shelf was read regardless of the seeds).
    @Test("With a seed picked, the shelf is not read")
    func seedsPickedMeansNoShelfRead() async throws {
        let shelf = try await seededShelf(saves: 30)
        let model = MixModel(repository: BlendRepository(), shelf: shelf)
        model.addSeed(SeriesFactory.make(id: 99, title: "Seed"))

        let suggested = await model.suggestedSeeds()

        #expect(suggested.isEmpty)
    }

    /// The control: with no seed, the row is the shelf's first 24 (item 52).
    @Test("With no seed picked, the shelf's saves are suggested")
    func noSeedsMeansShelfRead() async throws {
        let shelf = try await seededShelf(saves: 30)
        let model = MixModel(repository: BlendRepository(), shelf: shelf)

        let suggested = await model.suggestedSeeds()

        #expect(suggested.count == 24)
    }
}
