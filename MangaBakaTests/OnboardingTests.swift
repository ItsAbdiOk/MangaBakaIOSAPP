import Foundation
import Testing
@testable import MangaBaka

/// First run is a choice, not a gate. Every discovery endpoint answers without
/// a token, so a new reader gets a working app with no account.
@Suite("Onboarding", .serialized)
@MainActor
struct OnboardingTests {
    private func makeDefaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "onboarding.tests.\(UUID().uuidString)"))
    }

    @Test("A first launch shows it, and it is never shown twice")
    func showsOnceOnly() throws {
        let defaults = try makeDefaults()
        let first = OnboardingState(defaults: defaults)
        #expect(!first.hasCompleted)

        first.complete()
        #expect(first.hasCompleted)

        let relaunched = OnboardingState(defaults: defaults)
        #expect(relaunched.hasCompleted, "it must not reappear on every launch")
    }

    /// Every claim on those screens has to be something the app does. A
    /// redesign will be handed these as the boundary, so an untrue one here
    /// becomes an untrue one there.
    @Test("Onboarding claims only what the app can do",
          .enabled(if: SourceTree.isAvailable))
    func claimsAreTrue() throws {
        // Multi-line string literals wrap the copy, so the check is on the
        // words rather than on where the line breaks fell.
        let source = try SourceTree
            .read("MangaBaka/Features/Onboarding/OnboardingView.swift")
            .replacingOccurrences(of: "\\\n", with: "")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")

        // Blends really do return ten weighted tags that can be switched off.
        #expect(source.contains("switch any of them off"))
        // The token really is optional and really does stay on device.
        #expect(source.contains("Optional"))
        #expect(source.contains("stays on this device"))
        // Signed-out really is fully functional.
        #expect(source.contains("works signed out"))
    }

    /// "Start browsing" leads; connecting an account is the second control.
    /// Putting the account first would make it read as a requirement.
    @Test("Browsing is the primary action, not connecting an account",
          .enabled(if: SourceTree.isAvailable))
    func browsingLeads() throws {
        let source = try SourceTree.read("MangaBaka/Features/Onboarding/OnboardingView.swift")
        let browse = try #require(source.range(of: "Start browsing"))
        let connect = try #require(source.range(of: "Connect an account"))
        #expect(browse.lowerBound < connect.lowerBound)
    }
}
