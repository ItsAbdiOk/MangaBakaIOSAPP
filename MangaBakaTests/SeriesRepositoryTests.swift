import Foundation
import Testing
@testable import MangaBaka

/// The behaviour the on-device cache exists for: instant repeat visits, no
/// wasted requests, and content that survives going offline.
@Suite("Series repository", .serialized)
struct SeriesRepositoryTests {
    private let baseURL = URL(string: "https://api.example.invalid").unsafeTestURL

    private func payload(ids: [Int], titlePrefix: String = "S") -> Data {
        let items = ids.map { id in
            """
            {"id":\(id),"state":"active","merged_with":null,
             "titles":[{"language":"en","traits":["official"],
                        "title":"\(titlePrefix)\(id)","is_primary":true}],
             "cover":{"raw":null,"x150":null,"x250":null,"x350":null,
                      "blurhash":null,"width":200,"height":300},
             "description":null,"authors":null,"artists":null,"status":null,
             "rating":null,"type":null,"content_rating":null}
            """
        }
        return Data(#"{"status":200,"data":[\#(items.joined(separator: ","))]}"#.utf8)
    }

    private func makeRepository(clock: any Clock) throws -> SeriesRepository {
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

    /// Control: with a working network and an empty cache, the repository
    /// fetches and returns what the API gave it. If this fails, nothing else
    /// in this suite means anything.
    @Test("Control — an empty cache fetches from the network")
    func controlFetches() async throws {
        URLProtocolStub.setHandler { [data = payload(ids: [1, 2, 3])] _ in .respond(.init(body: data)) }
        defer { URLProtocolStub.reset() }

        let result = try await makeRepository(clock: TestClock()).feed(.rising, forceRefresh: false)

        #expect(result.origin == .network)
        #expect(result.series.map(\.id) == [1, 2, 3])
        #expect(URLProtocolStub.requests.count == 1)
    }

    /// A cached row that no longer decodes — a field the model has since
    /// made required, a payload an older build wrote — was dropped one row at
    /// a time, and the short feed served as a cache hit. Twenty became
    /// fourteen with nothing logged and a filter left to take the blame.
    @Test("A cached row that fails to decode makes the feed a miss, not a shorter hit")
    func undecodableRowIsAMiss() async throws {
        URLProtocolStub.setHandler { [data = payload(ids: [1, 2, 3])] _ in .respond(.init(body: data)) }
        defer { URLProtocolStub.reset() }

        let database = try AppDatabase.inMemory()
        let repository = SeriesRepository(
            client: APIClient(
                baseURL: baseURL,
                session: URLProtocolStub.makeSession(),
                tokenProvider: UnauthenticatedTokenProvider()
            ),
            database: database,
            clock: TestClock()
        )
        _ = await repository.feed(.rising, forceRefresh: false)
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE series SET payload = ? WHERE id = 2", arguments: [Data("{".utf8)])
        }

        let result = await repository.feed(.rising, forceRefresh: false)
        #expect(result.series.map(\.id) == [1, 2, 3], "The feed must not come back short")
        #expect(result.origin == .network, "One bad row is a miss; the feed is refetched")
    }

    /// Replacing a feed deleted its index and left the series rows it pointed
    /// at. The table grew on every fetch, and the "series cached" count on
    /// Discover counted the orphans nothing could reach.
    @Test("Refetching a feed does not leave its old rows behind")
    func refetchTrimsOrphans() async throws {
        URLProtocolStub.setHandler { [data = payload(ids: [1, 2, 3])] _ in .respond(.init(body: data)) }
        let repository = try makeRepository(clock: TestClock())
        _ = await repository.feed(.rising, forceRefresh: false)
        URLProtocolStub.reset()

        URLProtocolStub.setHandler { [data = payload(ids: [9])] _ in .respond(.init(body: data)) }
        defer { URLProtocolStub.reset() }
        _ = await repository.feed(.rising, forceRefresh: true)

        #expect(await repository.cachedSeriesCount() == 1, "Three orphans were still counted as cached")
    }

    /// The point of the cache: a second visit costs nothing.
    @Test("A second read inside the freshness window issues no request")
    func secondReadIsFree() async throws {
        URLProtocolStub.setHandler { [data = payload(ids: [1, 2, 3])] _ in .respond(.init(body: data)) }
        defer { URLProtocolStub.reset() }

        let repository = try makeRepository(clock: TestClock())
        _ = await repository.feed(.rising, forceRefresh: false)
        let second = await repository.feed(.rising, forceRefresh: false)

        #expect(second.origin == .cache)
        #expect(second.series.map(\.id) == [1, 2, 3])
        #expect(URLProtocolStub.requests.count == 1, "The cached read must not touch the network")
    }

    /// Freshness is driven by an injected clock, so this tests expiry in
    /// milliseconds rather than by sleeping for a day.
    @Test("Cache expires once past the freshness window")
    func cacheExpires() async throws {
        URLProtocolStub.setHandler { [data = payload(ids: [1])] _ in .respond(.init(body: data)) }
        defer { URLProtocolStub.reset() }

        let clock = TestClock()
        let repository = try makeRepository(clock: clock)
        _ = await repository.feed(.rising, forceRefresh: false)

        // Just inside the window: still cached.
        clock.advance(by: FeedKind.rising.freshness - 1)
        #expect(await repository.feed(.rising, forceRefresh: false).origin == .cache)
        #expect(URLProtocolStub.requests.count == 1)

        // Just past it: refetches.
        clock.advance(by: 2)
        #expect(await repository.feed(.rising, forceRefresh: false).origin == .network)
        #expect(URLProtocolStub.requests.count == 2)
    }

    /// A device clock that has moved backwards must not make stale content look
    /// fresh forever.
    @Test("A backwards device clock is treated as stale, not as fresh")
    func backwardsClockIsStale() async throws {
        URLProtocolStub.setHandler { [data = payload(ids: [1])] _ in .respond(.init(body: data)) }
        defer { URLProtocolStub.reset() }

        let clock = TestClock()
        let repository = try makeRepository(clock: clock)
        _ = await repository.feed(.rising, forceRefresh: false)

        clock.advance(by: -10_000)
        #expect(await repository.feed(.rising, forceRefresh: false).origin == .network)
    }

    @Test("Pull to refresh bypasses a fresh cache")
    func forceRefreshBypassesCache() async throws {
        URLProtocolStub.setHandler { [data = payload(ids: [1])] _ in .respond(.init(body: data)) }
        defer { URLProtocolStub.reset() }

        let repository = try makeRepository(clock: TestClock())
        _ = await repository.feed(.rising, forceRefresh: false)
        let refreshed = await repository.feed(.rising, forceRefresh: true)

        #expect(refreshed.origin == .network)
        #expect(URLProtocolStub.requests.count == 2)
    }

    /// The behaviour that matters on a train.
    @Test("Going offline serves cached content instead of an error")
    func offlineServesCache() async throws {
        URLProtocolStub.setHandler { [data = payload(ids: [1, 2])] _ in .respond(.init(body: data)) }
        let repository = try makeRepository(clock: TestClock())
        _ = await repository.feed(.rising, forceRefresh: false)
        URLProtocolStub.reset()

        URLProtocolStub.setHandler { _ in .fail(URLError(.notConnectedToInternet)) }
        defer { URLProtocolStub.reset() }
        let offline = await repository.feed(.rising, forceRefresh: true)

        #expect(offline.origin == .staleAfter(.offline))
        #expect(offline.series.map(\.id) == [1, 2], "Cached content must survive going offline")
        #expect(offline.blockingError == nil, "Content exists, so nothing should block the UI")
    }

    /// Offline with nothing cached is the one case that should show an error.
    @Test("Offline with an empty cache reports a blocking error")
    func offlineWithNoCacheBlocks() async throws {
        URLProtocolStub.setHandler { _ in .fail(URLError(.notConnectedToInternet)) }
        defer { URLProtocolStub.reset() }

        let result = try await makeRepository(clock: TestClock()).feed(.rising, forceRefresh: false)

        #expect(result.series.isEmpty)
        #expect(result.blockingError == .offline)
    }

    /// The API's ordering is editorial, so it must survive the round trip
    /// through SQLite rather than coming back in primary-key order.
    @Test("Feed order survives the cache")
    func feedOrderSurvives() async throws {
        URLProtocolStub.setHandler { [data = payload(ids: [30, 10, 20])] _ in .respond(.init(body: data)) }
        defer { URLProtocolStub.reset() }

        let repository = try makeRepository(clock: TestClock())
        _ = await repository.feed(.rising, forceRefresh: false)
        let cached = await repository.feed(.rising, forceRefresh: false)

        #expect(cached.origin == .cache)
        #expect(cached.series.map(\.id) == [30, 10, 20], "Order must not be re-sorted by id")
    }

    /// A feed is an ordered snapshot. Merging two snapshots produces an order
    /// that never existed, so a refetch must replace rather than merge.
    @Test("A refetch replaces the feed rather than merging into it")
    func refetchReplaces() async throws {
        let clock = TestClock()
        URLProtocolStub.setHandler { [data = payload(ids: [1, 2, 3])] _ in .respond(.init(body: data)) }
        let repository = try makeRepository(clock: clock)
        _ = await repository.feed(.rising, forceRefresh: false)
        URLProtocolStub.reset()

        URLProtocolStub.setHandler { [data = payload(ids: [9])] _ in .respond(.init(body: data)) }
        defer { URLProtocolStub.reset() }
        _ = await repository.feed(.rising, forceRefresh: true)

        let cached = await repository.feed(.rising, forceRefresh: false)
        #expect(cached.series.map(\.id) == [9], "Stale entries must not linger in the feed")
    }

    /// Regression: content_rating was once sent comma-joined
    /// (`content_rating=safe,suggestive`), which the API rejects with HTTP 400
    /// and a validation error. Every feed broke, while lint and the rest of the
    /// suite stayed green — nothing asserted the shape of the outgoing URL.
    @Test("Content rating is sent as repeated keys, never comma-joined")
    func contentRatingIsRepeated() async throws {
        URLProtocolStub.setHandler { [data = payload(ids: [1])] _ in .respond(.init(body: data)) }
        defer { URLProtocolStub.reset() }

        _ = try await makeRepository(clock: TestClock()).feed(.rising, forceRefresh: true)

        let url = try #require(URLProtocolStub.requests.first?.url)
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let ratings = items.filter { $0.name == "content_rating" }

        #expect(ratings.count == 2, "Each rating needs its own query item")
        #expect(Set(ratings.compactMap(\.value)) == ["safe", "suggestive"])
        #expect(
            !ratings.contains { ($0.value ?? "").contains(",") },
            "A comma-joined value is rejected by the API with HTTP 400"
        )
    }

    /// Regression: the stack sent a seedless request to /v1/series/mix, which
    /// the API rejects ("At least one seed series or one include tag is
    /// required"). A first-run reader saw an error instead of a stack.
    @Test("A seedless stack does not call the endpoint that requires seeds")
    func seedlessStackAvoidsMix() async throws {
        URLProtocolStub.setHandler { [data = payload(ids: [1])] _ in .respond(.init(body: data)) }
        defer { URLProtocolStub.reset() }

        _ = try await makeRepository(clock: TestClock()).feed(.surprise, forceRefresh: true)

        let path = try #require(URLProtocolStub.requests.first?.url?.path)
        #expect(!path.contains("/mix"), "mix rejects a request with no seeds")
        #expect(path.contains("/search"))
    }

    /// Every modelled field must survive the SQLite round trip. Cheap to get
    /// wrong silently: a dropped field shows up as a blank UI, not a crash.
    @Test("Modelled fields survive the cache round trip intact")
    func roundTripIsLossless() async throws {
        URLProtocolStub.setHandler { [data = payload(ids: [1])] _ in .respond(.init(body: data)) }
        defer { URLProtocolStub.reset() }

        let repository = try makeRepository(clock: TestClock())
        let fetched = await repository.feed(.rising, forceRefresh: false)
        let cached = await repository.feed(.rising, forceRefresh: false)

        #expect(cached.origin == .cache)
        #expect(cached.series == fetched.series,
                "The cached copy must equal what came off the network")
        #expect(cached.series.first?.displayTitle == "S1")
        #expect(cached.series.first?.cover.width == 200)
    }

    /// Merged and deleted series must not be cached into a discovery feed.
    @Test("Non-active series are filtered before caching")
    func filtersNonActive() async throws {
        let body = Data("""
        {"status":200,"data":[
          {"id":1,"state":"active","merged_with":null,
           "titles":[{"language":"en","traits":["official"],"title":"Live","is_primary":true}],
           "cover":{"raw":null,"x150":null,"x250":null,"x350":null,
                    "blurhash":null,"width":200,"height":300},
           "description":null,"authors":null,"artists":null,"status":null,
           "rating":null,"type":null,"content_rating":null},
          {"id":2,"state":"merged","merged_with":1,"titles":null,
           "cover":{"raw":null,"x150":null,"x250":null,"x350":null,
                    "blurhash":null,"width":null,"height":null},
           "description":null,"authors":null,"artists":null,"status":null,
           "rating":null,"type":null,"content_rating":null}
        ]}
        """.utf8)
        URLProtocolStub.setHandler { _ in .respond(.init(body: body)) }
        defer { URLProtocolStub.reset() }

        let repository = try makeRepository(clock: TestClock())
        let fetched = await repository.feed(.rising, forceRefresh: false)
        #expect(fetched.series.map(\.id) == [1])

        let cached = await repository.feed(.rising, forceRefresh: false)
        #expect(cached.origin == .cache)
        #expect(cached.series.map(\.id) == [1], "A merged series must not reappear from cache")
    }
}
