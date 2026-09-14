import Foundation
import os
import Testing
@testable import MangaBaka

/// A repository that counts what it is asked for and can be told how to
/// answer, so "how many times was this fetched" is an assertion rather than
/// an inference.
private final class CountingFeedRepository: StubRepositoryBase, @unchecked Sendable {
    /// Locked, not bare `+= 1`: `DiscoverModel.loadRows` asks all four rows
    /// at once in a `TaskGroup`, so an unsynchronised counter loses updates.
    /// That is what failed on Xcode Cloud build 75 — 7 calls counted of 8
    /// made, on a runner with a different core count — while passing here.
    private let counts = OSAllocatedUnfairLock(initialState: Counts())

    private struct Counts {
        var feed = 0
        var page = 0
    }

    var feedCalls: Int { counts.withLock { $0.feed } }
    var pageCalls: Int { counts.withLock { $0.page } }
    /// How the first page of every row comes back.
    var origin: FeedResult.Origin = .network

    /// Ids are per-page, not per-row: `DiscoverModel` deduplicates inside one
    /// row, so two rows holding the same ids is not a case this stub has to
    /// avoid.
    static func page(_ page: Int) -> [Series] {
        ((page - 1) * 20 + 1...page * 20).map { SeriesFactory.make(id: $0, title: "S\($0)") }
    }

    override func feed(_ feed: FeedKind, forceRefresh: Bool) async -> FeedResult {
        counts.withLock { $0.feed += 1 }
        return FeedResult(series: Self.page(1), origin: origin, cachedAt: nil, hasMore: true)
    }

    override func feedPage(_ feed: FeedKind, page: Int) async -> FeedResult {
        counts.withLock { $0.page += 1 }
        return FeedResult(series: Self.page(page), origin: .network, cachedAt: nil, hasMore: true)
    }
}

/// What `DiscoverView`'s `.task` re-running costs, and what a cancelled load
/// is allowed to say.
@Suite("Discover reloads")
@MainActor
struct DiscoverReloadTests {
    private var trendingID: DiscoverModel.Row.ID { FeedKind.trending.cacheKey }

    /// `.task` carries no id, so SwiftUI re-runs it on every tab reselect and
    /// every pop back from a series page. Each run reset all four rows to
    /// page 1, so a reader who had scrolled Trending to page 3 lost it by
    /// opening a series and coming back — and four requests went out for
    /// content already on screen (item 19).
    @Test("A second load leaves paged rows where they are")
    func secondLoadKeepsPages() async {
        let repository = CountingFeedRepository()
        let model = DiscoverModel(repository: repository)

        await model.load()
        await model.loadMore(trendingID)
        await model.loadMore(trendingID)
        let afterPaging = repository.feedCalls

        await model.load()

        let trending = model.rows.first { $0.id == trendingID }
        #expect(trending?.series.count == 60, "Pages 1-3 are still on screen")
        #expect(trending?.page == 3, "The next scroll asks for page 4, not page 2")
        #expect(repository.feedCalls == afterPaging, "Nothing was re-fetched")
    }

    /// Pull-to-refresh is the explicit way to ask again and must still work.
    @Test("Pull-to-refresh still refetches every row")
    func forceRefreshStillRefetches() async {
        let repository = CountingFeedRepository()
        let model = DiscoverModel(repository: repository)

        await model.load()
        await model.load(forceRefresh: true)

        #expect(repository.feedCalls == 8, "Four rows, twice")
        #expect(model.rows.allSatisfy { $0.page == 1 }, "A refresh is page one by definition")
    }

    /// Navigating away cancels the `.task`, and the repository answers the
    /// dead request with `.staleAfter(.cancelled)`. Written into the row it
    /// drew a "Cancelled" failure card on all four rows of a screen the
    /// reader had already left (item 3).
    @Test("A cancelled load is not a failure")
    func cancelledLoadShowsNoFailure() async {
        let repository = CountingFeedRepository()
        repository.origin = .staleAfter(.cancelled)
        let model = DiscoverModel(repository: repository)

        await model.load()

        #expect(model.rows.allSatisfy { $0.failure == nil }, "No row says Cancelled")
        #expect(model.failure == nil, "And neither does the screen")
    }

    /// The other half of the same rule: a cancelled load must not count as
    /// the load that happened, or coming back would show four skeletons
    /// forever.
    @Test("A cancelled load is asked again on the next appearance")
    func cancelledLoadIsRetried() async {
        let repository = CountingFeedRepository()
        repository.origin = .staleAfter(.cancelled)
        let model = DiscoverModel(repository: repository)

        await model.load()
        repository.origin = .network
        await model.load()

        #expect(repository.feedCalls == 8, "Four rows asked, then asked again")
        #expect(model.rows.allSatisfy { !$0.series.isEmpty }, "The second answer landed")
    }

    /// A real failure still reaches the row it belongs to — the cancellation
    /// skip must not swallow the errors the screen exists to explain. The
    /// control for the two tests above.
    @Test("A real failure is still shown")
    func realFailureIsStillShown() async {
        let repository = CountingFeedRepository()
        repository.origin = .staleAfter(.offline)
        let model = DiscoverModel(repository: repository)

        await model.load()

        #expect(model.rows.allSatisfy { $0.failure == .offline })
        #expect(model.failure == .offline)
    }
}
