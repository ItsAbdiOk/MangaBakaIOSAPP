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

/// The grid a screen shows before its covers arrive.
///
/// Skeletons in the real grid rather than a spinner, so the layout does not
/// jump when content lands — and per cover, BlurHash takes over the moment the
/// API's own placeholder is available. A centred spinner tells a reader
/// something is happening; this tells them what is about to be there.
struct CoverSkeletonRow: View {
    var count: Int = 4
    var width: CGFloat = Metrics.coverRowWidth

    var body: some View {
        HStack(alignment: .top, spacing: Metrics.gapCovers) {
            ForEach(0..<count, id: \.self) { index in
                VStack(alignment: .leading, spacing: 8) {
                    RoundedRectangle(cornerRadius: Metrics.radiusCoverRow, style: .continuous)
                        .fill(Palette.surface)
                        .frame(width: width, height: width / Metrics.coverAspect)

                    // Two bars, unequal, because a column of identical ones
                    // reads as a rendering artefact rather than as text about
                    // to arrive.
                    Capsule().fill(Palette.surface)
                        .frame(width: width * (index.isMultiple(of: 2) ? 0.82 : 0.66), height: 9)
                    Capsule().fill(Palette.surface)
                        .frame(width: width * 0.45, height: 8)
                }
            }
        }
        .padding(.horizontal, Metrics.gutter)
        .accessibilityHidden(true)
    }
}

/// The row at the foot of a list that is fetching its next page.
///
/// Never a full-screen state: there is already content above it, and replacing
/// that with a spinner throws away what the reader came for. It names the page
/// size deliberately — at 1,200 entries a reader deserves to know this takes
/// three rounds rather than watching an unexplained wait.
struct PaginationFooter: View {
    let pageSize: Int

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .tint(Palette.accent)
            Text("Loading \(pageSize) more")
                .typeSmallMeta()
                .foregroundStyle(Palette.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: Metrics.ctaSecondary)
        .background(Palette.surface, in: RoundedRectangle(
            cornerRadius: Metrics.radiusCard, style: .continuous
        ))
        .padding(.horizontal, Metrics.gutter)
        .accessibilityLabel("Loading \(pageSize) more")
    }
}
