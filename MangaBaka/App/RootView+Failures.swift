import SwiftUI

/// Two dead-tap fixes that did not belong inline in `RootView.body` — see
/// gaps 64 and 77 in `docs/reviews/FAILURES-SUMMARY.md` §6, batch 6. Their
/// own file for the same reason `RootView+Session.swift` exists: `RootView`
/// is at the lint's 250-line body cap, and both of these read as complete
/// ideas on their own rather than as one more line inline.
extension RootView {
    /// Gap 77: "Use as seed" used to call `mixModel?.addSeed(series)` and
    /// then unconditionally toast "Added to the mix" — so a tap landing
    /// before the Mix tab's own `.task` had built `mixModel` (reachable any
    /// time before that first runs) confirmed an addition that never
    /// happened, to a model that was never touched.
    func useAsSeedTapped(_ series: Series) {
        guard let mixModel else {
            toasts.show("Couldn't add that to the mix right now", kind: .failure)
            return
        }
        mixModel.addSeed(series)
        selection = .mix
        toasts.show("Added to the mix")
    }

    /// Gap 64: onboarding's "Connect an account" used to set `selection`,
    /// `wantsAccountFocus` and `showsSettings` synchronously, inside the same
    /// closure that also calls `onboarding.complete()` — which is what the
    /// `fullScreenCover` showing `OnboardingView` is keyed on to dismiss
    /// itself. Pushing a navigation destination and flipping tabs in the
    /// same turn SwiftUI is told to tear down a full-screen cover is a race
    /// this project could not pin to a specific device report, but the
    /// ordering it risks — Settings opening under a cover still animating
    /// away, or the push landing on whatever tab was showing before the
    /// cover appeared — is exactly the shape of the account-onboarding path
    /// nobody could reproduce on demand (see the "Unsure" section of this
    /// batch's report). Deferring the actual push to an `onChange` on the
    /// value the cover is keyed from means it only ever runs after SwiftUI
    /// has itself observed `hasCompleted` flip, in a later, separate update
    /// — never in the same one that asked for the cover to come down.
    func onboardingCompletionChanged(_ completed: Bool) {
        guard completed, wantsAccountAfterOnboarding else { return }
        wantsAccountAfterOnboarding = false
        selection = .library
        wantsAccountFocus = true
        showsSettings = true
    }
}
