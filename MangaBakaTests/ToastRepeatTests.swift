import Foundation
import Testing
@testable import MangaBaka

/// Two identical toasts are two confirmations.
///
/// The haptic, the transition and the capsule's identity were all keyed on
/// `ToastCentre.message`, a `String?`. Saving one series and then saving
/// another both post "Saved", so the second toast changed nothing SwiftUI
/// could see: no haptic, no animation, and — because the overlay never
/// re-entered — a reader watching the screen had no way to tell the second
/// save from a tap that missed. `revision` is the thing that actually changes.
@Suite("A repeated toast is a new toast")
@MainActor
struct ToastRepeatTests {
    /// Expected to fail before the fix with: "value of type 'ToastCentre' has
    /// no member 'revision'". There was nothing on the centre that a second
    /// identical message moved.
    @Test("Two identical messages are two toasts")
    func repeatedMessageIncrementsRevision() {
        let centre = ToastCentre()
        #expect(centre.revision == 0)
        centre.show("Saved")
        centre.show("Saved")
        #expect(centre.revision == 2)
        // The message is unchanged, which is exactly why it could not be the
        // trigger.
        #expect(centre.message == "Saved")
    }

    /// A failure holds the floor for `failureDuration` and a success arriving
    /// inside that window is dropped. A dropped toast shows nothing, so it
    /// must also buzz nothing — the increment belongs after that guard, not
    /// before it.
    @Test("A suppressed success does not count as a toast")
    func suppressedSuccessDoesNotIncrement() {
        let centre = ToastCentre()
        centre.show("Couldn't save", kind: .failure)
        #expect(centre.revision == 1)
        centre.show("Saved")
        #expect(centre.revision == 1)
        #expect(centre.message == "Couldn't save")
    }

    /// A second failure, or anything the reader triggered deliberately, still
    /// replaces the one on screen — and that is a new toast.
    @Test("A second failure replaces the first and counts")
    func secondFailureReplacesAndCounts() {
        let centre = ToastCentre()
        centre.show("Couldn't save", kind: .failure)
        centre.show("Couldn't save", kind: .failure)
        #expect(centre.revision == 2)
    }

    /// Dismissing clears the capsule without pretending a toast was shown.
    @Test("A swipe-away does not invent a toast")
    func dismissDoesNotIncrement() {
        let centre = ToastCentre()
        centre.show("Saved")
        centre.dismiss()
        #expect(centre.revision == 1)
        #expect(centre.message == nil)
    }
}
