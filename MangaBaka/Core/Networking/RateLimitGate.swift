import Foundation

/// Holds requests back after the API says we are over its limit, and — for
/// search — before it ever has the chance to.
///
/// MangaBaka rate limits per IP — 30 requests a minute for search, 180
/// otherwise — and that budget is shared with everyone behind the same address:
/// a carrier NAT, a campus network, a household. Retrying into a 429 does not
/// only waste this app's quota, it keeps other people's requests failing too.
///
/// So a 429 is remembered and the client refuses locally until the window
/// passes, rather than discovering the same refusal over and over. Search
/// additionally gets a local sliding-window count, enforced *before* the 30th
/// request of the minute is even sent — a client that already knows its own
/// budget should not have to spend a real request to be told it is over.
actor RateLimitGate {
    private var blockedUntil: Date?
    private var consecutiveRateLimits = 0

    /// Timestamps of the search requests let through in roughly the last
    /// `searchWindow`. Pruned to that window on every check, so this never
    /// grows past `searchLimit` entries.
    private var searchTimestamps: [Date] = []

    /// The clock is injected — the same `Clock` protocol `SeriesRepository`
    /// and friends use for cache-expiry tests — so both the 429 backoff and
    /// the sliding window can be tested by moving time forward deliberately
    /// instead of by sleeping. A test that sleeps for a minute to prove a
    /// 60-second window is slow and flaky; a test that advances a clock is
    /// neither.
    private let clock: Clock

    init(clock: Clock = SystemClock()) {
        self.clock = clock
    }

    /// A ceiling on how long the server's own `Retry-After` is honoured for.
    ///
    /// GUESS: nothing on record says what MangaBaka actually sends on a 429
    /// (the existing tests' `Retry-After: 30` is hand-written, not captured).
    /// Without some cap, a malformed or unusually large value — an
    /// HTTP-date parsed wrong, or a server-side misconfiguration — would lock
    /// every request in the process for however long it said, with the
    /// screen reading "Retrying in N minutes." 15 minutes is long enough that
    /// no plausible real backoff hits it, short enough that a bad value
    /// cannot strand the app for the rest of a reading session.
    static let maxHonouredRetryAfter: TimeInterval = 15 * 60

    /// MangaBaka documents search at 30 requests a minute — the tightest of
    /// its published limits, and the one the rest of the app's traffic (180/
    /// minute) has no business being blocked by. See gap 8: a single 429 on
    /// search used to close Discover, detail and the library because they all
    /// shared one refusal clock.
    static let searchLimit = 30
    static let searchWindow: TimeInterval = 60

    /// Any path this substring appears in is subject to the search window.
    /// A substring rather than an exact match because the API is versioned
    /// (`/v1/series/search`, `/v2/series/search` both exist on the wire).
    private static let searchPathMarker = "/series/search"

    /// The deadline before a request to `path` may be attempted, or `nil` when
    /// one may go now.
    ///
    /// Checks the global 429 backoff first — a refusal earned on any path
    /// blocks every path, since MangaBaka's own 429 is not scoped to the
    /// endpoint that earned it. Then, only for a search path, the local
    /// sliding window: if fewer than `searchLimit` requests were let through
    /// in the last `searchWindow`, this one is allowed and counted; otherwise
    /// the deadline is when the oldest of those thirty ages out.
    ///
    /// Deliberately not named `secondsUntilAllowed` anymore: the caller needs
    /// a deadline to hand `APIError.rateLimited(until:)`, not a duration to
    /// convert back into one.
    func until(for path: String) -> Date? {
        if let blockedUntil {
            if blockedUntil > clock.now { return blockedUntil }
            self.blockedUntil = nil
        }

        guard path.contains(Self.searchPathMarker) else { return nil }

        let cutoff = clock.now.addingTimeInterval(-Self.searchWindow)
        searchTimestamps.removeAll { $0 <= cutoff }

        guard searchTimestamps.count >= Self.searchLimit else {
            searchTimestamps.append(clock.now)
            return nil
        }
        // The window reopens by one slot as soon as the oldest counted
        // request ages past `searchWindow`.
        return searchTimestamps[0].addingTimeInterval(Self.searchWindow)
    }

    /// - Parameter retryAfter: the server's own `Retry-After`, in seconds.
    ///   Honoured when given, because the server knows better than any local
    ///   guess — but capped, same as the fallback below it, so a bad value
    ///   cannot lock the app out for longer than a transient spike could ever
    ///   justify. Otherwise back off exponentially, capped so the app cannot
    ///   lock itself out for minutes over a transient spike.
    func recordRateLimit(retryAfter: TimeInterval?) {
        consecutiveRateLimits += 1
        let fallback = min(pow(2, Double(consecutiveRateLimits)), 60)
        let wait = min(retryAfter ?? fallback, Self.maxHonouredRetryAfter)
        blockedUntil = clock.now.addingTimeInterval(wait)
    }

    /// Any success clears the backoff: the window has evidently reopened.
    /// The search sliding window is untouched — it counts requests actually
    /// made, regardless of whether they succeeded, because the local budget
    /// it tracks is MangaBaka's request count, not its error rate.
    func recordSuccess() {
        consecutiveRateLimits = 0
        blockedUntil = nil
    }
}
