import Foundation
import Testing
@testable import MangaBaka

/// Settings once lived only in a navigation-bar toolbar item. The Library
/// screen draws its own header and gives the bar no title and no back button,
/// so iOS collapsed the bar to nothing and took the gear with it — Settings
/// became unreachable without a single build error to say so.
///
/// These read source rather than run the view because the failure is a missing
/// entry point, not a wrong value: nothing to assert at runtime when the
/// control does not exist.
/// Gated per test, not per suite (2026-09-14): the gate on the suite also
/// skipped the tests below that assert on a value and never touch the
/// checkout, so they did not run on Xcode Cloud at all — and nothing
/// reports the difference between a local run and a cloud one.
@Suite("Chrome reachability")
struct ChromeReachabilityTests {
    @Test("Settings is reachable from the Library screen's own header", .enabled(if: SourceTree.isAvailable))
    func settingsHasAnEntryPoint() throws {
        let library = try SourceTree.read("MangaBaka/Features/Library/LibraryView.swift")
        #expect(library.contains("onOpenSettings"))
        #expect(library.contains("gearshape"))
        #expect(library.contains("accessibilityLabel(\"Settings\")"))

        // The Library tab and its five destinations moved out of RootView when
        // that type hit the body-length ceiling. Settings is one of them.
        let root = try SourceTree.read("MangaBaka/App/RootView+Session.swift")
        #expect(root.contains("onOpenSettings: { showsSettings = true }"))
        #expect(root.contains("SettingsView("))
    }

    /// Every other route into Settings goes through a screen that has to exist.
    ///
    /// Gap 64 (batch 6) moved this push out of `RootView.body` into
    /// `RootView+Failures.onboardingCompletionChanged`, deferred behind an
    /// `onChange` rather than fired inline from `onConnectAccount` — see
    /// that file for why. The route itself is unchanged; only which file it
    /// lives in moved.
    @Test("Onboarding's account route still lands on Settings", .enabled(if: SourceTree.isAvailable))
    func onboardingRouteSurvives() throws {
        let root = try SourceTree.read("MangaBaka/App/RootView.swift")
        #expect(root.contains(".onChange(of: onboarding.hasCompleted)"))
        let failures = try SourceTree.read("MangaBaka/App/RootView+Failures.swift")
        #expect(failures.contains("selection = .library"))
        #expect(failures.contains("showsSettings = true"))
    }

    /// The floating tab bar is the only chrome now. A second bar above it would
    /// reintroduce the stacked-header spacing that was just removed.
    @Test("No second top bar was reintroduced", .enabled(if: SourceTree.isAvailable))
    func noTopBar() throws {
        let root = try SourceTree.read("MangaBaka/App/RootView.swift")
        #expect(!root.contains("AppTopBar("))
    }

    /// The inset exists to clear the status bar, not a bar the app draws. It was
    /// 106 while a top bar existed; leaving it there is what put every screen
    /// title a third of the way down the display.
    @Test("Top inset clears the status bar, not a bar the app draws")
    func topInsetIsTight() {
        #expect(Metrics.scrollTopInset <= 32)
        #expect(Metrics.scrollTopInset > 0)
    }
}
