import Foundation
import Testing
@testable import MangaBaka

/// A minimal stand-in for `URLProtocolStub`, used only here. `URLProtocolStub`
/// itself hard-codes `didReceive:cacheStoragePolicy: .notAllowed` on every
/// response it serves — the right default for its other callers, who never
/// want a stubbed response actually landing in `URLCache` between tests, but
/// it means it cannot be used to prove anything about real caching, which
/// both suites below need. `.serialized` because `handler`/`loadCount` are
/// shared static state.
private final class CachingStubProtocol: URLProtocol, @unchecked Sendable {
    struct StubResponse {
        let statusCode: Int
        let body: Data
        let headers: [String: String]
    }

    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> StubResponse)?
    nonisolated(unsafe) static var loadCount = 0

    // swiftlint:disable:next static_over_final_class
    override class func canInit(with request: URLRequest) -> Bool { true }
    // swiftlint:disable:next static_over_final_class
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.loadCount += 1
        guard let handler = Self.handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let stub = handler(request)
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: stub.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: stub.headers
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        // `.allowed`, unlike `URLProtocolStub`: the whole point here is to
        // let `URLSession`'s real `URLCache` behaviour run.
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .allowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CachingStubProtocol.self]
        configuration.urlCache = URLCache(memoryCapacity: 1 << 20, diskCapacity: 0)
        return URLSession(configuration: configuration)
    }
}

/// Wire review #30/#13, 2026-09-14: a URLCache hit inside a search
/// response's measured 60s `max-age` used to still spend a `searchTimestamps`
/// slot and add a ledger row for a request that never reached MangaBaka, so
/// the local "31st search is refused" could fire when far fewer than 30
/// requests actually reached the server, and `NetworkLedger`'s recorded
/// latencies — the p99 the client's 20s timeout is meant to be sized against
/// — were salted with ~0ms rows for cache hits.
@Suite("APIClient refunds a cache-served search and skips its ledger row", .serialized)
struct APIClientCacheRefundTests {
    private let baseURL = URL(string: "https://api.example.invalid").unsafeTestURL

    /// Expected to fail before the fix with `searchTimestampCount == 2` and
    /// `ledgerRequests == 2`, because `reserveSlot`/`NetworkLedger.record`
    /// ran unconditionally before `perform` had any way to know the second
    /// response was classified as a cache hit.
    ///
    /// **What the stub can and cannot prove.** MEASURED 2026-09-14 (a
    /// standalone Foundation snippet, written because this test's original
    /// `loadCount == 1` assertion failed with 2): a `URLProtocol` subclass
    /// gets `startLoading` called for *every* request and returns fresh
    /// bytes each time — `URLCache` never short-circuits a custom protocol —
    /// while `URLSessionTaskMetrics` nonetheless reports
    /// `resourceFetchType == .localCache` for every request after the first
    /// to the same URL, whatever the response's `Cache-Control` says. So
    /// this test does not prove a real network round trip was avoided; it
    /// proves that when the loader classifies a load as cache-served —
    /// which is the one signal `perform` keys on — the slot is refunded and
    /// the ledger row skipped. `refundIsNotUnconditional` below is the
    /// control that the branch is conditional on something.
    @Test("A search the loader classifies as cache-served costs one slot and one ledger row")
    func cacheHitRefundsSlotAndSkipsLedger() async throws {
        CachingStubProtocol.loadCount = 0
        let path = "/v2/series/search"
        let ledgerKey = NetworkLedger.shape(path)
        let before = await NetworkLedger.shared.byPath[ledgerKey]?.requests ?? 0

        CachingStubProtocol.handler = { _ in
            CachingStubProtocol.StubResponse(
                statusCode: 200,
                body: Data(#"{"status":200,"data":[],"pagination":null}"#.utf8),
                headers: ["Cache-Control": "public, max-age=60", "Content-Type": "application/json"]
            )
        }
        defer { CachingStubProtocol.handler = nil }

        let client = APIClient(
            baseURL: baseURL,
            session: CachingStubProtocol.makeSession(),
            tokenProvider: UnauthenticatedTokenProvider()
        )

        struct Empty: Decodable {}
        let query = [URLQueryItem(name: "q", value: "solo leveling")]
        _ = try await client.get(path, query: query, as: [Empty].self)
        _ = try await client.get(path, query: query, as: [Empty].self)

        // The measurement itself, pinned rather than assumed: both requests
        // reached the stub. If this ever reads 1, `URLCache` has started
        // short-circuiting custom protocols and the comment above — and what
        // this test is entitled to claim — needs rewriting.
        #expect(CachingStubProtocol.loadCount == 2)

        let searchTimestampCount = await client.searchTimestampCountForTesting
        #expect(searchTimestampCount == 1)

        let after = await NetworkLedger.shared.byPath[ledgerKey]?.requests ?? 0
        #expect(after - before == 1)
    }

    /// The control for the test above: the refund must be conditional, or
    /// "one slot for two searches" would also be true of a client that
    /// refunded every request and the assertion above would prove nothing.
    ///
    /// Two *different* queries are each a first load of their own URL, which
    /// the loader classifies as `.networkLoad`/unknown rather than
    /// `.localCache` (same measurement as above), so both keep their slot and
    /// both get a ledger row.
    @Test("Two different searches keep both slots and both ledger rows")
    func refundIsNotUnconditional() async throws {
        let path = "/v2/series/search"
        let ledgerKey = NetworkLedger.shape(path)
        let before = await NetworkLedger.shared.byPath[ledgerKey]?.requests ?? 0

        CachingStubProtocol.handler = { _ in
            CachingStubProtocol.StubResponse(
                statusCode: 200,
                body: Data(#"{"status":200,"data":[],"pagination":null}"#.utf8),
                headers: ["Cache-Control": "public, max-age=60", "Content-Type": "application/json"]
            )
        }
        defer { CachingStubProtocol.handler = nil }

        let client = APIClient(
            baseURL: baseURL,
            session: CachingStubProtocol.makeSession(),
            tokenProvider: UnauthenticatedTokenProvider()
        )

        struct Empty: Decodable {}
        let first = [URLQueryItem(name: "q", value: "solo leveling")]
        let second = [URLQueryItem(name: "q", value: "berserk")]
        _ = try await client.get(path, query: first, as: [Empty].self)
        _ = try await client.get(path, query: second, as: [Empty].self)

        let searchTimestampCount = await client.searchTimestampCountForTesting
        #expect(searchTimestampCount == 2)

        let after = await NetworkLedger.shared.byPath[ledgerKey]?.requests ?? 0
        #expect(after - before == 2)
    }
}

/// Wire review #7/#73, 2026-09-14: `.reloadIgnoringLocalAndRemoteCacheData`
/// only ever governed whether the cache is *consulted*, not whether the
/// response is *stored* — so the promise that a response carrying the
/// reader's own data never sits in the shared on-disk `URLCache` rested
/// entirely on MangaBaka's own `no-store` header, which the comment beside
/// `makeRequest` already calls "their guarantee to change, not ours to
/// depend on". `ClientRequestDelegate.willCacheResponse` now refuses to
/// cache such a response regardless of what headers it carries.
@Suite("APIClient never caches an identity-carrying response", .serialized)
struct APIClientIdentityCacheTests {
    private let baseURL = URL(string: "https://api.example.invalid").unsafeTestURL

    /// Expected to fail before the fix by finding a non-nil cached response —
    /// and it did, against the `willCacheResponse` version of the fix, which
    /// is how that version was found to be inert. MEASURED 2026-09-14:
    /// `urlSession(_:dataTask:willCacheResponse:completionHandler:)` is never
    /// delivered under `session.data(for:delegate:)`, to a task delegate or a
    /// session delegate, so the response was stored whatever the delegate
    /// would have said. `.reloadIgnoringLocalAndRemoteCacheData` does not
    /// help either: it only stops the cache being read for this load, not
    /// written for the next one. `perform` now evicts the entry after the
    /// load instead.
    @Test("A /v1/my response that says it's cacheable is still never stored")
    func identityCarryingResponseIsNeverCached() async throws {
        let path = "/v1/my/profile"
        CachingStubProtocol.handler = { _ in
            CachingStubProtocol.StubResponse(
                statusCode: 200,
                body: Data(#"{"status":200,"data":{"id":"reader-1"}}"#.utf8),
                headers: ["Cache-Control": "public, max-age=60", "Content-Type": "application/json"]
            )
        }
        defer { CachingStubProtocol.handler = nil }

        let session = CachingStubProtocol.makeSession()
        let client = APIClient(
            baseURL: baseURL,
            session: session,
            tokenProvider: UnauthenticatedTokenProvider()
        )

        struct ReaderID: Decodable { let id: String }
        _ = try await client.get(path, as: ReaderID.self)

        guard let cache = session.configuration.urlCache else {
            Issue.record("Expected the stub session to carry a URLCache")
            return
        }
        let request = URLRequest(url: baseURL.appendingPathComponent(path))
        #expect(cache.cachedResponse(for: request) == nil)
    }

    /// The control: an ordinary public response is still stored, so the
    /// assertion above is about identity-carrying requests and not about a
    /// client that has simply stopped caching anything.
    @Test("A public response is still stored")
    func publicResponseIsStillCached() async throws {
        let path = "/v2/series/1"
        CachingStubProtocol.handler = { _ in
            CachingStubProtocol.StubResponse(
                statusCode: 200,
                body: Data(#"{"status":200,"data":{"id":"series-1"}}"#.utf8),
                headers: ["Cache-Control": "public, max-age=60", "Content-Type": "application/json"]
            )
        }
        defer { CachingStubProtocol.handler = nil }

        let session = CachingStubProtocol.makeSession()
        let client = APIClient(
            baseURL: baseURL,
            session: session,
            tokenProvider: UnauthenticatedTokenProvider()
        )

        struct SeriesID: Decodable { let id: String }
        _ = try await client.get(path, as: SeriesID.self)

        let cache = try #require(session.configuration.urlCache)
        let request = URLRequest(url: baseURL.appendingPathComponent(path))
        #expect(cache.cachedResponse(for: request) != nil)
    }
}
