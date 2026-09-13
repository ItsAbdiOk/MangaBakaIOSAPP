import Foundation

/// Default `RequestPriority` overloads for `SeriesRepositoryProtocol`.
///
/// Split out of `SeriesRepository.swift` for the lint's 400-line file-length
/// ceiling, the same reason `+Cache`, `+Paging` and `+Count` exist — this file
/// was already exactly at that ceiling before `priority` was added anywhere.
///
/// Each pair here exists so adding `priority` did not force every existing
/// conformer (test stubs included) to grow a new parameter: the
/// priority-taking requirement gets a default implementation that forwards to
/// the plain one and drops the priority on the floor, which is exactly right
/// for a stub with no real rate limiter to tell. `SeriesRepository` — the one
/// conformer that actually talks to the network — implements the
/// priority-taking requirement itself (see `SeriesRepository.swift`,
/// `+Paging.swift`, `+Count.swift`), so dispatch through `any
/// SeriesRepositoryProtocol` still reaches its real, priority-aware logic;
/// only conformers that never override it fall back to these.
extension SeriesRepositoryProtocol {
    func feed(_ feed: FeedKind, forceRefresh: Bool, priority: RequestPriority) async -> FeedResult {
        await self.feed(feed, forceRefresh: forceRefresh)
    }

    func search(_ query: SearchQuery, priority: RequestPriority) async -> FeedResult {
        await search(query)
    }

    func feedPage(_ feed: FeedKind, page: Int, priority: RequestPriority) async -> FeedResult {
        await feedPage(feed, page: page)
    }

    func count(_ query: SearchQuery, priority: RequestPriority) async -> Int? {
        await count(query)
    }
}
