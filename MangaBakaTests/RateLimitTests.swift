import Foundation
import Testing
@testable import MangaBaka

/// The rate limit is shared per IP with strangers on the same network, so
/// backoff behaviour is other people's problem as much as ours.
@Suite("Rate limit backoff")
struct RateLimitGateTests {
    /// A clock the test moves by hand, so a 60-second backoff takes no time
    /// to verify and never flakes.
    private final class MovableClock: @unchecked Sendable {
        private let lock = NSLock()
        private var current = Date(timeIntervalSince1970: 1_700_000_000)

        var now: Date {
            lock.lock(); defer { lock.unlock() }
            return current
        }

        func advance(_ seconds: TimeInterval) {
            lock.lock(); defer { lock.unlock() }
            current = current.addingTimeInterval(seconds)
        }
    }

    private func makeGate() -> (RateLimitGate, MovableClock) {
        let clock = MovableClock()
        return (RateLimitGate(now: { clock.now }), clock)
    }

    @Test("Nothing is blocked before any rate limit is seen")
    func startsOpen() async {
        let (gate, _) = makeGate()
        #expect(await gate.secondsUntilAllowed() == nil)
    }

    @Test("The server's Retry-After is honoured exactly")
    func honoursRetryAfter() async {
        let (gate, clock) = makeGate()
        await gate.recordRateLimit(retryAfter: 30)

        let wait = await gate.secondsUntilAllowed()
        #expect(wait == 30, "The server knows its own window better than we do")

        clock.advance(29)
        #expect(await gate.secondsUntilAllowed() != nil, "Still inside the window")

        clock.advance(2)
        #expect(await gate.secondsUntilAllowed() == nil, "Window passed")
    }

    /// Without a Retry-After header there is nothing to honour, so back off
    /// exponentially rather than retrying immediately into the same refusal.
    @Test("Backoff grows when the server gives no Retry-After")
    func exponentialFallback() async {
        let (gate, _) = makeGate()

        await gate.recordRateLimit(retryAfter: nil)
        let first = await gate.secondsUntilAllowed() ?? 0
        await gate.recordRateLimit(retryAfter: nil)
        let second = await gate.secondsUntilAllowed() ?? 0

        #expect(second > first, "Repeated refusals must wait longer each time")
    }

    /// A runaway backoff would lock the app out for minutes over a transient
    /// spike, which is worse than the problem it solves.
    @Test("Backoff is capped")
    func backoffIsCapped() async {
        let (gate, _) = makeGate()
        for _ in 0..<12 { await gate.recordRateLimit(retryAfter: nil) }
        let wait = await gate.secondsUntilAllowed() ?? 0
        #expect(wait <= 60, "A transient spike must not lock the app out for minutes")
    }

    @Test("A success reopens the gate immediately")
    func successClearsBackoff() async {
        let (gate, _) = makeGate()
        await gate.recordRateLimit(retryAfter: 60)
        #expect(await gate.secondsUntilAllowed() != nil)

        await gate.recordSuccess()
        #expect(await gate.secondsUntilAllowed() == nil, "The window has evidently reopened")
    }
}

@Suite("Rate limiting through the client", .serialized)
struct RateLimitClientTests {
    private let baseURL = URL(string: "https://api.example.invalid").unsafeTestURL

    private func makeClient() -> APIClient {
        APIClient(
            baseURL: baseURL,
            session: URLProtocolStub.makeSession(),
            tokenProvider: UnauthenticatedTokenProvider()
        )
    }

    /// The point of the gate: after a 429, the next call must not reach the
    /// network at all. Spending a request to be refused again helps nobody,
    /// least of all the strangers sharing the limit.
    @Test("After a 429, the next request is refused locally without a network call")
    func refusesLocallyAfterRateLimit() async {
        URLProtocolStub.setHandler { _ in
            .respond(.init(
                statusCode: 429,
                body: Data(#"{"status":429,"message":"Slow down"}"#.utf8),
                headers: ["Retry-After": "60"]
            ))
        }
        defer { URLProtocolStub.reset() }

        let client = makeClient()
        await #expect(throws: APIError.self) {
            let _: [Int] = try await client.get("/things")
        }
        let afterFirst = URLProtocolStub.requests.count

        await #expect(throws: APIError.self) {
            let _: [Int] = try await client.get("/things")
        }
        #expect(
            URLProtocolStub.requests.count == afterFirst,
            "The second call must be refused locally, not sent"
        )
    }

    @Test("A successful request clears the block")
    func successReopensTheClient() async throws {
        URLProtocolStub.setHandler { _ in
            .respond(.init(body: Data(#"{"status":200,"data":[1]}"#.utf8)))
        }
        defer { URLProtocolStub.reset() }

        let client = makeClient()
        let values: [Int] = try await client.get("/things")
        #expect(values == [1])

        // A second call still goes out, because nothing has been refused.
        let again: [Int] = try await client.get("/things")
        #expect(again == [1])
        #expect(URLProtocolStub.requests.count == 2)
    }
}

/// A tiny thread-safe queue, because the stub's handler is `@Sendable` and
/// cannot capture a mutable local.
private final class ResponseQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [URLProtocolStub.Response]

    init(_ responses: [URLProtocolStub.Response]) {
        self.responses = responses
    }

    func next() -> URLProtocolStub.Response {
        lock.lock(); defer { lock.unlock() }
        guard !responses.isEmpty else {
            return .init(body: Data(#"{"status":200,"data":[]}"#.utf8))
        }
        return responses.removeFirst()
    }
}

@Suite("Rate limit is not cleared by other failures", .serialized)
struct RateLimitClearingTests {
    private let baseURL = URL(string: "https://api.example.invalid").unsafeTestURL

    private func makeClient() -> APIClient {
        APIClient(
            baseURL: baseURL,
            session: URLProtocolStub.makeSession(),
            tokenProvider: UnauthenticatedTokenProvider()
        )
    }

    /// A 500 says the server is unwell, not that the rate-limit window has
    /// reopened. Treating it as permission to resume puts the app straight back
    /// into the limit it was told to back off from.
    @Test("A server error does not clear an active rate-limit backoff")
    func serverErrorDoesNotClearBackoff() async {
        // A queue the handler can drain from across concurrency domains.
        let queue = ResponseQueue([
            .init(statusCode: 429, body: Data(#"{"status":429}"#.utf8),
                  headers: ["Retry-After": "60"]),
            .init(statusCode: 500, body: Data(#"{"status":500}"#.utf8))
        ])
        URLProtocolStub.setHandler { _ in .respond(queue.next()) }
        defer { URLProtocolStub.reset() }

        let client = makeClient()
        // First call earns the backoff.
        await #expect(throws: APIError.self) {
            let _: [Int] = try await client.get("/a")
        }
        let afterRateLimit = URLProtocolStub.requests.count

        // The gate should refuse locally, so the queued 500 is never reached.
        await #expect(throws: APIError.self) {
            let _: [Int] = try await client.get("/b")
        }
        #expect(
            URLProtocolStub.requests.count == afterRateLimit,
            "The backoff must still hold"
        )
    }
}

/// Writes go through the same per-IP limit as reads. The gate used to cover
/// only `get`, so a reader whose feed had just been refused could still fire a
/// burst of library saves straight into the same window — and a 429 earned by a
/// save was never remembered, so the next feed load went out anyway.
@Suite("Rate limit covers writes as well as reads", .serialized)
struct RateLimitWriteTests {
    private let baseURL = URL(string: "https://api.example.invalid").unsafeTestURL

    private func makeClient() -> APIClient {
        APIClient(
            baseURL: baseURL,
            session: URLProtocolStub.makeSession(),
            tokenProvider: UnauthenticatedTokenProvider()
        )
    }

    private func rateLimited() -> URLProtocolStub.Response {
        .init(
            statusCode: 429,
            body: Data(#"{"status":429,"message":"Slow down"}"#.utf8),
            headers: ["Retry-After": "60"]
        )
    }

    @Test("A write after a 429 is refused locally without a network call")
    func writeIsRefusedDuringBackoff() async {
        URLProtocolStub.setHandler { _ in .respond(rateLimited()) }
        defer { URLProtocolStub.reset() }

        let client = makeClient()
        await #expect(throws: APIError.self) {
            let _: [Int] = try await client.get("/things")
        }
        let afterRead = URLProtocolStub.requests.count

        await #expect(throws: APIError.self) {
            try await client.post("/things", body: ["id": 1])
        }
        await #expect(throws: APIError.self) {
            try await client.patch("/things/1", body: ["state": "reading"])
        }
        await #expect(throws: APIError.self) {
            try await client.delete("/things/1")
        }
        #expect(
            URLProtocolStub.requests.count == afterRead,
            "No write may reach the network while the window is closed"
        )
    }

    @Test("A 429 on a write blocks the next read")
    func writeRateLimitIsRemembered() async {
        URLProtocolStub.setHandler { _ in .respond(rateLimited()) }
        defer { URLProtocolStub.reset() }

        let client = makeClient()
        await #expect(throws: APIError.self) {
            try await client.post("/things", body: ["id": 1])
        }
        let afterWrite = URLProtocolStub.requests.count

        await #expect(throws: APIError.self) {
            let _: [Int] = try await client.get("/things")
        }
        #expect(
            URLProtocolStub.requests.count == afterWrite,
            "The refusal earned by the write must be remembered for the read"
        )
    }
}
