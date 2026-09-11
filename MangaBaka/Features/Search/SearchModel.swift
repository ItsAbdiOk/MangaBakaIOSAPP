import Foundation

/// Backing state for the Search screen.
///
/// Every keystroke updates `query`, but the network call is debounced: the API
/// caps search at 30 requests a minute per IP, and that budget is shared with
/// everyone else on the same network (a carrier NAT, a campus Wi-Fi). Firing a
/// request per keystroke would burn through it in a couple of words typed and
/// starve other people's searches, not just waste this app's own quota.
@MainActor
@Observable
final class SearchModel {
    var query = SearchQuery()
    private(set) var results: [Series] = []
    private(set) var isSearching = false
    private(set) var message: String?
    private(set) var isLoadingMore = false
    /// Bumped by every fresh search. A page that comes back for an older
    /// generation belongs to a search the reader has since replaced, and is
    /// dropped rather than appended under the new one.
    private var generation = 0
    /// False once a page comes back short or empty. Starts false so the first
    /// page has to actually arrive before the view offers to fetch a second.
    private(set) var hasMore = false

    private let repository: any SeriesRepositoryProtocol
    private var debounceTask: Task<Void, Never>?
    /// The text `apply(_:)` just set, so the field's own change observer can
    /// tell that edit from a keystroke. See `queryDidChange`.
    private var appliedText: String?

    init(repository: any SeriesRepositoryProtocol) {
        self.repository = repository
    }

    /// Called on every edit to `query` from the view. Cancels whatever debounce
    /// or in-flight search is pending and starts a fresh 300ms wait, so only
    /// the last keystroke in a burst ever reaches the network.
    func queryDidChange() {
        debounceTask?.cancel()
        // An explicit apply — a lens, a recent term, a browse — sets the whole
        // query and searches at once, but assigning it also changes the text
        // the field observes, and that observer lands here and scheduled a
        // fresh debounce after the explicit search had already gone out: two
        // identical requests per tap, on a 30 req/min budget shared with
        // strangers. Whether the observer runs before or after the explicit
        // search is SwiftUI's business and not something to bet on, so the
        // model remembers what it applied and this ignores that one edit.
        if let appliedText, appliedText == query.text {
            self.appliedText = nil
            return
        }
        appliedText = nil
        // Typing a title means you want that title, not a shuffle. "Surprise
        // me" sets `sort = "random"` and nothing ever unset it, so every search
        // after one tap of it was randomised: `q=one piece&sort_by=random`
        // answers 32 series and ONE PIECE is not among them, while relevance
        // answers 411 with it first. Measured on 2026-09-10.
        if query.sort == "random", !(query.text ?? "").isEmpty {
            query.sort = nil
        }
        guard !query.isEmpty else {
            results = []
            message = nil
            isSearching = false
            hasMore = false
            return
        }
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await self?.search()
        }
    }

    /// Runs the search immediately, bypassing debounce. Used for explicit
    /// triggers: submitting the field, applying filters, or "Surprise me".
    ///
    /// Deliberately does NOT cancel `debounceTask`. It used to, which meant a
    /// debounced search cancelled the very task it was running inside: the
    /// request died with NSURLErrorCancelled, the cancellation guard returned
    /// early, and `isSearching` stayed true forever — an eternal spinner with
    /// no results and no error. Cancelling the pending debounce is the caller's
    /// business, not this method's.
    func search() async {
        guard !query.isEmpty else {
            results = []
            message = nil
            isSearching = false
            hasMore = false
            return
        }
        isSearching = true
        // A deferred reset, so no early return can strand the spinner again.
        defer { isSearching = false }

        // A new search is page one by definition. Without this a reader who
        // paged to 4 and then typed a new query would get page 4 of it.
        query.page = 1
        generation += 1
        let mine = generation
        let result = await repository.search(query)
        guard !Task.isCancelled, mine == generation else { return }
        results = result.series
        hasMore = result.series.count >= query.limit
        message = result.series.isEmpty ? result.blockingError?.userFacingMessage : nil
    }

    /// Drops every filter but the typed text, and searches again.
    ///
    /// The escape hatch for the case above: a filter set on another screen, or
    /// restored with a lens, silently zeroes an ordinary title search.
    func clearFilters() async {
        query = query.clearingFilters()
        cancelPendingDebounce()
        await search()
    }

    /// Appends the next page. Driven by scroll position, not a button.
    func loadMore() async {
        guard hasMore, !isSearching, !isLoadingMore, !query.isEmpty else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }

        var next = query
        next.page += 1
        let mine = generation
        let result = await repository.search(next)
        // The reader scrolled to the bottom of one search and typed another
        // before its page arrived: this page is for the old search.
        guard !Task.isCancelled, mine == generation else { return }

        // Deduplicate: the API repeats series across pages when the underlying
        // ordering shifts between requests, and a duplicate id traps ForEach.
        // Under sort_by=random it is not an edge case but the normal outcome.
        let known = Set(results.map(\.id))
        let additions = result.series.filter { !known.contains($0.id) }

        guard !additions.isEmpty else {
            // Either the end or a failure. Stop asking either way, rather than
            // re-requesting into a rate limit shared with everyone on this IP.
            hasMore = false
            return
        }

        results.append(contentsOf: additions)
        query.page = next.page
        hasMore = result.series.count >= query.limit
    }

    /// Runs a search for a genre or tag picked while browsing.
    ///
    /// Replaces the query rather than adding to it: arriving from a browse
    /// screen means "show me this", not "narrow whatever I had".
    func applyBrowse(genre: String? = nil, tag: String? = nil, publisher: String? = nil) {
        var next = SearchQuery()
        if let genre { next.tags = [genre] }
        if let tag { next.tags = [tag] }
        if let publisher { next.publisher = publisher }
        next.sort = "popularity_desc"
        // Assigned here, not in the task: a caller may read the query
        // straight back, and it should be the browse.
        appliedText = next.text
        query = next
        cancelPendingDebounce()
        Task { await search() }
    }

    /// Replaces the whole query and searches at once, without the debounce a
    /// keystroke gets. For the explicit triggers: a saved lens, a recent term,
    /// a browse. See `queryDidChange` for why the text is remembered first.
    func apply(_ next: SearchQuery) async {
        appliedText = next.text
        query = next
        cancelPendingDebounce()
        await search()
    }

    /// Drops a pending debounce without touching an in-flight search. Call this
    /// before an explicit `search()` so a queued keystroke cannot re-fire after
    /// the reader has already submitted.
    func cancelPendingDebounce() {
        debounceTask?.cancel()
    }
}
