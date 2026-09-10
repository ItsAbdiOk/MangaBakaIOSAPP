import Testing
import Foundation
@testable import MangaBaka

/// First run, from the 2026-09-10 design board.
@Suite("First run, as written", .enabled(if: SourceTree.isAvailable))
struct OnboardingCopyTests {
    private func source() throws -> String {
        try SourceTree.read("MangaBaka/Features/Onboarding/OnboardingView.swift")
    }

    @Test("Skip is on the first screen, not discovered on the third")
    func skipIsAlwaysReachable() throws {
        let source = try source()
        // If it genuinely is not a gate, the exit cannot be something a reader
        // has to page through the whole thing to find.
        #expect(source.contains("Button(\"Skip\", action: onFinish)"))
        #expect(source.contains("if page < 2"), "the controls row carries Skip on every page but the last")
    }

    @Test("Three screens, and the last one is refusable")
    func theAskIsRefusable() throws {
        let source = try source()
        #expect(source.contains("CoversFirstPage"))
        #expect(source.contains("StackMechanicPage"))
        #expect(source.contains("AccountPage"))
        #expect(source.contains("Not now"))
        // A full-width control, not grey text: refusing is a real choice, and a
        // choice styled as an afterthought reads as one the app would rather
        // you did not make.
        #expect(source.contains("frame(height: Metrics.ctaSecondary)"))
    }

    /// Every claim on those screens has to be something the app does.
    ///
    /// The copy changed wholesale when the board landed, so the specific
    /// sentences this used to check are gone — but the rule did not change, and
    /// these are the new sentences carrying it.
    @Test("Onboarding claims only what the app can do")
    func claimsAreTrue() throws {
        // Multi-line string literals wrap the copy, so the check is on the
        // words rather than on where the line breaks fell.
        let source = try source()
            .replacingOccurrences(of: "\\\n", with: "")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")

        // Signed-out really is fully functional — verified against the live API.
        #expect(source.contains("work with no account and no sign-up"))
        // The stack really does refill from what is rising, daily.
        #expect(source.contains("Series drawn from what is rising"))
        // Each of the three account benefits is a thing the app genuinely
        // cannot do without a token.
        #expect(source.contains("synced across devices"))
        #expect(source.contains("Predicted releases for series you are reading or have paused"))
    }

    /// Reading leads; connecting an account is the second control, and on the
    /// last screen it is the only ask. Putting the account first anywhere would
    /// make it read as a requirement.
    @Test("Nothing asks for an account before the app has proved itself")
    func theAskComesLast() throws {
        let source = try source()
        let covers = try #require(source.range(of: "CoversFirstPage"))
        let connect = try #require(source.range(of: "Connect an account"))
        #expect(covers.lowerBound < connect.lowerBound)
    }

    /// No cover art in the binary.
    ///
    /// The board suggested shipping a fallback set of covers for a first launch
    /// with no network, and Abdi agreed — but bundling real cover art means
    /// redistributing publisher artwork, and MangaBaka's own licence is explicit
    /// that the third-party data it aggregates carries no redistribution rights
    /// it can grant. Loading art from their CDN at runtime is a different act
    /// from shipping it inside an App Store binary.
    ///
    /// The fallback is a wash of the app's own colours in the same grid, so the
    /// screen still reads as covers arriving rather than as a broken page.
    @Test("No artwork is shipped in the app bundle")
    func shipsNoBorrowedArtwork() throws {
        let images = try SourceTree.files(under: "MangaBaka/Resources")
            .filter { path in
                [".png", ".jpg", ".jpeg", ".webp"].contains { path.lowercased().hasSuffix($0) }
            }
            .filter { !$0.contains("AppIcon") }
        #expect(images.isEmpty, "artwork in the bundle is redistribution: \(images)")
    }
}

/// The flag behind first run. Behaviour rather than copy, so it is not gated on
/// a source tree.
@Suite("Onboarding state", .serialized)
@MainActor
struct OnboardingStateTests {
    @Test("A first launch shows it, and it is never shown twice")
    func showsOnceOnly() throws {
        let defaults = try #require(UserDefaults(suiteName: "onboarding.tests.\(UUID().uuidString)"))
        let first = OnboardingState(defaults: defaults)
        #expect(!first.hasCompleted)

        first.complete()
        #expect(first.hasCompleted)

        let relaunched = OnboardingState(defaults: defaults)
        #expect(relaunched.hasCompleted, "it must not reappear on every launch")
    }
}
