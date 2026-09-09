import SwiftUI

/// Nothing to show, for a reason that is not a failure.
///
/// Distinct from `FailureState` on purpose. An empty shelf and a failed request
/// look similar and mean opposite things: one is the app working correctly and
/// telling the truth, the other is something broken. Dressing an empty state in
/// error clothing teaches readers to distrust the app, and dressing an error as
/// "nothing here" hides a problem.
///
/// Six screens each built their own version of this. One component means the
/// design can be settled once rather than six times.
struct EmptyState: View {
    let symbol: String
    let title: String
    let message: String
    /// The way out, when there is one. An empty state with no action is a dead
    /// end, so most of these carry one.
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Palette.textQuaternary)
                .accessibilityHidden(true)
                .padding(.bottom, 16)

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
                Button(action: action) {
                    Text(actionTitle)
                        .typeRowTitle()
                        .foregroundStyle(Palette.onAccent)
                        .padding(.horizontal, 20)
                        .frame(height: Metrics.ctaSecondary)
                        .background(Palette.accent, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 18)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 36)
        .padding(.vertical, 44)
        .accessibilityElement(children: .contain)
    }
}
