import Foundation
import Testing
import AppIntents
@testable import MangaBaka

/// "Add <series> to my library, as <status>."
///
/// `perform()` itself is not exercised here: it needs a live `AppServices`
/// (Keychain, `APIClient`, a real database) and no test in this codebase
/// builds one — `DueThisWeekIntentTests` does not exist either, only the
/// free-function half (`DueThisWeekTests`) is. What's testable without that
/// is pinned instead: the status labels Shortcuts shows, and the exact
/// no-token dialog `perform()` returns before it ever reaches a write.
@Suite("Add to library")
struct AddToLibraryIntentTests {
    /// Expected to fail before `LibraryEntry.State: AppEnum` existed with:
    /// `Type 'LibraryEntry.State' does not conform to protocol 'AppEnum'` —
    /// `@Parameter var status: LibraryEntry.State` could not compile at all.
    @Test("Every status has a Shortcuts label matching its own UI title")
    func statusMapping() {
        for state in LibraryEntry.State.allCases {
            let shown = LibraryEntry.State.caseDisplayRepresentations[state]
            #expect(shown != nil, Comment(rawValue: state.rawValue))
            #expect(shown?.title == LocalizedStringResource(stringLiteral: state.title))
        }
    }

    /// Expected to fail before `AddToLibraryIntent.noAccountDialog` existed
    /// with: `Cannot find 'noAccountDialog' in scope` — the message lived
    /// only as an inline literal inside `perform()`, unreachable without a
    /// real `AppServices`.
    @Test("No token says so, in words a reader can act on")
    func noTokenDialog() {
        #expect(AddToLibraryIntent.noAccountDialog == "Sign in to MangaBaka in Settings first.")
        // Names where to go ("Settings"), not the technical 401 an
        // unauthenticated write would otherwise surface — see
        // `AddToLibraryIntent.perform()`'s own comment on `hasCredentials`.
        #expect(AddToLibraryIntent.noAccountDialog.contains("Settings"))
    }

    @Test("The success line names both the series and the status chosen")
    func addedDialog() {
        let line = AddToLibraryIntent.addedDialog(title: "Solo Leveling", status: .reading)
        #expect(line == "Added Solo Leveling as Reading.")
    }
}
