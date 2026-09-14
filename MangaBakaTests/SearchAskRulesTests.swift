import Foundation
import Testing
@testable import MangaBaka

/// A clock that does not wait.
///
/// Debounces still collapse under it — a task cancelled before its body ever
/// ran never reaches its sleep — so "three taps are one request" is provable
/// without spending 300 ms of real time on it. The wider sweep of
/// `Task.sleep` out of the suite is item 129's, and belongs to the test lane;
/// this is the one case a test here needs.
///
/// Spelled with its module because this one does not: `MangaBaka` has its own
/// `Clock` protocol (`Core/Persistence/Clock.swift`).
private struct ImmediateClock: _Concurrency.Clock {
    typealias Instant = ContinuousClock.Instant

    var now: Instant { ContinuousClock().now }
    var minimumResolution: Duration { .zero }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        try Task.checkCancellation()
    }
}

/// Yields until the debounced search lands, or 1,000 hops have passed —
/// whichever comes first. The bound is a guess, chosen to be far past what
/// scheduling needs (the isolated run settles in under ten) while still
/// ending rather than hanging a suite if the search never fires.
@MainActor
private func waitForSecondSearch(
    _ repository: AskCountingRepository, target: Int = 2, hops: Int = 1_000
) async {
    for _ in 0..<hops where repository.searchCount < target {
        await Task.yield()
    }
}

private final class AskCountingRepository: StubRepositoryBase, @unchecked Sendable {
    private(set) var searchCount = 0
    private(set) var lastQuery: SearchQuery?

    override func search(_ query: SearchQuery) async -> FeedResult {
        searchCount += 1
        lastQuery = query
        return FeedResult(series: [], origin: .network)
    }
}

/// When the Search screen is allowed to spend a request, and what a dismissal
/// means.
@Suite("Search ask rules")
@MainActor
struct SearchAskRulesTests {
    // MARK: Item 49 — one character is not a search, filters or no filters

    /// `query.isEmpty` is false the moment any filter is set, so Return on a
    /// one-character field with Type=Manhwa omitted `q` entirely and answered
    /// 21,596 manhwa under a field showing "a" and a heading reading "21,596
    /// results". `RecentSearches` refuses the same term, so the two rules
    /// disagreed about what "a" means.
    @Test("Return on a one-character field with filters set asks nothing")
    func shortTextWithFiltersDoesNotSearch() async {
        let repository = AskCountingRepository()
        let model = SearchModel(repository: repository)
        model.query.types = ["manhwa"]
        model.query.text = "a"

        await model.search()

        #expect(repository.searchCount == 0)
    }

    /// The control, and the behaviour that must survive: a filter-only search
    /// with no text at all is a real query and still goes out.
    @Test("A filter-only search with no text still asks")
    func filterOnlyStillSearches() async {
        let repository = AskCountingRepository()
        let model = SearchModel(repository: repository)
        model.query.types = ["manhwa"]

        await model.search()

        #expect(repository.searchCount == 1)
        #expect(repository.lastQuery?.text == nil)
    }

    /// The second control: two characters is a search, so the guard is on the
    /// length rule and not on "there is text".
    @Test("Two characters with filters set does ask")
    func askedTextWithFiltersSearches() async {
        let repository = AskCountingRepository()
        let model = SearchModel(repository: repository)
        model.query.types = ["manhwa"]
        model.query.text = "ab"

        await model.search()

        #expect(repository.searchCount == 1)
    }

    // MARK: Item 51 — scope taps go through the debounce

    /// All → Manga → Manhwa → Manhua in two seconds was three
    /// `/v2/series/search` requests from a 30/min window shared with
    /// strangers, two of whose answers were downloaded and thrown away.
    @Test("Three scope taps in a burst are one request")
    func scopeTapsAreDebounced() async {
        let repository = AskCountingRepository()
        let model = SearchModel(repository: repository, clock: ImmediateClock())
        model.query.text = "berserk"
        await model.search()
        #expect(repository.searchCount == 1, "The search that put the screen in the asked state")

        model.query.types = ["manga"]
        model.filtersDidChange()
        model.query.types = ["manhwa"]
        model.filtersDidChange()
        model.query.types = ["manhua"]
        model.filtersDidChange()
        // Lets the one surviving debounce task run to completion. A fixed
        // count of yields passed alone and failed in the full suite, where
        // other `@MainActor` tests run in parallel and the surviving task
        // may not be scheduled within ten hops; this waits for the answer
        // instead, with a bound so a genuine regression still fails rather
        // than hanging. No sleep: `ImmediateClock` leaves no wall-clock wait
        // to cover, only scheduling.
        await waitForSecondSearch(repository)
        #expect(repository.searchCount == 2, "One more request, for the scope actually settled on")
        #expect(repository.lastQuery?.types == ["manhua"])
    }

    /// Nothing asked yet stays nothing asked — the panel is not an ask.
    @Test("A scope picked on the idle panel asks nothing")
    func idleScopeChangeAsksNothing() async {
        let repository = AskCountingRepository()
        let model = SearchModel(repository: repository, clock: ImmediateClock())

        model.query.types = ["manga"]
        model.filtersDidChange()
        for _ in 0..<10 { await Task.yield() }

        #expect(repository.searchCount == 0)
    }

    // MARK: Item 50 — a token-only search survives a push

    /// A tag opened from a series page, a Browse pick, or a lens with no text
    /// is a search with empty text by definition. Treating the dismissal as
    /// Cancel threw it away, so tapping a cover and coming back showed the
    /// idle panel with the token gone.
    @Test("A token-only query is not thrown away by a dismissal")
    func tokenOnlyQuerySurvivesDismissal() {
        var query = SearchQuery()
        query.tags = ["Isekai"]

        #expect(SearchField.isCancel(query: query) == false)
    }

    /// The control: an actually empty field still cancels, or Cancel stops
    /// working.
    @Test("An empty field with no tokens is still Cancel")
    func emptyFieldIsStillCancel() {
        #expect(SearchField.isCancel(query: SearchQuery()) == true)
    }

    /// And text still wins on its own — leaving for a series page with text
    /// in the field was always meant to keep the search.
    @Test("A dismissal that keeps the text is not Cancel")
    func textSurvivesDismissal() {
        var query = SearchQuery()
        query.text = "berserk"

        #expect(SearchField.isCancel(query: query) == false)
    }
}
