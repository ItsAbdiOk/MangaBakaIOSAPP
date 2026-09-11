import Foundation
import Testing
@testable import MangaBaka

/// Endless scrolling, and the ways it goes wrong.
///
/// Every test here corresponds to a failure that is invisible in a unit test
/// suite but obvious on a phone: a row that stops dead, a page that repeats
/// itself, a spinner that never resolves.
@Suite("Pagination")
struct PaginationTests {
    // MARK: - Query shape

    @Test("Page one sends no page parameter, later pages do")
    func pageParameter() {
        var query = SearchQuery(text: "solo")
        #expect(!query.queryItems.contains { $0.name == "page" })

        query.page = 3
        let page = query.queryItems.first { $0.name == "page" }
        #expect(page?.value == "3")
    }

    /// Checked against the published spec rather than assumed. `rising` and
    /// `hidden-gems` take only `limit`, max 20 — those rows really do end.
    @Test("Only the endpoints that document a page parameter claim to page")
    func supportsPaging() {
        #expect(FeedKind.trending.supportsPaging)
        #expect(FeedKind.surprise.supportsPaging)
        #expect(!FeedKind.rising.supportsPaging)
        #expect(!FeedKind.hiddenGems.supportsPaging)
        #expect(!FeedKind.mix(seeds: [1]).supportsPaging)
    }

    // MARK: - Search

    /// A repository that hands out a distinct page each time, so a test can
    /// tell "fetched page 2" apart from "fetched page 1 again".
    private final class PagingRepository: StubRepositoryBase, @unchecked Sendable {
        let pageSize: Int
        let totalPages: Int
        private(set) var requestedPages: [Int] = []
        /// When true, page 2 repeats page 1 — which the live API does whenever
        /// the underlying ordering shifts between requests.
        var repeatsFirstPage = false

        init(pageSize: Int, totalPages: Int) {
            self.pageSize = pageSize
            self.totalPages = totalPages
        }

        override func search(_ query: SearchQuery) async -> FeedResult {
            requestedPages.append(query.page)
            guard query.page <= totalPages else {
                return FeedResult(series: [], origin: .network)
            }
            if repeatsFirstPage { return FeedResult(series: page(1), origin: .network) }
            return FeedResult(series: page(query.page), origin: .network)
        }

        private func page(_ number: Int) -> [Series] {
            let start = (number - 1) * pageSize
            return (start..<(start + pageSize)).map { SeriesFactory.make(id: $0, title: "S\($0)") }
        }
    }

    @Test("Reaching the end of the results fetches the next page and appends it")
    func searchLoadsMore() async {
        let repository = PagingRepository(pageSize: 30, totalPages: 3)
        let model = await SearchModel(repository: repository)
        await MainActor.run { model.query = SearchQuery(text: "solo") }

        await model.search()
        #expect(await model.results.count == 30)
        #expect(await model.hasMore)

        await model.loadMore()
        #expect(await model.results.count == 60)
        #expect(repository.requestedPages == [1, 2])
    }

    /// The failure this prevents is a crash, not a cosmetic one: SwiftUI's
    /// ForEach traps on duplicate ids, and under sort_by=random a repeated
    /// series across pages is the normal case rather than an edge case.
    @Test("A page that repeats what is already shown adds nothing and stops")
    func searchDeduplicates() async {
        let repository = PagingRepository(pageSize: 30, totalPages: 3)
        repository.repeatsFirstPage = true
        let model = await SearchModel(repository: repository)
        await MainActor.run { model.query = SearchQuery(text: "solo") }

        await model.search()
        await model.loadMore()

        #expect(await model.results.count == 30)
        #expect(await model.results.map(\.id).count == Set(await model.results.map(\.id)).count)
        // And it stops asking, rather than re-requesting the same page into a
        // rate limit shared with everyone else on this IP.
        #expect(await model.hasMore == false)
    }

    @Test("A short page means the end, so no further request is made")
    func searchStopsAtEnd() async {
        let repository = PagingRepository(pageSize: 30, totalPages: 1)
        let model = await SearchModel(repository: repository)
        await MainActor.run { model.query = SearchQuery(text: "solo") }

        await model.search()
        await model.loadMore()
        await model.loadMore()

        // Page 2 is tried once, comes back empty, and is never tried again.
        #expect(repository.requestedPages == [1, 2])
        #expect(await model.hasMore == false)
    }

    /// Without the reset, typing a new query after paging to 4 would fetch
    /// page 4 of the new query — results that skip the most relevant matches.
    @Test("A new search starts at page one")
    func searchResetsPage() async {
        let repository = PagingRepository(pageSize: 30, totalPages: 5)
        let model = await SearchModel(repository: repository)
        await MainActor.run { model.query = SearchQuery(text: "solo") }

        await model.search()
        await model.loadMore()
        await MainActor.run { model.query.text = "berserk" }
        await model.search()

        #expect(repository.requestedPages == [1, 2, 1])
        #expect(await model.query.page == 1)
    }

    // MARK: - Discover rows

    private class RowPagingRepository: StubRepositoryBase, @unchecked Sendable {
        private(set) var requested: [(key: String, page: Int)] = []

        override func feed(_ feed: FeedKind, forceRefresh: Bool) async -> FeedResult {
            FeedResult(
                series: (0..<20).map { SeriesFactory.make(id: $0, title: "A\($0)") },
                origin: .network
            )
        }

        override func feedPage(_ feed: FeedKind, page: Int) async -> FeedResult {
            requested.append((feed.cacheKey, page))
            guard feed.supportsPaging else { return FeedResult(series: [], origin: .network) }
            let start = (page - 1) * 20
            return FeedResult(
                series: (start..<(start + 20)).map { SeriesFactory.make(id: $0, title: "A\($0)") },
                origin: .network
            )
        }
    }

    @Test("A pageable row grows; a row the API cannot page never asks")
    func discoverRowPaging() async {
        let repository = RowPagingRepository()
        let model = await DiscoverModel(repository: repository)
        await model.load()

        let trending = FeedKind.trending.cacheKey
        let rising = FeedKind.rising.cacheKey

        await model.loadMore(trending)
        await model.loadMore(rising)

        #expect(await model.rows.first { $0.id == trending }?.series.count == 40)
        // Rising has no page parameter at all, so it is never requested.
        #expect(repository.requested.map(\.key) == ["discover/trending"])
    }

    /// A refresh replaces the row's contents. Leaving the page counter behind
    /// would make the next scroll fetch page 5 of a row holding page 1.
    @Test("Reloading a row resets its paging")
    func reloadResetsPaging() async {
        let repository = RowPagingRepository()
        let model = await DiscoverModel(repository: repository)
        await model.load()

        let trending = FeedKind.trending.cacheKey
        await model.loadMore(trending)
        #expect(await model.rows.first { $0.id == trending }?.page == 2)

        await model.load(forceRefresh: true)
        #expect(await model.rows.first { $0.id == trending }?.page == 1)
        #expect(await model.rows.first { $0.id == trending }?.hasReachedEnd == false)
    }

    /// A page fetch that is slow enough for a pull-to-refresh to land first.
    private final class SlowPageRepository: RowPagingRepository, @unchecked Sendable {
        var gate: CheckedContinuation<Void, Never>?

        override func feedPage(_ feed: FeedKind, page: Int) async -> FeedResult {
            await withCheckedContinuation { gate = $0 }
            return await super.feedPage(feed, page: page)
        }
    }

    /// Pull to refresh while page 2 is in flight: the row is replaced with a
    /// fresh page 1, and the old page 2 must not be appended to it. It was,
    /// which left the row at page 2 with the refreshed 1 plus the stale 2.
    @Test("A page that was in flight during a refresh is dropped")
    func refreshDuringPageFetchDropsThePage() async {
        let repository = SlowPageRepository()
        let model = await DiscoverModel(repository: repository)
        await model.load()
        let trending = FeedKind.trending.cacheKey

        let paging = Task { await model.loadMore(trending) }
        while repository.gate == nil { await Task.yield() }
        await model.load(forceRefresh: true)
        repository.gate?.resume()
        await paging.value

        let row = await model.rows.first { $0.id == trending }
        #expect(row?.series.count == 20, "The refreshed page 1 alone")
        #expect(row?.page == 1)
    }
}
