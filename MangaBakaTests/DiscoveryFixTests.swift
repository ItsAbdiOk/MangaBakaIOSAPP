import Foundation
import Testing
@testable import MangaBaka

/// Regression tests for the discovery-ui fix batch (docs/reviews/perf/discovery-ui.md,
/// 2026-09-15): D2 (a swipe's own top-up must not be awaited by the swipe that
/// triggered it), PS7 (the stack's blend must send blocked tags the same way
/// Mix does), and D6 (a corrupt saved lens must not take the rest of the
/// lenses down with it).
@Suite("Discovery fix batch")
struct DiscoveryFixTests {
    /// Answers the first `feed` call immediately and every call after that
    /// only once released — modelled on `SurpriseAndStackTests.SlowRepository`,
    /// except it distinguishes "the initial load" from "a top-up triggered
    /// mid-session" instead of gating every call alike.
    private final class SlowTopUpRepository: StubRepositoryBase, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private(set) var topUpsStarted = 0

        override func feed(_ feed: FeedKind, forceRefresh: Bool) async -> FeedResult {
            let call: Int = {
                lock.lock(); defer { lock.unlock() }
                count += 1
                return count
            }()
            if call > 1 {
                lock.withLock { topUpsStarted += 1 }
                // Long enough that a caller which mistakenly awaits this
                // would clearly overshoot `elapsed < 0.5` below; short enough
                // that the test suite does not stall if the fix regresses.
                try? await Task.sleep(for: .seconds(1))
            }
            let base = call * 100
            return FeedResult(
                series: (base..<(base + 5)).map { SeriesFactory.make(id: $0, title: "S\($0)") },
                origin: .network
            )
        }
    }

    private func makeShelf() throws -> ShelfStore {
        ShelfStore(database: try AppDatabase.inMemory())
    }

    /// D2. Before the fix, `react(_:)` calls `await refill()` directly once
    /// the queue drops to two, so this test's third reaction would block on
    /// `SlowTopUpRepository`'s 1s delay before returning — failing the
    /// `elapsed < 0.5` assertion below. `refill()`'s own de-duplication
    /// (`refillTask`) still runs the network call; it is only no longer on
    /// `react`'s own await chain.
    @Test("A reaction that triggers a refill returns without waiting for it")
    @MainActor
    func reactDoesNotAwaitTheRefillItTriggers() async throws {
        let repository = SlowTopUpRepository()
        let model = StackModel(repository: repository, shelf: try makeShelf())

        await model.loadIfNeeded()
        try #require(model.queue.count == 5, "control: the first feed call answers immediately")

        await model.react(.skipped)
        await model.react(.skipped)
        // The third reaction leaves exactly two cards, which is what triggers
        // the top-up (`react`'s own `queue.count <= 2` check).
        let start = Date()
        await model.react(.skipped)
        let elapsed = Date().timeIntervalSince(start)

        #expect(
            elapsed < 0.5,
            "react awaited the refill it triggered instead of detaching it (took \(elapsed)s)"
        )
        #expect(model.queue.count == 2, "the reacted card is removed even while the top-up is in flight")

        // Let the detached refill actually finish so the test doesn't leak a
        // dangling Task, and confirm it did start.
        let deadline = Date().addingTimeInterval(3)
        while repository.topUpsStarted == 0, Date() < deadline { await Task.yield() }
        #expect(repository.topUpsStarted == 1, "the low-queue top-up must still have been requested")
    }

    /// PS7. `SeriesRepository.feed(.mix(seeds:))` sends blocked tags as
    /// `tag_not` (its `filterQuery()`'s default) — the spec for
    /// `/v1/series/mix` does not recognise that key. `SeriesRepository+Mix
    /// .swift`'s `mix(seeds:filters:excludedTags:)` sends `blocked_tag`
    /// instead, verified live against the endpoint (that file's own doc
    /// comment). `SeriesRepository+Mix.swift` is outside this fix's file
    /// list, so the fix here is routing the stack's seeded blend through the
    /// same `repository.mix` call Mix's own screen already uses, rather than
    /// `repository.feed(.mix(seeds:))`.
    ///
    /// Expected to fail before the fix with: `mixCalls.isEmpty == true` and
    /// `feedMixCalls == 1` — the seeded blend went through `feed(.mix)`, the
    /// path that sends the wrong key, and `repository.mix` was never called.
    @Test("A seeded blend calls the same repository path Mix uses, not feed(.mix)")
    @MainActor
    func stackSeededBlendUsesMixNotFeed() async throws {
        final class MixRoutingRepository: StubRepositoryBase, @unchecked Sendable {
            private(set) var mixCalls: [[Int]] = []
            private(set) var feedMixCalls = 0

            override func feed(_ feed: FeedKind, forceRefresh: Bool) async -> FeedResult {
                if case .mix = feed { feedMixCalls += 1 }
                return FeedResult(series: [], origin: .network)
            }

            override func mix(
                seeds: [Int], filters: SearchQuery, excludedTags: [Int]
            ) async -> MixResult {
                mixCalls.append(seeds)
                let recommendations = seeds.map { seed in
                    Recommendation(
                        series: SeriesFactory.make(id: seed + 1000, title: "M\(seed)"),
                        score: nil, sharedTags: nil, sharedTagsTotal: nil,
                        matchedAuthor: nil, matchedRelated: nil, sharedUsers: nil, rank: nil
                    )
                }
                return MixResult(recommendations: recommendations)
            }
        }

        let shelf = try makeShelf()
        try await shelf.record(SeriesFactory.make(id: 7, title: "A"), as: .saved)
        try await shelf.record(SeriesFactory.make(id: 8, title: "B"), as: .saved)

        let repository = MixRoutingRepository()
        let model = StackModel(repository: repository, shelf: shelf)
        await model.loadIfNeeded()

        #expect(repository.feedMixCalls == 0, "the seeded blend must not go through feed(.mix)")
        #expect(repository.mixCalls.count == 1)
        #expect(Set(repository.mixCalls.first ?? []) == [7, 8])
        #expect(model.queue.map(\.id).sorted() == [1007, 1008])
    }

    /// D6. `SearchLensStore`'s init used to decode `[SearchLens]` in one shot,
    /// so one lens whose shape no longer matched failed the whole array and
    /// every lens on disk vanished with it. Expected to fail before the fix
    /// with: `own.isEmpty == true` — decoding the raw array as one
    /// `[SearchLens]` throws on the malformed middle element and `own` never
    /// gets set at all.
    @Test("A corrupt saved lens does not take the other saved lenses down with it")
    @MainActor
    func corruptLensDoesNotWipeTheRest() throws {
        let suiteName = "DiscoveryFixTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let good = #"{"id":"1","name":"Cosy","rule":"Everything","query":{},"isOwn":true}"#
        // Valid JSON, but missing the non-optional "rule" and "query" keys —
        // parses fine as a loose `[String: Any]` and fails only when decoded
        // against `SearchLens`'s own shape, which is exactly the failure
        // `decodeLenient` is meant to isolate to this one element.
        let malformed = #"{"id":"2","name":"Broken"}"#
        let alsoGood = #"{"id":"3","name":"Seinen","rule":"Everything","query":{},"isOwn":true}"#
        let raw = "[\(good),\(malformed),\(alsoGood)]"
        defaults.set(Data(raw.utf8), forKey: "search.lenses")

        let store = SearchLensStore(defaults: defaults)

        #expect(store.own.map(\.name).sorted() == ["Cosy", "Seinen"])
    }
}
