import Foundation
import Testing
@testable import MangaBaka

/// Items 66, 67 and 68's feed half.
///
/// 66: on a cache miss the feed was read and JSON-decoded twice — the fresh
/// check, then the stale fallback — each a transaction plus an `IN (…)` fetch
/// plus up to fifty `Series` decodes, inside the actor, serialising every
/// other repository call behind them.
///
/// 67: the cache hit required `!fresh.isEmpty`, so a feed legitimately written
/// as empty fired a request on every visit inside its own freshness window.
@Suite("The feed cache is read once and believes an empty answer", .serialized)
struct FeedCacheReadTests {
    private let baseURL = URL(string: "https://api.example.invalid").unsafeTestURL

    private func makeRepository(clock: TestClock) throws -> SeriesRepository {
        SeriesRepository(
            client: APIClient(
                baseURL: baseURL,
                session: URLProtocolStub.makeSession(),
                tokenProvider: UnauthenticatedTokenProvider()
            ),
            database: try AppDatabase.inMemory(),
            clock: clock
        )
    }

    private let emptyPayload = Data(#"{"status":200,"data":[]}"#.utf8)

    /// Expected to fail before item 67 with: `URLProtocolStub.requests.count
    /// == 2`, because the `!fresh.isEmpty` guard rejected the empty-but-fresh
    /// cache row and the second call went to the network.
    @Test("A feed cached as empty is served from cache inside its window")
    func emptyCacheIsStillACacheHit() async throws {
        URLProtocolStub.setHandler { [payload = emptyPayload] _ in .respond(.init(body: payload)) }
        defer { URLProtocolStub.reset() }

        let clock = TestClock()
        let repository = try makeRepository(clock: clock)
        // `.similar` has a 24-hour freshness, so a second call a minute later
        // is inside the window by a wide margin.
        _ = await repository.feed(.similar(seriesId: 1), forceRefresh: true)
        let afterFirst = URLProtocolStub.requests.count
        #expect(afterFirst == 1)

        clock.advance(by: 60)
        _ = await repository.feed(.similar(seriesId: 1))
        #expect(URLProtocolStub.requests.count == afterFirst)
    }

    /// The control: outside the window the same empty cache does refetch, so
    /// the assertion above is about freshness and not about a request path
    /// that stopped working.
    @Test("The same empty feed refetches once its window has passed")
    func emptyCacheExpires() async throws {
        URLProtocolStub.setHandler { [payload = emptyPayload] _ in .respond(.init(body: payload)) }
        defer { URLProtocolStub.reset() }

        let clock = TestClock()
        let repository = try makeRepository(clock: clock)
        _ = await repository.feed(.similar(seriesId: 1), forceRefresh: true)
        clock.advance(by: 86_400 + 1)
        _ = await repository.feed(.similar(seriesId: 1))
        #expect(URLProtocolStub.requests.count == 2)
    }

    /// Item 68. A page with one undecodable row used to fail the whole array,
    /// so the reader saw nothing rather than nineteen of twenty.
    ///
    /// Expected to fail before item 68 with: `result.series.count == 0` — the
    /// `[Series]` decode threw on the bad row, `feed` fell into its catch, and
    /// the result was the (empty) stale cache with a `.staleAfter` origin.
    @Test("One bad row costs one row, not the whole page")
    func oneBadRowDropsOneRow() async throws {
        // Two well-formed rows and one whose `id` is a string where the model
        // requires a number. Shape taken from /v2/series/discover/rising,
        // 2026-09-14; trimmed to the fields a row must have to be decoded and
        // kept — `id`, `state` (which must be "active" for `isDiscoverable`)
        // and `cover`, which `Series.init(from:)` decodes non-optionally.
        // An earlier version of this fixture omitted `cover` and every row
        // was dropped, which looked exactly like the bug this test is about.
        let payload = Data(#"""
        {"status":200,"data":[
          {"id":1,"title":"One","type":"manga","state":"active","cover":{}},
          {"id":"not a number","title":"Bad","type":"manga","state":"active","cover":{}},
          {"id":3,"title":"Three","type":"manga","state":"active","cover":{}}
        ]}
        """#.utf8)
        URLProtocolStub.setHandler { _ in .respond(.init(body: payload)) }
        defer { URLProtocolStub.reset() }

        let repository = try makeRepository(clock: TestClock())
        let result = await repository.feed(.rising, forceRefresh: true)
        #expect(result.series.count == 2)
        #expect(result.series.map(\.id) == [1, 3])
        #expect(result.origin == .network)
    }
}
