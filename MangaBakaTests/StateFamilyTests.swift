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
