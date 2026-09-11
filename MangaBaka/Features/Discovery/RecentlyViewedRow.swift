import SwiftUI

/// The covers the reader most recently opened.
///
/// MangaBaka's own homepage carries a recently-viewed row, which is where the
/// idea comes from — but they can build it from a signed-in account and this
/// app cannot, so it is local. See `HistoryStore` for what that means.
@MainActor
@Observable
final class RecentlyViewedModel {
    private(set) var series: [Series] = []

    private let history: HistoryStore
    private let allowedRatings: () -> [String]

    init(history: HistoryStore, allowedRatings: @escaping () -> [String]) {
        self.history = history
        self.allowedRatings = allowedRatings
    }

    /// Below two entries there is nothing to come back to.
    ///
    /// One entry is always the series the reader just closed, so a row of one
    /// is a row showing them where they already are. Two is the first count at
    /// which the row answers a question.
    var isWorthShowing: Bool { series.count >= 2 }

    func load() async {
        let ratings = allowedRatings()
        series = (try? await history.entries(allowedRatings: ratings)) ?? []
    }

    func record(_ opened: Series) async {
        try? await history.record(opened)
        await load()
    }
}

/// One horizontal row, or nothing at all.
struct RecentlyViewedRow: View {
    let model: RecentlyViewedModel
    let namespace: Namespace.ID
    let onOpen: (Series) -> Void

    var body: some View {
        if model.isWorthShowing {
            VStack(alignment: .leading, spacing: 11) {
                SectionHeader(title: "Recently viewed")

                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: Metrics.gapCovers) {
                        ForEach(model.series) { series in
                            Button { onOpen(series) } label: {
                                CoverCard(series: series, meta: DiscoverView.meta(for: series))
                            }
                            .buttonStyle(.press)
                            .matchedTransitionSource(id: "recent#\(series.id)", in: namespace)
                        }
                    }
                    .padding(.horizontal, Metrics.gutter)
                }
                .scrollIndicators(.hidden)
            }
        }
    }
}
