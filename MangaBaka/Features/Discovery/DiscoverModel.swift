import Foundation

/// Backing state for the Discover screen.
///
/// Loads several feeds at once. Each row reports its own state, so one failing
/// endpoint leaves the rest of the screen intact rather than blanking it —
/// which matters here, because the rate limit is shared and partial failure is
/// an ordinary occurrence, not an exceptional one.
@MainActor
@Observable
final class DiscoverModel {
    struct Row: Identifiable, Equatable {
        let kind: FeedKind
        let title: String
        /// The link at the right of the row header. The mockup gives each row
        /// its own label rather than one shared "See all".
        let more: String
        var series: [Series] = []
        var staleReason: String?
        var isLoading = true
        /// The last page fetched. 1 until the row is scrolled to its end.
        var page = 1
        var isLoadingMore = false
        /// Set when a page comes back short or empty, or when the endpoint has
        /// no paging at all. `rising` and `hidden-gems` are capped at 20 by the
        /// API with no page parameter, so those rows genuinely end.
        var hasReachedEnd = false

        var canLoadMore: Bool {
            kind.supportsPaging && !hasReachedEnd && !isLoading && !isLoadingMore
        }

        var id: String { kind.cacheKey }
    }

    private(set) var rows: [Row] = [
        Row(kind: .rising, title: "Rising this week", more: "7 days"),
        Row(kind: .hiddenGems, title: "Hidden gems", more: "See all"),
        Row(kind: .trending, title: "Trending", more: "7d · 30d"),
        // MangaBaka's own homepage carries four rails — Trending, Rising in
        // libraries, Hidden gems and New releases — and this app had the first
        // three. There is no "recently viewed" on their site to mirror; that
        // would have to be built from what this device has opened.
        Row(kind: .newReleases, title: "New releases", more: "Just added")
    ]

    /// How many series are cached, for the subtitle. Zero until it is read.
    private(set) var cachedCount = 0

    /// True only when every row failed with nothing cached — the one case that
    /// deserves a whole-screen error.
    var isCompletelyEmpty: Bool {
        !rows.contains { !$0.series.isEmpty } && !rows.contains(where: \.isLoading)
    }

    /// Why the screen is empty. Carried as the error itself rather than a
    /// string, so the view can choose a symbol and phrasing that match the
    /// actual cause instead of assuming everything is an outage.
    private(set) var failure: APIError?

    private let repository: any SeriesRepositoryProtocol

    init(repository: any SeriesRepositoryProtocol) {
        self.repository = repository
    }

    func load(forceRefresh: Bool = false) async {
        defer { Task { await refreshCachedCount() } }
        await withTaskGroup(of: (Int, FeedResult).self) { group in
            for (index, row) in rows.enumerated() {
                group.addTask { [repository] in
                    (index, await repository.feed(row.kind, forceRefresh: forceRefresh))
                }
            }
            var firstFailure: APIError?
            for await (index, result) in group {
                rows[index].series = result.series
                rows[index].isLoading = false
                // A reload replaces the row, so paging starts over with it.
                // Leaving these would make the next scroll to the bottom fetch
                // page 5 of a row that currently holds page 1.
                rows[index].page = 1
                rows[index].hasReachedEnd = false
                if case let .staleAfter(error) = result.origin {
                    rows[index].staleReason = result.series.isEmpty ? nil : error.userFacingMessage
                    firstFailure = firstFailure ?? error
                } else {
                    rows[index].staleReason = nil
                }
            }
            failure = firstFailure
        }
    }

    private func refreshCachedCount() async {
        cachedCount = await repository.cachedSeriesCount()
    }

    /// Fetches the next page of one row and appends it.
    ///
    /// Called when the reader nears the end of a row rather than from a button:
    /// a row that stops dead with no way forward reads as the end of the
    /// catalogue, which it is not.
    func loadMore(_ rowID: Row.ID) async {
        guard let index = rows.firstIndex(where: { $0.id == rowID }),
              rows[index].canLoadMore
        else { return }

        rows[index].isLoadingMore = true
        defer { rows[index].isLoadingMore = false }

        let nextPage = rows[index].page + 1
        let result = await repository.feedPage(rows[index].kind, page: nextPage)

        // Deduplicate against what is already on screen. The API can and does
        // repeat a series across pages when the underlying ordering shifts
        // between requests, and SwiftUI's ForEach traps on duplicate IDs.
        let known = Set(rows[index].series.map(\.id))
        let additions = result.series.filter { !known.contains($0.id) }

        guard !additions.isEmpty else {
            // Nothing new: either the end, or a failure. Either way, stop
            // asking — repeatedly requesting the same page against a shared
            // per-IP rate limit costs everyone on the network, not just us.
            rows[index].hasReachedEnd = true
            return
        }

        rows[index].series.append(contentsOf: additions)
        rows[index].page = nextPage
    }
}
