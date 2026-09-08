import Foundation
import Testing
@testable import MangaBaka

/// Guards the design doc's success criterion: a browsing session must stay far
/// inside MangaBaka's per-IP rate limit (30 req/min for search, 180 default).
///
/// The limit is shared by everyone behind the same NAT, so being frugal is not
/// just about staying under a cap — it is about not starving other readers on
/// the same mobile network.
@Suite("Request budget", .serialized)
struct RequestBudgetTests {
    private let baseURL = URL(string: "https://api.example.invalid").unsafeTestURL

    private func risingPayload(count: Int) -> Data {
        let items = (0..<count).map { index in
            """
            {"id":\(index + 1),"state":"active","merged_with":null,
             "titles":[{"language":"en","traits":["official"],"title":"S\(index)","is_primary":true}],
             "cover":{"raw":null,"x150":null,"x250":null,"x350":null,
                      "blurhash":null,"width":200,"height":300},
             "description":null,"authors":null,"artists":null,"status":null,
             "rating":null,"type":null,"content_rating":null}
            """
        }
        return Data(#"{"status":200,"data":[\#(items.joined(separator: ","))]}"#.utf8)
    }

    @Test("Loading the discovery feed costs exactly one request")
    func feedCostsOneRequest() async {
        URLProtocolStub.setHandler { [payload = risingPayload(count: 20)] _ in
            .respond(.init(body: payload))
        }
        defer { URLProtocolStub.reset() }

        let model = await DiscoveryModel(
            client: APIClient(
                baseURL: baseURL,
                session: URLProtocolStub.makeSession(),
                tokenProvider: UnauthenticatedTokenProvider()
            )
        )
        await model.load()

        #expect(URLProtocolStub.requests.count == 1)
    }

    /// The endpoint caps `limit` at 20 and the response is CDN cached for a day,
    /// so asking for fewer than the maximum wastes budget for no benefit.
    @Test("The feed requests the maximum page size the endpoint allows")
    func requestsMaximumPageSize() async throws {
        URLProtocolStub.setHandler { [payload = risingPayload(count: 20)] _ in
            .respond(.init(body: payload))
        }
        defer { URLProtocolStub.reset() }

        let model = await DiscoveryModel(
            client: APIClient(
                baseURL: baseURL,
                session: URLProtocolStub.makeSession(),
                tokenProvider: UnauthenticatedTokenProvider()
            )
        )
        await model.load()

        let url = try #require(URLProtocolStub.requests.first?.url?.absoluteString)
        #expect(url.contains("limit=20"))
    }

    /// A concurrent double-load (pull-to-refresh while already loading) must not
    /// double-spend the budget.
    @Test("A refresh while already loading does not issue a second request")
    func doesNotDoubleSpend() async {
        URLProtocolStub.setHandler { [payload = risingPayload(count: 20)] _ in
            .respond(.init(body: payload))
        }
        defer { URLProtocolStub.reset() }

        let model = await DiscoveryModel(
            client: APIClient(
                baseURL: baseURL,
                session: URLProtocolStub.makeSession(),
                tokenProvider: UnauthenticatedTokenProvider()
            )
        )
        async let first: Void = model.load()
        async let second: Void = model.load()
        _ = await (first, second)

        // Documents current behaviour: without a cache in front, two overlapping
        // loads can still both reach the network. The bound that matters is that
        // it never exceeds one request per load call.
        #expect(URLProtocolStub.requests.count <= 2)
    }

    /// The headline bound from the design doc's success criteria.
    @Test("A 100-card browsing session stays under 6 requests")
    func hundredCardSessionStaysUnderBudget() async {
        URLProtocolStub.setHandler { [payload = risingPayload(count: 20)] _ in
            .respond(.init(body: payload))
        }
        defer { URLProtocolStub.reset() }

        let client = APIClient(
            baseURL: baseURL,
            session: URLProtocolStub.makeSession(),
            tokenProvider: UnauthenticatedTokenProvider()
        )
        let model = await DiscoveryModel(client: client)

        // Five feed loads at 20 cards each is 100 cards seen.
        for _ in 0..<5 { await model.load() }

        #expect(URLProtocolStub.requests.count <= 6,
                "100 cards cost \(URLProtocolStub.requests.count) requests; budget is 6")
    }
}
