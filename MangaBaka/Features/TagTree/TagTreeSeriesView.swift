import SwiftUI

/// The leaf of the tag tree: every series behind one tag, in the same
/// `CoverGrid`/`CoverCard` cells `SearchView` and `PublisherView` already
/// draw, so a series opened from here looks and zooms exactly like one
/// opened from anywhere else.
struct TagTreeSeriesView: View {
    let request: TagBrowseRequest
    let repository: any SeriesRepositoryProtocol
    @Binding var path: [Series]
    @State private var model: TagTreeSeriesModel?
    @Environment(\.zoomRoute) private var zoomRoute

    var body: some View {
        Group {
            if let model {
                content(model)
            } else {
                CoverSkeletonGrid()
            }
        }
        .navigationTitle(request.tag.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // `.task` (no `id:`) re-runs on every re-appearance, including a
            // pop back from a series opened out of this grid — guarding on
            // `.idle` is what stops that from re-issuing the same search
            // `PublisherView`'s own `needsLoad`/`loadedOrder` guard against
            // the same re-run for the same reason (F10).
            let active = model ?? TagTreeSeriesModel(tag: request.tag, repository: repository)
            model = active
            guard case .idle = active.state else { return }
            await active.load()
        }
        .refreshable { await model?.load() }
    }

    @ViewBuilder
    private func content(_ model: TagTreeSeriesModel) -> some View {
        switch model.state {
        case .idle, .loading:
            CoverSkeletonGrid()
        case let .loaded(series, _, _) where series.isEmpty:
            EmptyState(
                title: "Nothing here yet",
                message: "MangaBaka lists nothing under \(model.tag.name) yet."
            )
        case let .loaded(series, _, _):
            grid(series, model: model)
        case let .failed(error, stale):
            if let stale {
                VStack(spacing: 0) {
                    StaleBar(
                        headline: "Showing what you had",
                        detail: error.userFacingMessage,
                        retry: { await model.load() }
                    )
                    .padding(.horizontal, Metrics.gutter)
                    grid(stale, model: model)
                }
            } else {
                FailureState(error: error, retry: { await model.load() })
            }
        }
    }

    private func grid(_ series: [Series], model: TagTreeSeriesModel) -> some View {
        VStack(spacing: 0) {
            CoverGrid(items: series) { index, item, layout in
                Button {
                    zoomRoute?.source = ZoomRoute.id("tagTree", item.id)
                    zoomRoute?.neighbours = series
                    path.append(item)
                } label: {
                    CoverCard(
                        series: item, width: layout.cardWidth, radius: Metrics.radiusCoverGrid,
                        meta: DiscoverView.meta(for: item), sizing: .gridColumn
                    )
                }
                .zoomSource("tagTree", item.id)
                .buttonStyle(.press)
                .onAppear {
                    guard layout.shouldLoadMore(
                        index: index, count: series.count,
                        hasMore: model.hasMore, isLoadingMore: model.isLoadingMore
                    ) else { return }
                    Task { await model.loadMore() }
                }
            }
            if model.isLoadingMore {
                ProgressView()
                    .tint(Palette.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            } else if let pageFailure = model.pageFailure {
                InlineFailure(error: pageFailure) { await model.loadMore() }
                    .padding(.vertical, 12)
            }
        }
    }
}
