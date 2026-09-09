import Foundation
import Testing
@testable import MangaBaka

private final class MixRepository: StubRepositoryBase, @unchecked Sendable {
    private(set) var mixCalls = 0
    private(set) var lastSeeds: [Int] = []
    var results: [Recommendation] = []
    /// Handed back as the blend's DNA, so a test can drive the strand controls.
    var dna: BlendDNA = .empty
    private(set) var lastExcludedTags: [Int] = []

    override func mix(
        seeds: [Int],
        filters: SearchQuery,
        excludedTags: [Int]
    ) async -> MixResult {
        mixCalls += 1
        lastSeeds = seeds
        lastExcludedTags = excludedTags.sorted()
        return MixResult(recommendations: results, dna: dna)
    }
}

@Suite("Mix model")
@MainActor
struct MixModelTests {
    private func makeShelf() throws -> ShelfStore {
        ShelfStore(database: try AppDatabase.inMemory(), clock: TestClock())
    }

    private func recommendation(_ id: Int, sharedTags: Int? = nil) -> Recommendation {
        Recommendation(
            series: SeriesFactory.make(id: id, title: "S\(id)"),
            score: 0.5,
            sharedTags: sharedTags.map { _ in [Recommendation.Tag(id: 1, name: "Necromancy")] },
            sharedTagsTotal: sharedTags,
            matchedAuthor: false,
            matchedRelated: false
        )
    }

    /// The API rejects a seedless mix with HTTP 400. Spending a request to be
    /// told that wastes a budget shared with strangers on the same network.
    @Test("Running with no seeds never calls the API")
    func seedlessDoesNotCallTheAPI() async throws {
        let repository = MixRepository()
        let model = MixModel(repository: repository, shelf: try makeShelf())

        await model.run()

        #expect(repository.mixCalls == 0)
        #expect(model.message != nil, "The reader needs to know why nothing happened")
    }

    @Test("Seeds are capped at three")
    func seedsAreCapped() async throws {
        let model = MixModel(repository: MixRepository(), shelf: try makeShelf())
        for id in 1...5 {
            model.addSeed(SeriesFactory.make(id: id, title: "S\(id)"))
        }
        #expect(model.seeds.count <= 3)
    }

    @Test("Removing a seed drops exactly that one")
    func removeSeed() async throws {
        let model = MixModel(repository: MixRepository(), shelf: try makeShelf())
        model.addSeed(SeriesFactory.make(id: 1, title: "One"))
        model.addSeed(SeriesFactory.make(id: 2, title: "Two"))

        model.removeSeed(id: 1)

        #expect(model.seeds.map(\.id) == [2])
    }

    /// Results left over from the previous seeds would sit under the new ones
    /// looking like an answer to a question nobody asked.
    @Test("Changing the seeds clears stale results")
    func seedChangeClearsResults() async throws {
        let repository = MixRepository()
        repository.results = [recommendation(9)]
        let model = MixModel(repository: repository, shelf: try makeShelf())
        model.addSeed(SeriesFactory.make(id: 1, title: "One"))
        await model.run()
        #expect(!model.results.isEmpty)

        model.addSeed(SeriesFactory.make(id: 2, title: "Two"))

        #expect(model.results.isEmpty, "Old results must not sit under new seeds")
    }

    @Test("Running with seeds passes them through")
    func runsWithSeeds() async throws {
        let repository = MixRepository()
        repository.results = [recommendation(9, sharedTags: 88)]
        let model = MixModel(repository: repository, shelf: try makeShelf())
        model.addSeed(SeriesFactory.make(id: 3397, title: "Solo Leveling"))

        await model.run()

        #expect(repository.lastSeeds == [3397])
        #expect(model.results.count == 1)
        #expect(model.results.first?.reason != nil, "The API's own reason should survive")
    }

    /// Someone who has used the Stack already told the app what they like.
    @Test("Suggested seeds come from the shelf")
    func suggestsFromShelf() async throws {
        let shelf = try makeShelf()
        try await shelf.record(SeriesFactory.make(id: 7, title: "Saved"), as: .saved)
        let model = MixModel(repository: MixRepository(), shelf: shelf)

        let suggestions = await model.suggestedSeeds()

        #expect(suggestions.map(\.id) == [7])
    }

    /// A skip is not an endorsement and must never be offered as a seed.
    @Test("Skipped series are not suggested as seeds")
    func skippedAreNotSuggested() async throws {
        let shelf = try makeShelf()
        try await shelf.record(SeriesFactory.make(id: 8, title: "Skipped"), as: .skipped)
        let model = MixModel(repository: MixRepository(), shelf: shelf)

        #expect(await model.suggestedSeeds().isEmpty)
    }
}

@Suite("Shelf store")
struct ShelfStoreTests {
    private func makeShelf() throws -> ShelfStore {
        ShelfStore(database: try AppDatabase.inMemory(), clock: TestClock())
    }

    @Test("A saved series comes back")
    func savesAndReads() async throws {
        let shelf = try makeShelf()
        try await shelf.record(SeriesFactory.make(id: 1, title: "Kept"), as: .saved)

        let saved = try await shelf.entries(.saved)
        #expect(saved.map(\.id) == [1])
        #expect(saved.first?.displayTitle == "Kept")
    }

    /// A skip is recorded rather than discarded, so the same series stops
    /// reappearing in the stack and can still be recovered.
    @Test("Saves and skips are kept apart")
    func kindsAreSeparate() async throws {
        let shelf = try makeShelf()
        try await shelf.record(SeriesFactory.make(id: 1, title: "Kept"), as: .saved)
        try await shelf.record(SeriesFactory.make(id: 2, title: "Passed"), as: .skipped)

        #expect(try await shelf.entries(.saved).map(\.id) == [1])
        #expect(try await shelf.entries(.skipped).map(\.id) == [2])
    }

    /// The stack asks for this to avoid showing something already judged.
    @Test("Reacted ids cover both saves and skips")
    func reactedCoversBoth() async throws {
        let shelf = try makeShelf()
        try await shelf.record(SeriesFactory.make(id: 1), as: .saved)
        try await shelf.record(SeriesFactory.make(id: 2), as: .skipped)

        #expect(try await shelf.reactedIDs() == [1, 2])
    }

    /// Changing your mind is ordinary: a skip later saved must not leave two
    /// rows, or the series appears in both lists at once.
    @Test("Re-reacting replaces rather than duplicates")
    func reReactingReplaces() async throws {
        let shelf = try makeShelf()
        let series = SeriesFactory.make(id: 1, title: "Reconsidered")
        try await shelf.record(series, as: .skipped)
        try await shelf.record(series, as: .saved)

        #expect(try await shelf.entries(.saved).map(\.id) == [1])
        #expect(try await shelf.entries(.skipped).isEmpty, "It cannot be in both lists")
    }

    @Test("Removing takes it out of both lists")
    func removes() async throws {
        let shelf = try makeShelf()
        try await shelf.record(SeriesFactory.make(id: 1), as: .saved)

        try await shelf.remove(seriesId: 1)

        #expect(try await shelf.entries(.saved).isEmpty)
        #expect(try await shelf.reactedIDs().isEmpty)
    }

    /// The shelf renders when the cache is empty or the reader is offline, so
    /// it stores its own copy of the series rather than a reference to one.
    @Test("A saved series survives without the feed cache")
    func selfContained() async throws {
        let database = try AppDatabase.inMemory()
        let shelf = ShelfStore(database: database, clock: TestClock())
        try await shelf.record(
            SeriesFactory.make(id: 1, title: "Standalone", cover: .sized),
            as: .saved
        )

        // Wipe the derived cache out from under the shelf. GRDB offers sync
        // and async writes; the sync one is named explicitly because in an
        // async test the async overload wins and does not compile.
        try await database.writer.write { db in
            try db.execute(sql: "DELETE FROM series")
            try db.execute(sql: "DELETE FROM feedEntry")
        }

        let saved = try await shelf.entries(.saved)
        #expect(saved.first?.displayTitle == "Standalone")
        #expect(saved.first?.cover.width == 200, "The stored copy keeps its cover")
    }

    /// Most recent first, so the shelf reads as a record of what you just found.
    @Test("Newest saves come first")
    func newestFirst() async throws {
        let clock = TestClock()
        let shelf = ShelfStore(database: try AppDatabase.inMemory(), clock: clock)
        try await shelf.record(SeriesFactory.make(id: 1, title: "First"), as: .saved)
        clock.advance(by: 60)
        try await shelf.record(SeriesFactory.make(id: 2, title: "Second"), as: .saved)

        #expect(try await shelf.entries(.saved).map(\.id) == [2, 1])
    }
}

/// The blend's DNA: ten weighted tags, and the only steering the API allows.
@Suite("Blend DNA")
@MainActor
struct BlendDNATests {
    private func makeShelf() throws -> ShelfStore {
        ShelfStore(database: try AppDatabase.inMemory(), clock: TestClock())
    }

    private func strand(_ tagId: Int, _ name: String, _ weight: Double) -> BlendDNA.Strand {
        BlendDNA.Strand(tagId: tagId, name: name, weight: weight)
    }

    private func dna(_ strands: [BlendDNA.Strand]) -> BlendDNA {
        BlendDNA(strands: strands, seedCount: 1)
    }

    /// Verified live: excluding a strand drops it from the DNA and re-derives
    /// the rest. The app has to send that exclusion or nothing happens.
    @Test("Switching a strand off sends it as an exclusion and re-blends")
    func excludingAStrandReblends() async throws {
        let repository = MixRepository()
        repository.dna = dna([strand(467, "Kuudere", 0.16), strand(827, "Twins", 0.11)])
        let model = MixModel(repository: repository, shelf: try makeShelf())
        model.addSeed(SeriesFactory.make(id: 1, title: "Seed"))

        await model.run()
        #expect(repository.lastExcludedTags.isEmpty)

        await model.toggleStrand(467)
        #expect(repository.lastExcludedTags == [467])
        #expect(model.isDNAEdited)
        #expect(repository.mixCalls == 2, "an edit has to re-blend, or nothing changes")
    }

    @Test("Switching it back on removes the exclusion")
    func togglingBackOn() async throws {
        let repository = MixRepository()
        repository.dna = dna([strand(467, "Kuudere", 0.16)])
        let model = MixModel(repository: repository, shelf: try makeShelf())
        model.addSeed(SeriesFactory.make(id: 1, title: "Seed"))

        await model.run()
        await model.toggleStrand(467)
        await model.toggleStrand(467)

        #expect(repository.lastExcludedTags.isEmpty)
        #expect(!model.isDNAEdited)
    }

    @Test("Starting over clears every exclusion")
    func resetClearsExclusions() async throws {
        let repository = MixRepository()
        repository.dna = dna([strand(1, "A", 0.2), strand(2, "B", 0.1)])
        let model = MixModel(repository: repository, shelf: try makeShelf())
        model.addSeed(SeriesFactory.make(id: 1, title: "Seed"))

        await model.run()
        await model.toggleStrand(1)
        await model.toggleStrand(2)
        #expect(model.excludedTags.count == 2)

        await model.resetDNA()
        #expect(model.excludedTags.isEmpty)
        #expect(repository.lastExcludedTags.isEmpty)
    }

    /// The weights re-derive server-side after every edit, so showing how they
    /// moved is the feedback for the edit just made.
    @Test("Movement is reported against the previous blend")
    func reportsMovement() async throws {
        let repository = MixRepository()
        repository.dna = dna([strand(1, "A", 0.20), strand(2, "B", 0.10)])
        let model = MixModel(repository: repository, shelf: try makeShelf())
        model.addSeed(SeriesFactory.make(id: 1, title: "Seed"))

        await model.run()
        #expect(model.moves.isEmpty, "a first blend has nothing to compare against")

        repository.dna = dna([strand(1, "A", 0.30), strand(2, "B", 0.10)])
        await model.toggleStrand(9)

        let move = try #require(model.moves.first)
        #expect(move.name == "A")
        #expect(move.from == 0.20)
        #expect(move.to == 0.30)
        #expect(move.rose)
    }

    /// A weight that barely twitched is noise, not a result.
    @Test("Movement below half a percent is not reported")
    func ignoresNoise() {
        let before = dna([strand(1, "A", 0.200)])
        let after = dna([strand(1, "A", 0.202)])
        #expect(BlendDNA.moves(from: before, to: after).isEmpty)
    }

    /// Changing the seeds invalidates everything derived from them.
    @Test("Editing the seeds discards the DNA and its exclusions")
    func seedChangeClearsDNA() async throws {
        let repository = MixRepository()
        repository.dna = dna([strand(1, "A", 0.2)])
        let model = MixModel(repository: repository, shelf: try makeShelf())
        model.addSeed(SeriesFactory.make(id: 1, title: "Seed"))

        await model.run()
        await model.toggleStrand(1)
        #expect(model.isDNAEdited)

        model.addSeed(SeriesFactory.make(id: 2, title: "Another"))
        #expect(model.dna.isEmpty)
        #expect(model.excludedTags.isEmpty)
    }
}

/// The DNA has to survive the wire, and the endpoint's envelope is its own
/// shape: `data` alongside `dna` and `seed_count` at the top level.
@Suite("Blend DNA decoding", .serialized)
struct BlendDNADecodingTests {
    private let baseURL = URL(string: "https://api.example.invalid").unsafeTestURL

    @Test("A real mix response yields both the results and the DNA")
    func decodesDNA() async throws {
        let body = Data("""
        {"status":200,
         "seed_count":1,
         "dna":[{"tag_id":467,"name":"Kuudere","weight":0.1605},
                {"tag_id":253,"name":"Twins","weight":0.1122}],
         "data":[{"score":0.9,"matched_related":true,
                  "series":{"id":7,"state":"active","cover":{},
                            "titles":[{"language":"en","traits":["official"],
                                       "title":"Blend","is_primary":true}]}}]}
        """.utf8)
        URLProtocolStub.setHandler { _ in .respond(.init(body: body)) }
        defer { URLProtocolStub.reset() }

        let repository = SeriesRepository(
            client: APIClient(
                baseURL: baseURL,
                session: URLProtocolStub.makeSession(),
                tokenProvider: UnauthenticatedTokenProvider()
            ),
            database: try AppDatabase.inMemory(),
            clock: TestClock()
        )
        let blend = await repository.mix(seeds: [1], filters: SearchQuery(), excludedTags: [])

        #expect(blend.recommendations.count == 1)
        #expect(blend.dna.strands.count == 2)
        #expect(blend.dna.strands.first?.name == "Kuudere")
        #expect(blend.dna.seedCount == 1)
    }

    /// Sent as repeated keys, like every other list parameter on this API.
    @Test("Excluded strands are sent as repeated tag_not keys")
    func sendsExclusions() async throws {
        URLProtocolStub.setHandler { _ in
            .respond(.init(body: Data(#"{"status":200,"data":[]}"#.utf8)))
        }
        defer { URLProtocolStub.reset() }

        let repository = SeriesRepository(
            client: APIClient(
                baseURL: baseURL,
                session: URLProtocolStub.makeSession(),
                tokenProvider: UnauthenticatedTokenProvider()
            ),
            database: try AppDatabase.inMemory(),
            clock: TestClock()
        )
        _ = await repository.mix(seeds: [1], filters: SearchQuery(), excludedTags: [467, 253])

        let url = try #require(URLProtocolStub.requests.first?.url)
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.filter { $0.name == "tag_not" }.compactMap(\.value) == ["467", "253"])
    }
}

/// Excluding a strand removes it from what the API returns, so the chip
/// vanished and the only way back was "Start over" — a one-way control.
@Suite("Excluded strands stay reachable")
@MainActor
struct ExcludedStrandTests {
    private func makeShelf() throws -> ShelfStore {
        ShelfStore(database: try AppDatabase.inMemory(), clock: TestClock())
    }

    @Test("An excluded strand is remembered so it can be switched back on")
    func excludedStrandIsRemembered() async throws {
        let repository = MixRepository()
        repository.dna = BlendDNA(
            strands: [BlendDNA.Strand(tagId: 467, name: "Kuudere", weight: 0.16)],
            seedCount: 1
        )
        let model = MixModel(repository: repository, shelf: try makeShelf())
        model.addSeed(SeriesFactory.make(id: 1, title: "Seed"))
        await model.run()

        // The API drops an excluded tag from the DNA it returns.
        repository.dna = BlendDNA(strands: [], seedCount: 1)
        await model.toggleStrand(467)

        #expect(model.dna.strands.isEmpty, "the API no longer returns it")
        #expect(model.excludedStrands.map(\.name) == ["Kuudere"], "but it is still shown")

        await model.toggleStrand(467)
        #expect(model.excludedStrands.isEmpty)
        #expect(model.excludedTags.isEmpty)
    }
}
