import SwiftUI

/// What everyone else here has been doing, and where the reader sits in it.
///
/// MangaBaka is a community-maintained database and nothing in the app said
/// so. This is the one surface that does — and it is built around the reader
/// rather than as a dashboard, because 53,975,689 says nothing on its own and
/// "4,210 of them are yours" turns it into a place you are standing in.
///
/// Moderation figures are deliberately absent. The endpoint carries edit
/// counts and duplicate-set reviews; a contribution leaderboard on a screen
/// nobody contributes from is vanity, and Abdi said so plainly.
struct CommunityPulseCard: View {
    let pulse: CommunityPulse
    /// The reader's own chapters, where the app knows them.
    let chaptersRead: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Eyebrow(text: "This week on MangaBaka")

            VStack(alignment: .leading, spacing: 14) {
                ForEach(pulse.figures) { figure in
                    row(figure)
                }
            }
            .padding(.top, 14)

            if let share = pulse.readerShare(chaptersRead: chaptersRead) {
                Text(share)
                    .typeSmallMeta()
                    .foregroundStyle(Palette.accent)
                    .padding(.top, 14)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(15)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .hairlineBorder(Palette.border, radius: 18)
        .padding(.horizontal, Metrics.gutter)
        // One element: VoiceOver should read this as a paragraph about the
        // place, not as nine fragments.
        .accessibilityElement(children: .combine)
    }

    private func row(_ figure: CommunityPulse.Figure) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(figure.value)
                .countsNotCuts()
                .typeSectionHeader()
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            VStack(alignment: .leading, spacing: 1) {
                Text(figure.label)
                    .typeSmallMeta()
                    .foregroundStyle(Palette.textMuted)
                if let change = figure.change {
                    Text(change)
                        .typeGridMeta()
                        .foregroundStyle(Palette.positive)
                }
            }
            Spacer(minLength: 0)
        }
    }
}
