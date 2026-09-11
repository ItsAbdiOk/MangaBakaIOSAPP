import SwiftUI

/// Nothing to show, for a reason that is not a failure.
///
/// Distinct from `FailureState` on purpose. An empty shelf and a failed request
/// look similar and mean opposite things: one is the app working correctly and
/// telling the truth, the other is something broken. Dressing an empty state in
/// error clothing teaches readers to distrust the app, and dressing an error as
/// "nothing here" hides a problem.
///
/// **No mark.** The failure family leads with a glyph in a rounded square; this
/// one deliberately does not. The mark is what says *something is wrong*, and
/// nothing here is. That single difference is what lets a reader tell the two
/// apart before reading a word.
///
/// The action's weight carries the rest of the meaning, and the design board is
/// strict about it: an invitation gets a filled button, a dead end gets a way
/// out, and a finished thing gets neither.
struct EmptyState: View {
    let title: String
    let message: String
    /// The way out, when there is one.
    var actionTitle: String?
    var actionWeight: StateAction.Weight = .fixes
    var action: (() -> Void)?
    /// A second, quieter way out. "Clear filters" beside "search for this
    /// instead" — two different doors out of the same dead end.
    var secondaryTitle: String?
    var secondaryAction: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .typeSubsectionHeader()
                .foregroundStyle(Palette.textPrimary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Text(message)
                .typeSubtitle()
                .foregroundStyle(Palette.textMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)

            if let actionTitle, let action {
                StateAction(title: actionTitle, weight: actionWeight, action: action)
                    .padding(.top, 18)
            }

            if let secondaryTitle, let secondaryAction {
                StateAction(title: secondaryTitle, weight: .aside, action: secondaryAction)
                    .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 36)
        .padding(.vertical, 44)
        .accessibilityElement(children: .contain)
    }
}
