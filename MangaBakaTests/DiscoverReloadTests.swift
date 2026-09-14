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

/// Fails one row on its first ask and answers every later ask with content,
/// counting per row — so "how many rows did the retry re-fetch" is a
/// number, not an inference.
private final class FailOnceRepository: StubRepositoryBase, @unchecked Sendable {
    private let counts = OSAllocatedUnfairLock(initialState: [FeedKind: Int]())
    private let failing: FeedKind

    init(failing: FeedKind) {
        self.failing = failing
    }

    func calls(_ kind: FeedKind) -> Int { counts.withLock { $0[kind] ?? 0 } }
    var totalCalls: Int { counts.withLock { $0.values.reduce(0, +) } }

    override func feed(_ feed: FeedKind, forceRefresh: Bool) async -> FeedResult {
        let call = counts.withLock { state -> Int in
            state[feed, default: 0] += 1
            return state[feed, default: 0]
        }
        if feed == failing, call == 1 {
            return FeedResult(series: [], origin: .staleAfter(.rateLimited(until: nil)))
        }
        return FeedResult(series: CountingFeedRepository.page(1), origin: .network, hasMore: true)
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

/// Screens F11 (2026-09-14): a row's `InlineFailure` retry called
/// `load(forceRefresh: true)` — all four rows re-fetched, two from the
/// 30/min family, for one row's failure.
@Suite("Retrying one Discover row")
@MainActor
struct DiscoverRowRetryTests {
    private var trendingID: DiscoverModel.Row.ID { FeedKind.trending.cacheKey }

    /// Expected to fail before the fix with: `retryRow` did not exist — the
    /// view's retry closure was `load(forceRefresh: true)`, which on this
    /// stub is `repository.totalCalls == 8`, not 5.
    @Test("A row's retry re-fetches that row and nothing else")
    func retryFetchesOneRow() async {
        let repository = FailOnceRepository(failing: .trending)
        let model = DiscoverModel(repository: repository)

        await model.load()
        #expect(repository.totalCalls == 4)
        let trending = model.rows.first { $0.id == trendingID }
        #expect(trending?.series.isEmpty == true, "Sanity: the row asked and failed")
        #expect(trending?.failure == .rateLimited(until: nil))
        #expect(model.failure == .rateLimited(until: nil), "The screen-wide verdict names the failure")

        await model.retryRow(trendingID)

        #expect(repository.totalCalls == 5)
        #expect(repository.calls(.trending) == 2)
        let retried = model.rows.first { $0.id == trendingID }
        #expect(retried?.series.count == 20)
        #expect(retried?.failure == nil)
        #expect(retried?.isLoading == false)
        #expect(model.failure == nil, "No row is failing now, so the screen is not")
    }

    /// The control: pull-to-refresh still re-fetches every row.
    @Test("Pull-to-refresh after a row retry still asks for all four")
    func forceRefreshStillAsksAll() async {
        let repository = FailOnceRepository(failing: .trending)
        let model = DiscoverModel(repository: repository)

        await model.load()
        await model.retryRow(trendingID)
        await model.load(forceRefresh: true)

        #expect(repository.totalCalls == 9)
    }
}
