import Testing
import Foundation
@testable import MangaBaka

/// Publishers as a way in.
@Suite("Browsing by publisher")
struct PublisherBrowseTests {
    @Test("A publisher becomes a real filter on the query")
    func publisherReachesTheAPI() {
        // Verified against the live API on 2026-09-10: publisher=Seven Seas
        // answers 1,265 of 304,096, a name it does not know answers 0 rather
        // than being ignored, and the rows really are theirs.
        var query = SearchQuery()
        query.publisher = "Seven Seas"

        let names = query.queryItems.filter { $0.name == "publisher" }.map(\.value)
        #expect(names == ["Seven Seas"])
    }

    @Test("A publisher on its own is a real query")
    func publisherIsNotEmpty() {
        // The same trap "Surprise me" fell into: a query the app reads as empty
        // returns before making a request, and the screen keeps its idle state
        // while the reader waits for results that were never asked for.
        var query = SearchQuery()
        query.publisher = "Ize Press"
        #expect(!query.isEmpty)
    }

    @Test("An empty publisher is not sent")
    func blankPublisherIsDropped() {
        var query = SearchQuery(text: "murim")
        query.publisher = ""
        #expect(!query.queryItems.contains { $0.name == "publisher" })
    }

    @Test("A saved lens says which publisher it is for")
    func describedInALens() {
        var query = SearchQuery()
        query.publisher = "Seven Seas"
        #expect(SearchLens.describe(query).contains("publisher: Seven Seas"))
    }

    @Test("Arriving from browse narrows the query rather than replacing it")
    @MainActor
    func browseAdds() async {
        // UX#11, decision 2026-09-13: Browse adds, like the panel's own
        // publisher picker, and the pick shows as a token beside the text.
        // Inverted from "replaces" — expected to fail on HEAD~ with:
        // `model.query.text == "leftover"` → actual `nil`.
        let model = SearchModel(repository: StubRepositoryBase())
        model.query = SearchQuery(text: "leftover", types: ["novel"])

        model.applyBrowse(publisher: "Ize Press")

        #expect(model.query.publisher == "Ize Press")
        #expect(model.query.text == "leftover")
        #expect(model.query.types == ["novel"])
    }
}

/// A clock that does not wait, so the debounce collapses without spending
/// 350 ms of real time per test. Same shape as `SearchAskRulesTests`'.
private struct ImmediateClock: _Concurrency.Clock {
    typealias Instant = ContinuousClock.Instant

    var now: Instant { ContinuousClock().now }
    var minimumResolution: Duration { .zero }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        try Task.checkCancellation()
    }
}

/// Holds a request open until the test lets it answer, so "a keystroke
/// landed while the request was in the air" is a sequence the test controls
/// rather than a race it hopes for.
private actor Gate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        released = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

/// Yields until `condition` holds or `hops` have passed — a bound far past
/// what scheduling needs, so a broken sequence ends instead of hanging.
@MainActor
private func settle(hops: Int = 1_000, until condition: () -> Bool) async {
    for _ in 0..<hops where !condition() {
        await Task.yield()
    }
}

/// Screens F14 (2026-09-14): the spinner's lifecycle across a cancelled
/// request. The B-1 cancellation guard returned with `isSearching` still
/// true, and the replacement's short-text branch never touched it.
@Suite("The publisher field's spinner")
@MainActor
struct PublisherSearchSpinnerTests {
    /// Type "se", let the request go out, delete to "s". Expected to fail
    /// before the fix with: `search.isSearching == false` → `true` (the
    /// short-text branch reset results and flags but not the spinner, and
    /// the cancelled request returned before its own reset).
    @Test("Deleting to one character while a request is in the air clears the spinner")
    func shortTextClearsSpinnerAfterCancelledRequest() async {
        let gate = Gate()
        let search = PublisherSearch(
            search: { _ in
                await gate.wait()
                return []
            },
            clock: ImmediateClock()
        )

        search.update(query: "se")
        await settle { search.isSearching }
        #expect(search.isSearching, "Sanity: the request is in the air")

        search.update(query: "s")
        #expect(search.isSearching == false)

        await gate.release()
        await settle { search.hasSearched }
        #expect(search.isSearching == false)
        #expect(search.hasSearched == false, "A cancelled answer writes nothing")
        #expect(search.didFail == false)
    }

    /// The control: a request that lands unopposed clears its own spinner
    /// and records that it searched — the known answer the test above must
    /// not have broken.
    @Test("A request that lands clears the spinner and marks the search done")
    func landedRequestClearsSpinner() async {
        let search = PublisherSearch(search: { _ in [] }, clock: ImmediateClock())

        search.update(query: "seven")
        await settle { search.hasSearched }

        #expect(search.hasSearched)
        #expect(search.isSearching == false)
        #expect(search.didFail == false)
    }

    /// Item 48's own case, kept: a keystroke mid-flight must not clear the
    /// spinner under the replacement's request, and the cancelled answer
    /// must not be written.
    @Test("A cancelled answer does not clear the spinner the replacement owns")
    func cancelledAnswerLeavesReplacementSpinner() async {
        let first = Gate()
        let second = Gate()
        let calls = Counter()
        let search = PublisherSearch(
            search: { text in
                calls.record(text)
                if text == "se" { await first.wait() } else { await second.wait() }
                return nil
            },
            clock: ImmediateClock()
        )

        search.update(query: "se")
        await settle { calls.count == 1 }
        search.update(query: "sev")
        await settle { calls.count == 2 }
        #expect(search.isSearching, "The second request is in the air")

        await first.release()
        await settle(hops: 50) { false }
        #expect(search.isSearching, "The first answer, cancelled, must not clear the second's spinner")
        #expect(search.didFail == false, "The cancelled failure is not shown")

        await second.release()
        await settle { search.hasSearched }
        #expect(search.isSearching == false)
        #expect(search.didFail, "The live request's failure is")
    }

    private final class Counter: @unchecked Sendable {
        private(set) var count = 0
        func record(_ text: String) { count += 1 }
    }
}
