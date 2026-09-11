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
        try await Task.sleep(for: .milliseconds(600))

        #expect(repository.searchCount == 1, "The debounced search must actually run")
        #expect(model.results.count == 1)
        #expect(model.isSearching == false, "The spinner must not be left running")
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
    override func search(_ query: SearchQuery) async -> FeedResult {
        // Distinct id ranges per query, so a stale page is recognisable by id.
        let base = query.text == "naruto" ? 1 : 2
        if query.page > 1 {
            try? await Task.sleep(for: .milliseconds(150))
        }
        let ids = (0..<query.limit).map { base * 1000 + query.page * 100 + $0 }
        return FeedResult(
            series: ids.map { SeriesFactory.make(id: $0, title: "\(query.text ?? "")-\($0)") },
            origin: .network
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
        let model = SearchModel(repository: SlowPageTwoRepository())
        model.query.text = "naruto"
        await model.search()
        #expect(model.results.count == model.query.limit)

        async let paging: Void = model.loadMore()
        try? await Task.sleep(for: .milliseconds(20))
        model.query.text = "bleach"
        await model.search()
        await paging

        #expect(model.results.count == model.query.limit, "Naruto's page two was appended to bleach")
        #expect(model.results.allSatisfy { $0.id >= 2000 }, "Only bleach's ids may be present")
        #expect(model.query.page == 1, "The page counter must describe the current search")
    }
}
