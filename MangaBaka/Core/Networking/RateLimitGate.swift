import Foundation

/// Holds requests back after the API says we are over its limit.
///
/// MangaBaka rate limits per IP — 30 requests a minute for search, 180
/// otherwise — and that budget is shared with everyone behind the same address:
/// a carrier NAT, a campus network, a household. Retrying into a 429 does not
/// only waste this app's quota, it keeps other people's requests failing too.
///
/// So a 429 is remembered and the client refuses locally until the window
/// passes, rather than discovering the same refusal over and over.
actor RateLimitGate {
    private var blockedUntil: Date?
    private var consecutiveRateLimits = 0

    /// The clock is injectable so backoff can be tested without waiting.
    private let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    /// Seconds left before a request should be attempted, or `nil` when one may
    /// go now.
    func secondsUntilAllowed() -> TimeInterval? {
        guard let blockedUntil else { return nil }
        let remaining = blockedUntil.timeIntervalSince(now())
        if remaining <= 0 {
            self.blockedUntil = nil
            return nil
        }
        return remaining
    }

    /// - Parameter retryAfter: the server's own `Retry-After`, in seconds.
    ///   Honoured when given, because the server knows better than any local
    ///   guess. Otherwise back off exponentially, capped so the app cannot
    ///   lock itself out for minutes over a transient spike.
    func recordRateLimit(retryAfter: TimeInterval?) {
        consecutiveRateLimits += 1
        let fallback = min(pow(2, Double(consecutiveRateLimits)), 60)
        let wait = retryAfter ?? fallback
        blockedUntil = now().addingTimeInterval(wait)
    }

    /// Any success clears the backoff: the window has evidently reopened.
    func recordSuccess() {
        consecutiveRateLimits = 0
        blockedUntil = nil
    }
}
