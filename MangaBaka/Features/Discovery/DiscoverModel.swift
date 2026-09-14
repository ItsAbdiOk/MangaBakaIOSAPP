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
        /// This row's own failure from the initial load, distinct from the
        /// screen-wide `DiscoverModel.failure`.
        ///
        /// A shared, first-failure-wins property used to mean one row's
        /// `.offline` (with nothing cached) painted every other, perfectly
        /// fine row as "showing stale" the instant any row on screen had
        /// content — the two facts had nothing to do with each other
        /// (gap 13). Each row now carries its own answer.
        var failure: APIError?
        /// A trailing page fetch (`loadMore`) failed. Shown as an
        /// `InlineFailure` at the end of the row rather than read as the end
        /// of the feed — see `loadMore`'s doc comment (gap 15).
        var pageFailure: APIError?

        var canLoadMore: Bool {
            kind.supportsPaging && !hasReachedEnd && !isLoading && !isLoadingMore && pageFailure == nil
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

    /// Bumped at the start of every `loadRows`, so a call that is still in
    /// flight when a newer one starts (a pull-to-refresh landing on top of
    /// the initial `.task` load, say) can tell its own results are stale and
    /// drop them instead of overwriting what the newer call already wrote —
    /// the interleaving that made the `StaleBar` flicker between runs
    /// (gap 47).
    private var loadGeneration = 0

    /// Whether a load has already finished for this screen.
    ///
    /// `DiscoverView`'s `.task` carries no id, so SwiftUI runs it again on
    /// every tab reselect and on every pop back from a series page. Each of
    /// those re-ran `loadRows`, which resets all four rows to page 1 — so a
    /// reader who had scrolled Trending to page 3 lost it by opening a series
    /// and coming back, and four requests went out for content already on
    /// screen, two of them from the 30/min family. Pull-to-refresh passes
    /// `forceRefresh` and stays the explicit way to ask again (item 19).
    private var hasLoadedOnce = false

    init(repository: any SeriesRepositoryProtocol) {
        self.repository = repository
    }

    func load(forceRefresh: Bool = false) async {
        guard forceRefresh || !hasLoadedOnce else { return }
        await Signposts.measure("Discover load") {
            await loadRows(forceRefresh: forceRefresh)
        }
    }

    private func loadRows(forceRefresh: Bool) async {
        loadGeneration += 1
        let generation = loadGeneration
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
            /// Rows whose answer was a cancellation. They kept what they had
            /// (nothing, on a first load), so this load did not finish for
            /// them and `hasLoadedOnce` must not claim it did.
            var cancelledRows = 0
            for await (index, result) in group {
                // A newer `loadRows` has started since this one did — its
                // results win, and this one's are dropped rather than
                // clobbering them out of order.
                guard generation == loadGeneration else { continue }
                // Navigating away cancels the `.task` that started this, and
                // the repository answers the dead request with
                // `.staleAfter(.cancelled)`. Written straight into the row, it
                // drew a "Cancelled" failure card on all four rows of a screen
                // the reader had already left — and the next appearance asked
                // for all four again (C2, item 3). The row keeps what it had;
                // `hasLoadedOnce` stays false below, so coming back re-asks.
                if case .staleAfter(.cancelled) = result.origin {
                    cancelledRows += 1
                    continue
                }
                // A cache answer for a row that already has content says
                // nothing the row does not already know, and rewriting it
                // would throw away the pages the reader scrolled to (item 19).
                if result.origin == .cache, !rows[index].series.isEmpty {
                    rows[index].isLoading = false
                    rows[index].failure = nil
                    continue
                }
                rows[index].series = result.series
                rows[index].isLoading = false
                // A reload replaces the row, so paging starts over with it.
                // Leaving these would make the next scroll to the bottom fetch
                // page 5 of a row that currently holds page 1.
                rows[index].page = 1
                rows[index].hasReachedEnd = false
                rows[index].pageFailure = nil
                rows[index].reloads += 1
                if case let .staleAfter(error) = result.origin {
                    rows[index].failure = error
                    firstFailure = firstFailure ?? error
                    // One bar for the screen, not one per row. Four rows all
                    // failing the same refresh produced four identical banners
                    // saying the same thing about the same network.
                    if !result.series.isEmpty {
                        staleSince = [staleSince, result.cachedAt].compactMap { $0 }.min()
                    }
                } else {
                    rows[index].failure = nil
                }
            }
            guard generation == loadGeneration else { return }
            // A cancelled load has no verdict to give: the rows above kept
            // what they had, and a screen-wide `failure` set from a
            // cancellation would outlive the navigation that caused it.
            guard !Task.isCancelled else { return }
            failure = firstFailure
            // Only a load where every row actually answered counts as the
            // load that happened. Setting this after a cancelled one made
            // `load()` early-return on the next appearance, so the reader
            // came back to four empty rows and nothing ever asked again —
            // the exact opposite of what the skip above was for (item 3).
            if cancelledRows == 0 { hasLoadedOnce = true }
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
    /// Both halves matter, and they have to come from the *same* row: a
    /// screen-wide "some row somewhere failed" combined with "some other row
    /// happens to have content" used to read as the whole screen showing
    /// stale content, even when the failing row itself had nothing cached
    /// (gap 13) — three fine rows do not make a fourth, empty, offline row
    /// "stale". A row only counts once its own failed refresh still left
    /// something on screen.
    var isShowingStale: Bool {
        rows.contains { $0.failure != nil && !$0.series.isEmpty }
    }

    /// The failure behind a stale screen, for the view to build a `StaleBar`
    /// with the real cause — and, for a rate limit, a live countdown — rather
    /// than the generic wording this used to carry regardless of what
    /// actually happened (gap 46). Nil unless `isShowingStale`.
    var staleFailure: APIError? {
        guard isShowingStale else { return nil }
        return failure
    }

    /// Built once rather than per read. `staleDetail` is read from a view
    /// body, and a `RelativeDateTimeFormatter` carries a locale and a
    /// calendar it has to set up each time it is allocated.
    private static let ageFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    /// "Last updated 19 hours ago · Too many requests, briefly".
    var staleDetail: String? {
        guard let staleFailure else { return nil }
        guard let staleSince else { return staleFailure.headline }
        let age = Self.ageFormatter.localizedString(for: staleSince, relativeTo: Date())
        return "Last updated \(age) · \(staleFailure.headline)"
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
        // Background: the reader is looking at page 1 already (or scrolling
        // toward the end of it) — filling in the next page ahead of that is
        // this app getting ahead of itself, not something asked for, and must
        // not compete with a foreground search for the same window
        // (2026-09-13).
        let result = await repository.feedPage(rows[index].kind, page: nextPage, priority: .background)

        // A pull-to-refresh while this page was in flight has replaced the
        // row with a fresh page 1. Appending would leave the row holding the
        // new page 1 plus the old page 2, with `page` saying 2 — so the next
        // scroll fetched page 3 of a row missing its 2. Compared on a reload
        // count, not on `page`: the reload resets `page` to 1, which is
        // exactly the value this fetch started from, so a page check passes.
        // (Tried first; the test caught it.)
        guard rows[index].reloads == reloads else { return }

        // `feedPage` now answers a failed page with `hasMore: true` (its own
        // contract, `SeriesRepository+Paging.swift`), so a page failure no
        // longer reads as the end of the feed on its own — but leaving it
        // there also meant `canLoadMore` would fire the very same failing
        // page again on every scroll frame near the row's end. Recorded as
        // `pageFailure` and shown as a trailing `InlineFailure` instead
        // (gap 15); `canLoadMore` excludes a row with one set, so only an
        // explicit `retryPage` tries again.
        guard case let .staleAfter(error) = result.origin else {
            rows[index].pageFailure = nil
            // Deduplicate against what is already on screen. The API can and
            // does repeat a series across pages when the underlying ordering
            // shifts between requests, and SwiftUI's ForEach traps on
            // duplicate IDs.
            let known = Set(rows[index].series.map(\.id))
            let additions = result.series.filter { !known.contains($0.id) }
            rows[index].hasReachedEnd = !result.hasMore
            // Advanced even when the page added nothing, so the next scroll
            // asks for the page after it rather than the same one again.
            rows[index].page = nextPage
            rows[index].series.append(contentsOf: additions)
            return
        }
        rows[index].pageFailure = error
    }

    /// Retries a failed page after `loadMore` recorded a `pageFailure`.
    /// `canLoadMore` excludes a row with one set, so the automatic
    /// near-the-end trigger cannot loop on the same failing page — only this,
    /// wired to the trailing `InlineFailure`'s Retry, tries again.
    func retryPage(_ rowID: Row.ID) async {
        guard let index = rows.firstIndex(where: { $0.id == rowID }) else { return }
        rows[index].pageFailure = nil
        await loadMore(rowID)
    }
}
