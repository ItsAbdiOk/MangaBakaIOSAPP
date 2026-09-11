import Foundation
import Testing
@testable import MangaBaka

/// Arrival times of the stubbed requests, recorded from the handler, which is
/// `@Sendable` and so cannot append to a plain local array.
private final class ArrivalLog: @unchecked Sendable {
    private let lock = NSLock()
    private var times: [ContinuousClock.Instant] = []

    func record() {
        lock.lock(); defer { lock.unlock() }
        times.append(.now)
    }

    /// Time between the last two arrivals.
    var lastGap: Duration? {
        lock.lock(); defer { lock.unlock() }
        guard times.count >= 2 else { return nil }
        return times[times.count - 2].duration(to: times[times.count - 1])
    }
}

/// MangaUpdates asks for spacing and a ban costs the feature. The spacing was
/// an actor holding one "next allowed" date — but the wait released the actor
/// before the date was written, so two callers arriving together both read the
/// same slot, both slept the same time, and both fired at once.
@Suite("MangaUpdates request spacing", .serialized)
struct MangaUpdatesSpacingTests {
    @Test("Two concurrent callers are spaced by the minimum interval")
    func concurrentCallersAreSpaced() async throws {
        let arrivals = ArrivalLog()
        URLProtocolStub.setHandler { _ in
            arrivals.record()
            return .respond(.init(body: Data(#"{"results":[]}"#.utf8)))
        }
        defer { URLProtocolStub.reset() }

        let client = MangaUpdatesClient(
            baseURL: URL(string: "https://mu.example.invalid/v1").unsafeTestURL,
            session: URLProtocolStub.makeSession(),
            clock: TestClock()
        )

        // A warm-up so the slot is already taken: the first caller from cold
        // never waits, and so never shows the bug. Both later callers must wait.
        _ = try await client.releases(seriesNumber: 1)
        async let first = client.releases(seriesNumber: 2)
        async let second = client.releases(seriesNumber: 3)
        _ = try await (first, second)

        let gap = try #require(arrivals.lastGap)
        // The clock is frozen, so the spacing shows up only as real elapsed
        // time between the two requests reaching the stub.
        #expect(
            gap >= .seconds(MangaUpdatesClient.minimumInterval - 0.5),
            "Both requests reached the network \(gap) apart; the slot was not reserved before the wait"
        )
    }
}

/// The rule itself, checked without sleeping: the claim happens at call time,
/// so callers that arrive together get consecutive slots.
@Suite("Request spacing slots")
struct RequestSpacingTests {
    private let start = Date(timeIntervalSince1970: 1_757_000_000)

    @Test("The first claim on an open slot waits nothing")
    func firstClaimIsFree() {
        var spacing = RequestSpacing(minimumInterval: 3)
        #expect(spacing.claim(now: start) == 0)
    }

    @Test("Claims made at the same instant are handed consecutive slots")
    func simultaneousClaimsQueue() {
        var spacing = RequestSpacing(minimumInterval: 3)
        _ = spacing.claim(now: start)
        let second = spacing.claim(now: start)
        let third = spacing.claim(now: start)
        #expect(second == 3)
        #expect(third == 6, "Each claim reserves the slot after the one before it")
    }

    @Test("A slot that has already passed is not owed")
    func elapsedSlotDoesNotAccumulate() {
        var spacing = RequestSpacing(minimumInterval: 3)
        _ = spacing.claim(now: start)
        let later = spacing.claim(now: start.addingTimeInterval(60))
        #expect(later == 0, "Idle time must not build up a debt of waits")
    }

    @Test("A back-off only ever pushes the slot later")
    func backOffNeverShortens() {
        var spacing = RequestSpacing(minimumInterval: 3)
        _ = spacing.claim(now: start)
        spacing.backOff(until: start.addingTimeInterval(1))
        #expect(spacing.claim(now: start) == 3, "A shorter Retry-After cannot reopen a claimed slot")
        spacing.backOff(until: start.addingTimeInterval(60))
        #expect(spacing.claim(now: start) == 60)
    }
}
