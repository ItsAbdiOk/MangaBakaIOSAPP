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
