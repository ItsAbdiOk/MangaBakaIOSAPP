import Foundation
import Testing
import Translation
@testable import MangaBaka

/// The gate that stops the Translation framework raising system UI from inside
/// a sheet. See `TranslationGate`.
///
/// TestFlight build 64 crashed on iOS 26.6.2 with
/// `-[_UISceneHostingController _setSheetConfiguration:]: unrecognized
/// selector`, from `_tryToConnectToRemoteSheet:` — a system sheet being
/// presented on top of the app's own character sheet.
@Suite("Translation gate")
struct TranslationGateTests {
    /// The regression. `.supported` means the pair exists but is NOT
    /// downloaded, which is exactly the state that makes the system show its
    /// download prompt. The old gate was `!= .unsupported`, which let it pass.
    @Test("Supported-but-not-installed is refused, because it is the crash case")
    func supportedIsRefused() {
        #expect(!TranslationGate.allows(.supported))
    }

    /// The control: the gate is not simply refusing everything. An installed
    /// pack translates with no system UI at all, which is the whole point.
    @Test("An installed pack is allowed")
    func installedIsAllowed() {
        #expect(TranslationGate.allows(.installed))
    }

    @Test("An unsupported pair is refused, as it always was")
    func unsupportedIsRefused() {
        #expect(!TranslationGate.allows(.unsupported))
    }
}
