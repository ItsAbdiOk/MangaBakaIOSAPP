import Foundation
import Testing
@testable import MangaBaka

/// What the account card can tell the reader about their stored token.
///
/// Most of Settings' fixes in this batch are wiring — a Keychain write
/// failure reads differently from a rejection, a stuck control gets a way
/// out, a check trusts its own recent answer — verified here where the logic
/// is a pure value (`TokenStatus`, `APIError.shortReason`) and against the
/// source itself (`SourceTree`) where it lives inside a SwiftUI view's
/// private methods and cannot be driven from outside without a much larger
/// refactor than this batch's remit covers. That split is called out
/// per-test below rather than left implicit.
@Suite("Token status")
struct TokenStatusTests {
    /// Gap 118: `.notStored` is a local storage failure, not a verdict from
    /// MangaBaka on the token — and `isRejection` is the one flag the rest
    /// of the screen (the card's border colour, its "Tokens are revoked…"
    /// copy) keys off to decide whether this is the reader's problem to fix
    /// by getting a new token.
    /// Expected to fail before the fix with: no such case, a compile error —
    /// `.notStored` did not exist and every write failure surfaced as
    /// `.failed("Could not save to the Keychain.")`, `isRejection == true`.
    @Test("A Keychain write failure is not a rejection")
    func notStoredIsNotARejection() {
        #expect(TokenStatus.notStored.isRejection == false)
        #expect(TokenStatus.failed("x").isRejection == true)
    }

    @Test("Every other status is unaffected by adding .notStored")
    func otherStatusesUnaffected() {
        #expect(TokenStatus.idle.isRejection == false)
        #expect(TokenStatus.checking.isRejection == false)
        #expect(TokenStatus.signedIn(nil).isRejection == false)
        #expect(TokenStatus.unverified("x").isRejection == false)
    }
}

/// Gap 119: the account card's "not checked yet" line used to embed
/// `error.userFacingMessage`, which is copy built to stand alone on a
/// full-screen failure ("Showing what was downloaded. Nothing new can load
/// until you're back.") and read as a mismatched sentence once glued after
/// "Saved on this phone but not checked yet:". `shortReason` is the phrase
/// built for that one cramped spot; it lives with its only caller in
/// `SettingsView.swift` rather than widening `APIError` itself.
@Suite("A short reason for a cramped line")
struct ShortReasonTests {
    /// Expected to fail before the fix with: no such member — `shortReason`
    /// did not exist and `RootView.validateStoredToken` passed
    /// `error.userFacingMessage` straight through instead.
    @Test("Offline gets its own short phrase, not the full failure paragraph")
    func offline() {
        #expect(APIError.offline.shortReason == "you're offline")
        #expect(!APIError.offline.shortReason.contains("Showing what was downloaded"))
    }

    @Test("Every other case still has a non-empty short reason")
    func everyCaseHasAReason() {
        let cases: [APIError] = [
            .rateLimited(until: nil),
            .cancelled,
            .server(status: 500, message: "", party: .mangaBaka),
            .decoding(underlying: "x"),
            .transport(underlying: "x")
        ]
        for error in cases {
            #expect(!error.shortReason.isEmpty)
        }
    }
}

/// The Settings screen's own wiring for gaps 90, 118, 119, 120, 121: these
/// live inside `private func save()`/`check()` and a `private var` on a
/// SwiftUI `View` struct, which cannot be called from outside without
/// exposing internals no other caller needs — so this checks the source
/// directly, the same way `SpotlightWiringTests` already does for
/// `RootView+Session.swift`.
@Suite("Settings wiring", .enabled(if: SourceTree.isAvailable))
struct SettingsWiringTests {
    @Test("A Keychain write failure sets .notStored, not .failed")
    func writeFailureIsNotStored() throws {
        let source = try SourceTree.read("MangaBaka/Features/Settings/SettingsView.swift")
        let save = try #require(source.range(of: "private func save() async {"))
        let check = try #require(source.range(of: "private func check() async {"))
        let body = String(source[save.upperBound..<check.lowerBound])
        #expect(body.contains("status = .notStored"))
        #expect(!body.contains(#"status = .failed("Could not save to the Keychain."#))
    }

    @Test("Replace hands control back to idle, which is what reveals the field")
    func replaceRestoresField() throws {
        let source = try SourceTree.read("MangaBaka/Features/Settings/AccountCard.swift")
        #expect(source.contains("onReplace()"))
        let settings = try SourceTree.read("MangaBaka/Features/Settings/SettingsView.swift")
        #expect(settings.contains("onReplace: { status = .idle }"))
    }

    @Test("Remove token is behind a confirmation naming what is lost")
    func removeTokenConfirms() throws {
        let source = try SourceTree.read("MangaBaka/Features/Settings/AccountCard.swift")
        #expect(source.contains("isConfirmingRemoval = true"))
        #expect(source.contains(".confirmDestructive("))
        #expect(source.contains("action: onRemove"))
    }

    @Test("A check less than an hour old is trusted rather than repeated")
    func recentCheckIsTrusted() throws {
        let source = try SourceTree.read("MangaBaka/Features/Settings/SettingsView.swift")
        #expect(source.contains("recentlyCheckedName()"))
        #expect(source.contains("recheckInterval: TimeInterval = 60 * 60"))
    }

    @Test("The switch and its accessibility value both read effectiveEnabled")
    func remindersSwitchReadsEffectiveEnabled() throws {
        let source = try SourceTree.read("MangaBaka/Features/Settings/RemindersSection.swift")
        #expect(source.contains("SwitchIndicator(isOn: reminders.effectiveEnabled)"))
        #expect(source.contains(".accessibilityValue(reminders.effectiveEnabled ? \"On\" : \"Off\")"))
        #expect(!source.contains("SwitchIndicator(isOn: reminders.isEnabled)"))
    }

    @Test("Clearing history toasts on a real failure instead of swallowing it")
    func historyClearToastsOnFailure() throws {
        let source = try SourceTree.read("MangaBaka/Features/Settings/HistorySection.swift")
        #expect(source.contains("toasts?.show(\"Couldn't clear the list\", kind: .failure)"))
        #expect(!source.contains("try? await history.clear()"))
    }
}
