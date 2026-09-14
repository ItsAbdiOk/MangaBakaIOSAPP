import Foundation

/// One spacing rule for one *host*, shared by every client that talks to it.
///
/// `RequestSpacing` is a value owned by one actor, which is right when one
/// actor is the only thing calling a host. It is wrong the moment two are:
/// `OpenLibraryCovers` and `OpenLibraryEditions` each held their own, so the
/// two could put two requests on openlibrary.org inside one gap no matter what
/// either interval said. `OpenLibraryEditions.minimumInterval`'s own comment
/// recorded that as an open defect on 2026-09-14 — this is the fix it named.
///
/// **Why it is worth a type.** Measured 2026-09-14 and recorded in
/// `docs/sources/bibliographic.md`: twelve requests spaced 4 s apart over about
/// two minutes ended with openlibrary.org refusing TCP connections outright
/// (`Failed to connect … after 75008 ms`), and a client at 3 s gaps was reset
/// by peer on five of five calls. The ceiling is not the documented 1 req/s and
/// is not purely time-based, so the *number* of clients on the host matters as
/// much as the gap between one client's calls.
///
/// An actor, unlike `RequestSpacing`: it is shared by construction, so claiming
/// a slot has to be serialised by something. The claim stays synchronous
/// *inside* the actor — the caller awaits the claim, then sleeps outside it, so
/// a client waiting out its slot never holds the gate against the next caller.
/// That is the same ordering `RequestSpacing`'s doc comment insists on, and for
/// the same reason: claim before the wait, or two callers read one slot.
actor HostRateGate {
    /// The gate for openlibrary.org **and covers.openlibrary.org**, which are
    /// two names for one service and — measured above — one IP-level limit.
    /// Both Open Library clients take this by default.
    ///
    /// 4 seconds, the figure `OpenLibraryEditions` measured on 2026-09-14. It
    /// is the slower of the two intervals that existed before this type
    /// (covers used 3.0), and the slower one is the one to keep: the 3 s
    /// figure was A GUESS made before the connection refusals were seen.
    static let openLibrary = HostRateGate(minimumInterval: 4.0)

    private var spacing: RequestSpacing

    /// The interval this gate enforces, so a test can assert against the same
    /// number the client waits out rather than a copy of it.
    nonisolated let minimumInterval: TimeInterval

    init(minimumInterval: TimeInterval) {
        self.minimumInterval = minimumInterval
        spacing = RequestSpacing(minimumInterval: minimumInterval)
    }

    /// Reserves the next slot on this host and returns how long the caller
    /// must wait for it. **Sleep outside the gate**, not inside: this returns
    /// so the caller can `Task.sleep` on its own actor.
    func claim(now: Date) -> TimeInterval {
        spacing.claim(now: now)
    }

    /// Honours a 429 for every client on this host at once, which is the other
    /// half of the reason the gate exists — a back-off one client learned used
    /// to be invisible to the other, so the second kept firing into a host that
    /// had just refused the first.
    @discardableResult
    func backOff(retryAfterHeader header: String?, now: Date) -> TimeInterval? {
        spacing.backOff(retryAfterHeader: header, now: now)
    }

    /// Test-only: when this gate will next let a request out, so a 429 test can
    /// prove the server's own header reached *both* clients on the host
    /// without waiting one out.
    var nextAllowedForTesting: Date { spacing.nextAllowed }
}
