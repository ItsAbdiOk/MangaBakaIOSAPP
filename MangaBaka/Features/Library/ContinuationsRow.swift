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
    /// Gap 92: at least one of the last walk's asks failed, rather than the
    /// row genuinely having nothing to show. Shown as `InlineFailure` under
    /// the header instead of the row vanishing — the same distinction
    /// `Fetched<T>` draws everywhere else a section asks and gets nothing
    /// back versus asks and fails.
    var hasFailure = false
    var onRetry: (() async -> Void)?
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
        } else if items.isEmpty && hasFailure {
            VStack(alignment: .leading, spacing: 11) {
                header
                // `ContinuationsModel` only knows that at least one
                // `relationships(for:)` call failed, not why —
                // `SeriesRepositoryProtocol` swallows the real `APIError`
                // before it gets here. `.transport` is the one case whose
                // copy ("The request didn't complete.") claims no specific
                // cause, so this does not assert "offline" for a failure
                // that might have been a rate limit or a server error.
                InlineFailure(
                    error: .transport(underlying: "continuations", party: .mangaBaka),
                    retry: onRetry
                )
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
                                zoomRoute?.neighbours = items.map(\.series)
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
                            .enterScale()
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
