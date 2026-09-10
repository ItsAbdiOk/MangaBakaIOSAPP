import SwiftUI

/// The two cards that lead off the Library screen to somewhere else.
///
/// Split out of `LibraryView` for the lint's body-length ceiling. They are the
/// only route to the schedule and the taste screen, which is why they survived
/// a redesign that did not draw them.
extension LibraryView {
    /// The way into the schedule, carrying its own summary so the card says
    /// something rather than just pointing.
    var scheduleCard: some View {
        Button(action: onOpenSchedule) {
            HStack(spacing: 12) {
                Image(systemName: "calendar")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Palette.textPrimary)
                    .frame(width: 34, height: 34)
                    .background(Palette.surfacePill, in: RoundedRectangle(
                        cornerRadius: 11, style: .continuous
                    ))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Next chapters")
                        .typeRowTitle()
                        .foregroundStyle(Palette.textPrimary)
                    Text(scheduleSummary ?? "Estimate when each one is due")
                        .typeSmallMeta()
                        .foregroundStyle(Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.textQuaternary)
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 13)
            .background(Palette.surface, in: RoundedRectangle(
                cornerRadius: Metrics.radiusCard, style: .continuous
            ))
            .hairlineBorder(Palette.border, radius: Metrics.radiusCard)
            .contentShape(RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Metrics.gutter)
        .padding(.top, 22)
    }

    var tasteCard: some View {
        Button(action: onOpenTaste) {
            HStack(spacing: 12) {
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Palette.textPrimary)
                    .frame(width: 34, height: 34)
                    .background(Palette.surfacePill, in: RoundedRectangle(
                        cornerRadius: 11, style: .continuous
                    ))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Your taste")
                        .typeRowTitle()
                        .foregroundStyle(Palette.textPrimary)
                    Text("Counted from your own library")
                        .typeSmallMeta()
                        .foregroundStyle(Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.textQuaternary)
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 13)
            .background(Palette.surface, in: RoundedRectangle(
                cornerRadius: Metrics.radiusCard, style: .continuous
            ))
            .hairlineBorder(Palette.border, radius: Metrics.radiusCard)
            .contentShape(RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Metrics.gutter)
        .padding(.top, Metrics.gapCovers)
    }

}
