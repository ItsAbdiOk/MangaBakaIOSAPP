import SwiftUI

/// Every other name this series goes by.
///
/// A series carries one title per language — 25 of them on Solo Leveling,
/// verified live on 2026-09-11 — and the app showed exactly one. The website
/// offers "Show 36 more titles" and we offered none, which matters more than
/// it sounds: a reader who knows a series as "Ore Dake Level-Up na Ken" or
/// "나 혼자만 레벨업" has no way to confirm from this page that they are
/// looking at the same book.
///
/// Folded by default. This is a reference list, not something to read on the
/// way past.
struct AlternativeTitles: View {
    let titles: [SeriesTitle]
    /// The one already on screen, which should not be repeated.
    let shown: String?

    @State private var isExpanded = false

    /// Everything except the title the page is already showing.
    /// The gathering lives on `SeriesTitle` so it can be tested.
    private var others: [SeriesTitle.Alternative] {
        SeriesTitle.alternatives(in: titles, excluding: shown)
    }

    var body: some View {
        let rows = others
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    Motion.run(.snappy(duration: 0.22)) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        Text("Also known as")
                            .typeDetailSectionHeader()
                            .foregroundStyle(Palette.textPrimary)
                        Text("\(rows.count)")
                            .typeChip()
                            .foregroundStyle(Palette.textMuted)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Palette.textMuted)
                            .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    }
                    .frame(minHeight: Metrics.tapTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Also known as, \(rows.count) other titles")
                .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")

                if isExpanded {
                    VStack(spacing: 0) {
                        ForEach(rows) { row in
                            titleRow(row)
                            if row.id != rows.last?.id {
                                Rectangle()
                                    .fill(Palette.hairline)
                                    .frame(height: 0.5)
                                    .padding(.leading, 14)
                            }
                        }
                    }
                    .background(Palette.surface, in: RoundedRectangle(
                        cornerRadius: Metrics.radiusCard, style: .continuous
                    ))
                    .hairlineBorder(Palette.border, radius: Metrics.radiusCard)
                }
            }
            .padding(.horizontal, Metrics.gutter)
        }
    }

    /// Each row copies its own title on tap.
    ///
    /// The reason to look at this list at all is usually to take one of these
    /// somewhere else — a search, a message, a reading site — and holding a
    /// line of text to select it inside a scroll view is a fight.
    private func titleRow(_ row: SeriesTitle.Alternative) -> some View {
        Button {
            UIPasteboard.general.string = row.title
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(row.title)
                    .typeBody()
                    .foregroundStyle(Palette.textPrimary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Text(row.languageLabel)
                    .typeGridMeta()
                    .foregroundStyle(Palette.textMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(minHeight: Metrics.tapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(row.title), \(row.languageLabel)")
        .accessibilityHint("Copies this title")
    }
}
