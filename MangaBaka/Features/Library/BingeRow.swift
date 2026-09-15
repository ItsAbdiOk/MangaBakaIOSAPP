import SwiftUI

/// "Binge a season" — see `BingeCandidates`. Sits under "Pick back up" on
/// the library screen; hides itself when there is nothing to say.
struct BingeRow: View {
    let candidates: [BingeCandidate]
    @Binding var path: [Series]
    var coverWidth: CGFloat = Metrics.coverSavedStripWidth
    @Environment(\.zoomRoute) private var zoomRoute

    var body: some View {
        if !candidates.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("Binge a season")
                        .typeSectionHeader()
                        .foregroundStyle(Palette.textPrimary)
                    Spacer(minLength: 0)
                    Text("\(candidates.count) waiting")
                        .typeSmallMeta()
                        .foregroundStyle(Palette.textMuted)
                        .countsNotCuts()
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.bottom, 11)

                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: Metrics.gapCovers) {
                        ForEach(candidates) { candidate in
                            card(candidate).arrives()
                        }
                    }
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.vertical, 2)
                    .scrollTargetLayout()
                }
                .scrollIndicators(.hidden)
                .scrollTargetBehavior(.viewAligned)
            }
            .padding(.top, Metrics.sectionGap)
        }
    }

    private func card(_ candidate: BingeCandidate) -> some View {
        Button {
            zoomRoute?.source = ZoomRoute.id("binge", candidate.series.id)
            zoomRoute?.neighbours = candidates.map(\.series)
            path.append(candidate.series)
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                CoverImage(
                    cover: candidate.series.cover,
                    width: coverWidth,
                    radius: Metrics.radiusCoverRow,
                    accessibilityText: candidate.series.displayTitle ?? "Untitled series"
                )
                Text(candidate.reason.line)
                    .typeFootnote()
                    .foregroundStyle(Palette.textMuted)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: coverWidth, alignment: .leading)
        }
        .buttonStyle(.press)
        .zoomSource("binge", candidate.series.id)
        .accessibilityLabel(
            "\(candidate.series.displayTitle ?? "Untitled series"), \(candidate.reason.line)"
        )
    }
}
