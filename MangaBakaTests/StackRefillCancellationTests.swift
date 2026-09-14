import Foundation
import Testing
@testable import MangaBaka

/// Second-pass review, items 48 and 19 (2026-09-14), both in `StackModel`.
@Suite("Stack refill cancellation and ranking input")
struct StackRefillCancellationTests {
    /// A feed that parks every request until the test releases it, and
    /// answers each call with a different batch so the queue says which
    /// refill filled it. Modelled on `SlowRepository` in
    /// `SurpriseAndStackTests`, which keeps one gate; this keeps them all.
    private final class GatedRepository: StubRepositoryBase, @unchecked Sendable {
        private let lock = NSLock()
        private var gates: [CheckedContinuation<Void, Never>] = []
        private var count = 0

        var feeds: Int {
            lock.lock(); defer { lock.unlock() }
            return count
        }

        /// Ids `100 × n ..< 100 × n + 5` for the n-th call.
        static func batch(_ call: Int) -> [Int] { Array((call * 100)..<(call * 100 + 5)) }

        override func feed(_ feed: FeedKind, forceRefresh: Bool) async -> FeedResult {
            let call: Int = {
                lock.lock(); defer { lock.unlock() }
                count += 1
                return count
            }()
            await withCheckedContinuation { continuation in
                lock.lock(); defer { lock.unlock() }
                gates.append(continuation)
            }
            return FeedResult(
                series: Self.batch(call).map { SeriesFactory.make(id: $0, title: "S\($0)") },
                origin: .network
            )
        }

        func releaseAll() {
            lock.lock()
            let waiting = gates
            gates = []
            lock.unlock()
            waiting.forEach { $0.resume() }
        }

        func waitForFeeds(_ wanted: Int) async throws {
            let deadline = Date().addingTimeInterval(5)
            while feeds < wanted {
                try #require(Date() < deadline, "the repository never saw feed request \(wanted)")
                try await Task.sleep(for: .milliseconds(5))
            }
        }
    }

    /// Item 48. Reset while a refill is parked mid-request, so the reset's
    /// own refill is a second request; then let both answer. The cancelled
    /// first refill must not append its batch to the queue the reset just
    /// emptied, and must not clear the second refill's registration on its
    /// way out.
    ///
    /// Expected to fail before the fix with: `queue ids == [100, 101, 102,
    /// 103, 104, 200, 201, 202, 203, 204]` — the thrown-away seeds' batch
    /// dealt first, the reset's batch behind it.
    @Test("A refill cancelled by a reset does not deal into the reset stack")
    @MainActor
    func cancelledRefillDoesNotAppend() async throws {
        let repository = GatedRepository()
        let shelf = ShelfStore(database: try AppDatabase.inMemory())
        let model = StackModel(repository: repository, shelf: shelf)

        let first = Task { await model.refill() }
        try await repository.waitForFeeds(1)

        let reset = Task { await model.resetStack() }
        try await repository.waitForFeeds(2)
        #expect(model.queue.isEmpty, "control: the reset emptied the queue before either refill answered")

        repository.releaseAll()
        await first.value
        _ = await reset.value

        #expect(model.queue.map(\.id) == GatedRepository.batch(2), "only the reset's own refill deals")
        #expect(!model.isLoading, "the surviving refill ended its own loading state")
    }

    /// Item 19's measurement. The review held that the `.mix` feed arrives
    /// without `tags_v2` and so scores every card 0. It does not: recorded
    /// from `GET /v1/series/mix?series=3397&series=105398&strict=false&
    /// limit=20` on 2026-09-14, every one of the 20 rows carried `tags_v2`
    /// (30 to 103 each; 533 KB for the page). This is the smallest row,
    /// wrapper and all. Adding `schema=full` to that endpoint answers 400
    /// (`Validation error: Unrecognized key: "schema"`), so the proposed fix
    /// would have broken the stack's main feed outright.
    ///
    /// A control, not a fix: it fails if the mix decode ever drops the tags
    /// the ranker needs, which is the only way the ranker becomes inert.
    @Test("A dealt mix row carries the tags the taste ranker scores from")
    func mixRowScores() throws {
        let decoder = Fixture.decoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(
            APIEnvelope<[Recommendation]>.self, from: try Fixture.data("mix-lean-2026-09-14")
        )
        let dealt = try #require(envelope.data?.first?.series)
        #expect(dealt.richTags.count == 35)

        let loved = try #require(dealt.richTags.first)
        let affinity = TagAffinity(tagId: loved.id, name: loved.name, score: 1, seriesCount: 1)
        let ranker = TasteRanker(affinities: [affinity])
        #expect(ranker.score(dealt) > 0, "one shared tag is enough to move it")
        #expect(ranker.reasons(for: dealt) == [loved.name])
    }
}
