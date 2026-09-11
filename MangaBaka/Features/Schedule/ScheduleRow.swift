import SwiftUI

/// One work in the schedule.
///
/// Confidence and lateness are shown as separate things, deliberately. Merging
/// them shipped a real bug elsewhere — a single field that could read "overdue"
/// produced "LIKELY · expected 6 days ago", a healthy green pill on a late
/// chapter. A very regular series can be very late, and that pairing is the
/// most informative thing on the row.
struct ScheduleRow: View {
    let work: ScheduledWork
    let onOpen: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Metrics.gapCovers) {
            Button(action: onOpen) {
                CoverImage(
                    cover: work.series.cover,
                    width: Metrics.coverUpcomingThumb,
                    radius: Metrics.radiusThumb,
                    accessibilityText: work.series.displayTitle ?? "Untitled series"
                )
                .opacity(work.cadence == nil ? 0.55 : 1)
            }
            .buttonStyle(.press)

            VStack(alignment: .leading, spacing: 6) {
                Text(work.series.displayTitle ?? "Untitled series")
                    .typeRowTitle()
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                if let cadence = work.cadence {
                    estimate(cadence)
                } else if let reason = work.reason {
                    Text(reason.explanation)
                        .typeChip()
                        .foregroundStyle(Palette.textMuted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 13)
        .overlay(alignment: .top) {
            Rectangle().fill(Palette.hairline).frame(height: 0.5)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func estimate(_ cadence: Cadence) -> some View {
        let now = Date()
        let isLate = cadence.state(asOf: now) == .late

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(cadence.confidence.rawValue.uppercased())
                    .typeTabLabel()
                    .tracking(0.7)
                    .foregroundStyle(
                        cadence.confidence == .likely ? Palette.onAccent : Palette.textSecondary
                    )
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        cadence.confidence == .likely ? Palette.accent : Palette.surfaceChip,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                    )

                Text(Self.stateText(cadence, isLate: isLate, now: now))
                    .typeChip()
                    .foregroundStyle(isLate ? Palette.accent : Palette.textPrimary)
            }

            Text(Self.cadenceLine(cadence))
                .typeSmallMeta()
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(Self.provenance(cadence))
                .typeFootnote()
                .foregroundStyle(Palette.textMuted)
        }
    }

    static func stateText(_ cadence: Cadence, isLate: Bool, now: Date) -> String {
        let days = abs(cadence.overdueDays(asOf: now))
        if isLate {
            if days > 365 { return "\(days / 365) year\(days / 365 == 1 ? "" : "s") overdue" }
            return days == 0 ? "Due today" : "\(days) day\(days == 1 ? "" : "s") overdue"
        }
        if days == 0 { return "Due today" }
        return "Due in \(days) day\(days == 1 ? "" : "s")"
    }

    /// "About every 7 days, give or take 1."
    static func cadenceLine(_ cadence: Cadence) -> String {
        let gap = "About every \(cadence.medianGapDays) day\(cadence.medianGapDays == 1 ? "" : "s")"
        let rhythm = cadence.spreadDays == 0
            ? "\(gap), very evenly"
            : "\(gap), give or take \(cadence.spreadDays)"
        // The season leads where there is one: for a series on its third
        // season, "chapter 235" means nothing without it — the numbering
        // started again twice.
        guard let season = cadence.season else { return rhythm }
        return "Season \(season) · \(rhythm.lowercased())"
    }

    /// Where the number came from. An estimate that will not say what it was
    /// built from is asking to be trusted rather than checked.
    ///
    /// The number is the one the median was taken over. It used to say
    /// "From 14 releases" for a series with 40 releases on 14 days and 13 gaps
    /// between them — wrong in both directions depending on which question
    /// the reader thought they were asking.
    static func provenance(_ cadence: Cadence) -> String {
        let last = cadence.lastRelease.formatted(.dateTime.day().month(.abbreviated).year())
        let evidence = cadence.gaps.map { "\($0) gaps between releases" }
            ?? "\(cadence.samples) release days"
        return "From \(evidence) on MangaUpdates · last \(last)"
    }
}
