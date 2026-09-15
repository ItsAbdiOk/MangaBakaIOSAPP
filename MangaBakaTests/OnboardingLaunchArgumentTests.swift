import Testing
@testable import MangaBaka

/// The UI tests skip onboarding with a `-key YES` launch argument, and the
/// key has to be the one `OnboardingState` reads. A UI-test bundle cannot
/// `@testable import` the app to share the constant, so the two spellings
/// are held together here by reading both files.
///
/// Fails if either side is renamed alone: the audit would silently go back
/// to measuring the carousel five times under five screen names, which is
/// exactly what happened on 2026-09-15.
@Suite("Onboarding's launch-argument key", .enabled(if: SourceTree.isAvailable))
struct OnboardingLaunchArgumentTests {
    @Test("the UI tests and OnboardingState agree on the key")
    func keyMatches() throws {
        let state = try SourceTree.read("MangaBaka/Features/Onboarding/OnboardingView.swift")
        let key = "onboarding.completed"
        #expect(state.contains("private static let key = \"\(key)\""))
        let uiTests = [
            "MangaBakaUITests/FlowAffordanceUITests.swift", "MangaBakaUITests/AccessibilityAuditTests.swift"
        ]
        for file in uiTests {
            let source = try SourceTree.read(file)
            #expect(source.contains("\"-\(key)\", \"YES\""), Comment(rawValue: file))
        }
    }
}
