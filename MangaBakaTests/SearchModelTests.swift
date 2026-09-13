import Foundation
import Testing
@testable import MangaBaka

/// A stub that records what it was asked and can be made slow, so debounce
/// behaviour is testable without real time or a real network.
private final class RecordingRepository: StubRepositoryBase, @unchecked Sendable {
    private(set) var searchCount = 0
    private(set) var lastQuery: SearchQuery?
    var result = FeedResult(series: [], origin: .network)

    override func search(_ query: SearchQuery) async -> FeedResult {
        searchCount += 1
        lastQuery = query
        return result
    }
}

@Suite("Search model")
@MainActor
struct SearchModelTests {
    private func series(_ id: Int) -> Series {
        SeriesFactory.make(id: id, title: "S\(id)", cover: .sized)
    }

    /// Regression: `search()` used to cancel the debounce task it was running
    /// inside. The request died with NSURLErrorCancelled and `isSearching`
    /// stayed true forever — the reader saw a spinner that never resolved and
    /// no error explaining why.
    @Test("A debounced search completes and clears the loading state")
    func debouncedSearchCompletes() async throws {
        let repository = RecordingRepository()
        repository.result = FeedResult(series: [series(1)], origin: .network)
        let model = SearchModel(repository: repository)

        model.query.text = "solo"
        model.queryDidChange()
        // Waits on SearchModel's own 300ms debounce, at 2x margin.
        try await Task.sleep(for: .milliseconds(600))

        #expect(repository.searchCount == 1, "The debounced search must actually run")
        #expect(model.results.count == 1)
        #expect(model.isSearching == false, "The spinner must not be left running")
    }

    /// Running a lens or a recent term assigns the query and searches at
    /// once; the assignment also fires the field's change observer, which
    /// used to schedule a second, identical search 300ms later.
    @Test("An applied query searches once, even when the field observes the edit")
    func appliedQuerySearchesOnce() async throws {
        let repository = RecordingRepository()
        let model = SearchModel(repository: repository)

        await model.apply(SearchQuery(text: "solo"))
        // What the view's onChange(of: query.text) does, whichever side of
        // the explicit search it lands on.
        model.queryDidChange()
        // Waits on SearchModel's own 300ms debounce, at 2x margin.
        try await Task.sleep(for: .milliseconds(600))

        #expect(repository.searchCount == 1)

        // The next real keystroke still debounces into a search of its own.
        model.query.text = "solo l"
        model.queryDidChange()
        // Waits on SearchModel's own 300ms debounce, at 2x margin.
        try await Task.sleep(for: .milliseconds(600))
        #expect(repository.searchCount == 2)
    }

    @Test("The loading state clears even when nothing was found")
    func clearsLoadingOnEmpty() async {
        let repository = RecordingRepository()
        let model = SearchModel(repository: repository)
        model.query.text = "nothing"

        await model.search()

        #expect(model.isSearching == false)
        #expect(model.results.isEmpty)
    }

    @Test("A burst of keystrokes produces one request, not one per key")
    func debounceCollapsesABurst() async throws {
        let repository = RecordingRepository()
        let model = SearchModel(repository: repository)

        for text in ["s", "so", "sol", "solo"] {
            model.query.text = text
            model.queryDidChange()
        }
        // Waits on SearchModel's own 300ms debounce, at 2x margin.
        try await Task.sleep(for: .milliseconds(600))

        #expect(repository.searchCount == 1, "30 req/min is shared with strangers on the same network")
        #expect(repository.lastQuery?.text == "solo")
    }

    /// The idle screen's inline `FilterPanel` binds straight to `model.query`
    /// — chip taps mutate `query.types`/`.statuses`/etc directly, with no
    /// `queryDidChange()` call attached to any of those bindings (only the
    /// search field's `onChange` calls that). "Show results" is the one
    /// thing wired to actually search: `cancelPendingDebounce()` then
    /// `search()`, called once. This is the regression that would surface if
    /// a future edit accidentally wired a chip's binding through
    /// `queryDidChange()` too: filters would start firing their own debounced
    /// searches, and "Show results" would double up with them.
    @Test("Show results is one search, however many filters changed first")
    func showResultsIsOneSearch() async {
        let repository = RecordingRepository()
        let model = SearchModel(repository: repository)

        model.query.types = ["manga"]
        model.query.statuses = ["completed"]
        model.query.minimumRating = 80
        #expect(repository.searchCount == 0, "Changing filters must not search on its own")

        // What the panel's "Show results" button actually does.
        model.cancelPendingDebounce()
        await model.search()

        #expect(repository.searchCount == 1, "Show results must fire exactly one request")
    }

    @Test("Clearing the field drops results without calling the API")
    func clearingIsLocal() async {
        let repository = RecordingRepository()
        let model = SearchModel(repository: repository)
        model.query.text = ""

        model.queryDidChange()

        #expect(repository.searchCount == 0)
        #expect(model.results.isEmpty)
        #expect(model.isSearching == false)
    }

    /// Gap 7, the headline reader complaint: a 429 mid-typing used to blank
    /// the grid behind a static sentence with no countdown
    /// (`SearchView.swift:275-285`) and `message` (`SearchModel.swift:16`)
    /// could not tell "nothing matched" from "the ask failed" apart from an
    /// empty string either way. `FeedResult.blockingError` is the line
    /// `SeriesRepository`'s other callers already draw between the two —
    /// non-nil only when there is genuinely nothing to show for this ask —
    /// and `search()` now leaves `results` untouched when it is set, so the
    /// last good page stays on screen under a `StaleBar` rather than being
    /// thrown away on every further keystroke.
    @Test("A rate-limited search keeps the previous results and surfaces a live countdown")
    func rateLimitedSearchKeepsPreviousResults() async {
        let repository = RecordingRepository()
        repository.result = FeedResult(series: [series(1), series(2)], origin: .network)
        let model = SearchModel(repository: repository)
        model.query.text = "one"
        await model.search()
        #expect(model.results.count == 2, "Sanity: the first search must actually land")
        #expect(model.failure == nil)

        let until = Date().addingTimeInterval(30)
        repository.result = FeedResult(
            series: [],
            origin: .staleAfter(.rateLimited(until: until)),
            hasMore: true
        )
        model.query.text = "one two"
        await model.search()

        #expect(
            model.results.count == 2,
            "The previous results must stay on screen through a rate limit, not be thrown away"
        )
        #expect(model.failure == .rateLimited(until: until))
        #expect(model.failure?.countdown != nil, "Expected a live countdown, not a frozen sentence")
    }

    /// The control for the test above: a genuinely empty answer (no error at
    /// all) is a real "nothing matched" and must not be confused with a
    /// failure — the two need to render as `EmptyState` and `FailureState`
    /// respectively, which the view can only do if the model tells them apart.
    @Test("A truly empty answer clears any previous failure")
    func emptyAnswerIsNotAFailure() async {
        let repository = RecordingRepository()
        repository.result = FeedResult(series: [], origin: .network)
        let model = SearchModel(repository: repository)
        model.query.text = "nothing at all matches this"

        await model.search()

        #expect(model.results.isEmpty)
        #expect(model.failure == nil, "An empty, non-failing answer must not read as a failure")
    }
}

/// A search whose page 2 fails outright, rather than merely coming back
/// empty after local filtering — the distinction gap 15 is about.
private final class PagedFailureRepository: StubRepositoryBase, @unchecked Sendable {
    private(set) var searchCount = 0

    override func search(_ query: SearchQuery) async -> FeedResult {
        searchCount += 1
        guard query.page > 1 else {
            return FeedResult(
                series: [SeriesFactory.make(id: 1, title: "S1", cover: .sized)],
                origin: .network,
                hasMore: true
            )
        }
        // Mirrors what `SeriesRepository.search`'s own catch branch actually
        // returns on a real failure: `hasMore: true`, not the default
        // `false` — see `SeriesRepository+Paging.swift`.
        return FeedResult(series: [], origin: .staleAfter(.offline), hasMore: true)
    }
}

@Suite("Search pages that fail outright are not the end of the results")
@MainActor
struct SearchPageFailureTests {
    /// Gap 15: `loadMore`'s loop used to read `result.hasMore` at face value
    /// regardless of *why* a page came back empty, so a page that failed
    /// outright (`.staleAfter`) was folded into the same "filtered-empty
    /// page" counter as a page that genuinely had nothing after local
    /// filtering — three of either in a row flipped `hasMore` to `false` and
    /// the failed page read as the end of the results, while also spending
    /// the shared 30 req/min budget retrying pages 3 and 4 it should not
    /// have touched at all.
    @Test("A failed page 2 stays retryable and stops the walk immediately")
    func failedPageStaysRetryable() async {
        let repository = PagedFailureRepository()
        let model = SearchModel(repository: repository)
        model.query.text = "solo"
        await model.search()
        #expect(model.results.count == 1)
        #expect(model.hasMore == true)

        await model.loadMore()

        #expect(model.hasMore == true, "A failed page must not be read as the end of the results")
        #expect(model.pageFailure == .offline)
        #expect(
            repository.searchCount == 2,
            "Must stop at the first failed page rather than burning the empty-page budget on it"
        )
    }
}

/// Filters that outlive the screen they were set on.
///
/// Both of these came out of walking the app as a reader on 2026-09-10, and
/// both are silent: the results are simply wrong, with nothing on screen
/// saying why.
@Suite("Search filters do not follow you around")
@MainActor
struct SearchFilterEscapeTests {
    /// "Surprise me" sets `sort = "random"` and nothing ever unset it, so every
    /// search afterwards was shuffled. Measured against the live API on
    /// 2026-09-10: `q=one piece&sort_by=random` answers 32 series without ONE
    /// PIECE among them; the same query at relevance answers 411 with it first.
    @Test("Typing a title turns off the random sort")
    func typingClearsRandom() {
        let model = SearchModel(repository: StubRepositoryBase())
        model.query.sort = "random"
        model.query.text = "one piece"

        model.queryDidChange()

        #expect(model.query.sort == nil)
        model.cancelPendingDebounce()
    }

    @Test("Browsing at random is left alone")
    func randomBrowsingSurvives() {
        // No text: "Surprise me" is the whole request, and clearing the sort
        // here would turn the feature off.
        let model = SearchModel(repository: StubRepositoryBase())
        model.query.sort = "random"

        model.queryDidChange()

        #expect(model.query.sort == "random")
        model.cancelPendingDebounce()
    }

    @Test("Clearing filters keeps the words the reader typed")
    func clearKeepsText() async {
        let model = SearchModel(repository: StubRepositoryBase())
        model.query.text = "one piece"
        model.query.tags = ["Isekai"]
        model.query.types = ["novel"]
        model.query.minimumRating = 80

        #expect(model.query.activeFilterCount == 3)
        await model.clearFilters()

        #expect(model.query.text == "one piece")
        #expect(model.query.activeFilterCount == 0)
    }
}

/// A search whose page-two request is slow, so a new search can land while
/// the old one's next page is still on its way.
private final class SlowPageTwoRepository: StubRepositoryBase, @unchecked Sendable {
    /// Set once the page-two request is in flight and paused, so the test can
    /// wait for it deterministically instead of racing a fixed sleep against
    /// a real network stub — see `SlowPageRepository` in PaginationTests.
    var gate: CheckedContinuation<Void, Never>?

    override func search(_ query: SearchQuery) async -> FeedResult {
        // Distinct id ranges per query, so a stale page is recognisable by id.
        let base = query.text == "naruto" ? 1 : 2
        if query.page > 1 {
            await withCheckedContinuation { gate = $0 }
        }
        let ids = (0..<query.limit).map { base * 1000 + query.page * 100 + $0 }
        return FeedResult(
            series: ids.map { SeriesFactory.make(id: $0, title: "\(query.text ?? "")-\($0)") },
            origin: .network,
            // Always "there is more" — this stub exists to race a page-two
            // fetch against a new search, which needs `loadMore` to actually
            // fire a page-two request rather than being guarded off.
            hasMore: true
        )
    }
}

@Suite("Search pages belong to the search that asked for them")
@MainActor
struct SearchPagingGenerationTests {
    /// The reader scrolls to the bottom of "naruto", the next page goes out,
    /// and before it returns they type "bleach". Page two of naruto must not
    /// be appended to page one of bleach.
    @Test("A stale page is dropped when the query changed while it was loading")
    func stalePageIsDropped() async {
        let repository = SlowPageTwoRepository()
        let model = SearchModel(repository: repository)
        model.query.text = "naruto"
        await model.search()
        #expect(model.results.count == model.query.limit)

        async let paging: Void = model.loadMore()
        // Wait for page two to actually be in flight before switching the
        // query, rather than guessing at a sleep that races loadMore()'s own
        // scheduling — the same race that failed the pre-push hook 3/3.
        // Bounded so a genuine bug fails the test instead of hanging it.
        let deadline = Date().addingTimeInterval(2)
        while repository.gate == nil, Date() < deadline { await Task.yield() }
        model.query.text = "bleach"
        await model.search()
        repository.gate?.resume()
        await paging

        #expect(model.results.count == model.query.limit, "Naruto's page two was appended to bleach")
        #expect(model.results.allSatisfy { $0.id >= 2000 }, "Only bleach's ids may be present")
        #expect(model.query.page == 1, "The page counter must describe the current search")
    }
}

/// Tapping a tag on a series page is the same gesture as picking one while
/// browsing, and must go through the same door.
@Suite("Opening a tag from a series page")
struct OpenTagRouteTests {
    @Test("A tag route produces a tag-filtered query with a stable sort")
    @MainActor
    func applyBrowseSetsTagAndSort() async {
        let model = SearchModel(repository: StubRepositoryBase())
        model.applyBrowse(tag: "Isekai")
        #expect(model.query.tags == ["Isekai"])
        // A sort, not nil: the app pages by asking for the next page and
        // dropping ids it has seen, so an unsorted query whose order shifts
        // between requests loses rows.
        #expect(model.query.sort == "popularity_asc")
        #expect(!model.query.isEmpty, "an empty query never reaches the network")
    }

    /// The control: a tag route replaces the previous query rather than
    /// narrowing it. Arriving from a series page means "show me this tag",
    /// not "this tag plus whatever was still set".
    @Test("A tag route drops the text and filters that were already there")
    @MainActor
    func applyBrowseReplacesTheQuery() async {
        let model = SearchModel(repository: StubRepositoryBase())
        model.query.text = "one piece"
        model.query.statuses = ["completed"]
        model.applyBrowse(tag: "Isekai")
        #expect(model.query.text == nil)
        #expect(model.query.statuses.isEmpty)
        #expect(model.query.tags == ["Isekai"])
    }
}

private extension SearchResultOrigin {
    var isOfflineIndex: Bool {
        if case .offlineIndex = self { return true }
        return false
    }
}

/// Offline browsing: the "Browse offline" toggle, and the automatic fallback
/// when the network answer is `.offline` or rate-limited.
@Suite("Search falls back to the offline index")
@MainActor
struct SearchOfflineFallbackTests {
    /// The bundled `OfflineIndex.json.gz` — real, not a stub, the same way
    /// `TagTaxonomyTests` exercises the real `TagTaxonomy.json`. `.origin`
    /// existing at all is the thing under test; a fake index would only prove
    /// the plumbing compiles.
    private func makeModel(repository: any SeriesRepositoryProtocol) -> SearchModel {
        SearchModel(repository: repository)
    }

    /// "Browse offline" is the reader choosing not to ask the network at all —
    /// the toggle exists specifically so a search made with it on can be
    /// proven to send zero requests, not merely to usually avoid sending one.
    @Test("Toggling Browse offline answers from the index and calls the repository zero times")
    func browseOfflineSendsZeroRequests() async {
        let repository = RecordingRepository()
        let model = makeModel(repository: repository)
        model.preferOffline = true
        model.query.text = "one"

        await model.search()

        #expect(repository.searchCount == 0, "Browse offline must never touch the network")
        #expect(model.origin.isOfflineIndex)
        #expect(!model.results.isEmpty, "\"one\" should match real titles in the bundled index")
    }

    /// Paging while browsing offline must not fall back to the network either
    /// — the toggle's promise is zero requests for the whole session on it,
    /// not just the first page.
    @Test("Loading more pages of the offline index also calls the repository zero times")
    func offlinePagingSendsZeroRequests() async {
        let repository = RecordingRepository()
        let model = makeModel(repository: repository)
        model.preferOffline = true
        // Sort-only is a real, non-empty query (see `SearchQuery.isEmpty`'s
        // doc comment) that matches broadly enough to guarantee a second page.
        model.query.sort = "score_desc"

        await model.search()
        let firstPageCount = model.results.count
        #expect(model.hasMore, "Sanity: the bundled index has far more than one page of results")

        await model.loadMore()

        #expect(repository.searchCount == 0)
        #expect(model.results.count > firstPageCount)
    }

    /// The control for the fallback tests below: a failure that is not
    /// `.offline` or `.rateLimited` says nothing about whether the network
    /// itself works, so it must read as the ordinary failure it is rather
    /// than triggering the offline index.
    @Test("A non-network failure does not fall back to the offline index")
    func serverErrorDoesNotFallBackOffline() async {
        let repository = RecordingRepository()
        repository.result = FeedResult(series: [], origin: .staleAfter(.server(status: 500, message: "")))
        let model = makeModel(repository: repository)
        model.query.text = "solo"

        await model.search()

        #expect(model.origin == .network)
        #expect(model.failure != nil)
        #expect(repository.searchCount == 1, "The online path must still be the one that ran")
    }

    @Test("An offline search failure falls back to the bundled index")
    func offlineFailureFallsBack() async {
        let repository = RecordingRepository()
        repository.result = FeedResult(series: [], origin: .staleAfter(.offline))
        let model = makeModel(repository: repository)
        model.query.text = "one"

        await model.search()

        #expect(
            repository.searchCount == 1,
            "One request must go out before the fallback is known to be needed"
        )
        #expect(model.origin.isOfflineIndex)
        #expect(model.failure == nil, "The fallback answered, so this is not a dead end needing FailureState")
        #expect(!model.results.isEmpty)
    }

    @Test("A rate-limited search failure also falls back to the bundled index")
    func rateLimitedFailureFallsBack() async {
        let repository = RecordingRepository()
        repository.result = FeedResult(series: [], origin: .staleAfter(.rateLimited(until: nil)))
        let model = makeModel(repository: repository)
        model.query.text = "one"

        await model.search()

        #expect(model.origin.isOfflineIndex)
        #expect(model.failure == nil)
    }
}
