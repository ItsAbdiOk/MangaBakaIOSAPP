import Foundation
import Testing
@testable import MangaBaka

/// The rate limit is shared per IP with strangers on the same network, so
/// backoff behaviour is other people's problem as much as ours.
@Suite("Rate limit backoff")
struct RateLimitGateTests {
    /// A clock the test moves by hand, so a 60-second backoff takes no time
    /// to verify and never flakes. Conforms to the app's own `Clock` protocol
    /// (the one `SeriesRepository`'s cache-expiry tests already use) now that
    /// `RateLimitGate` takes a `Clock` rather than a bare closure — a second,
    /// parallel clock abstraction for the same purpose was the thing worth
    /// not adding.
    private final class MovableClock: Clock, @unchecked Sendable {
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
        return (RateLimitGate(clock: clock), clock)
    }

    /// `reserve`'s deadline is absolute; these helpers read it back as
    /// "seconds from the clock's current time" so the assertions below read
    /// the same as they did against the old seconds-returning method.
    ///
    /// `/v1/my/profile` is a general-family path, deliberately: these tests
    /// pin the 429-backoff half of the gate, which is now scoped per family
    /// (see `familyScoping` below) — a general path is what stays unaffected
    /// by a search-only refusal and vice versa.
    private func secondsUntilAllowed(_ gate: RateLimitGate, _ clock: MovableClock) async -> TimeInterval? {
        do {
            try await gate.reserveSlot(for: "/v1/my/profile", priority: .userInitiated)
            return nil
        } catch let error {
            guard case let .rateLimited(until, _) = error, let until else { return nil }
            return until.timeIntervalSince(clock.now)
        }
    }

    @Test("Nothing is blocked before any rate limit is seen")
    func startsOpen() async {
        let (gate, clock) = makeGate()
        #expect(await secondsUntilAllowed(gate, clock) == nil)
    }

    @Test("The server's Retry-After is honoured exactly")
    func honoursRetryAfter() async {
        let (gate, clock) = makeGate()
        await gate.recordRateLimit(retryAfter: 30, path: "/v1/my/profile")

        let wait = await secondsUntilAllowed(gate, clock)
        #expect(wait == 30, "The server knows its own window better than we do")

        clock.advance(29)
        #expect(await secondsUntilAllowed(gate, clock) != nil, "Still inside the window")

        clock.advance(2)
        #expect(await secondsUntilAllowed(gate, clock) == nil, "Window passed")
    }

    /// 2026-09-13: a 429 earned by search used to back off *every* path
    /// (deliberately, per gap 8's original fix) — but that meant a search
    /// refusal also closed the series page's own `/v1/series/{id}/*` legs,
    /// which are a different family entirely and have nothing to do with the
    /// 30/min search cap. The 429 memory is now per `RateLimitGate.Family`.
    ///
    /// Expected to fail before the fix: the old `recordRateLimit(retryAfter:)`
    /// took no path and set one global `blockedUntil`, so a search refusal
    /// blocked `/v1/my/profile` too — this test's second assertion is exactly
    /// the one the old behaviour violated.
    @Test("A 429 on search blocks search only; a 429 on a general path blocks that only")
    func familyScopedBackoff() async {
        let (searchGate, _) = makeGate()
        await searchGate.recordRateLimit(retryAfter: 60, path: "/v2/series/search")
        await #expect(throws: APIError.self) {
            try await searchGate.reserveSlot(for: "/v2/series/search", priority: .userInitiated)
        }
        // The general family is untouched by a search-only refusal.
        try? await searchGate.reserveSlot(for: "/v1/my/profile", priority: .userInitiated)

        let (generalGate, _) = makeGate()
        await generalGate.recordRateLimit(retryAfter: 60, path: "/v1/my/profile")
        await #expect(throws: APIError.self) {
            try await generalGate.reserveSlot(for: "/v1/my/profile", priority: .userInitiated)
        }
        // And a general-only refusal does not touch search.
        try? await generalGate.reserveSlot(for: "/v2/series/search", priority: .userInitiated)
    }

    /// A `.rateLimited` thrown for the search family carries `.mangaBakaSearch`
    /// so `FailureState`'s copy (via `APIError.headline`/`userFacingMessage`)
    /// can say "Search is paused" rather than the general MangaBaka wording —
    /// see `APIError.Party.mangaBakaSearch`'s doc comment.
    @Test("A search-family refusal is tagged with the search party, not the general one")
    func searchRefusalCarriesSearchParty() async {
        let (gate, _) = makeGate()
        await gate.recordRateLimit(retryAfter: 60, path: "/v2/series/search")
        do {
            try await gate.reserveSlot(for: "/v2/series/search", priority: .userInitiated)
            Issue.record("Expected a rate-limit refusal")
        } catch let error {
            #expect(error.party == .mangaBakaSearch)
        }
    }

    /// `FailureState` reads `error.headline`/`error.userFacingMessage`
    /// directly (it has no family-aware logic of its own), so the copy
    /// change the brief calls for lives entirely in `APIError` — no change to
    /// `Features/Shared/FailureState.swift` was needed. This pins the two
    /// strings apart so a reader on the series page whose background work
    /// spent the search budget sees "Search is paused", not "Too many
    /// requests, briefly" — the latter reads as the whole connection being
    /// throttled when only search was.
    @Test("Search-family and general-family rate limits read differently on screen")
    func searchFamilyCopyDiffersFromGeneral() {
        let searchError = APIError.rateLimited(until: nil, party: .mangaBakaSearch)
        let generalError = APIError.rateLimited(until: nil, party: .mangaBaka)

        #expect(searchError.headline != generalError.headline)
        #expect(searchError.userFacingMessage != generalError.userFacingMessage)
        #expect(searchError.headline.localizedCaseInsensitiveContains("search"))
        // The reassurance that prompted this in the first place: the reader
        // must be told the rest of the page still works.
        #expect(searchError.userFacingMessage.localizedCaseInsensitiveContains("else"))
    }

    /// Gap 8: search is capped at 30 a minute; this is the preventive half —
    /// refusing the 31st *before* it is sent, rather than spending it to earn
    /// the 429 the server would give anyway.
    @Test("The 31st search in a rolling minute is refused before it is sent")
    func searchSlidingWindowRefusesTheThirtyFirst() async {
        let (gate, clock) = makeGate()
        for _ in 0..<RateLimitGate.searchLimit {
            try? await gate.reserveSlot(for: "/v1/series/search", priority: .userInitiated)
        }
        do {
            try await gate.reserveSlot(for: "/v1/series/search", priority: .userInitiated)
            Issue.record("The 31st request in the window must be refused")
        } catch {
            // Expected.
        }

        // A different path is unaffected — the search window is scoped to
        // paths containing `/series/search`.
        try? await gate.reserveSlot(for: "/v1/discover/rising", priority: .userInitiated)

        // Once the oldest of the thirty ages past the window, a slot reopens.
        clock.advance(RateLimitGate.searchWindow + 1)
        do {
            try await gate.reserveSlot(for: "/v1/series/search", priority: .userInitiated)
        } catch {
            Issue.record("A slot should have reopened")
        }
    }

    /// GUESS (labelled in `RateLimitGate.maxHonouredRetryAfter`): nothing on
    /// record says what MangaBaka actually sends on a 429. Without some cap,
    /// a malformed or oversized `Retry-After` would lock the app out for
    /// however long it said — the doc comment promised a cap that only ever
    /// applied to the exponential fallback, not to the server's own value.
    @Test("An honoured Retry-After is capped, not trusted verbatim")
    func honouredRetryAfterIsCapped() async {
        let (gate, clock) = makeGate()
        await gate.recordRateLimit(retryAfter: 36000, path: "/v1/my/profile")
        let wait = await secondsUntilAllowed(gate, clock) ?? 0
        #expect(wait <= RateLimitGate.maxHonouredRetryAfter)
    }

    /// Without a Retry-After header there is nothing to honour, so back off
    /// exponentially rather than retrying immediately into the same refusal.
    @Test("Backoff grows when the server gives no Retry-After")
    func exponentialFallback() async {
        let (gate, clock) = makeGate()

        await gate.recordRateLimit(retryAfter: nil, path: "/v1/my/profile")
        let first = await secondsUntilAllowed(gate, clock) ?? 0
        await gate.recordRateLimit(retryAfter: nil, path: "/v1/my/profile")
        let second = await secondsUntilAllowed(gate, clock) ?? 0

        #expect(second > first, "Repeated refusals must wait longer each time")
    }

    /// A runaway backoff would lock the app out for minutes over a transient
    /// spike, which is worse than the problem it solves.
    @Test("Backoff is capped")
    func backoffIsCapped() async {
        let (gate, clock) = makeGate()
        for _ in 0..<12 { await gate.recordRateLimit(retryAfter: nil, path: "/v1/my/profile") }
        let wait = await secondsUntilAllowed(gate, clock) ?? 0
        #expect(wait <= 60, "A transient spike must not lock the app out for minutes")
    }

    @Test("A success reopens the gate immediately")
    func successClearsBackoff() async {
        let (gate, clock) = makeGate()
        await gate.recordRateLimit(retryAfter: 60, path: "/v1/my/profile")
        #expect(await secondsUntilAllowed(gate, clock) != nil)

        await gate.recordSuccess(path: "/v1/my/profile")
        #expect(await secondsUntilAllowed(gate, clock) == nil, "The window has evidently reopened")
    }
}

/// 2026-09-13: the series page showed "Too many requests, briefly" while
/// background work — lens counts, follow checks, a swipe-stack deal — was
/// still running, because that work was free to spend the same 30/min search
/// window a reader's own search needs. These tests pin
/// `RequestPriority.background`'s budget: capped below the full window, and
/// waiting for room rather than failing or competing with a foreground
/// search for the last few slots.
///
/// These use real (short) sleeps rather than the injected `Clock`, because
/// what is under test is genuinely concurrent scheduling — which of several
/// suspended tasks the actor lets through next — not a time-based expiry the
/// clock already covers elsewhere in this file.
@Suite("Background requests wait for a reserved slot")
struct RequestPriorityBudgetTests {
    private func makeGate() -> RateLimitGate { RateLimitGate() }

    /// Thread-safe enough for a test: set once, read from a different task.
    private final class CompletionFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var isDone = false
        var done: Bool { lock.lock(); defer { lock.unlock() }; return isDone }
        func markDone() { lock.lock(); isDone = true; lock.unlock() }
    }

    /// Expected to fail before the fix: the old `RateLimitGate` had no
    /// concept of priority at all, so a 21st search-family request — of any
    /// kind — was refused immediately with `.rateLimited` rather than
    /// waiting; there was no `reserve` to leave headroom in the first place.
    @Test("The 21st background request in a rolling minute waits rather than failing")
    func backgroundRequestPastReserveWaits() async throws {
        let gate = makeGate()
        for _ in 0..<(RateLimitGate.searchLimit - RateLimitGate.reserve) {
            try await gate.reserveSlot(for: "/v1/series/search", priority: .background)
        }

        let flag = CompletionFlag()
        let waiter = Task {
            try? await gate.reserveSlot(for: "/v1/series/search", priority: .background)
            flag.markDone()
        }
        defer { waiter.cancel() }

        try? await Task.sleep(for: .milliseconds(150))
        #expect(!flag.done, "The 21st background request must wait for room, not return immediately")
    }

    /// Build note: "25 background then a user search → the user search goes
    /// out next." A `.userInitiated` request is checked against the full
    /// window directly rather than joining `backgroundQueue`, so it must not
    /// be stuck behind background requests already waiting there.
    @Test("A user search is not queued behind waiting background requests")
    func userSearchIsNeverQueuedBehindBackground() async throws {
        let gate = makeGate()
        let waiters = (0..<25).map { _ in
            Task { try? await gate.reserveSlot(for: "/v1/series/search", priority: .background) }
        }
        defer { waiters.forEach { $0.cancel() } }

        // Let the first `searchLimit - reserve` land and the rest start
        // polling for room.
        try? await Task.sleep(for: .milliseconds(80))

        var threw = false
        do {
            try await gate.reserveSlot(for: "/v1/series/search", priority: .userInitiated)
        } catch {
            threw = true
        }
        #expect(!threw, "The reader's own search must go out even while background work waits for room")
    }

    /// Build note: "a cancelled background wait never sends." Proven at the
    /// gate level: a caller only reaches the network (`APIClient.perform`)
    /// once `reserveSlot` returns without throwing, so a cancelled wait
    /// throwing `.cancelled` *is* "never sends".
    @Test("A cancelled background wait throws .cancelled rather than proceeding")
    func cancelledBackgroundWaitNeverSends() async throws {
        let gate = makeGate()
        for _ in 0..<(RateLimitGate.searchLimit - RateLimitGate.reserve) {
            try await gate.reserveSlot(for: "/v1/series/search", priority: .background)
        }

        let waiter = Task {
            try await gate.reserveSlot(for: "/v1/series/search", priority: .background)
        }
        // Give it a moment to actually enter the poll loop rather than racing
        // the cancel against its very first check.
        try? await Task.sleep(for: .milliseconds(50))
        waiter.cancel()

        do {
            try await waiter.value
            Issue.record("A cancelled wait must not resolve as success")
        } catch let error as APIError {
            #expect(error == .cancelled)
        } catch {
            Issue.record("Expected APIError.cancelled, got \(error)")
        }
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
