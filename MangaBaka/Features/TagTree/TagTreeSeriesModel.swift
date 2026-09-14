import Foundation

/// Backing state for `TagTreeSeriesView`: the series behind one tag,
/// searched exactly the way `SearchModel.openTag` searches a tag tapped from
/// a series page — the same `SearchQuery.tags` field, the same
/// `popularity_asc` sort — reused rather than reinvented. `SearchQuery`'s own
/// `wireTagIDs` already resolves the name to the taxonomy id the wire wants
/// (`tag=39` finds 34,704 series against `tag=Action`'s 4,380 — measured,
/// see `SearchQuery`'s doc comment), so passing the tag's name here is
/// exactly as precise as passing its id.
///
/// `Fetched<[Series]>`, not a hand-rolled loading/failure pair: this is a new
/// screen, and `Fetched`'s own doc comment names the reason it exists —
/// "asked and got nothing" and "asked and failed" collapsing into the same
/// empty value is the largest single family in the failure review this
/// codebase ran. `fetched(from:)` is the one place that translates
/// `FeedResult`'s shape into `Fetched`'s.
@MainActor
@Observable
final class TagTreeSeriesModel {
    let tag: Tag
    private(set) var state: Fetched<[Series]> = .idle
    private(set) var hasMore = false
    private(set) var isLoadingMore = false
    /// A page-2+ request that failed outright, kept separate from `state`
    /// for the same reason `SearchModel.pageFailure` is: a reader thirty rows
    /// into good results who hits a throttled next page has not had their
    /// browse fail, just its next page (gap 15's shape, reused here).
    private(set) var pageFailure: APIError?

    private let repository: any SeriesRepositoryProtocol
    private var query: SearchQuery

    init(tag: Tag, repository: any SeriesRepositoryProtocol) {
        self.tag = tag
        self.repository = repository
        var query = SearchQuery()
        query.tags = [tag.name]
        query.sort = "popularity_asc"
        self.query = query
    }

    func load() async {
        state = .loading
        query.page = 1
        pageFailure = nil
        let result = await repository.search(query)
        state = Self.fetched(from: result)
        hasMore = result.hasMore
    }

    /// Appends the next page; a short or failed page stops it. Deduplicated
    /// like every other paging model here — the API repeats a series across
    /// pages when the underlying ordering shifts between requests, and
    /// `ForEach` traps on a duplicate id.
    func loadMore() async {
        guard hasMore, !isLoadingMore, case let .loaded(series, fetchedAt, isPartial) = state else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        var next = query
        next.page += 1
        let result = await repository.search(next)
        guard result.blockingError == nil else {
            pageFailure = result.blockingError
            return
        }
        pageFailure = nil
        query.page = next.page
        let known = Set(series.map(\.id))
        let additions = result.series.filter { !known.contains($0.id) }
        state = .loaded(series + additions, fetchedAt: fetchedAt, isPartial: isPartial)
        hasMore = result.hasMore
    }

    /// The pure translation `load()` applies — `nonisolated static` so a test
    /// can drive it with a hand-built `FeedResult` and no repository at all.
    /// A `.staleAfter` result with something cached still becomes `.failed`
    /// with that content attached as `stale`, mirroring `FeedResult.
    /// blockingError`'s own rule: only a failure with nothing to show at all
    /// should read as a blocking failure.
    nonisolated static func fetched(from result: FeedResult) -> Fetched<[Series]> {
        if case let .staleAfter(error) = result.origin {
            return .failed(error, stale: result.series.isEmpty ? nil : result.series)
        }
        return .loaded(result.series, fetchedAt: Date(), isPartial: false)
    }
}
