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
    /// Same closure shape as ratings, for the same reason: read at load time,
    /// so a format or blocked tag toggled in Settings takes effect on the
    /// next load rather than the next launch.
    private let allowedFormats: () -> [String]
    private let blockedTags: () -> [Int]

    init(
        history: HistoryStore,
        allowedRatings: @escaping () -> [String],
        allowedFormats: @escaping () -> [String] = { [] },
        blockedTags: @escaping () -> [Int] = { [] }
    ) {
        self.history = history
        self.allowedRatings = allowedRatings
        self.allowedFormats = allowedFormats
        self.blockedTags = blockedTags
    }

    /// Below two entries there is nothing to come back to.
    ///
    /// One entry is always the series the reader just closed, so a row of one
    /// is a row showing them where they already are. Two is the first count at
    /// which the row answers a question.
    var isWorthShowing: Bool { series.count >= 2 }

    func load() async {
        let ratings = allowedRatings()
        series = (try? await history.entries(
            allowedRatings: ratings, allowedFormats: allowedFormats(), blockedTags: blockedTags()
        )) ?? []
    }

    func record(_ opened: Series) async {
        try? await history.record(opened)
        await load()
    }
}

/// One horizontal row, or nothing at all.
struct RecentlyViewedRow: View {
    let model: RecentlyViewedModel
    let onOpen: (Series) -> Void

    var body: some View {
        if model.isWorthShowing {
            VStack(alignment: .leading, spacing: 11) {
                // Above every API row (see `DiscoverView`), so it arrives
                // first in the stagger.
                SectionHeader(title: "Recently viewed")
                    .arrives(index: 0)

                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: Metrics.gapCovers) {
                        ForEach(model.series) { series in
                            Button { onOpen(series) } label: {
                                CoverCard(series: series, meta: DiscoverView.meta(for: series))
                            }
                            .buttonStyle(.press)
                            .zoomSource("recent", series.id)
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
            // A guess, matching the API rows below it: drifts a few points
            // against the ground as the page scrolls.
            .parallax(4)
        }
    }
}
