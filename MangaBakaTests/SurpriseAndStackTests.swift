import Foundation
import Testing
@testable import MangaBaka

/// "Surprise me" set `sort = "random"` and nothing else. `SearchQuery.isEmpty`
/// ignored `sort`, so the query still read as empty, `search()` returned before
/// making a request, and the view kept rendering its idle state. The button was
/// wired up correctly and did nothing at all.
@Suite("Surprise me")
struct SurpriseTests {
    private final class RecordingRepository: StubRepositoryBase, @unchecked Sendable {
        private(set) var searches: [SearchQuery] = []

        override func search(_ query: SearchQuery) async -> FeedResult {
            searches.append(query)
            return FeedResult(
                series: [SeriesFactory.make(id: 1, title: "Random")],
                origin: .network
            )
        }
    }

    @Test("A sort-only query is not an empty query")
    func sortCountsAsAQuery() {
        var query = SearchQuery()
        #expect(query.isEmpty)
        query.sort = "random"
        #expect(!query.isEmpty)
    }

    @Test("Surprise me actually makes a request and shows results")
    func surpriseSearches() async {
        let repository = RecordingRepository()
        let model = await SearchModel(repository: repository)

        // Exactly what the button does.
        await MainActor.run { model.query.sort = "random" }
        await model.search()

        #expect(repository.searches.count == 1)
        #expect(repository.searches.first?.sort == "random")
        #expect(await model.results.count == 1)
        #expect(await model.isSearching == false)
    }

    /// The view keys its idle state off this. While it was true, the results
    /// were fetched and then never rendered.
    @Test("The screen leaves its idle state once a sort is chosen")
    func leavesIdleState() async {
        let model = await SearchModel(repository: RecordingRepository())
        await MainActor.run { model.query.sort = "random" }
        #expect(await model.query.isEmpty == false)
    }
}

/// Where the stack's queue comes from, and whether it is honest about it.
@Suite("Stack personalisation")
struct StackPersonalisationTests {
    private final class SeedRecordingRepository: StubRepositoryBase, @unchecked Sendable {
        private(set) var feeds: [FeedKind] = []
        /// id ranges keyed by seed, so a rotated blend returns different series.
        var offset = 0

        override func feed(_ feed: FeedKind, forceRefresh: Bool) async -> FeedResult {
            feeds.append(feed)
            let start = offset + feeds.count * 100
            return FeedResult(
                series: (start..<(start + 5)).map { SeriesFactory.make(id: $0, title: "S\($0)") },
                origin: .network
            )
        }
    }

    /// A feed that pauses mid-request, so two refills can be proven to
    /// overlap instead of hoping a fixed sleep makes them overlap.
    private final class SlowRepository: StubRepositoryBase, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var feeds: Int {
            lock.lock(); defer { lock.unlock() }
            return count
        }

        private func noteFeed() {
            lock.lock(); defer { lock.unlock() }
            count += 1
        }

        /// Set once a feed request is in flight and paused, so the test can
        /// wait for it deterministically — see `SlowPageRepository` in
        /// PaginationTests.
        var gate: CheckedContinuation<Void, Never>?

        override func feed(_ feed: FeedKind, forceRefresh: Bool) async -> FeedResult {
            noteFeed()
            await withCheckedContinuation { gate = $0 }
            return FeedResult(
                series: (1...5).map { SeriesFactory.make(id: $0, title: "S\($0)") },
                origin: .network
            )
        }
    }

    private func makeShelf() throws -> ShelfStore {
        ShelfStore(database: try AppDatabase.inMemory())
    }

    /// A refill is triggered from three places — first load, every reaction
    /// that leaves two cards, and the empty state's retry — and none of them
    /// waited for the last one. Two overlapping refills are two feed requests
    /// against a limit shared with strangers, for one stack.
    @Test("An overlapping refill does not fetch twice")
    func overlappingRefillFetchesOnce() async throws {
        let repository = SlowRepository()
        let model = await StackModel(repository: repository, shelf: try makeShelf())

        async let first: Void = model.refill()
        async let second: Void = model.refill()
        // Wait for the first (and only, if dedup works) feed request to
        // actually be in flight before releasing it, so the overlap is
        // proven rather than assumed from a fixed sleep.
        let deadline = Date().addingTimeInterval(2)
        while repository.gate == nil, Date() < deadline { await Task.yield() }
        repository.gate?.resume()
        _ = await (first, second)

        #expect(repository.feeds == 1, "The second refill must join the first, not repeat it")
    }

    /// `source` was stored "so the screen can say" and the screen never
    /// said it. The caption is what the header now shows.
    @Test("Every source has a caption that names it")
    func sourcesHaveCaptions() {
        let sources: [StackModel.Source] = [.yourProfile, .yourSaves, .yourLibrary, .random]
        let captions = Set(sources.map(\.caption))
        #expect(captions.count == sources.count, "Two sources reading the same is the bug")
        #expect(StackModel.Source.random.caption.contains("random"))
    }

    /// With nothing saved and no account, the queue is a random sample. The
    /// screen has to say so — calling a random queue "picked for you" is the
    /// kind of claim that makes every later recommendation untrustworthy.
    @Test("An empty shelf and no account gives a random queue, and says so")
    func randomWhenNothingKnown() async throws {
        let repository = SeedRecordingRepository()
        let model = await StackModel(repository: repository, shelf: try makeShelf())
        await model.loadIfNeeded()

        #expect(repository.feeds == [.surprise])
        #expect(await model.source == .random)
    }

    @Test("Saved series seed the blend, and the screen credits them")
    func savesSeedTheBlend() async throws {
        let shelf = try makeShelf()
        try await shelf.record(SeriesFactory.make(id: 7, title: "A"), as: .saved)
        try await shelf.record(SeriesFactory.make(id: 8, title: "B"), as: .saved)

        let repository = SeedRecordingRepository()
        let model = await StackModel(repository: repository, shelf: shelf)
        await model.loadIfNeeded()

        #expect(repository.feeds.count == 1)
        if case let .mix(seeds) = repository.feeds[0] {
            #expect(Set(seeds) == [7, 8])
        } else {
            Issue.record("Expected a seeded mix, got \(repository.feeds[0])")
        }
        #expect(await model.source == .yourSaves)
    }

    /// A skip is not an endorsement. Seeding from it would steer the stack
    /// towards exactly what the reader just rejected.
    @Test("A skipped series never seeds the blend")
    func skipsDoNotSeed() async throws {
        let shelf = try makeShelf()
        try await shelf.record(SeriesFactory.make(id: 9, title: "Skipped"), as: .skipped)

        let repository = SeedRecordingRepository()
        let model = await StackModel(repository: repository, shelf: shelf)
        await model.loadIfNeeded()

        #expect(repository.feeds == [.surprise])
    }

    /// `mix` takes no page parameter, so one set of seeds yields one batch and
    /// then repeats itself forever. Rotating is the only way the stack keeps
    /// going, and it stops the queue narrowing onto the first three saves.
    @Test("A queue that comes back fully seen rotates to the next seeds")
    func rotatesSeeds() async throws {
        let shelf = try makeShelf()
        for id in 1...6 {
            try await shelf.record(SeriesFactory.make(id: id, title: "S\(id)"), as: .saved)
        }

        // Everything the first blend returns has already been reacted to.
        final class ExhaustedFirstBlend: StubRepositoryBase, @unchecked Sendable {
            private(set) var seedGroups: [[Int]] = []

            override func feed(_ feed: FeedKind, forceRefresh: Bool) async -> FeedResult {
                guard case let .mix(seeds) = feed else {
                    return FeedResult(series: [], origin: .network)
                }
                seedGroups.append(seeds)
                // The first blend returns only series already on the shelf.
                let ids = seedGroups.count == 1 ? [1, 2, 3] : [90, 91, 92]
                return FeedResult(
                    series: ids.map { SeriesFactory.make(id: $0, title: "S\($0)") },
                    origin: .network
                )
            }
        }

        let repository = ExhaustedFirstBlend()
        let model = await StackModel(repository: repository, shelf: shelf)
        await model.loadIfNeeded()

        #expect(repository.seedGroups.count == 2)
        #expect(repository.seedGroups[0] != repository.seedGroups[1])
        #expect(await model.queue.count == 3)
    }
}
