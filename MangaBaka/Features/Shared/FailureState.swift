import SwiftUI

/// A whole-screen failure, shown only when there is genuinely nothing to
/// display. Anywhere content exists, the content wins and the reason becomes a
/// `StaleBar` instead.
///
/// Six causes, one skeleton: mark, headline, one line of cause, one action.
/// What changes between them is the action, never the furniture — a reader who
/// meets two of these in a row should recognise the second immediately rather
/// than reading it as a different kind of wrong.
struct FailureState: View {
    let error: APIError
    var retry: (() async -> Void)?
    /// Where "Open Settings" goes. Absent on screens that cannot present it,
    /// in which case the account failure falls back to a retry.
    var openSettings: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            StateMark(symbol: error.symbolName)
                .padding(.bottom, 20)

            Text(error.headline)
                .typeSubsectionHeader()
                .foregroundStyle(Palette.textPrimary)
                .multilineTextAlignment(.center)

            Text(error.userFacingMessage)
                .typeSubtitle()
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 25)

            // The live half of a rate limit. Bold and attached to the body
            // rather than to the button, because it is a fact about the wait
            // and not a label for the tap.
            if let countdown = error.countdown {
                Text(countdown)
                    .typeSubtitle()
                    .fontWeight(.semibold)
                    .foregroundStyle(Palette.textPrimary)
                    .padding(.top, 6)
            }

            action
                .padding(.top, 23)
        }
        .frame(maxWidth: 280)
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    /// One button, and only one of the six gets the accent.
    ///
    /// The rule is the board's: an accent fill means tapping this fixes the
    /// problem. Connecting an account does. Retrying does not fix being
    /// offline or a server having a bad day — it just asks again.
    ///
    /// The board's own offline frame draws an accent-filled "Try again", which
    /// contradicts the rule it states two panels later. The rule wins; a
    /// rendering is easier to get wrong than a sentence.
    @ViewBuilder
    private var action: some View {
        if error.needsAccount, let openSettings {
            StateAction(title: "Open Settings", weight: .fixes, action: openSettings)
        } else if let retry {
            StateAction(
                title: error.countdown == nil ? "Try again" : "Retry now",
                weight: .wayOut
            ) {
                Task { await retry() }
            }
        }
    }
}

/// Good content, failed refresh.
///
/// **Not an error screen, and the whole point is that it is not.** The app
/// frequently has perfectly good content and a refresh that did not land, and
/// until this existed that was silent — yesterday's covers with nothing saying
/// they were yesterday's. The content stays the hero and this states its age.
///
/// Amber rather than the accent, and only as a dot. The accent means "tap me";
/// this is a fact with an optional action. The bar's fill is the ordinary card
/// grey, because a wash of amber across the top of a working screen reads as a
/// warning about the content itself.
struct StaleBar: View {
    let headline: String
    let detail: String
    var retry: (() async -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(Palette.stale)
                .frame(width: 8, height: 8)
                // Aligned to the first line's centre rather than the block's,
                // so it reads as a bullet on the fact rather than a decoration
                // floating beside two lines.
                .padding(.top, 5)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(headline)
                    .typeRowTitle()
                    .foregroundStyle(Palette.textPrimary)
                Text(detail)
                    .typeSmallMeta()
                    .foregroundStyle(Palette.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let retry {
                StateAction(title: "Retry", weight: .aside) { Task { await retry() } }
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .background(Palette.surface, in: RoundedRectangle(
            cornerRadius: Metrics.radiusCard, style: .continuous
        ))
        .hairlineBorder(Palette.border, radius: Metrics.radiusCard)
        .padding(.horizontal, Metrics.gutter)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(headline). \(detail)")
    }
}
