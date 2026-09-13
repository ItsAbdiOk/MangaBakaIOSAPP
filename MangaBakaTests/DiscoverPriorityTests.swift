import Foundation
import Testing
@testable import MangaBaka

/// 2026-09-13: `DiscoverModel.loadMore` prefetches a row's next page ahead of
/// the reader scrolling into it — this app's own idea, not something asked
/// for — and must not spend the same 30/min search window a reader's own
/// search needs.
///
/// A fresh conformer rather than a stub subclass overriding
/// `feedPage(_:page:priority:)`: the override would never be reached through
/// the protocol's dispatch, because no subclassable base declares that exact
/// method itself — see the same caveat on
/// `DueThisWeekTests.StubExtrasRepository`.
@Suite("Discover's page prefetch is background priority")
@MainActor
struct DiscoverPriorityTests {
    private final class PriorityCapturingRepository: SeriesRepositoryProtocol, @unchecked Sendable {
        private(set) var lastPagePriority: RequestPriority?

        func feed(_ feed: FeedKind, forceRefresh: Bool) async -> FeedResult {
            FeedResult(series: [SeriesFactory.make(id: 1)], origin: .network)
        }
        func feedPage(_ feed: FeedKind, page: Int) async -> FeedResult {
            FeedResult(series: [], origin: .network)
        }
        func feedPage(_ feed: FeedKind, page: Int, priority: RequestPriority) async -> FeedResult {
            lastPagePriority = priority
            return FeedResult(series: [SeriesFactory.make(id: 2)], origin: .network, hasMore: false)
        }
        func search(_ query: SearchQuery) async -> FeedResult { FeedResult(series: [], origin: .network) }
        func mix(seeds: [Int], filters: SearchQuery, excludedTags: [Int]) async -> MixResult { .empty }
        func extras(for seriesId: Int) async -> SeriesExtras { SeriesExtras() }
        func images(for seriesId: Int) async -> [SeriesImage]? { [] }
        func relationships(for seriesId: Int) async -> [SeriesRelationship]? { nil }
        func updateContentRatings(_ ratings: [String]) async {}
        func updateFormats(_ formats: [String]) async {}
        func updateLibraryExclusion(userID: String?) async {}
        func updateBlockedTags(_ ids: [Int]) async {}
        func cachedSeriesCount() async -> Int { 0 }
        func count(_ query: SearchQuery) async -> Int? { nil }
    }

    /// Expected to fail before the fix: `feedPage` took no priority at all,
    /// so there was nothing for `loadMore` to mark background with — every
    /// prefetch competed with a foreground search on equal footing.
    @Test("loadMore fetches its page at background priority")
    func loadMoreIsBackgroundPriority() async throws {
        let repository = PriorityCapturingRepository()
        let model = DiscoverModel(repository: repository)
        await model.load()

        // `.rising`/`.hidden-gems` (the model's first rows) have no paging at
        // all — `.trending` is the first row that does.
        let rowID = try #require(model.rows.first { $0.kind.supportsPaging }?.id)
        await model.loadMore(rowID)

        #expect(repository.lastPagePriority == .background)
    }
}
