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
