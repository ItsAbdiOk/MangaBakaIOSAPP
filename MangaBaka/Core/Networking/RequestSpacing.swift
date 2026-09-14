import Foundation

/// The spacing rule for a host that asks for "reasonable" gaps between
/// requests: claim the next slot, then wait for it.
///
/// A value, not an actor, so the owning actor mutates it synchronously. That is
/// the point. Claiming the slot must happen *before* the wait, because the
/// wait's `await` releases the actor — with claim-after-wait, two callers
/// arriving together both read the same slot, both sleep the same time, and
/// both fire at once (measured at 96 µs apart before this existed). Three
/// clients had that bug from the same copied function; now there is one.
struct RequestSpacing: Sendable {
    let minimumInterval: TimeInterval
    private(set) var nextAllowed: Date = .distantPast

    init(minimumInterval: TimeInterval) {
        self.minimumInterval = minimumInterval
    }

    /// Reserves the next slot and returns how long the caller must wait for
    /// it — zero when the slot is already open.
    mutating func claim(now: Date) -> TimeInterval {
        let slot = max(nextAllowed, now)
        nextAllowed = slot.addingTimeInterval(minimumInterval)
        return slot.timeIntervalSince(now)
    }

    /// Pushes the next slot out to honour a server's refusal.
    mutating func backOff(until date: Date) {
        nextAllowed = max(nextAllowed, date)
    }

    /// How long a third party's own `Retry-After` is honoured for at most.
    ///
    /// The same ceiling `RateLimitGate.maxHonouredRetryAfter` applies to
    /// MangaBaka itself, and **a guess for the same reason it is one there**:
    /// nothing on record says what AniList, Shikimori, MangaUpdates, Webtoons
    /// or GigaViewer actually send on a 429. What is not a guess is what
    /// an uncapped value costs — `TimeInterval("nan")` and `TimeInterval("inf")`
    /// both parse to non-finite doubles rather than failing (confirmed on
    /// device, see `APIClient.parseRetryAfter`), and a NaN reaching
    /// `nextAllowed` makes every later `claim` return NaN, so `guard wait > 0`
    /// is false forever and that client never spaces its requests again for the
    /// life of the process. `86400` is the other end: one malformed header and
    /// the next caller sleeps for a day.
    static let maxHonouredRetryAfter = RateLimitGate.maxHonouredRetryAfter

    /// The back-off used when a 429 carries no usable `Retry-After` at all.
    /// **A guess**, carried over unchanged from the call sites that each
    /// hard-coded it before this function existed — all ten of them as of
    /// 2026-09-14, when `GoogleBooksClient` was the last one moved across.
    static let unstatedBackOff: TimeInterval = 60

    /// Parses a `Retry-After` header, clamps it, and pushes the next slot out
    /// by it — the one place the nine third-party clients' copies of this
    /// two-line pattern now live.
    ///
    /// Parsing is `APIClient.parseRetryAfter`, which already rejects
    /// non-finite values and understands the HTTP-date form (RFC 7231 §7.1.3)
    /// the bare `TimeInterval.init` the clients used could not.
    ///
    /// - Returns: the number of seconds actually honoured, for the caller's
    ///   `APIError.rateLimited(retryAfter:)` — so what a screen says it is
    ///   waiting for is what the client is really waiting for, and a
    ///   nonsense header cannot reach `humanDuration`. Nil when the header
    ///   was absent or unusable; the slot is still pushed out by
    ///   `unstatedBackOff` in that case, exactly as before.
    @discardableResult
    mutating func backOff(
        retryAfterHeader header: String?,
        now: Date
    ) -> TimeInterval? {
        guard let seconds = APIClient.parseRetryAfter(header) else {
            backOff(until: now.addingTimeInterval(Self.unstatedBackOff))
            return nil
        }
        // Until 2026-09-14 the ceiling was a `cap:` parameter with a default
        // and no caller anywhere — added for a call site that never
        // materialised. A parameter nobody passes reads as configurability
        // that was considered and is not; the constant says the same thing and
        // cannot drift per client.
        let honoured = min(max(seconds, 0), Self.maxHonouredRetryAfter)
        backOff(until: now.addingTimeInterval(honoured))
        return honoured
    }
}
