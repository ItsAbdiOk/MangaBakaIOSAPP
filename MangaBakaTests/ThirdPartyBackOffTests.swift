import Testing
import Foundation
@testable import MangaBaka

/// `RequestSpacing.backOff(retryAfterHeader:now:cap:)` — the one place the
/// nine third-party clients now parse and clamp `Retry-After`.
///
/// Each of them used to do it inline with a bare `TimeInterval.init`, which
/// accepts "nan" and "inf" (confirmed on device; see
/// `APIClient.parseRetryAfter`). A NaN reaching `nextAllowed` makes every
/// later `claim` return NaN, so `guard wait > 0` never fires again and that
/// client stops spacing its requests for the life of the process — the one
/// failure mode that turns a politeness rule into a ban.
@Suite("Third-party Retry-After")
struct ThirdPartyBackOffTests {
    private let now = Date(timeIntervalSince1970: 1_757_000_000)

    private func spacing() -> RequestSpacing { RequestSpacing(minimumInterval: 3.5) }

    /// Expected failure before the fix: `claim` returns NaN — `wait.isFinite`
    /// is false, and `wait > 0` is false, so the client fires immediately and
    /// keeps doing so forever.
    @Test("A NaN Retry-After does not end this client's spacing for the session")
    func nanDoesNotPoisonSpacing() {
        var subject = spacing()
        let honoured = subject.backOff(retryAfterHeader: "nan", now: now)

        #expect(honoured == nil, "unusable, so the caller says nothing about a deadline")
        let wait = subject.claim(now: now)
        #expect(wait.isFinite)
        #expect(wait >= RequestSpacing.unstatedBackOff, "backed off by the stated fallback instead")
    }

    /// Expected failure before the fix: `wait` is 1,000,000,000 seconds — the
    /// next caller sleeps for 31 years, and `humanDuration` is handed a number
    /// no copy can render.
    @Test("An absurd Retry-After is clamped to the ceiling, not honoured")
    func absurdValuesAreClamped() {
        var subject = spacing()
        let honoured = subject.backOff(retryAfterHeader: "1e9", now: now)

        #expect(honoured == RequestSpacing.maxHonouredRetryAfter)
        #expect(subject.claim(now: now) <= RequestSpacing.maxHonouredRetryAfter)
    }

    @Test("A negative Retry-After does not pull the next slot into the past")
    func negativeValuesFloorAtZero() {
        var subject = spacing()
        #expect(subject.backOff(retryAfterHeader: "-5", now: now) == 0)
        #expect(subject.claim(now: now) >= 0)
    }

    /// The control: an ordinary header is honoured exactly, so the three
    /// assertions above are about the clamp rather than about back-off having
    /// stopped working.
    @Test("Control: an ordinary Retry-After is honoured to the second")
    func ordinaryValuesAreHonoured() {
        var subject = spacing()
        #expect(subject.backOff(retryAfterHeader: "60", now: now) == 60)
        #expect(abs(subject.claim(now: now) - 60) < 0.001)
    }

    @Test("A missing Retry-After still backs off, by the stated fallback")
    func missingHeaderFallsBack() {
        var subject = spacing()
        #expect(subject.backOff(retryAfterHeader: nil, now: now) == nil)
        #expect(abs(subject.claim(now: now) - RequestSpacing.unstatedBackOff) < 0.001)
    }

    /// `APIClient.parseRetryAfter` already understood the HTTP-date form
    /// (RFC 7231 §7.1.3); the clients' own `TimeInterval.init` did not, so a
    /// server sending the other legal form was silently ignored. Reusing that
    /// parser is what fixed it, which is worth a test at this level too.
    @Test("The HTTP-date form of Retry-After is understood, not discarded")
    func httpDateFormIsParsed() {
        var subject = spacing()
        let soon = Date().addingTimeInterval(120)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"

        let honoured = subject.backOff(retryAfterHeader: formatter.string(from: soon), now: now)
        #expect(honoured != nil)
        #expect((honoured ?? 0) > 60 && (honoured ?? 0) <= 121)
    }
}
