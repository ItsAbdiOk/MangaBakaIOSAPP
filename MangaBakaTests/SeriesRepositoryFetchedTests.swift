import Foundation
import Testing
@testable import MangaBaka

/// Batch 1 of FAILURES-SUMMARY.md §6: the repository must be able to tell a
/// caller "I asked and it failed" from "I asked and there was nothing" —
/// `extras`, `mix`, `images` and `feedPage` each used to collapse the two.
/// Split from `SeriesRepositoryTests.swift` rather than appended to it,
/// which was already at the lint's 250-line type-body ceiling.
@Suite("Series repository — failure vs. emptiness", .serialized)
struct SeriesRepositoryFetchedTests {
    private let baseURL = URL(string: "https://api.example.invalid").unsafeTestURL

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

    /// The bare `/v1/series/{id}` body `fetchExtras`'s other tests reuse, for
    /// the legs below that need a real `Series` rather than an empty array.
    private func bareSeriesBody(id: Int) -> Data {
        Data("""
        {"status":200,"data":{"id":\(id),"state":"active","merged_with":null,"titles":null,
         "cover":{"raw":null,"x150":null,"x250":null,"x350":null,"blurhash":null,"width":null,"height":null},
         "description":null,"authors":null,"artists":null,"status":null,"rating":null,"type":null,
         "content_rating":null,"total_chapters":null,"final_volume":null,
         "publishers":null,"anime":null,"source":null}}
        """.utf8)
    }

    /// Gap 9 (FAILURES-SUMMARY.md §6, Batch 1): five of `fetchExtras`'s six
    /// concurrent legs used to succeed and cache the sixth's absence for the
    /// full six hours — a rate limit on `/works` looked exactly like a series
    /// with no volumes, for the rest of the cache's life. Expected to fail
    /// without the fix: today `extras` caches on anything but an all-empty
    /// struct, so the second call below issues no second `/works` request and
    /// `volumes` stays `[]` regardless of what the server would now answer.
    @Test("A partial extras answer is not cached, so the next open retries the failed leg")
    func partialExtrasIsNotCached() async throws {
        URLProtocolStub.setHandler { [bareSeriesBody = bareSeriesBody(id: 1)] request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/works") {
                return .respond(.init(
                    statusCode: 429,
                    body: Data(#"{"status":429,"message":"Too Many Requests"}"#.utf8),
                    headers: ["Retry-After": "0"]
                ))
            }
            if path.hasSuffix("/links") || path.hasSuffix("/news")
                || path.hasSuffix("/relationships") || path.hasSuffix("/collections") {
                return .respond(.init(body: Data(#"{"status":200,"data":[]}"#.utf8)))
            }
            // The bare `/v1/series/{id}` fetch.
            return .respond(.init(body: bareSeriesBody))
        }
        defer { URLProtocolStub.reset() }

        let clock = TestClock()
        let repository = try makeRepository(clock: clock)

        let first = await repository.extras(for: 1)
        #expect(first.failure != nil, "the failed /works leg must be reported, not swallowed")
        #expect(first.volumes.isEmpty)

        clock.advance(by: 1)
        _ = await repository.extras(for: 1)

        let worksRequests = URLProtocolStub.requests.filter { $0.url?.path.hasSuffix("/works") == true }
        #expect(worksRequests.count == 2, "a partial answer must not stick — the failed leg is retried")
    }

    /// Control for the test above: when every leg answers, the whole struct
    /// is cached and a second open costs nothing.
    @Test("Control — a complete extras answer is cached")
    func completeExtrasIsCached() async throws {
        let body = bareSeriesBody(id: 1)
        let allEmptyLegs: @Sendable (URLRequest) -> URLProtocolStub.Outcome = { [body] request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/links") || path.hasSuffix("/news") || path.hasSuffix("/relationships")
                || path.hasSuffix("/collections") || path.hasSuffix("/works") {
                return .respond(.init(body: Data(#"{"status":200,"data":[]}"#.utf8)))
            }
            return .respond(.init(body: body))
        }
        URLProtocolStub.setHandler(allEmptyLegs)

        let repository = try makeRepository(clock: TestClock())
        let first = await repository.extras(for: 1)
        #expect(first.failure == nil)

        // A fresh handler and an empty request log, so the assertion below
        // proves the second call touched no request at all rather than just
        // that the requests it does make happen to succeed.
        URLProtocolStub.reset()
        URLProtocolStub.setHandler(allEmptyLegs)
        defer { URLProtocolStub.reset() }
        _ = await repository.extras(for: 1)
        #expect(URLProtocolStub.requests.isEmpty, "a complete answer must be served from cache")
    }

    /// Gap 11: `mix` used to answer `.empty` for a failed request, identical
    /// to a real "nothing matched". Expected to fail without the fix: `.mix`
    /// only ever returns `MixResult.empty`, which has no `.failure` to read.
    @Test("A failed blend is distinguishable from one with nothing to recommend")
    func mixFailureIsCarried() async throws {
        URLProtocolStub.setHandler { _ in .fail(URLError(.notConnectedToInternet)) }
        defer { URLProtocolStub.reset() }

        let result = try await makeRepository(clock: TestClock())
            .mix(seeds: [1], filters: SearchQuery(), excludedTags: [])

        #expect(result.failure == .offline)
        #expect(result.recommendations.isEmpty)
    }

    /// Gap 32: `images` used to answer `[]` for both a failed fetch and a
    /// series with no covers. Expected to fail without the fix: `images`
    /// returns `[SeriesImage]`, not `[SeriesImage]?`, so there is no `nil` to
    /// distinguish the two.
    @Test("A failed image fetch is nil; a series with none is an empty array")
    func imagesDistinguishFailureFromEmpty() async throws {
        let repository = try makeRepository(clock: TestClock())

        URLProtocolStub.setHandler { _ in .fail(URLError(.notConnectedToInternet)) }
        let failed = await repository.images(for: 1)
        #expect(failed == nil)
        URLProtocolStub.reset()

        URLProtocolStub.setHandler { _ in .respond(.init(body: Data(#"{"status":200,"data":[]}"#.utf8))) }
        defer { URLProtocolStub.reset() }
        let empty = await repository.images(for: 2)
        #expect(empty != nil, "a genuinely empty answer must not read as a failure")
        #expect(empty?.isEmpty == true)
    }

    /// Gap 15: a page-2 failure used to default `hasMore` to `false`, which
    /// reads exactly like the end of the feed. Expected to fail without the
    /// fix: `feedPage`'s catch does not set `hasMore`, so it stays `false`.
    @Test("A failed page keeps hasMore true, so it is not read as the end of the feed")
    func failedPageKeepsHasMore() async throws {
        let body = Data(#"{"status":500}"#.utf8)
        URLProtocolStub.setHandler { _ in .respond(.init(statusCode: 500, body: body)) }
        defer { URLProtocolStub.reset() }

        let result = try await makeRepository(clock: TestClock()).feedPage(.trending, page: 2)

        #expect(result.hasMore, "a failed page is not the same thing as no more pages")
        let message = "MangaBaka returned an unexpected response."
        #expect(result.origin == .staleAfter(.server(status: 500, message: message)))
    }

    /// Gap 74: a discard that fails to a locked or read-only database used to
    /// be spent through `try?` and forgotten, leaving content on screen the
    /// reader's own filter change should have removed with nothing on record
    /// to say why. Expected to fail without the fix: `discardCachedFeeds`
    /// returns `Void`, so there is no result to check.
    @Test("A failed cache discard reports failure rather than swallowing it")
    func failedDiscardReportsFailure() async throws {
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
        // Close the underlying connection so the very next write fails —
        // standing in for a locked file or a full disk.
        try database.writer.close()

        #expect(await repository.discardCachedFeeds() == false)
    }

    /// Control for the test above: an ordinary, writable database discards
    /// successfully.
    @Test("Control — an ordinary cache discard reports success")
    func successfulDiscardReportsSuccess() async throws {
        let repository = try makeRepository(clock: TestClock())
        #expect(await repository.discardCachedFeeds() == true)
    }

    /// This suite is about telling "asked and it failed" from "asked and
    /// there was nothing wrong" — and a 304 revalidation (see
    /// `FeedRevalidationTests` for the full behaviour, and the measurement it
    /// rests on) is exactly the case in between: the network answered, and
    /// the answer is "you already have the current copy". That must read as
    /// current (`.cache`), never as `.staleAfter` — the family reserved for
    /// when the network genuinely could not be reached.
    @Test("A 304 revalidation is current, not a stale fallback")
    func notModifiedIsNotTreatedAsAFailure() async throws {
        let feedBody = Data(#"""
        {"status":200,"data":[{"id":1,"state":"active","merged_with":null,
         "titles":[{"language":"en","traits":["official"],"title":"S1","is_primary":true}],
         "cover":{"raw":null,"x150":null,"x250":null,"x350":null,"blurhash":null,
                  "width":null,"height":null},
         "description":null,"authors":null,"artists":null,"status":null,
         "rating":null,"type":null,"content_rating":null}]}
        """#.utf8)
        URLProtocolStub.setHandler { _ in
            .respond(.init(body: feedBody, headers: ["Last-Modified": "Sun, 13 Sep 2026 13:56:53 GMT"]))
        }
        let clock = TestClock()
        let repository = try makeRepository(clock: clock)
        _ = await repository.feed(.rising, forceRefresh: false)
        URLProtocolStub.reset()

        clock.advance(by: FeedKind.rising.freshness + 1)
        URLProtocolStub.setHandler { _ in .respond(.init(statusCode: 304, body: Data())) }
        defer { URLProtocolStub.reset() }
        let result = await repository.feed(.rising, forceRefresh: false)

        #expect(result.origin == .cache, "A confirmed-current answer is not a network failure")
        #expect(result.blockingError == nil)
        #expect(result.series.map(\.id) == [1])
    }
}
