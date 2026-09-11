import Foundation
import Testing
@testable import MangaBaka

/// The card that says what an update added: once per set of notes, never
/// on a fresh install.
@Suite("What's new")
@MainActor
struct WhatsNewTests {
    private func defaults() -> UserDefaults {
        let suite = "whatsnew-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test("Due after an update, until put away, then never for the same notes")
    func dueOnceAfterUpdate() {
        let store = defaults()
        let state = WhatsNewState(defaults: store)
        #expect(state.isDue(hasCompletedOnboarding: true))
        state.dismiss()
        #expect(!state.isDue(hasCompletedOnboarding: true))
        // A relaunch reads the same answer back.
        #expect(!WhatsNewState(defaults: store).isDue(hasCompletedOnboarding: true))
    }

    /// Nothing is new to someone who has not used the app. The current
    /// notes are marked seen quietly, so the card first appears on the
    /// update after this one.
    @Test("A fresh install never sees it, and is not shown it later either")
    func freshInstall() {
        let store = defaults()
        let state = WhatsNewState(defaults: store)
        #expect(!state.isDue(hasCompletedOnboarding: false))
        #expect(!WhatsNewState(defaults: store).isDue(hasCompletedOnboarding: true))
    }

    @Test("The notes have something to say")
    func notesExist() {
        #expect(!ReleaseNotes.current.id.isEmpty)
        #expect(!ReleaseNotes.current.items.isEmpty)
    }
}
