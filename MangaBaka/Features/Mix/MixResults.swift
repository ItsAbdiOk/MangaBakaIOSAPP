import SwiftUI

/// The blend's output: a count line with a reshuffle, and a grid of covers each
/// carrying the reason it matched.
///
/// Its own file because MixView was at the lint's body-length ceiling.
struct MixResults: View {
    let model: MixModel
    @Binding var path: [Series]
    @Environment(\.zoomRoute) private var zoomRoute

    var body: some View {
        if model.isRunning {
            HStack {
                Spacer()
                ProgressView().tint(Palette.textTertiary)
                Spacer()
            }
            .padding(.top, Metrics.sectionGap)
        } else if let message = model.message {
            Text(message)
                .typeSmallMeta()
                .foregroundStyle(Palette.textMuted)
                .padding(.horizontal, Metrics.gutter)
        } else if !model.results.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(model.results.count) in the blend")
                        .typeSectionHeader()
                        .foregroundStyle(Palette.textPrimary)
                    Spacer(minLength: 0)
                    Button { Task { await model.run() } } label: {
                        Text("Reshuffle")
                            .typeInstruction()
                            .foregroundStyle(Palette.accent)
                    }
                    .buttonStyle(.press)
                }
                .padding(.horizontal, 2)
                .padding(.bottom, 12)

                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(.flexible(), spacing: Metrics.gapCovers),
                        count: 3
                    ),
                    alignment: .leading,
                    spacing: 16
                ) {
                    ForEach(model.results) { recommendation in
                        Button {
                            zoomRoute?.source = ZoomRoute.id("mix", recommendation.series.id)
                            path.append(recommendation.series)
                        } label: {
                            card(recommendation)
                        }
                        .buttonStyle(.press)
                        .zoomSource("mix", recommendation.series.id)
                    }
                }
            }
            .padding(.horizontal, Metrics.gutter)
        }
    }

    /// The mockup puts the reason in the accent under each cover, where a
    /// rating would normally sit — in a blend, why it matched IS the metadata.
    private func card(_ recommendation: Recommendation) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            CoverImage(
                cover: recommendation.series.cover,
                width: 111,
                radius: Metrics.radiusCoverGrid,
                accessibilityText: recommendation.series.displayTitle ?? "Untitled series"
            )
            Text(recommendation.series.displayTitle ?? "Untitled series")
                .typeCardTitle()
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 7)
            if let reason = recommendation.reason {
                Text(reason)
                    .typeGridMeta()
                    .foregroundStyle(Palette.accent)
                    .lineLimit(1)
                    .padding(.top, 2)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            [recommendation.series.displayTitle ?? "Untitled series", recommendation.reason]
                .compactMap { $0 }
                .joined(separator: ", ")
        )
        .accessibilityAddTraits(.isButton)
    }
}
