import Foundation
import Testing
@testable import MangaBaka

/// A 429 that says nothing about how long to wait must still count down.
///
/// Every 429 the older tests know about invents `Retry-After: 60`; the API's
/// own schema (`V1_Error_429` in `docs/schemas/mangabaka_openapi.json`) is
/// `{status, message}` and promises no header at all. Before this suite, a
/// header-less 429 threw `.rateLimited(until: nil)`, which every screen
/// rendered as a static "Search is paused" with no countdown and no
/// automatic retry — while the gate underneath had already computed a
/// perfectly good deadline of its own and kept it to itself.
///
/// `.serialized` because `URLProtocolStub` records per test but the client's
/// gate is per client, and two of these running at once would each see the
/// other's backoff count in the exponential fallback.
@Suite("Rate limit without Retry-After", .serialized)
struct RateLimitFallbackTests {
    private let baseURL = URL(string: "https://api.example.invalid").unsafeTestURL

    private func makeClient() -> APIClient {
        APIClient(
            baseURL: baseURL,
            session: URLProtocolStub.makeSession(),
            tokenProvider: UnauthenticatedTokenProvider()
        )
    }

    /// The only 429 body on record. Not a capture: no real 429 has been
    /// recorded (the limit is per IP and shared with strangers, so the review
    /// declined to provoke one). Shape and default `message` taken verbatim
    /// from `V1_Error_429` in `docs/schemas/mangabaka_openapi.json`,
    /// 2026-09-13.
    private let schemaBody = Data(#"{"status":429,"message":"Too Many Requests"}"#.utf8)

    /// Expected to fail before the fix with: "A header-less 429 must still
    /// carry the gate's deadline" — `APIClient` built `until` from the
    /// header alone, so this threw `.rateLimited(until: nil, …)`.
    @Test("A 429 with no Retry-After carries the gate's own deadline")
    func headerlessRateLimitCarriesGateDeadline() async throws {
        URLProtocolStub.setHandler { _ in
            .respond(.init(statusCode: 429, body: self.schemaBody))
        }
        defer { URLProtocolStub.reset() }

        let client = makeClient()
        let before = Date()
        let error = await thrownRateLimit { let _: [Series] = try await client.get("/v2/series/search") }

        guard case let .rateLimited(until, party) = error, let until else {
            Issue.record(
                "A header-less 429 must still carry the gate's deadline; got \(String(describing: error))"
            )
            return
        }
        #expect(party == .mangaBakaSearch)
        // The gate's first fallback is 2^1 = 2 seconds (`recordRateLimit`);
        // a generous window either side so a slow test host cannot flake it.
        let wait = until.timeIntervalSince(before)
        #expect(wait > 0 && wait <= 2 + 5, "Expected roughly the gate's 2 s first backoff, got \(wait)")
    }

    /// The thrown deadline must be *the gate's* deadline, not a second one
    /// computed alongside it: the date the gate holds in `blockedUntil` and
    /// the date the error carries being equal is what proves there is one
    /// source. A copied value would drift by however long the throw took.
    ///
    /// Until 2026-09-15 this sent a second request and compared the two
    /// throws; a foreground request now *waits out* a 2 s back-off instead
    /// of throwing it (review perf W2), so the second call went to the
    /// server. The gate's own record is read directly instead.
    @Test("The thrown deadline is the same date the gate then refuses against")
    func thrownDeadlineMatchesLocalRefusal() async throws {
        URLProtocolStub.setHandler { _ in
            .respond(.init(statusCode: 429, body: self.schemaBody))
        }
        defer { URLProtocolStub.reset() }

        let gate = RateLimitGate()
        let client = APIClient(
            baseURL: baseURL,
            session: URLProtocolStub.makeSession(),
            tokenProvider: UnauthenticatedTokenProvider(),
            limiter: gate
        )
        let first = await thrownRateLimit { let _: [Series] = try await client.get("/v2/series/search") }

        guard case let .rateLimited(fromServer, _) = first else {
            Issue.record("Expected a rate limit, got \(String(describing: first))")
            return
        }
        #expect(fromServer != nil)
        #expect(await gate.blockedUntilForTesting(.search) == fromServer, "One deadline, owned by the gate")
    }

    /// Control: when the server does say, the server wins over the fallback,
    /// so the fix cannot have replaced the header path with the gate's guess.
    @Test("A 429 with Retry-After still honours the header")
    func headerStillWins() async throws {
        URLProtocolStub.setHandler { _ in
            .respond(.init(statusCode: 429, body: self.schemaBody, headers: ["Retry-After": "60"]))
        }
        defer { URLProtocolStub.reset() }

        let client = makeClient()
        let before = Date()
        let error = await thrownRateLimit { let _: [Series] = try await client.get("/v2/series/search") }

        guard case let .rateLimited(until, _) = error, let until else {
            Issue.record("Expected a deadline from the header; got \(String(describing: error))")
            return
        }
        let wait = until.timeIntervalSince(before)
        #expect(wait > 30 && wait <= 60 + 5, "Expected the header's 60 s, got \(wait)")
    }

    private func thrownRateLimit(_ body: () async throws -> Void) async -> APIError? {
        do {
            try await body()
            Issue.record("Expected a 429 to throw")
            return nil
        } catch let error as APIError {
            return error
        } catch {
            Issue.record("Expected an APIError, got \(error)")
            return nil
        }
    }
}

/// The stale bar over live results was the one rate-limit surface with no
/// countdown: `APIError.countdown` is a string frozen at render, and the bar
/// showed it as plain text. `StaleBar` now takes a deadline and mounts
/// `Countdown`; these drive the two static helpers the view is built on,
/// since without ViewInspector the mounted view itself cannot be inspected.
@Suite("Stale bar countdown")
struct StaleBarCountdownTests {
    /// Control. Expected to pass before and after: a limit with no deadline
    /// must not mount a countdown that would read "Retrying now…" forever.
    @Test("A rate limit with no deadline gives the bar nothing to count down")
    func noDeadlineNoCountdown() {
        #expect(APIError.rateLimited(until: nil, party: .mangaBakaSearch).rateLimitDeadline == nil)
        #expect(APIError.offline.rateLimitDeadline == nil)
    }

    /// Expected to fail before the fix by not compiling: `APIError` had no
    /// `rateLimitDeadline`; the only date-shaped reading was `FailureState`'s
    /// private copy, which the stale bar could not reach.
    @Test("A rate limit with a deadline hands that exact date to the bar")
    func deadlineReachesTheBar() {
        let until = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(APIError.rateLimited(until: until, party: .mangaBakaSearch).rateLimitDeadline == until)
    }

    /// Names whose results are under the bar, so "berserk" in the field over
    /// a grid of "one piece" is no longer a mystery.
    @Test("The bar names the query the results belong to")
    func stillShowingCopy() {
        #expect(StaleBar.stillShowing("one piece") == "Still showing 'one piece'")
        #expect(StaleBar.stillShowing("  ") == "Still showing the last results")
    }
}
