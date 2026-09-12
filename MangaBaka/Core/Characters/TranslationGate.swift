import Foundation
import Translation

/// Whether a character description may be translated right now.
///
/// **This exists because of a crash, not a preference.** TestFlight build 64
/// died on iPhone 17,1 / iOS 26.6.2 with
/// `-[_UISceneHostingController _setSheetConfiguration:]: unrecognized
/// selector`, thrown from `-[UISheetPresentationController
/// _tryToConnectToRemoteSheet:]`. A "remote sheet" is system UI hosted out of
/// process, and the only thing in this app that presents any is the
/// Translation framework's language-pack download prompt. `CharacterProfileView`
/// is itself presented in a `.sheet`, so that prompt is a system sheet opening
/// on top of an app sheet — and UIKit aborts rather than presenting it.
///
/// The gate used to be `status != .unsupported`, which let `.supported`
/// through. `.supported` means precisely "this pair exists but is NOT
/// downloaded" — the one state that makes the system prompt appear. Only
/// `.installed` can be translated without any system UI at all.
///
/// The cost is real and worth stating: a reader who has never downloaded the
/// ru→en pack now sees no description instead of being asked to fetch one.
/// That is the behaviour the profile already had for every other failure —
/// "the description stays dropped" — and a missing paragraph beats a
/// terminated app. Offering the download from somewhere that is not inside a
/// sheet is the proper fix and is not built yet.
enum TranslationGate {
    /// Whether translation may proceed for a language-pair status.
    ///
    /// Written as a pure function over the status so it can be tested: the
    /// availability call itself is a system API with no seam.
    static func allows(_ status: LanguageAvailability.Status) -> Bool {
        switch status {
        case .installed:
            true
        // Supported-but-not-installed is the crash case: asking for a session
        // here is what raises the download prompt.
        case .supported:
            false
        case .unsupported:
            false
        @unknown default:
            // A status this build has never heard of might also prompt, and a
            // missing description is the recoverable outcome.
            false
        }
    }
}
