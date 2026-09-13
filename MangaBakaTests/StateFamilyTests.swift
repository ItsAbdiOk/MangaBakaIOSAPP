import Testing
import Foundation
@testable import MangaBaka

/// The empty / error / stale family, from the 2026-09-10 design board.
///
/// The rules here are the ones a reader feels rather than reads, which is
/// exactly why they rot silently without tests.
@Suite("State family")
struct StateFamilyTests {
    @Test("Every failure says what still works, not only what broke")
    func failuresNameWhatSurvives() {
        // A screen that says only "no" reads as the whole app being broken.
        // Each of these keeps a clause about what is still true.
        let cases: [(APIError, String)] = [
            (.offline, "Showing what was downloaded"),
            (.rateLimited(retryAfter: nil), "may not be you"),
            (.server(status: 500, message: ""), "still here"),
            (.server(status: 401, message: "Unauthenticated."), "keep working"),
            (.decoding(underlying: "x"), "because they may no longer be accurate")
        ]
        for (error, clause) in cases {
            #expect(
                error.userFacingMessage.contains(clause),
                "\(error.headline) does not say what survives"
            )
        }
    }

    @Test("Decode and transport read identically at the headline")
    func decodeAndTransportShareAHeadline() {
        // A reader cannot act on the difference, and two near-identical screens
        // only invite them to hunt for one.
        #expect(
            APIError.decoding(underlying: "x").headline
                == APIError.transport(underlying: "y").headline
        )
    }

    @Test("A rate limit only counts down when the server said how long")
    func countdownNeedsAnAnswer() {
        #expect(APIError.rateLimited(retryAfter: nil).countdown == nil)
        #expect(APIError.rateLimited(retryAfter: 38).countdown?.contains("38") == true)
        #expect(APIError.offline.countdown == nil)
    }

    /// Gap 5: `Retry-After: nan` used to survive `max(_, 0)` (a NaN operand
    /// makes Swift's `max` return NaN) and lock `RateLimitGate` refused
    /// forever, since every future `blockedUntil.timeIntervalSince(now)`
    /// compares against a NaN deadline and never reads `<= 0`. `"inf"` is the
    /// same shape of bug: `TimeInterval("inf")` parses to `.infinity` rather
    /// than failing, so a blocked-forever deadline was equally reachable from
    /// a header nobody malicious even had to try hard to send.
    ///
    /// Expected to fail before the fix: `TimeInterval("nan")` parses (Swift
    /// really does accept the literal), so the old `parseRetryAfter` returned
    /// `.some(Double.nan)` for both inputs rather than `nil`.
    @Test("A non-finite Retry-After is rejected, not propagated as NaN")
    func retryAfterRejectsNonFiniteInput() {
        #expect(APIClient.parseRetryAfter("nan") == nil)
        #expect(APIClient.parseRetryAfter("inf") == nil)
        #expect(APIClient.parseRetryAfter("-inf") == nil)
        // Control: an ordinary value still parses, so the guard isn't
        // rejecting everything.
        #expect(APIClient.parseRetryAfter("30") == 30)
    }

    /// Gap 24: "Retry now" stayed live for the whole retry, so a second tap
    /// while the first was still in flight fired a second, overlapping
    /// request and the button showed nothing for either. `FailureState` had
    /// no unit-testable seam for this — the guard lived entirely in private
    /// `@State` — so `RetryGate` was pulled out specifically so this could be
    /// asserted without ViewInspector.
    ///
    /// Expected to fail before the fix existed: there was no `RetryGate` to
    /// import, and the equivalent logic (`FailureState`'s private
    /// `isRetrying`) could not be reached from a test at all.
    @Test("A second retry while one is in flight is a no-op")
    func secondRetryDuringOneInFlightDoesNothing() async {
        let gate = await RetryGate()
        let runCount = Counter()

        // Two "taps" fired concurrently, the way a double-tap on the real
        // button would arrive.
        async let first: Void = gate.fire { await runCount.increment(); await Task.yield() }
        async let second: Void = gate.fire { await runCount.increment() }
        _ = await (first, second)

        #expect(await runCount.value == 1, "The second tap must not run the retry a second time")
    }

    /// A minimal actor rather than a plain `var` captured by two concurrent
    /// closures, which Swift's strict concurrency checking would refuse.
    private actor Counter {
        private(set) var value = 0
        func increment() { value += 1 }
    }

    /// Gaps 52, 65: `PressStyle` had no disabled look at all — a spine with
    /// no link, or a row with no series, pressed and coloured exactly like a
    /// live control. `ButtonStyleConfiguration` has no public initialiser, so
    /// `makeBody` cannot be driven from a test directly; `PressStyle` exposes
    /// its colour/scale/opacity decisions as `nonisolated static` functions
    /// specifically so this can be asserted without ViewInspector.
    ///
    /// Expected to fail before the fix: `PressStyle` read no `isEnabled` at
    /// all, so these static helpers did not exist to call.
    @Test("A disabled control is muted and does not answer a press")
    func pressStyleRendersDisabledDifferently() {
        #expect(PressStyle.foregroundColor(isEnabled: false) == Palette.textMuted)
        #expect(PressStyle.foregroundColor(isEnabled: true) != Palette.textMuted)
        #expect(PressStyle.scale(isEnabled: false, isPressed: true, reduceMotion: false) == 1)
        #expect(PressStyle.scale(isEnabled: true, isPressed: true, reduceMotion: false) == 0.97)
        #expect(PressStyle.opacity(isEnabled: false, isPressed: true, reduceMotion: true) == 1)
    }
}

/// The two rules above that are enforced by reading the source rather than by
/// running it. Gated, because a source tree is not always there.
@Suite("State family, as written", .enabled(if: SourceTree.isAvailable))
struct StateFamilySourceTests {
    @Test("An accent-filled button means tapping it fixes the problem")
    func onlyTheAccountErrorGetsTheAccent() throws {
        let source = try SourceTree.read("MangaBaka/Features/Shared/FailureState.swift")

        // The rule is worth pinning because it is the whole visual grammar of
        // the family: exactly one branch may ask for `.fixes`, and it is the
        // account one. A retry that cannot fix being offline must not look
        // like the answer to it.
        let fixes = source.components(separatedBy: "weight: .fixes").count - 1
        #expect(fixes == 1)
        let accountBranch = source.range(of: "error.needsAccount")
        let accentUse = source.range(of: "weight: .fixes")
        #expect(accountBranch != nil)
        #expect(
            (accountBranch?.lowerBound ?? source.endIndex) < (accentUse?.lowerBound ?? source.startIndex),
            "the accent must sit inside the needs-an-account branch"
        )
    }

    @Test("Only the stale bar uses amber")
    func amberMeansExactlyOneThing() throws {
        // If a second thing ever wants amber, that is the moment to stop and
        // ask what the colour is supposed to mean — not to add it quietly.
        let users = try SourceTree.swiftFiles(under: "MangaBaka")
            .filter { try SourceTree.read($0).contains("Palette.stale") }
            .filter { !$0.hasSuffix("Palette.swift") }
        #expect(users == ["MangaBaka/Features/Shared/FailureState.swift"], "amber leaked: \(users)")
    }
}
