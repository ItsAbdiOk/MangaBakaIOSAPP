import SwiftUI

/// "More of what you finished" — sequels, spin-offs and side stories of series
/// the reader has completed, not already in their library.
///
/// Same ScrollView/HStack/CoverCard/zoomSource shape as `DetailOnwardRows`:
/// it is the same idea, a horizontal strip of covers with a reason attached
/// to each one, just fed from finished series instead of a series page.
struct ContinuationsRow: View {
    let items: [Continuation]
    let isLoading: Bool
    @Binding var path: [Series]
    @Environment(\.zoomRoute) private var zoomRoute

    private static let rowID = "continuations"

    var body: some View {
        if isLoading && items.isEmpty {
            VStack(alignment: .leading, spacing: 11) {
                header
                CoverSkeletonRow()
                    .padding(.horizontal, Metrics.gutter)
            }
            .padding(.top, Metrics.sectionGap)
        } else if !items.isEmpty {
            VStack(alignment: .leading, spacing: 11) {
                header
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: Metrics.gapCovers) {
                        ForEach(items) { item in
                            Button {
                                zoomRoute?.source = ZoomRoute.id(Self.rowID, item.series.id)
                                path.append(item.series)
                            } label: {
                                CoverCard(
                                    series: item.series,
                                    width: Metrics.coverDetailRowWidth,
                                    meta: "\(item.label) of \(item.because)"
                                )
                            }
                            .zoomSource(Self.rowID, item.series.id)
                            .buttonStyle(.press)
                            .arrives()
                        }
                    }
                    .padding(.horizontal, Metrics.gutter)
                    .scrollTargetLayout()
                }
                .scrollIndicators(.hidden)
                .scrollTargetBehavior(.viewAligned)
            }
            .padding(.top, Metrics.sectionGap)
        }
    }

    private var header: some View {
        Text("More of what you finished")
            .typeSectionHeader()
            .foregroundStyle(Palette.textPrimary)
            .padding(.horizontal, Metrics.gutter)
    }
}
