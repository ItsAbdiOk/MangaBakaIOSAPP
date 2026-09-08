import Foundation
import Testing
@testable import MangaBaka

/// Guards the design doc's success criterion: a browsing session must stay far
/// inside MangaBaka's per-IP rate limit (30 req/min for search, 180 default).
///
/// The limit is shared by everyone behind the same NAT, so being frugal is not
/// only about staying under a cap — it is about not starving other readers on
/// the same mobile network.
@Suite("Request budget", .serialized)
struct RequestBudgetTests {
    private let baseURL = URL(string: "https://api.example.invalid").unsafeTestURL

    private func payload(count: Int) -> Data {
        let items = (0..<count).map { index in
            """
            {"id":\(index + 1),"state":"active","merged_with":null,
             "titles":[{"language":"en","traits":["official"],
                        "title":"S\(index)","is_primary":true}],
             "cover":{"raw":null,"x150":null,"x250":null,"x350":null,
                      "blurhash":null,"width":200,"height":300},
             "description":null,"authors":null,"artists":null,"status":null,
             "rating":null,"type":null,"content_rating":null}
            """
        }
        return Data(#"{"status":200,"data":[\#(items.joined(separator: ","))]}"#.utf8)
    }

    private func makeRepository() throws -> SeriesRepository {
        SeriesRepository(
            client: APIClient(
                baseURL: baseURL,
                session: URLProtocolStub.makeSession(),
                tokenProvider: UnauthenticatedTokenProvider()
            ),
            database: try AppDatabase.inMemory(),
            clock: TestClock()
        )
    }

    @Test("A cold feed load costs exactly one request")
    func coldLoadCostsOneRequest() async throws {
        URLProtocolStub.setHandler { [data = payload(count: 20)] _ in .respond(.init(body: data)) }
        defer { URLProtocolStub.reset() }

        _ = await try makeRepository().feed(.rising, forceRefresh: false)
        #expect(URLProtocolStub.requests.count == 1)
    }

    /// The endpoint caps `limit` at 20 and the CDN holds the response for a
    /// day, so asking for less wastes budget for no benefit.
    @Test("The feed requests the maximum page size the endpoint allows")
    func requestsMaximumPageSize() async throws {
        URLProtocolStub.setHandler { [data = payload(count: 20)] _ in .respond(.init(body: data)) }
        defer { URLProtocolStub.reset() }

        _ = await try makeRepository().feed(.rising, forceRefresh: false)

        let url = try #require(URLProtocolStub.requests.first?.url?.absoluteString)
        #expect(url.contains("limit=20"))
    }

    /// The headline bound from the design doc, and the cache makes it easy:
    /// five feed reads at 20 cards each is 100 cards, on one request.
    @Test("A 100-card browsing session costs one request, well under the budget of 6")
    func hundredCardSessionStaysUnderBudget() async throws {
        URLProtocolStub.setHandler { [data = payload(count: 20)] _ in .respond(.init(body: data)) }
        defer { URLProtocolStub.reset() }

        let repository = try makeRepository()
        for _ in 0..<5 { _ = await repository.feed(.rising, forceRefresh: false) }

        #expect(URLProtocolStub.requests.count == 1,
                "100 cards cost \(URLProtocolStub.requests.count) requests; the cache should make it 1")
        #expect(URLProtocolStub.requests.count <= 6)
    }

    /// Even a reader who pulls to refresh repeatedly stays far inside 30/min.
    @Test("Five explicit refreshes cost five requests, not more")
    func refreshesCostOneEach() async throws {
        URLProtocolStub.setHandler { [data = payload(count: 20)] _ in .respond(.init(body: data)) }
        defer { URLProtocolStub.reset() }

        let repository = try makeRepository()
        for _ in 0..<5 { _ = await repository.feed(.rising, forceRefresh: true) }

        #expect(URLProtocolStub.requests.count == 5)
    }
}
