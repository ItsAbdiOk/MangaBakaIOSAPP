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
    /// What every search answers; the fallback tests set a failure here.
    var result = FeedResult(series: [], origin: .network)

    override func search(_ query: SearchQuery) async -> FeedResult {
        searchCount += 1
        lastQuery = query
        return result
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

/// Yields until `condition` holds or `hops` have passed — far past what
/// scheduling needs, so a request that never comes ends the test rather
/// than hanging it.
@MainActor
private func settle(hops: Int = 1_000, until condition: () -> Bool) async {
    for _ in 0..<hops where !condition() {
        await Task.yield()
    }
}

/// What a tag opened from a series page leaves behind when the reader
/// takes it away again (screens F6 and F7, 2026-09-14).
@Suite("Leaving a token-only search")
@MainActor
struct SearchTokenExitTests {
    /// F7: `openTag` chooses `popularity_asc`, and `cancelSearch` never
    /// cleared it, so every title typed after Cancel went out
    /// `sort_by=popularity_asc`. Expected to fail before the fix with:
    /// `model.query.sort == nil` → `"popularity_asc"`.
    @Test("Cancel drops the sort a tag or browse pick chose")
    func cancelDropsAppChosenSort() async {
        let repository = AskCountingRepository()
        let model = SearchModel(repository: repository, clock: ImmediateClock())

        model.openTag("Isekai")
        await settle { repository.searchCount == 1 }
        #expect(model.query.sort == "popularity_asc", "Sanity: the tag search carries the stable sort")

        model.cancelSearch()

        #expect(model.query.sort == nil)
        #expect(model.query.randomSeed == nil)
        #expect(model.hasAsked == false)
    }

    /// F6: removing the last token ran `filtersDidChange`, guarded only on
    /// `hasAsked`; `query.isEmpty` counts `sort`, so `{tags: [], sort:
    /// popularity_asc}` went to the wire — the whole catalogue by popularity
    /// under an empty field. Expected to fail before the fix with:
    /// `repository.searchCount == 1` → `2` (once `tokensDidChange` exists;
    /// before that the call does not compile, which proves nothing about
    /// behaviour — the old path was `filtersDidChange`).
    @Test("Removing the last token is idle, not a sort-only search of everything")
    func removingLastTokenIsIdle() async {
        let repository = AskCountingRepository()
        let model = SearchModel(repository: repository, clock: ImmediateClock())

        model.openTag("Isekai")
        await settle { repository.searchCount == 1 }

        // What the field's tokens binding writes when the × is tapped.
        model.query.tags = []
        model.tokensDidChange()
        await settle(hops: 100) { false }

        #expect(repository.searchCount == 1)
        #expect(model.hasAsked == false)
        #expect(model.query.sort == nil, "The app-chosen sort does not outlive the token it was for")
    }

    /// The control: a token removed from beside typed text re-asks for the
    /// text, as before.
    @Test("Removing a token beside typed text re-asks for the text")
    func removingTokenBesideTextReasks() async {
        let repository = AskCountingRepository()
        let model = SearchModel(repository: repository, clock: ImmediateClock())
        var query = SearchQuery(text: "one")
        query.tags = ["Isekai"]
        await model.apply(query)
        #expect(repository.searchCount == 1)

        model.query.tags = []
        model.tokensDidChange()
        await settle { repository.searchCount == 2 }

        #expect(repository.searchCount == 2)
        #expect(repository.lastQuery?.tags.isEmpty == true)
        #expect(model.hasAsked)
    }
}

/// Screens F8 (2026-09-14): what a rate-limited search leaves behind once
/// it has fallen back to the bundled index. Its own suite rather than a
/// second `SearchOfflineFallbackTests` — `SearchModelTests` already has one
/// of those, and two suites of one name do not compile.
@Suite("A rate-limited search keeps its deadline over the offline rows")
@MainActor
struct SearchRateLimitedFallbackTests {
    private func isOfflineIndex(_ origin: SearchResultOrigin) -> Bool {
        if case .offlineIndex = origin { return true }
        return false
    }

    /// Screens F8 (2026-09-14): the fallback used to clear `failure`, so the
    /// grid had no countdown, nothing auto-retried, and Return was refused
    /// as a byte-identical re-ask — the reader sat on the offline index for
    /// that query until they changed the text. Expected to fail before the
    /// fix with: `model.failure == .rateLimited(until: until)` → `nil`, and
    /// `repository.searchCount == 2` → `1`.
    @Test("A rate-limited search falls back to the bundled index and keeps its deadline")
    func rateLimitedFailureFallsBackAndKeepsDeadline() async {
        let repository = AskCountingRepository()
        let until = Date().addingTimeInterval(30)
        repository.result = FeedResult(series: [], origin: .staleAfter(.rateLimited(until: until)))
        let model = SearchModel(repository: repository)
        model.query.text = "one"

        await model.search()

        #expect(isOfflineIndex(model.origin))
        #expect(!model.results.isEmpty, "The offline rows are what the countdown sits over")
        #expect(model.failure == .rateLimited(until: until))

        // Return, or the countdown reaching zero: the same query goes out
        // again rather than being refused as already answered.
        await model.search()
        #expect(repository.searchCount == 2)
    }

    /// The control for the test above: a genuine `.offline` fallback has no
    /// deadline and keeps today's behaviour — nothing to count down to, so
    /// no failure to show over the offline rows.
    @Test("An offline fallback keeps no failure")
    func offlineFallbackKeepsNoFailure() async {
        let repository = AskCountingRepository()
        repository.result = FeedResult(series: [], origin: .staleAfter(.offline))
        let model = SearchModel(repository: repository)
        model.query.text = "one"

        await model.search()

        #expect(isOfflineIndex(model.origin))
        #expect(model.failure == nil)
    }
}
