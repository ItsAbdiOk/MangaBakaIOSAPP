import Foundation
import Testing
@testable import MangaBaka

/// Item 31. MangaBaka publishes two per-IP limits — 30/min for search, 180/min
/// for everything else — and until this change only the first was enforced
/// locally. `RateLimitGate`'s own doc comment named the 180 and nothing
/// counted against it, so the app found that ceiling by earning a 429 on a
/// budget shared with everyone behind the same address.
@Suite("The general 180/min window is enforced before the server has to")
struct GeneralRateLimitWindowTests {
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

    /// A general path: anything without `/series/search` in it.
    private let path = "/v1/series/3397"

    /// Expected to fail before item 31 with: no throw at all on the 181st
    /// call — `reserveSlot` returned early for every non-search path
    /// (`guard family == .search else { return nil }`), so the general window
    /// did not exist and the assertion `error != nil` fails with nil.
    @Test("The 181st general request in a minute is refused locally")
    func generalWindowIsEnforced() async throws {
        let (gate, _) = makeGate()

        for _ in 0..<RateLimitGate.Family.general.limit {
            _ = try await gate.reserveSlot(for: path, priority: .userInitiated)
        }
        #expect(await gate.timestampCountForTesting(.general) == 180)

        var refusal: APIError?
        do {
            _ = try await gate.reserveSlot(for: path, priority: .userInitiated)
        } catch let error {
            refusal = error
        }
        let caught = try #require(refusal)
        // Attributed to MangaBaka in general, not to search — the copy for a
        // paused series page must not say search was what paused.
        guard case let .rateLimited(_, party) = caught else {
            Issue.record("expected .rateLimited, got \(caught)")
            return
        }
        #expect(party == .mangaBaka)
    }

    /// The control: once the window has passed the same request goes through,
    /// so the refusal above is the sliding window and not a permanent block.
    @Test("The general window reopens after its minute")
    func generalWindowReopens() async throws {
        let (gate, clock) = makeGate()
        for _ in 0..<RateLimitGate.Family.general.limit {
            _ = try await gate.reserveSlot(for: path, priority: .userInitiated)
        }
        clock.advance(RateLimitGate.Family.general.window + 1)
        _ = try await gate.reserveSlot(for: path, priority: .userInitiated)
        #expect(await gate.timestampCountForTesting(.general) == 1)
    }

    /// The second control: the two windows are genuinely separate, so filling
    /// one does not refuse the other. This is the property gap 8 was filed
    /// for, re-asserted now that both families count.
    @Test("A full general window does not refuse a search")
    func windowsAreIndependent() async throws {
        let (gate, _) = makeGate()
        for _ in 0..<RateLimitGate.Family.general.limit {
            _ = try await gate.reserveSlot(for: path, priority: .userInitiated)
        }
        _ = try await gate.reserveSlot(for: "/v1/series/search", priority: .userInitiated)
        #expect(await gate.timestampCountForTesting(.search) == 1)
    }

    /// A `.background` general request now waits on the general window rather
    /// than passing straight through, and gives up when its task is
    /// cancelled — the same contract search already had.
    ///
    /// Expected to fail before item 31 with: the call returning immediately
    /// (a general path never entered `waitForBackgroundSlot`), so
    /// `finished` is true and the `.cancelled` expectation fails.
    @Test("Background general work waits on the general reserve")
    func backgroundWaitsOnGeneral() async throws {
        let (gate, _) = makeGate()
        // Fill past `limit - reserve`, which is what background is capped at.
        let backgroundCap = RateLimitGate.Family.general.limit - RateLimitGate.Family.general.reserve
        for _ in 0..<backgroundCap {
            _ = try await gate.reserveSlot(for: path, priority: .userInitiated)
        }

        let waiter = Task {
            try await gate.reserveSlot(for: path, priority: .background)
        }
        // Give the waiter a turn to enter the poll loop before cancelling, so
        // this asserts "it waited and then gave up" rather than "it was
        // cancelled before it started".
        await Task.yield()
        waiter.cancel()

        var thrown: APIError?
        do {
            _ = try await waiter.value
        } catch let error {
            thrown = error as? APIError
        }
        #expect(thrown == .cancelled)
        // And the reader's reserve was never spent by that background work.
        #expect(await gate.timestampCountForTesting(.general) == backgroundCap)
    }
}
