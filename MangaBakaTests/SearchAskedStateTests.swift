import Foundation
import Testing
@testable import MangaBaka

/// The search state machine's fourth input and what hangs off it — split
/// from `SearchModelTests.swift` for the lint's file-length ceiling.

/// A stub that records what it was asked, with an answer the test sets.
private final class RecordingRepository: StubRepositoryBase, @unchecked Sendable {
    private(set) var searchCount = 0
    var result = FeedResult(series: [], origin: .network)

    override func search(_ query: SearchQuery) async -> FeedResult {
        searchCount += 1
        return result
    }
}

/// A stub whose page-one request blocks until the test resumes it, so state
/// *during* a request — not just after it — can be asserted.
private final class GatedSearchRepository: StubRepositoryBase, @unchecked Sendable {
    var gate: CheckedContinuation<Void, Never>?
    var result = FeedResult(series: [], origin: .network)
    private(set) var searchCount = 0

    override func search(_ query: SearchQuery) async -> FeedResult {
        searchCount += 1
        await withCheckedContinuation { gate = $0 }
        return result
    }
}

/// The search state machine's fourth input (review 2026-09-13, cause A):
/// whether the reader has *asked* yet, and whether an answer is pending.
/// Every finding in this suite came from deriving the screen from
/// `query.isEmpty` instead — a chip tap on the idle panel counted as a
/// query with no results and flipped the panel into "Nothing matched".
@Suite("Search asks and pending answers")
@MainActor
struct SearchAskedStateTests {
    private func series(_ id: Int) -> Series {
        SeriesFactory.make(id: id, title: "S\(id)", cover: .sized)
    }

    /// UX#1 / LW ✔: tapping "Manga" on the idle panel replaced the panel
    /// with "0 shown / Nothing matched these filters". A chip is not an ask.
    @Test("A filter set without searching is not an ask")
    func filterAloneIsNotAnAsk() async {
        let repository = RecordingRepository()
        let model = SearchModel(repository: repository)

        model.query.types = ["manga"]

        #expect(!model.hasAsked, "Choosing a filter must keep the idle panel")
        #expect(!model.isPending)

        // "Show results" is the ask.
        await model.search()
        #expect(model.hasAsked)
    }

    /// E F4: the ≥300 ms between the first keystroke and the request going
    /// out used to render as "Nothing matched 'n'". Typing is an ask whose
    /// answer is pending, and the model must say so.
    @Test("A keystroke is an ask with a pending answer until the debounce fires")
    func keystrokeIsPending() async throws {
        let repository = RecordingRepository()
        let model = SearchModel(repository: repository)

        model.query.text = "n"
        model.queryDidChange()

        #expect(model.hasAsked, "Typing is an ask")
        #expect(model.isPending, "…whose answer has not gone out yet")

        // Waits on SearchModel's own 300ms debounce, at 2x margin.
        try await Task.sleep(for: .milliseconds(600))
        #expect(!model.isPending, "Pending ends when the request runs")
        #expect(repository.searchCount == 1)
    }

    /// E F2: Return after the debounce had already answered the same query
    /// sent a byte-identical second request — 2 of the shared 30/min for one
    /// answer already on screen.
    @Test("Searching the same query twice sends one request")
    func repeatedSearchIsFree() async {
        let repository = RecordingRepository()
        repository.result = FeedResult(series: [series(1)], origin: .network)
        let model = SearchModel(repository: repository)
        model.query.text = "one"

        await model.search()
        await model.search()

        #expect(repository.searchCount == 1, "An answered query must not be asked again")
        #expect(model.results.count == 1, "…and its answer stays")
    }

    /// E F8, the comparison half: `"one "` (a pause after the first word of
    /// "one piece") is the same question as `"one"`. Lane C trims the wire
    /// side in `SearchQuery.queryItems`; this pins the model's own memory.
    @Test("A trailing space is not a new query")
    func trailingSpaceIsFree() async {
        let repository = RecordingRepository()
        repository.result = FeedResult(series: [series(1)], origin: .network)
        let model = SearchModel(repository: repository)
        model.query.text = "one"
        await model.search()

        model.query.text = "one "
        await model.search()

        #expect(repository.searchCount == 1)
    }

    /// The controls for the two above: a failed ask is asked again on retry,
    /// and a random sort is a reshuffle every time by definition.
    @Test("A failed or random search is always re-sent")
    func failureAndRandomAreNotShortCircuited() async {
        let repository = RecordingRepository()
        repository.result = FeedResult(series: [], origin: .staleAfter(.server(status: 500, message: "")))
        let model = SearchModel(repository: repository)
        model.query.text = "one"
        await model.search()
        await model.search()
        #expect(repository.searchCount == 2, "Retry after a failure must go out")

        repository.result = FeedResult(series: [series(1)], origin: .network)
        model.query.text = nil
        model.query.sort = "random"
        await model.search()
        await model.search()
        #expect(repository.searchCount == 4, "Surprise me twice is two shuffles")
    }

    /// E F5: a lens/browse with no text applied while the field held text
    /// fired the field's `onChange` ("naruto" → nil), which `appliedText`
    /// (`nil`) could not recognise as the apply, so a second search was
    /// debounced and the first answer thrown away by the generation bump.
    @Test("Applying a text-less query over typed text is one ask, not two")
    func textlessApplyOverTextIsOneAsk() async {
        let repository = RecordingRepository()
        let model = SearchModel(repository: repository)
        model.query.text = "naruto"
        var lens = SearchQuery()
        lens.tags = ["Isekai"]

        await model.apply(lens)
        // What the view's onChange(of: query.text) does for "naruto" → nil.
        model.queryDidChange()

        #expect(!model.isPending, "The apply's own text edit must not schedule a second search")
        #expect(repository.searchCount == 1)
        model.cancelPendingDebounce()
    }

    /// E F1 / R F13: `pagination.count` was decoded into `FeedResult.total`
    /// and never read, so the heading said "30 shown" and the filter sheet
    /// spent a `limit=1` request to ask for a number the model had been
    /// handed.
    @Test("The response's total is kept on the model")
    func totalIsKept() async {
        let repository = RecordingRepository()
        repository.result = FeedResult(series: [series(1)], origin: .network, total: 411)
        let model = SearchModel(repository: repository)
        model.query.text = "one"

        await model.search()

        #expect(model.total == 411)
        #expect(model.knownTotal(for: model.query) == 411, "The sheet may read it without a request")
        var other = model.query
        other.types = ["manga"]
        #expect(model.knownTotal(for: other) == nil, "…but only for the query that was answered")
    }

    /// R F10: `hasMore` was not reset per search, so a query with more pages
    /// followed by a one-page query fired the "end of results" haptic as the
    /// new results landed, and the view offered page 2 of a search that had
    /// not answered yet.
    @Test("hasMore is false while a new search is in flight")
    func hasMoreResetsPerSearch() async {
        let repository = GatedSearchRepository()
        repository.result = FeedResult(series: [series(1)], origin: .network, hasMore: true)
        let model = SearchModel(repository: repository)
        model.query.text = "one"
        async let first: Void = model.search()
        let deadline = Date().addingTimeInterval(2)
        while repository.gate == nil, Date() < deadline { await Task.yield() }
        repository.gate?.resume()
        repository.gate = nil
        await first
        #expect(model.hasMore, "Sanity: the first answer has more")

        model.query.text = "two"
        async let second: Void = model.search()
        while repository.gate == nil, Date() < deadline { await Task.yield() }
        #expect(!model.hasMore, "A new search has no next page until its first one lands")
        repository.gate?.resume()
        await second
        #expect(model.hasMore)
    }
}

/// E F7: `sort_by=random` without `random_seed` made page 2 a fresh shuffle
/// of mostly-seen rows, and three such pages tripped "Stopped early" on a
/// 300k-row catalogue. Confirmed live 2026-09-13 that one seed pins the
/// order (`SearchQuery.randomSeed`'s doc comment).
@Suite("Random search pages against one seed")
@MainActor
struct SearchRandomSeedTests {
    @Test("Two pages of a random query share a seed; a new Surprise me mints a new one")
    func pagesShareSeedAndTapsRenewIt() async {
        let repository = EndlessRepository()
        let model = SearchModel(repository: repository)

        await model.surpriseMe()
        // `last` is a double optional; flattened so nil means "no seed".
        let first = repository.seeds.last.flatMap { $0 }
        #expect(first != nil, "A random search must carry a seed")
        #expect(model.query.sort == "random")

        await model.loadMore()
        #expect(repository.seeds.count == 2)
        #expect(repository.seeds[1] == first, "Page 2 must be the same shuffle as page 1")

        // Bounded: a 1-in-1000 collision is possible; ten misses in a row
        // are not.
        var renewed = false
        for _ in 0..<10 where !renewed {
            await model.surpriseMe()
            renewed = (repository.seeds.last.flatMap { $0 }) != first
        }
        #expect(renewed, "Surprise me again is a new shuffle")
    }

    /// The control: leaving random drops the seed, so it cannot ride along
    /// under a relevance search — `queryItems` guards on the sort too, but
    /// a lens saved from this query would otherwise store a dead value.
    @Test("Leaving the random sort clears the seed")
    func leavingRandomClearsSeed() async {
        let repository = EndlessRepository()
        let model = SearchModel(repository: repository)
        await model.surpriseMe()
        #expect(model.query.randomSeed != nil)

        model.query.text = "one piece"
        model.queryDidChange()
        model.cancelPendingDebounce()
        #expect(model.query.sort == nil)
        #expect(model.query.randomSeed == nil)

        model.query.sort = "random"
        model.query.randomSeed = 0.5
        model.query.sort = "score_desc"
        await model.search()
        #expect((repository.seeds.last.flatMap { $0 }) == nil, "A non-random search must not carry a seed")
    }
}

/// A stub with one unique row per page and no end, for walking to the
/// API's page cap.
private final class EndlessRepository: StubRepositoryBase, @unchecked Sendable {
    private(set) var pagesAsked: [Int] = []
    /// One entry per request: the seed it carried, nil when none.
    private(set) var seeds: [Double?] = []

    override func search(_ query: SearchQuery) async -> FeedResult {
        pagesAsked.append(query.page)
        seeds.append(query.randomSeed)
        return FeedResult(
            series: [SeriesFactory.make(id: query.page, title: "P\(query.page)")],
            origin: .network,
            hasMore: true
        )
    }
}

@Suite("Search paging stays inside the API's bounds")
@MainActor
struct SearchPagingBoundsTests {
    /// E F9: `/v2/series/search` accepts `page` up to 100 (the schema; what
    /// page 101 answers is not on record). `loadMore` incremented without
    /// bound, so a reader 3,000 rows into "Isekai" ended on a retry button
    /// that asked for page 101 forever.
    @Test("Page 100 is the last page asked for")
    func stopsAtPageCap() async {
        let repository = EndlessRepository()
        let model = SearchModel(repository: repository)
        model.query.text = "isekai"
        await model.search()
        // Skip the walk: the model's own counter says page 100 has landed.
        model.query.page = 100

        await model.loadMore()

        #expect(repository.pagesAsked == [1], "Page 101 must never be requested")
        #expect(!model.hasMore, "The cap is the end of what can be shown")
        #expect(model.pageFailure == nil, "…and not a failure to retry")
    }

    /// R F12a: page 2+ was deduplicated by id and page 1 was not, so a
    /// repeated id within one page gave `ForEach` two views with one
    /// identity (a console warning and a missed zoom source).
    @Test("Page one is deduplicated by id like every later page")
    func pageOneIsDeduplicated() async {
        let repository = RecordingRepository()
        let one = SeriesFactory.make(id: 1, title: "S1")
        repository.result = FeedResult(
            series: [one, one, SeriesFactory.make(id: 2, title: "S2")], origin: .network
        )
        let model = SearchModel(repository: repository)
        model.query.text = "one"

        await model.search()

        #expect(model.results.map(\.id) == [1, 2])
    }
}
