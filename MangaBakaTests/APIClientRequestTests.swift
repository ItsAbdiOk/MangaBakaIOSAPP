import Foundation
import Testing
@testable import MangaBaka

@Suite("APIClient request construction", .serialized)
struct APIClientRequestTests {
    private let baseURL = URL(string: "https://api.example.invalid").unsafeTestURL

    @Test("A PAT is sent as the x-api-key header")
    func attachesPATHeader() async throws {
        URLProtocolStub.setHandler { _ in
            .respond(.init(body: Data(#"{"status":200,"data":[]}"#.utf8)))
        }
        defer { URLProtocolStub.reset() }

        let provider = try #require(
            PATTokenProvider(infoDictionary: ["MB_PAT": "mb-testtoken1234"])
        )
        let client = APIClient(
            baseURL: baseURL,
            session: URLProtocolStub.makeSession(),
            tokenProvider: provider
        )
        let _: [Int] = try await client.get("/things")

        let sent = try #require(URLProtocolStub.requests.first)
        #expect(sent.value(forHTTPHeaderField: "x-api-key") == "mb-testtoken1234")
    }

    @Test("Unauthenticated requests carry no credential header")
    func noHeaderWhenUnauthenticated() async throws {
        URLProtocolStub.setHandler { _ in
            .respond(.init(body: Data(#"{"status":200,"data":[]}"#.utf8)))
        }
        defer { URLProtocolStub.reset() }

        let client = APIClient(
            baseURL: baseURL,
            session: URLProtocolStub.makeSession(),
            tokenProvider: UnauthenticatedTokenProvider()
        )
        let _: [Int] = try await client.get("/things")

        let sent = try #require(URLProtocolStub.requests.first)
        #expect(sent.value(forHTTPHeaderField: "x-api-key") == nil)
        #expect(sent.value(forHTTPHeaderField: "Authorization") == nil)
    }

    /// MangaBaka answers 403 to unrecognised agents, so an absent or default
    /// User-Agent is a production outage waiting to happen, not a nicety.
    @Test("Every request identifies the client by User-Agent")
    func sendsUserAgent() async throws {
        URLProtocolStub.setHandler { _ in
            .respond(.init(body: Data(#"{"status":200,"data":[]}"#.utf8)))
        }
        defer { URLProtocolStub.reset() }

        let client = APIClient(
            baseURL: baseURL,
            session: URLProtocolStub.makeSession(),
            tokenProvider: UnauthenticatedTokenProvider()
        )
        let _: [Int] = try await client.get("/things")

        let sent = try #require(URLProtocolStub.requests.first)
        let agent = try #require(sent.value(forHTTPHeaderField: "User-Agent"))
        #expect(agent.contains("MangaBakaIOS"))
        #expect(agent.contains("github.com"), "Give MangaBaka a way to contact us")
    }

    @Test("Query parameters are encoded onto the URL")
    func encodesQuery() async throws {
        URLProtocolStub.setHandler { _ in
            .respond(.init(body: Data(#"{"status":200,"data":[]}"#.utf8)))
        }
        defer { URLProtocolStub.reset() }

        let client = APIClient(
            baseURL: baseURL,
            session: URLProtocolStub.makeSession(),
            tokenProvider: UnauthenticatedTokenProvider()
        )
        let _: [Int] = try await client.get("/things", query: [
                URLQueryItem(name: "limit", value: "20"),
                URLQueryItem(name: "q", value: "solo leveling")
        ])

        let url = try #require(URLProtocolStub.requests.first?.url?.absoluteString)
        #expect(url.contains("limit=20"))
        #expect(url.contains("q=solo%20leveling") || url.contains("q=solo+leveling"))
    }

    /// "+Anima" (a real series title) used to go out as `q=+Anima`, which
    /// every server decodes as `q= Anima`. Fails before the fix with the URL
    /// containing `q=+Anima` and not `%2B`.
    @Test("A plus sign in a query value is sent as %2B, never as a literal plus")
    func plusIsPercentEncoded() async throws {
        URLProtocolStub.setHandler { _ in
            .respond(.init(body: Data(#"{"status":200,"data":[]}"#.utf8)))
        }
        defer { URLProtocolStub.reset() }

        let client = APIClient(
            baseURL: baseURL,
            session: URLProtocolStub.makeSession(),
            tokenProvider: UnauthenticatedTokenProvider()
        )
        let _: [Int] = try await client.get("/things", query: [URLQueryItem(name: "q", value: "+Anima")])

        let url = try #require(URLProtocolStub.requests.first?.url?.absoluteString)
        #expect(url.contains("q=%2BAnima"), Comment(rawValue: url))
        #expect(!url.contains("q=+Anima"))
    }
}
