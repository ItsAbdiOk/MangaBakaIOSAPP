import Testing
import Foundation
@testable import MangaBaka

/// `TagTreeSeriesModel`: the pure `FeedResult` → `Fetched` translation, and
/// that a load actually asks for the tapped tag's own name.
///
/// `TagTreeSeriesModel` does not exist before this change, so every test
/// here fails to compile without it — `error: cannot find 'TagTreeSeriesModel'
/// in scope`.
@Suite("Tag tree series")
@MainActor
struct TagTreeSeriesModelTests {
    private static let boxing = Tag(
        id: 900, name: "Boxing", namePath: "Activities > Sports > Boxing", parentId: 42,
        level: 3, description: nil, seriesCount: 19, isGenre: false, isSpoiler: false,
        mergedWith: nil, contentRating: nil
    )

    @Test("a network result becomes .loaded")
    func networkResultLoads() {
        let series = [SeriesFactory.make(id: 1), SeriesFactory.make(id: 2)]
        let result = FeedResult(series: series, origin: .network, hasMore: true, total: 2)
        guard case let .loaded(value, _, isPartial) = TagTreeSeriesModel.fetched(from: result) else {
            Issue.record("expected .loaded")
            return
        }
        #expect(value.map(\.id) == [1, 2])
        #expect(isPartial == false)
    }

    @Test("a stale failure with cached series becomes .failed with that content attached")
    func staleFailureKeepsContent() {
        let series = [SeriesFactory.make(id: 3)]
        let result = FeedResult(series: series, origin: .staleAfter(.offline))
        guard case let .failed(error, stale) = TagTreeSeriesModel.fetched(from: result) else {
            Issue.record("expected .failed")
            return
        }
        #expect(error == .offline)
        #expect(stale?.map(\.id) == [3])
    }

    @Test("a stale failure with nothing cached becomes .failed with no stale value")
    func blockingFailureHasNoStale() {
        let result = FeedResult(series: [], origin: .staleAfter(.offline))
        guard case let .failed(error, stale) = TagTreeSeriesModel.fetched(from: result) else {
            Issue.record("expected .failed")
            return
        }
        #expect(error == .offline)
        #expect(stale == nil)
    }

    @Test("load() searches the tapped tag by name, most popular first")
    func loadSearchesTheTappedTag() async {
        let spy = QueryCapturingRepository()
        let model = TagTreeSeriesModel(tag: Self.boxing, repository: spy)
        await model.load()
        #expect(spy.lastQuery?.tags == ["Boxing"])
        #expect(spy.lastQuery?.sort == "popularity_asc")
    }
}

/// Records the query it was asked to search, so a test can check what a
/// model actually sent without a live network.
private final class QueryCapturingRepository: StubRepositoryBase, @unchecked Sendable {
    private(set) var lastQuery: SearchQuery?

    override func search(_ query: SearchQuery) async -> FeedResult {
        lastQuery = query
        return FeedResult(series: [], origin: .network)
    }
}
