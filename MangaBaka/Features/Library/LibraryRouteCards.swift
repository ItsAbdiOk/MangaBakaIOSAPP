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
                        .foregroundStyle(Palette.textMuted)
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

    /// The year, which is a different question from "your reading".
    ///
    /// `Your reading` answers what is waiting and what you drop — it is about
    /// the state of the library now. This is about the reader: what they
    /// finished, what they read faster than anything else, and the tags that
    /// are theirs rather than the database's.
    var wrappedCard: some View {
        Button(action: onOpenWrapped) {
            routeRow(
                symbol: "sparkles",
                title: "Your year",
                subtitle: "What you finished, and what makes your library yours"
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Metrics.gutter)
        .padding(.top, 10)
    }

    private func routeRow(symbol: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Palette.textPrimary)
                .frame(width: 34, height: 34)
                .background(Palette.surfacePill, in: RoundedRectangle(
                    cornerRadius: 11, style: .continuous
                ))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .typeRowTitle()
                    .foregroundStyle(Palette.textPrimary)
                Text(subtitle)
                    .typeSmallMeta()
                    .foregroundStyle(Palette.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.textMuted)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 13)
        .background(Palette.surface, in: RoundedRectangle(
            cornerRadius: Metrics.radiusCard, style: .continuous
        ))
        .hairlineBorder(Palette.border, radius: Metrics.radiusCard)
        .contentShape(RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous))
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
                    Text("Your reading")
                        .typeRowTitle()
                        .foregroundStyle(Palette.textPrimary)
                    Text("What is waiting, what you finish, what you drop")
                        .typeSmallMeta()
                        .foregroundStyle(Palette.textMuted)
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
