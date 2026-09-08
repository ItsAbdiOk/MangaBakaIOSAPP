import Foundation
import Testing
@testable import MangaBaka

/// Every failure path the client can produce. These exist because the happy
/// path is the one case that never surprises anyone in production.
@Suite("APIClient failure paths", .serialized)
struct APIClientFailurePathTests {
    private let baseURL = URL(string: "https://api.example.invalid").unsafeTestURL

    private func makeClient(
        tokenProvider: TokenProvider = UnauthenticatedTokenProvider()
    ) -> APIClient {
        APIClient(
            baseURL: baseURL,
            session: URLProtocolStub.makeSession(),
            tokenProvider: tokenProvider
        )
    }

    /// Control: with a well-formed response the client succeeds. If this fails,
    /// every failure assertion below is meaningless.
    @Test("Control — a well-formed response decodes")
    func controlSucceeds() async throws {
        URLProtocolStub.setHandler { _ in
            .respond(.init(body: Data(#"{"status":200,"data":[1,2,3]}"#.utf8)))
        }
        defer { URLProtocolStub.reset() }

        let values: [Int] = try await makeClient().get("/things")
        #expect(values == [1, 2, 3])
    }

    @Test("429 becomes rateLimited and carries Retry-After")
    func rateLimited() async {
        URLProtocolStub.setHandler { _ in
            .respond(.init(
                statusCode: 429,
                body: Data(#"{"status":429,"message":"Slow down"}"#.utf8),
                headers: ["Retry-After": "30"]
            ))
        }
        defer { URLProtocolStub.reset() }

        await #expect(throws: APIError.rateLimited(retryAfter: 30)) {
            let _: [Int] = try await makeClient().get("/things")
        }
    }

    @Test("429 without Retry-After still reports rateLimited")
    func rateLimitedWithoutHeader() async {
        URLProtocolStub.setHandler { _ in .respond(.init(statusCode: 429)) }
        defer { URLProtocolStub.reset() }

        await #expect(throws: APIError.rateLimited(retryAfter: nil)) {
            let _: [Int] = try await makeClient().get("/things")
        }
    }

    /// A rate limit is shared per IP, so it can be triggered by someone else on
    /// the same network. The message must never blame the reader.
    @Test("Rate-limit message does not blame the user")
    func rateLimitMessageIsBlameless() {
        let message = APIError.rateLimited(retryAfter: 30).userFacingMessage
        #expect(!message.lowercased().contains("you "))
        #expect(!message.lowercased().contains("your request"))
        #expect(message.contains("MangaBaka"))
    }

    @Test("No connection becomes offline, not a generic transport failure")
    func offline() async {
        URLProtocolStub.setHandler { _ in .fail(URLError(.notConnectedToInternet)) }
        defer { URLProtocolStub.reset() }

        await #expect(throws: APIError.offline) {
            let _: [Int] = try await makeClient().get("/things")
        }
    }

    @Test("Connection lost mid-flight is also treated as offline")
    func connectionLost() async {
        URLProtocolStub.setHandler { _ in .fail(URLError(.networkConnectionLost)) }
        defer { URLProtocolStub.reset() }

        await #expect(throws: APIError.offline) {
            let _: [Int] = try await makeClient().get("/things")
        }
    }

    /// The spec documents `message` as safe to show end users verbatim, so it
    /// must survive to the UI rather than being replaced by a generic string.
    @Test("Server error surfaces the API's own message verbatim")
    func serverErrorKeepsMessage() async throws {
        URLProtocolStub.setHandler { _ in
            .respond(.init(
                statusCode: 404,
                body: Data(#"{"status":404,"message":"That series doesn't exist."}"#.utf8)
            ))
        }
        defer { URLProtocolStub.reset() }

        do {
            let _: [Int] = try await makeClient().get("/things")
            Issue.record("Expected the request to throw")
        } catch {
            #expect(error == .server(status: 404, message: "That series doesn't exist."))
            #expect(error.userFacingMessage == "That series doesn't exist.")
        }
    }

    @Test("Server error with an unreadable body still produces a usable message")
    func serverErrorWithGarbageBody() async {
        URLProtocolStub.setHandler { _ in
            .respond(.init(statusCode: 500, body: Data("<html>nope</html>".utf8)))
        }
        defer { URLProtocolStub.reset() }

        do {
            let _: [Int] = try await makeClient().get("/things")
            Issue.record("Expected the request to throw")
        } catch {
            guard case let .server(status, message) = error else {
                Issue.record("Expected .server, got \(error)")
                return
            }
            #expect(status == 500)
            #expect(!message.isEmpty)
        }
    }

    @Test("Malformed JSON becomes a decoding error, not a crash")
    func malformedJSON() async {
        URLProtocolStub.setHandler { _ in
            .respond(.init(body: Data("{ this is not json".utf8)))
        }
        defer { URLProtocolStub.reset() }

        do {
            let _: [Int] = try await makeClient().get("/things")
            Issue.record("Expected the request to throw")
        } catch {
            guard case .decoding = error else {
                Issue.record("Expected .decoding, got \(error)")
                return
            }
        }
    }

    @Test("A 200 with no data key is a decoding error, not an empty success")
    func successWithoutData() async {
        URLProtocolStub.setHandler { _ in
            .respond(.init(body: Data(#"{"status":200}"#.utf8)))
        }
        defer { URLProtocolStub.reset() }

        do {
            let _: [Int] = try await makeClient().get("/things")
            Issue.record("Expected the request to throw")
        } catch {
            guard case .decoding = error else {
                Issue.record("Expected .decoding, got \(error)")
                return
            }
        }
    }

    @Test("Empty body is a decoding error")
    func emptyBody() async {
        URLProtocolStub.setHandler { _ in .respond(.init(body: Data())) }
        defer { URLProtocolStub.reset() }

        do {
            let _: [Int] = try await makeClient().get("/things")
            Issue.record("Expected the request to throw")
        } catch {
            guard case .decoding = error else {
                Issue.record("Expected .decoding, got \(error)")
                return
            }
        }
    }

    @Test("Decoding and transport failures never leak internals to the user")
    func technicalErrorsAreNotShownRaw() {
        let decoding = APIError.decoding(underlying: "keyNotFound(CodingKeys(stringValue: \"id\"))")
        let transport = APIError.transport(underlying: "NSURLErrorDomain -1200")
        #expect(!decoding.userFacingMessage.contains("CodingKeys"))
        #expect(!transport.userFacingMessage.contains("NSURLError"))
    }
}

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
}

@Suite("PAT configuration")
struct PATTokenProviderTests {
    @Test("Missing, empty and placeholder tokens all degrade to unauthenticated")
    func rejectsNonTokens() {
        #expect(PATTokenProvider(infoDictionary: nil) == nil)
        #expect(PATTokenProvider(infoDictionary: [:]) == nil)
        #expect(PATTokenProvider(infoDictionary: ["MB_PAT": ""]) == nil)
        #expect(PATTokenProvider(infoDictionary: ["MB_PAT": "   "]) == nil)
        // The example xcconfig ships this literal; it must never be sent.
        #expect(PATTokenProvider(
            infoDictionary: ["MB_PAT": "mb-your-personal-access-token-here"]
        ) == nil)
    }

    @Test("A token without the documented mb- prefix is rejected")
    func rejectsWrongPrefix() {
        #expect(PATTokenProvider(infoDictionary: ["MB_PAT": "sk-not-a-mangabaka-token"]) == nil)
    }

    @Test("A valid token is accepted and whitespace-trimmed")
    func acceptsValidToken() throws {
        let provider = try #require(
            PATTokenProvider(infoDictionary: ["MB_PAT": "  mb-realtoken123  "])
        )
        #expect(provider.token == "mb-realtoken123")
    }
}

extension Optional where Wrapped == URL {
    /// Test-only. The literals in this file are compile-time constants; this
    /// keeps `force_unwrapping` satisfied without weakening the rule.
    var unsafeTestURL: URL {
        guard let self else { preconditionFailure("Test URL literal failed to parse.") }
        return self
    }
}
