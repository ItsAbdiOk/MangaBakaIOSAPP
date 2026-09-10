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
@Suite("Chrome reachability", .enabled(if: SourceTree.isAvailable))
struct ChromeReachabilityTests {
    @Test("Settings is reachable from the Library screen's own header")
    func settingsHasAnEntryPoint() throws {
        let library = try SourceTree.read("MangaBaka/Features/Library/LibraryView.swift")
        #expect(library.contains("onOpenSettings"))
        #expect(library.contains("gearshape"))
        #expect(library.contains("accessibilityLabel(\"Settings\")"))

        let root = try SourceTree.read("MangaBaka/App/RootView.swift")
        #expect(root.contains("onOpenSettings: { showsSettings = true }"))
        #expect(root.contains("SettingsView("))
    }

    /// Every other route into Settings goes through a screen that has to exist.
    @Test("Onboarding's account route still lands on Settings")
    func onboardingRouteSurvives() throws {
        let root = try SourceTree.read("MangaBaka/App/RootView.swift")
        #expect(root.contains("selection = .library"))
        #expect(root.contains("showsSettings = true"))
    }

    /// The floating tab bar is the only chrome now. A second bar above it would
    /// reintroduce the stacked-header spacing that was just removed.
    @Test("No second top bar was reintroduced")
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
