import Foundation
import Testing
@testable import MangaBaka

/// Wire review #2/#8, 2026-09-14: `Retry-After` reaches
/// `APIError.rateLimited(retryAfter:party:)` straight from the wire for
/// every third-party client (`AniListClient`, `MangaUpdatesClient`,
/// `SeriesCharacter`, the feed clients) with no cap of its own — MangaBaka's
/// own path is already safe (`APIClient.parseRetryAfter` + `RateLimitGate`'s
/// 15-minute cap), but a hostile or merely broken third party is exactly
/// what `APIError.Party` exists to distrust.
///
/// `Int((wholeSeconds / 60).rounded())` on a finite-but-astronomical value
/// traps: `1e300` is finite, so it survives `isFinite`, becomes a `Date`
/// unreasonably far in the future, and `humanDuration` computing minutes
/// from `timeIntervalSinceNow` divides by 60 into a `Double` far outside
/// `Int`'s range before calling `Int(_:)` on it — a crash the moment any
/// `StaleBar` or failure screen renders the countdown.
@Suite("rateLimited(retryAfter:) clamps an uncapped third-party value")
struct RateLimitedRetryAfterClampTests {
    /// Expected to fail before the fix by trapping (EXC_BAD_INSTRUCTION /
    /// "Fatal error: Double value cannot be converted to Int because the
    /// result would be greater than Int.max") the moment `.countdown` is
    /// read — `Int(Double)` has no recovery path, so this is a crash, not a
    /// thrown error, and cannot be caught with `#expect(throws:)`. Passing
    /// after the fix proves the clamp in `rateLimited(retryAfter:party:)`
    /// and `Int(wholeOrClamped:)` in `humanDuration` both did their job.
    @Test("An astronomical Retry-After no longer traps computing the countdown")
    func astronomicalRetryAfterDoesNotTrap() {
        let error = APIError.rateLimited(retryAfter: 1e300)
        let countdown = error.countdown
        #expect(countdown != nil)
    }

    /// The clamp caps at `RateLimitGate.maxHonouredRetryAfter` (15 minutes) —
    /// the same ceiling MangaBaka's own 429s are held to — so the countdown
    /// this produces should read in minutes, not as some enormous number.
    @Test("The clamped deadline is at most the shared 15-minute ceiling")
    func clampedDeadlineRespectsCeiling() {
        let error = APIError.rateLimited(retryAfter: 1e300)
        guard let deadline = error.rateLimitDeadline else {
            Issue.record("Expected a deadline for a finite (if absurd) retryAfter")
            return
        }
        let remaining = deadline.timeIntervalSinceNow
        #expect(remaining <= RateLimitGate.maxHonouredRetryAfter + 1)
        #expect(remaining > 0)
    }

    /// A negative `Retry-After` — malformed, but still finite — must not
    /// produce a deadline in the past; the clamp's `max($0, 0)` half.
    @Test("A negative Retry-After clamps to zero, not a past deadline")
    func negativeRetryAfterClampsToZero() {
        let error = APIError.rateLimited(retryAfter: -500)
        guard let deadline = error.rateLimitDeadline else {
            Issue.record("Expected a deadline for a finite retryAfter")
            return
        }
        #expect(deadline.timeIntervalSinceNow >= -1)
    }

    /// Non-finite values (`.infinity`, `.nan`) were already handled by
    /// `countdown`'s own `isFinite` guard and by the clamp's `flatMap`
    /// turning them into `nil` — a control proving this fix didn't change
    /// that existing behaviour.
    @Test("Infinite and NaN Retry-After still produce no deadline at all")
    func nonFiniteRetryAfterStillProducesNil() {
        #expect(APIError.rateLimited(retryAfter: .infinity).rateLimitDeadline == nil)
        #expect(APIError.rateLimited(retryAfter: .nan).rateLimitDeadline == nil)
    }
}
