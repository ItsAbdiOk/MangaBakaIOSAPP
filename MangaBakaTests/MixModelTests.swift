import Foundation
import Testing
@testable import MangaBaka

private final class MixRepository: StubRepositoryBase, @unchecked Sendable {
    private(set) var mixCalls = 0
    private(set) var lastSeeds: [Int] = []
    var results: [Recommendation] = []

    override func mix(seeds: [Int], filters: SearchQuery) async -> [Recommendation] {
        mixCalls += 1
        lastSeeds = seeds
        return results
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
