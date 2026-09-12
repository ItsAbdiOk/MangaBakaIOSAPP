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
        var isLoading = true
        /// The last page fetched. 1 until the row is scrolled to its end.
        var page = 1
        /// Bumped each time a reload replaces the row's contents, so a page
        /// fetch that was in flight across the reload can tell.
        var reloads = 0
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
        await Signposts.measure("Discover load") {
            await loadRows(forceRefresh: forceRefresh)
        }
    }

    private func loadRows(forceRefresh: Bool) async {
        defer { Task { await refreshCachedCount() } }
        // A successful refresh has to clear this, or the bar outlives the
        // failure it describes.
        staleSince = nil
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
                rows[index].reloads += 1
                if case let .staleAfter(error) = result.origin {
                    firstFailure = firstFailure ?? error
                    // One bar for the screen, not one per row. Four rows all
                    // failing the same refresh produced four identical banners
                    // saying the same thing about the same network.
                    if !result.series.isEmpty {
                        staleSince = [staleSince, result.cachedAt].compactMap { $0 }.min()
                    }
                }
            }
            failure = firstFailure
        }
    }

    /// When the oldest thing on screen was downloaded, if the last refresh
    /// failed and there is still content to show. Nil means nothing is stale.
    ///
    /// Oldest rather than newest: the bar states an age, and the honest age of
    /// a screen is that of its stalest part.
    private(set) var staleSince: Date?

    /// Whether there is content on screen that a failed refresh left behind.
    ///
    /// Both halves matter: a failure with nothing to show is a `FailureState`,
    /// and content with no failure is just the app working.
    var isShowingStale: Bool {
        failure != nil && rows.contains { !$0.series.isEmpty }
    }

    /// "Last updated 19 hours ago · refresh failed".
    var staleDetail: String? {
        guard isShowingStale else { return nil }
        guard let staleSince else { return "Refresh failed" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        let age = formatter.localizedString(for: staleSince, relativeTo: Date())
        return "Last updated \(age) · refresh failed"
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
        let reloads = rows[index].reloads
        let result = await repository.feedPage(rows[index].kind, page: nextPage)

        // A pull-to-refresh while this page was in flight has replaced the
        // row with a fresh page 1. Appending would leave the row holding the
        // new page 1 plus the old page 2, with `page` saying 2 — so the next
        // scroll fetched page 3 of a row missing its 2. Compared on a reload
        // count, not on `page`: the reload resets `page` to 1, which is
        // exactly the value this fetch started from, so a page check passes.
        // (Tried first; the test caught it.)
        guard rows[index].reloads == reloads else { return }

        // Deduplicate against what is already on screen. The API can and does
        // repeat a series across pages when the underlying ordering shifts
        // between requests, and SwiftUI's ForEach traps on duplicate IDs.
        let known = Set(rows[index].series.map(\.id))
        let additions = result.series.filter { !known.contains($0.id) }

        // The API's own end-of-list signal, now that `feedPage` carries it
        // (`pagination.next`). A page is filtered locally for
        // `isDiscoverable`/format after it arrives, so a page can add nothing
        // while the feed still has thousands behind it — that used to end the
        // row. A failure also arrives as `hasMore == false`, which stops the
        // asking, as before: re-requesting into a per-IP rate limit shared
        // with everyone on the network costs more than a short row.
        rows[index].hasReachedEnd = !result.hasMore
        // Advanced even when the page added nothing, so the next scroll asks
        // for the page after it rather than the same one again.
        rows[index].page = nextPage
        rows[index].series.append(contentsOf: additions)
    }
}
