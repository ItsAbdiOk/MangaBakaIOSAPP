import SwiftUI

/// "Retrying in 38 s" that actually counts down, instead of a string frozen
/// at the instant the error was read.
///
/// `FailureState` used to compute `error.countdown` once, at render time, and
/// never again — a reader looking at "Retrying in 30 s" thirty seconds later
/// still saw "Retrying in 30 s" (gap 24). `TimelineView(.periodic(by: 1))`
/// re-evaluates this view's content once a second for as long as it's on
/// screen, so the number is always the true distance to `until`, not the one
/// true when the screen first drew.
struct Countdown: View {
    let until: Date
    /// Called once, the first time this view notices `until` has passed.
    /// Lives here rather than in a caller's own `onChange`, because only
    /// `TimelineView`'s periodic re-render actually re-evaluates "has it
    /// passed yet" once a second — a caller watching its own, separately
    /// computed snapshot of that fact would only see it change when
    /// something else happened to redraw that caller.
    var onReachZero: (() -> Void)?

    /// Guards `onReachZero` firing more than once: the tick after the
    /// deadline passes still reads "reached", and the one after that, for as
    /// long as this view stays on screen.
    @State private var hasFired = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = until.timeIntervalSince(context.date)
            Text(text(for: remaining))
                .onChange(of: hasReached(remaining)) { _, reached in
                    guard reached, !hasFired else { return }
                    hasFired = true
                    onReachZero?()
                }
        }
    }

    private func hasReached(_ remaining: TimeInterval) -> Bool {
        !remaining.isFinite || remaining <= 0
    }

    private func text(for remaining: TimeInterval) -> String {
        guard remaining.isFinite, remaining > 0 else { return "Retrying now…" }
        if remaining < 60 {
            let seconds = max(Int(remaining.rounded()), 1)
            return "Retrying in \(seconds) s"
        }
        let minutes = max(Int((remaining / 60).rounded()), 1)
        return "Retrying in \(minutes) min"
    }
}
