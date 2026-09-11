import SwiftUI

/// Everywhere a series page leads: explicit relationships first, then the two
/// recommendation rows.
///
/// Split out of `SeriesDetailView` because that type outgrew its length limit,
/// but they belong together anyway — they are one idea, three rows of covers,
/// and they share the placeholder and the empty-row rules.
struct DetailOnwardRows: View {
    let relationships: [SeriesRelationship]
    let similar: [Series]
    let alsoLike: [Series]
    let isLoading: Bool
    @Binding var path: [Series]
    @Environment(\.zoomRoute) private var zoomRoute

    var body: some View {
        relatedRow
        onwardRow("Similar", similar)
        onwardRow("Readers also like", alsoLike)
    }

    /// Sequels, prequels, spin-offs and source novels. The strongest onward
    /// path there is, because it is an explicit link rather than a guess.
    @ViewBuilder
    private var relatedRow: some View {
        if !relationships.isEmpty {
            VStack(alignment: .leading, spacing: 11) {
                Text("Related")
                    .typeDetailSectionHeader()
                    .foregroundStyle(Palette.textPrimary)
                    .padding(.horizontal, Metrics.gutter)

                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: Metrics.gapCovers) {
                        ForEach(relationships) { relation in
                            Button {
                                zoomRoute?.source = ZoomRoute.id("related", relation.series.id)
                                path.append(relation.series)
                            } label: {
                                CoverCard(
                                    series: relation.series,
                                    width: Metrics.coverDetailRowWidth,
                                    meta: relation.label
                                )
                            }
                            .zoomSource("related", relation.series.id)
                            .buttonStyle(.press)
                        }
                    }
                    .padding(.horizontal, Metrics.gutter)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    @ViewBuilder
    private func onwardRow(_ title: String, _ items: [Series]) -> some View {
        if isLoading || !items.isEmpty {
            VStack(alignment: .leading, spacing: 11) {
                Text(title)
                    .typeDetailSectionHeader()
                    .foregroundStyle(Palette.textPrimary)
                    .padding(.horizontal, Metrics.gutter)

                if items.isEmpty {
                    HStack(spacing: Metrics.gapCovers) {
                        ForEach(0..<3, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: Metrics.radiusCoverRow, style: .continuous)
                                .fill(Palette.imagePlaceholder)
                                .frame(
                                    width: Metrics.coverDetailRowWidth,
                                    height: Metrics.coverDetailRowWidth / Metrics.coverAspect
                                )
                        }
                    }
                    .padding(.horizontal, Metrics.gutter)
                } else {
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: Metrics.gapCovers) {
                            ForEach(items) { item in
                                Button {
                                    zoomRoute?.source = ZoomRoute.id(title, item.id)
                                    path.append(item)
                                } label: {
                                    CoverCard(series: item, width: Metrics.coverDetailRowWidth)
                                }
                                .buttonStyle(.press)
                                .zoomSource(title, item.id)
                            }
                        }
                        .padding(.horizontal, Metrics.gutter)
                    }
                    .scrollIndicators(.hidden)
                }
            }
        }
    }

}
