import Foundation
import Testing
@testable import MangaBaka

/// The gate waits instead of throwing (review perf W1/W2, 2026-09-15), and
/// a cancelled request keeps its slot (W3). These sleep on the wall clock —
/// the injected clock cannot be slept on — so the window is a few hundred
/// milliseconds, not the app's minute.
@Suite("Rate-limit gate waits", .serialized)
struct RateLimitWaitTests {
    /// Fails on the old code with `APIError.rateLimited` thrown: the 181st
    /// foreground request used to be refused the instant the window was full
    /// with a deadline 0.3 s away.
    @Test("A foreground request whose window reopens in under the ceiling waits, then proceeds")
    func foregroundWaitsOutAShortDeadline() async throws {
        let gate = RateLimitGate(window: 0.3)
        for _ in 0..<RateLimitGate.Family.general.limit {
            _ = try await gate.reserveSlot(for: "/v1/series/1", priority: .userInitiated)
        }
        let started = Date()
        _ = try await gate.reserveSlot(for: "/v1/series/1", priority: .userInitiated)
        let waited = Date().timeIntervalSince(started)
        #expect(waited >= 0.25, "it had to wait for the oldest slot to expire: \(waited)")
        #expect(waited < 2, "and not much longer: \(waited)")
    }

    /// The control: a deadline past the ceiling is still thrown, so a long
    /// back-off is said out loud rather than becoming a hang.
    @Test("A foreground request facing a long back-off still throws its deadline")
    func foregroundThrowsALongDeadline() async {
        let gate = RateLimitGate(window: 0.3)
        let long = RateLimitGate.foregroundWaitCeiling + 30
        _ = await gate.recordRateLimit(retryAfter: long, path: "/v1/series/1")
        var thrown: APIError?
        do throws(APIError) {
            _ = try await gate.reserveSlot(for: "/v1/series/1", priority: .userInitiated)
        } catch let error {
            thrown = error
        }
        guard case .rateLimited = thrown else {
            Issue.record("Expected .rateLimited, got \(String(describing: thrown))")
            return
        }
    }

    /// Fails on the old code with `.rateLimited` thrown from
    /// `waitForBackgroundSlot`: a family 429 used to stop every waiter.
    @Test("A background request waits through a short 429 back-off instead of throwing")
    func backgroundWaitsThroughABackOff() async throws {
        let gate = RateLimitGate(window: 0.3)
        _ = await gate.recordRateLimit(retryAfter: 0.3, path: "/v1/series/1")
        let started = Date()
        _ = try await gate.reserveSlot(for: "/v1/series/1", priority: .background)
        let waited = Date().timeIntervalSince(started)
        #expect(waited >= 0.25, "it waited for the back-off to pass: \(waited)")
    }

    /// Fails on the old code with `count == 0`: the cancel branch refunded
    /// the slot. The stub answers with `URLError.cancelled` directly — the
    /// same error a task cancelled mid-flight surfaces — since the stub has
    /// no way to hold a response open.
    @Test("A request cancelled in flight keeps the slot it spent")
    func cancelledRequestKeepsItsSlot() async {
        URLProtocolStub.setHandler { _ in .fail(URLError(.cancelled)) }
        defer { URLProtocolStub.reset() }
        let gate = RateLimitGate()
        let client = APIClient(
            baseURL: URL(string: "https://api.example.invalid").unsafeTestURL,
            session: URLProtocolStub.makeSession(),
            tokenProvider: UnauthenticatedTokenProvider(),
            limiter: gate
        )
        var thrown: APIError?
        do throws(APIError) {
            let _: [Int] = try await client.get("/v1/series/search", query: [.init(name: "q", value: "x")])
        } catch let error {
            thrown = error
        }
        #expect(thrown == .cancelled)
        #expect(await gate.searchTimestampCountForTesting == 1)
        // The control: offline still refunds — that attempt never left.
        URLProtocolStub.setHandler { _ in .fail(URLError(.notConnectedToInternet)) }
        do throws(APIError) {
            let _: [Int] = try await client.get("/v1/series/search", query: [.init(name: "q", value: "y")])
        } catch {}
        #expect(await gate.searchTimestampCountForTesting == 1)
    }
}
