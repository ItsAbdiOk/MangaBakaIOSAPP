import SwiftUI

/// The hero's action row — add to library, use as seed — out of the main
/// file for the lint's file-length ceiling (2026-09-15).
extension SeriesDetailView {
    /// The mockup pairs the primary action with "Use as seed", which is the
    /// only place in the app that sends a specific series into a blend from the
    /// screen where you decided you liked it.
    var actions: some View {
        // Side by side normally; stacked at accessibility text sizes, where
        // two fixed-height buttons sharing a row truncated into "Add to li…"
        // and "Use as…" — both unreadable, and the primary action of the page
        // among them.
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: Metrics.gapStrip) {
                    libraryAction
                    seedAction
                }
                .padding(.leading, Metrics.gutter)
            } else {
                HStack(spacing: Metrics.gapStrip) {
                    libraryAction
                        .padding(.leading, Metrics.gutter)
                    seedAction
                }
            }
        }
        .padding(.trailing, Metrics.gutter)
    }

    private var libraryAction: some View {
        LibraryControl(series: shown, library: library, store: libraryStore)
    }

    @ViewBuilder
    private var seedAction: some View {
        if onUseAsSeed != nil {
            Button { onUseAsSeed?(shown) } label: {
                Text("Use as seed")
                    .typeChip()
                    .lineLimit(1)
                    .padding(.horizontal, 16)
                    // minHeight, not height: at accessibility text sizes a
                    // fixed 52pt button clips its own label.
                    .frame(minHeight: Metrics.ctaPrimary)
                    .foregroundStyle(Palette.textPrimary)
                    .background(
                        Palette.surfaceChip,
                        in: RoundedRectangle(
                            cornerRadius: Metrics.radiusCard, style: .continuous
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous)
                            .strokeBorder(Palette.border, lineWidth: 0.5)
                    )
            }
            .buttonStyle(.press)
            .accessibilityHint("Adds this series to the Mix and opens it")
        }
    }
}
