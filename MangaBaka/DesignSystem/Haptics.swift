import SwiftUI

/// The rule for haptics in this app: **a haptic marks a state change the
/// reader caused.** Not a tap — a tap is its own feedback — but a
/// consequence: the list beneath a chip changed, a card committed, a copy
/// landed, a switch moved.
///
/// Two corollaries. Nothing here fires for anything the reader did not do —
/// a background refresh is a phone buzzing in a pocket for no reason. And
/// everything goes through `.sensoryFeedback`, which is tied to a value
/// change: it cannot fire twice for one event, cannot fire during a body
/// pass, and honours the system's own haptics setting. Three sites used to
/// call `UIImpactFeedbackGenerator` directly from a button action; those
/// are the ones this replaces.
///
/// The vocabulary, so the same event feels the same everywhere:
///
/// - `.selection` — a choice changed: a tab, a chip, a star, a switch, a seed.
/// - `.impact(weight: .light)` — something small landed: a copy.
/// - `.impact(flexibility: .soft)` — something settled back or ran out: a
///   cancelled swipe, the end of a feed.
/// - `.impact(weight: .medium)` — a commitment: a card thrown.
/// - `.impact(flexibility: .rigid)` — a whole list is new: a refresh landed.
/// - `.success` / `.error` — a write to the reader's real data, and its
///   failure. Already in `LibraryControl` and the toast.
enum Haptics {
    static let selection: SensoryFeedback = .selection
    static let copied: SensoryFeedback = .impact(weight: .light)
    static let settled: SensoryFeedback = .impact(flexibility: .soft)
    static let committed: SensoryFeedback = .impact(weight: .medium)
    static let refreshed: SensoryFeedback = .impact(flexibility: .rigid)
    /// A unit changed under the reader's finger — +1 chapter, a pip moving —
    /// distinct from `.selection` (a pick) even though both are light: this
    /// one repeats as a value climbs, `.selection` marks a single choice.
    static let tick: SensoryFeedback = .increase
    /// A reward: saved, completed. Pairs with `Motion.celebrate`.
    static let success: SensoryFeedback = .success
    /// Something the reader should notice went wrong without it being a
    /// hard failure — the `.error` of the two write-outcome feedbacks is for
    /// an actual failed write.
    static let warning: SensoryFeedback = .warning
}

extension View {
    /// Fires `feedback` each time `count` increases. For events that have no
    /// value of their own to watch — a copy, a cancelled swipe — the caller
    /// keeps a counter and bumps it.
    func haptic(_ feedback: SensoryFeedback, onEach count: Int) -> some View {
        sensoryFeedback(feedback, trigger: count) { old, new in new > old }
    }

    /// Fires `feedback` on any change to `trigger`, not just an increase —
    /// for triggers with no direction (a toggle, an enum case, a one-shot
    /// counter bumped once per gesture in `PressStyle`).
    func haptic(_ feedback: SensoryFeedback, on trigger: some Equatable) -> some View {
        sensoryFeedback(feedback, trigger: trigger)
    }
}
