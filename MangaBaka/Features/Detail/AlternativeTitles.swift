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
/// It lives in the hero, under the byline, because that is where a reader
/// looking for a name they recognise will look — the question "is this the
/// same book?" is asked on arrival, not two screens down. One line with a
/// count, opening a sheet: the list is a reference, not something to read on
/// the way past, and inlining twenty-five names would push the synopsis off
/// the screen.
/// The line in the hero. One tap, one sheet.
struct AlternativeTitlesButton: View {
    let titles: [SeriesTitle]
    /// The one already on screen, which should not be counted or repeated.
    let shown: String?

    @State private var isOpen = false

    private var others: [SeriesTitle.Alternative] {
        SeriesTitle.alternatives(in: titles, excluding: shown)
    }

    var body: some View {
        let rows = others
        if !rows.isEmpty {
            Button { isOpen = true } label: {
                HStack(spacing: 5) {
                    Text("Also known as")
                        .typeSmallMeta()
                    Text("\(rows.count)")
                        .typeGridMeta()
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Palette.surfaceChip, in: Capsule())
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(Palette.textMuted)
                .frame(minHeight: Metrics.tapTarget, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.press)
            .accessibilityLabel("Also known as, \(rows.count) other titles")
            .accessibilityHint("Opens the full list")
            .sheet(isPresented: $isOpen) {
                AlternativeTitlesSheet(rows: rows)
                    .presentationDetents([.medium, .large])
                    .presentationCornerRadius(Metrics.radiusSheet)
            }
        }
    }
}

/// Every other name, in the API's own order.
struct AlternativeTitlesSheet: View {
    let rows: [SeriesTitle.Alternative]

    @Environment(\.dismiss) private var dismiss
    /// Bumped per copy, for the haptic; see `Haptics`.
    @State private var copies = 0

    var body: some View {
        NavigationStack {
            ScrollView {
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
                .padding(.horizontal, Metrics.gutter)
                .padding(.top, 12)
                .padding(.bottom, 40)
            }
            .scrollIndicators(.hidden)
            .background(Palette.ground)
            .navigationTitle("Also known as")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.foregroundStyle(Palette.accent)
                }
            }
        }
        .preferredColorScheme(.dark)
        .edgeSwipeToDismiss()
    }

    /// Each row copies its own title on tap.
    ///
    /// The reason to open this list at all is usually to take one of these
    /// somewhere else — a search, a message, a reading site — and holding a
    /// line of text to select it inside a scroll view is a fight.
    private func titleRow(_ row: SeriesTitle.Alternative) -> some View {
        Button {
            UIPasteboard.general.string = row.title
            copies += 1
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
                    .multilineTextAlignment(.trailing)
                // Last, in a fixed column, so the flags line up down the
                // list whatever the length of the name beside them.
                Text(row.flags)
                    .typeGridMeta()
                    .frame(minWidth: Metrics.flagColumn, alignment: .trailing)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(minHeight: Metrics.tapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.press)
        .haptic(Haptics.copied, onEach: copies)
        .accessibilityLabel("\(row.title), \(row.languageLabel)")
        .accessibilityHint("Copies this title")
    }
}
