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
    /// Nearest neighbours over the bundled sentence embeddings — see
    /// `EmbeddingIndex`. Never a `FeedResult`: this never asks a network
    /// that can fail, so there is nothing here to retry. Empty means either
    /// "this series has no vector in the file" or "asked and got nothing" —
    /// both stay silent, the same as an onward row with no failure to show
    /// (see `showsSimilarByDescription`).
    var similarByDescription: [Series] = []
    let isLoading: Bool
    /// Set only when the corresponding feed asked and failed with nothing to
    /// fall back on (`FeedResult.blockingError`) — nil for "asked and got
    /// nothing", which stays silent. Both rows used to vanish identically on
    /// failure (gap 16, FAILURES-SUMMARY.md).
    var similarFailure: APIError?
    var alsoLikeFailure: APIError?
    var onRetrySimilar: (() async -> Void)?
    var onRetryAlsoLike: (() async -> Void)?
    @Binding var path: [Series]
    @Environment(\.zoomRoute) private var zoomRoute

    enum State: Equatable {
        case hidden
        case loading
        case failed(APIError)
        case list
    }

    /// A pure decision, testable without a view: real items win even over a
    /// stored failure, the same rule `CharacterRow.state` uses.
    nonisolated static func onwardRowState(
        items: [Series], isLoading: Bool, failure: APIError?
    ) -> State {
        if !items.isEmpty { return .list }
        if let failure { return .failed(failure) }
        if isLoading { return .loading }
        return .hidden
    }

    /// `items`, de-duplicated by series id. A feed page has repeated an id
    /// across a boundary before (gap 6) — verified only in principle, not
    /// against a live response that actually did it — and a duplicate id
    /// traps `ForEach`, which is a crash worth a one-line guard even for an
    /// unconfirmed input.
    nonisolated static func deduplicated(_ items: [Series]) -> [Series] {
        var seen = Set<Int>()
        return items.filter { seen.insert($0.id).inserted }
    }

    /// Whether "Similar by description" belongs on the page at all. On-device
    /// and never a network ask, so there is no loading or failed branch to
    /// decide between — the row exists exactly when it has something to show.
    nonisolated static func showsSimilarByDescription(_ items: [Series]) -> Bool {
        !items.isEmpty
    }

    var body: some View {
        relatedRow
        onwardRow(
            "Similar", similar, failure: similarFailure, retry: onRetrySimilar
        )
        onwardRow(
            "Readers also like", alsoLike, failure: alsoLikeFailure, retry: onRetryAlsoLike
        )
        similarByDescriptionRow
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
                    // Lazy: an eager stack starts a `CoverStore` fetch for
                    // every card in the first frame, and `CoverStore`
                    // deliberately never cancels — three ~20-card rows here
                    // alone outlived every pop (item 58).
                    LazyHStack(alignment: .top, spacing: Metrics.gapCovers) {
                        ForEach(relationships) { relation in
                            Button {
                                zoomRoute?.source = ZoomRoute.id("related", relation.series.id)
                                // This row's own siblings, not whatever row
                                // pushed *this* page: `neighbours` was never
                                // cleared, so tapping a related series that
                                // happened to also be in the originating row
                                // wrapped it in that row's pager and swiping
                                // stepped through the wrong list — the case
                                // `RootView+Session`'s guard comment claims
                                // it rules out (item 122).
                                zoomRoute?.neighbours = relationships.map(\.series)
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
        }
    }

    @ViewBuilder
    private func onwardRow(
        _ title: String, _ rawItems: [Series], failure: APIError?, retry: (() async -> Void)?
    ) -> some View {
        let items = Self.deduplicated(rawItems)
        let state = Self.onwardRowState(items: items, isLoading: isLoading, failure: failure)
        Group {
            switch state {
            case .hidden:
                EmptyView()
            case .loading:
                VStack(alignment: .leading, spacing: 11) {
                    header(title)
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
                }
                .transition(.blurReplace)
            case let .failed(error):
                VStack(alignment: .leading, spacing: 11) {
                    header(title)
                    InlineFailure(error: error, retry: retry)
                }
                .transition(.blurReplace)
            case .list:
                VStack(alignment: .leading, spacing: 11) {
                    header(title)
                    ScrollView(.horizontal) {
                        // Lazy, same reasoning as `relatedRow` (item 58).
                        LazyHStack(alignment: .top, spacing: Metrics.gapCovers) {
                            ForEach(items) { item in
                                Button {
                                    zoomRoute?.source = ZoomRoute.id(title, item.id)
                                    // This row's items (item 122).
                                    zoomRoute?.neighbours = items
                                    path.append(item)
                                } label: {
                                    CoverCard(series: item, width: Metrics.coverDetailRowWidth)
                                }
                                .buttonStyle(.press)
                                .zoomSource(title, item.id)
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
                .rowAmbient(items)
                .transition(.blurReplace)
            }
        }
        .animation(Motion.reduced(Motion.settle), value: state)
    }

    /// "Similar by description": nearest neighbours by embedding, after the
    /// two feed-backed rows. Cards may carry only a title — resolved from
    /// `OfflineCatalogue`, the same bundled 19k-title source the embedding
    /// ids are drawn from, never a network fetch per id — in which case
    /// `CoverCard` draws its existing placeholder in place of artwork.
    @ViewBuilder
    private var similarByDescriptionRow: some View {
        let items = Self.deduplicated(similarByDescription)
        if Self.showsSimilarByDescription(items) {
            VStack(alignment: .leading, spacing: 11) {
                header("Similar by description")
                ScrollView(.horizontal) {
                    // Lazy, same reasoning as `relatedRow` (item 58).
                    LazyHStack(alignment: .top, spacing: Metrics.gapCovers) {
                        ForEach(items) { item in
                            Button {
                                zoomRoute?.source = ZoomRoute.id("Similar by description", item.id)
                                // This row's items (item 122).
                                zoomRoute?.neighbours = items
                                path.append(item)
                            } label: {
                                CoverCard(series: item, width: Metrics.coverDetailRowWidth)
                            }
                            .buttonStyle(.press)
                            .zoomSource("Similar by description", item.id)
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
            .rowAmbient(items)
        }
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .typeDetailSectionHeader()
            .foregroundStyle(Palette.textPrimary)
            .padding(.horizontal, Metrics.gutter)
    }
}
