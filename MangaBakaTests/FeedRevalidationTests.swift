import Foundation
import Testing
@testable import MangaBaka

/// Conditional requests on the feeds: launch costs nothing when nothing
/// changed on the server.
///
/// MEASURED 2026-09-13 against api.mangabaka.org: feed responses carry no
/// `ETag` at all, only `Last-Modified` (e.g.
/// "Sun, 13 Sep 2026 13:56:53 GMT") and `cache-control: public,
/// max-age=60`. A request repeating that exact value as `If-Modified-Since`
/// gets back HTTP 304 with a zero-byte body; `/v1/series/{id}` carries
/// `Last-Modified` too. So a stale-but-present feed cache is revalidated
/// with `If-Modified-Since` rather than always paying for a full
/// re-download — see `SeriesRepository.feed`.
@Suite("Feed revalidation (Last-Modified / If-Modified-Since)", .serialized)
struct FeedRevalidationTests {
    private let baseURL = URL(string: "https://api.example.invalid").unsafeTestURL
    /// The exact string this suite pretends the server sent. Deliberately not
    /// in the format `HTTPURLResponse` or any local formatter would produce —
    /// proves the value is carried through untouched rather than round-tripped
    /// through a date parser and reformatted, which could silently stop
    /// matching what the server compares against.
    private let serverLastModified = "Sun, 13 Sep 2026 13:56:53 GMT"

    private func payload(ids: [Int], lastModified: String? = nil) -> URLProtocolStub.Response {
        let items = ids.map { id in
            """
            {"id":\(id),"state":"active","merged_with":null,
             "titles":[{"language":"en","traits":["official"],
                        "title":"S\(id)","is_primary":true}],
             "cover":{"raw":null,"x150":null,"x250":null,"x350":null,
                      "blurhash":null,"width":200,"height":300},
             "description":null,"authors":null,"artists":null,"status":null,
             "rating":null,"type":null,"content_rating":null}
            """
        }
        let body = Data(#"{"status":200,"data":[\#(items.joined(separator: ","))]}"#.utf8)
        var headers: [String: String] = [:]
        if let lastModified { headers["Last-Modified"] = lastModified }
        return URLProtocolStub.Response(body: body, headers: headers)
    }

    private func notModified() -> URLProtocolStub.Response {
        URLProtocolStub.Response(statusCode: 304, body: Data())
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

    /// Raw SQL rather than the `FeedMetadata` record type's own query
    /// interface (`.filter(Column(...) == ...)`) — this test file has no
    /// `import GRDB` of its own, and unlike `Int.fetchOne(db, sql:...)`
    /// elsewhere in this test target, `Column` is a type this file has never
    /// named directly.
    private func feedMetadata(
        _ database: AppDatabase,
        feed: FeedKind
    ) async throws -> (cachedAt: Date?, lastModified: String?) {
        try await database.writer.read { db in
            let cachedAt = try Date.fetchOne(
                db, sql: "SELECT cachedAt FROM feedMetadata WHERE feedKey = ?", arguments: [feed.cacheKey]
            )
            let lastModified = try String.fetchOne(
                db, sql: "SELECT lastModified FROM feedMetadata WHERE feedKey = ?", arguments: [feed.cacheKey]
            )
            return (cachedAt, lastModified)
        }
    }

    /// Control: with no prior cache, the first request carries no
    /// `If-Modified-Since` at all — there is nothing yet to be conditional
    /// on, and this must stay indistinguishable from the plain fetch that ran
    /// before this feature existed.
    @Test("Control — a first fetch sends no If-Modified-Since")
    func firstFetchSendsNoHeader() async throws {
        URLProtocolStub.setHandler { [payload = payload(ids: [1], lastModified: serverLastModified)] _ in
            .respond(payload)
        }
        defer { URLProtocolStub.reset() }

        _ = try await makeRepository(clock: TestClock()).feed(.rising, forceRefresh: false)

        let sent = try #require(URLProtocolStub.requests.first)
        #expect(sent.value(forHTTPHeaderField: "If-Modified-Since") == nil)
    }

    /// Control: a cache still inside its freshness window is served without
    /// touching the network at all — today's behaviour, unaffected by this
    /// feature, since there is nothing to revalidate yet.
    @Test("Control — a fresh cache sends nothing, conditional or otherwise")
    func freshCacheSendsNothing() async throws {
        URLProtocolStub.setHandler { [payload = payload(ids: [1], lastModified: serverLastModified)] _ in
            .respond(payload)
        }
        defer { URLProtocolStub.reset() }

        let repository = try makeRepository(clock: TestClock())
        _ = await repository.feed(.rising, forceRefresh: false)
        URLProtocolStub.reset()
        // No handler at all: any second request would crash the stub with
        // "unsupportedURL", which is exactly what should never happen here.
        let second = await repository.feed(.rising, forceRefresh: false)

        #expect(second.origin == .cache)
        #expect(URLProtocolStub.requests.isEmpty)
    }

    /// The header is the server's own string, sent back byte for byte. A
    /// reformatted date can fail to match what the server compares against
    /// and never earn a 304 at all.
    @Test("A stale cache's revalidation sends the stored Last-Modified verbatim")
    func sendsStoredHeaderVerbatim() async throws {
        let clock = TestClock()
        URLProtocolStub.setHandler { [payload = payload(ids: [1], lastModified: serverLastModified)] _ in
            .respond(payload)
        }
        let repository = try makeRepository(clock: clock)
        _ = await repository.feed(.rising, forceRefresh: false)
        URLProtocolStub.reset()

        clock.advance(by: FeedKind.rising.freshness + 1)
        URLProtocolStub.setHandler { _ in .respond(notModified()) }
        defer { URLProtocolStub.reset() }
        _ = await repository.feed(.rising, forceRefresh: false)

        let sent = try #require(URLProtocolStub.requests.first)
        #expect(sent.value(forHTTPHeaderField: "If-Modified-Since") == serverLastModified)
    }

    /// The behaviour this whole feature exists for: a 304 leaves the cached
    /// rows exactly as they were, costs exactly one request, and the series
    /// come back as current rather than as an error or a downgrade to stale.
    @Test("A 304 leaves cached rows untouched, refreshes fetchedAt, and costs one request")
    func notModifiedRevalidatesForFree() async throws {
        let clock = TestClock()
        let database = try AppDatabase.inMemory()
        let repository = SeriesRepository(
            client: APIClient(
                baseURL: baseURL,
                session: URLProtocolStub.makeSession(),
                tokenProvider: UnauthenticatedTokenProvider()
            ),
            database: database,
            clock: clock
        )
        let initial = payload(ids: [1, 2, 3], lastModified: serverLastModified)
        URLProtocolStub.setHandler { [initial] _ in .respond(initial) }
        _ = await repository.feed(.rising, forceRefresh: false)
        let firstMetadata = try await feedMetadata(database, feed: .rising)
        let firstCachedAt = try #require(firstMetadata.cachedAt)
        URLProtocolStub.reset()

        clock.advance(by: FeedKind.rising.freshness + 1)
        URLProtocolStub.setHandler { _ in .respond(notModified()) }
        defer { URLProtocolStub.reset() }
        let revalidated = await repository.feed(.rising, forceRefresh: false)

        #expect(revalidated.series.map(\.id) == [1, 2, 3], "A 304 must not empty or alter the cached rows")
        #expect(revalidated.blockingError == nil)
        #expect(URLProtocolStub.requests.count == 1, "A revalidation is one request, not a re-download")

        let secondMetadata = try await feedMetadata(database, feed: .rising)
        let secondCachedAt = try #require(secondMetadata.cachedAt)
        #expect(
            secondCachedAt > firstCachedAt,
            "The freshness clock must reset so the next visit doesn't immediately revalidate again"
        )
        #expect(secondMetadata.lastModified == serverLastModified, "Nothing rewrote the stored header")
    }

    /// The other half: when the server says the feed did change, the rows are
    /// rewritten exactly as an unconditional fetch would, and the new
    /// `Last-Modified` replaces the old one for the next revalidation.
    @Test("A 200 on a stale cache rewrites rows and stores the new Last-Modified")
    func freshResponseRewritesRows() async throws {
        let clock = TestClock()
        let database = try AppDatabase.inMemory()
        let repository = SeriesRepository(
            client: APIClient(
                baseURL: baseURL,
                session: URLProtocolStub.makeSession(),
                tokenProvider: UnauthenticatedTokenProvider()
            ),
            database: database,
            clock: clock
        )
        URLProtocolStub.setHandler { [payload = payload(ids: [1, 2], lastModified: serverLastModified)] _ in
            .respond(payload)
        }
        _ = await repository.feed(.rising, forceRefresh: false)
        URLProtocolStub.reset()

        let newLastModified = "Mon, 14 Sep 2026 00:00:00 GMT"
        clock.advance(by: FeedKind.rising.freshness + 1)
        URLProtocolStub.setHandler { [payload = payload(ids: [9], lastModified: newLastModified)] _ in
            .respond(payload)
        }
        defer { URLProtocolStub.reset() }
        let refetched = await repository.feed(.rising, forceRefresh: false)

        #expect(refetched.origin == .network)
        #expect(refetched.series.map(\.id) == [9], "A 200 must replace the feed, not merge into it")

        let metadata = try await feedMetadata(database, feed: .rising)
        #expect(metadata.lastModified == newLastModified)
    }

    /// A revalidation failure (offline, a 5xx) must fall back to the same
    /// stale cache a plain fetch failure would — the conditional path is not
    /// a second, less forgiving failure mode.
    @Test("A failed revalidation still falls back to the stale cache")
    func failedRevalidationFallsBackToCache() async throws {
        let clock = TestClock()
        URLProtocolStub.setHandler { [payload = payload(ids: [1], lastModified: serverLastModified)] _ in
            .respond(payload)
        }
        let repository = try makeRepository(clock: clock)
        _ = await repository.feed(.rising, forceRefresh: false)
        URLProtocolStub.reset()

        clock.advance(by: FeedKind.rising.freshness + 1)
        URLProtocolStub.setHandler { _ in .fail(URLError(.notConnectedToInternet)) }
        defer { URLProtocolStub.reset() }
        let result = await repository.feed(.rising, forceRefresh: false)

        #expect(result.origin == .staleAfter(.offline))
        #expect(result.series.map(\.id) == [1], "The cached copy must survive a failed revalidation")
    }
}
