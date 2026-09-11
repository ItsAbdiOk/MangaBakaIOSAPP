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
}
