import SwiftUI

/// One shelf, as a card: name, count, a strip of covers, and a line saying what
/// the shelf actually is.
struct ShelfCard: View {
    let shelf: LibraryModel.Shelf

    /// Dropped is tinted a step brighter and its covers dimmed. It is the
    /// largest shelf on a real library — 46% — so it earns its own weight
    /// rather than being tucked away, but its covers are things the reader
    /// walked away from.
    private var isDropped: Bool { shelf.state == .dropped }

    private var countColour: Color {
        isDropped ? Palette.textEmphasis : Palette.textSecondary
    }

    private var shelfName: some View {
        Text(shelf.label)
            .typeSubsectionHeader()
            .foregroundStyle(Palette.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Palette.textQuaternary)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            // Side by side until they no longer fit. Squeezed, the name broke
            // mid-word — "Complete" over a lone "d" — because the count and
            // chevron took their width first.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    shelfName
                    Text(shelf.count.formatted())
                        .typeStatNumber()
                        .foregroundStyle(countColour)
                    chevron
                }
                VStack(alignment: .leading, spacing: 4) {
                    shelfName
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(shelf.count.formatted())
                            .typeStatNumber()
                            .foregroundStyle(countColour)
                        chevron
                    }
                }
            }

            HStack(spacing: 7) {
                ForEach(shelf.covers) { series in
                    CoverImage(
                        cover: series.cover,
                        width: 54,
                        radius: Metrics.radiusThumb,
                        accessibilityText: ""
                    )
                    .accessibilityHidden(true)
                    .opacity(isDropped ? 0.78 : 1)
                    .frame(maxWidth: .infinity)
                }
            }
            .accessibilityHidden(true)

            Text(shelf.note)
                .typeFootnote()
                .foregroundStyle(Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 15)
        .padding(.top, 14)
        .padding(.bottom, 13)
        .background(
            isDropped ? Palette.surfaceChip : Palette.surfaceInset,
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .hairlineBorder(Palette.border, radius: 18)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(shelf.label), \(shelf.count) series")
    }
}
