import Foundation
import Testing
@testable import MangaBaka

/// One gate per host, shared by every client on it.
///
/// The defect this fixes was recorded as an open caveat in
/// `OpenLibraryEditions.minimumInterval` on 2026-09-14: `OpenLibraryCovers`
/// and `OpenLibraryEditions` each held their own `RequestSpacing`, so the two
/// could put two requests on openlibrary.org inside one gap however either
/// number was set — and measured that day, twelve requests at 4 s spacing ended
/// with the host refusing TCP connections outright.
///
/// **Expected to fail before the change with:** a compile error —
/// `HostRateGate` did not exist, and `OpenLibraryCovers`/`OpenLibraryEditions`
/// took no `gate:`. Written against the gate rather than against two live
/// clients because the behaviour under test is the *sharing*, and two clients
/// with a stubbed session would prove it only by sleeping through real seconds.
@Suite("Host rate gate")
struct HostRateGateTests {
    /// The claim-before-wait ordering `RequestSpacing`'s own doc comment
    /// insists on, now across two holders instead of one. Two callers arriving
    /// together must be handed two different slots.
    @Test("Two clients on one gate are spaced from each other, not each from itself")
    func twoHoldersShareOneQueue() async {
        let gate = HostRateGate(minimumInterval: 4)
        let now = Date(timeIntervalSince1970: 1_000_000)

        // Standing in for the covers client and the editions client arriving
        // in the same instant — which is exactly what a series page does.
        let first = await gate.claim(now: now)
        let second = await gate.claim(now: now)

        #expect(first == 0, "The first caller finds the slot open")
        #expect(
            second == 4,
            "The second waits a full interval — with two `RequestSpacing`s it waited 0 and both fired"
        )
    }

    /// The other half of the reason the gate exists: a 429 one client learned
    /// used to be invisible to the other, so the second kept firing into a host
    /// that had just refused the first.
    @Test("A 429 one client meets backs the other client off too")
    func aBackOffReachesEveryHolder() async {
        let gate = HostRateGate(minimumInterval: 1)
        let now = Date(timeIntervalSince1970: 1_000_000)

        let honoured = await gate.backOff(retryAfterHeader: "120", now: now)
        #expect(honoured == 120)

        let next = await gate.claim(now: now)
        #expect(next == 120, "The next caller — any caller — waits out the server's own header")
    }

    /// `RequestSpacing.backOff` already clamps a nonsense header; this proves
    /// the gate does not route around it. A NaN reaching `nextAllowed` makes
    /// every later `claim` return NaN, so `wait > 0` is false forever and the
    /// host loses its gate for the life of the process.
    @Test("A nonsense Retry-After does not disarm the gate")
    func nonsenseRetryAfterIsClamped() async {
        let gate = HostRateGate(minimumInterval: 1)
        let now = Date(timeIntervalSince1970: 1_000_000)

        let honoured = await gate.backOff(retryAfterHeader: "nan", now: now)
        #expect(honoured == nil, "Unparseable, so the unstated back-off applies instead")

        let next = await gate.claim(now: now)
        #expect(next.isFinite, "A non-finite wait is a gate that never spaces again")
        #expect(next == RequestSpacing.unstatedBackOff)
    }

    /// Both Open Library clients read the host's number rather than each
    /// carrying one. The 3.0 that `OpenLibraryCovers` used was A GUESS made
    /// before the connection refusals were measured; 4.0 is the measured one,
    /// and the slower of two figures is the one to keep.
    @Test("Both Open Library clients report the host's own interval")
    func bothClientsReadTheHostsNumber() {
        #expect(OpenLibraryCovers.minimumInterval == HostRateGate.openLibrary.minimumInterval)
        #expect(OpenLibraryEditions.minimumInterval == HostRateGate.openLibrary.minimumInterval)
        #expect(HostRateGate.openLibrary.minimumInterval == 4.0)
    }
}
