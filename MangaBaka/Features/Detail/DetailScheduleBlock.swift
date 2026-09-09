import SwiftUI

/// "ESTIMATED NEXT" at the top of the series page, as the mockup draws it.
///
/// Reuses `ScheduleRow`'s wording rather than restating it. The confidence pill
/// and the lateness are deliberately two separate things: a very regular series
/// can still be late, and that combination is the most informative thing this
/// block can say. Collapsing them once produced "LIKELY — expected 6 days ago",
/// a healthy pill on a late chapter.
struct DetailScheduleBlock: View {
    let estimate: Cadence
    let onOpen: (() -> Void)?

    var body: some View {
        Button { onOpen?() } label: { content }
            .buttonStyle(.plain)
            .disabled(onOpen == nil)
            .accessibilityElement(children: .combine)
            .accessibilityHint(onOpen == nil ? "" : "Opens the release schedule")
    }

    private var content: some View {
        let now = Date()
        let isLate = estimate.state(asOf: now) == .late

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                Text("Estimated next")
                    .typeEyebrow()
                    .foregroundStyle(Palette.textMuted)
                if onOpen != nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Palette.textQuaternary)
                }
            }

            HStack(spacing: 7) {
                Text(estimate.confidence.rawValue.uppercased())
                    .typeTabLabel()
                    .tracking(0.7)
                    .foregroundStyle(
                        estimate.confidence == .likely ? Palette.onAccent : Palette.textSecondary
                    )
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        estimate.confidence == .likely ? Palette.accent : Palette.surfaceChip,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                    )

                Text(ScheduleRow.stateText(estimate, isLate: isLate, now: now))
                    .typeRowTitle()
                    .foregroundStyle(isLate ? Palette.accent : Palette.textPrimary)
            }
            .padding(.top, 8)

            Text(ScheduleRow.cadenceLine(estimate))
                .typeSmallMeta()
                .foregroundStyle(Palette.textMuted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
