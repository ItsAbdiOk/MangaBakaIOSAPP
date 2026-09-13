import Foundation

/// Where the current `SearchModel.results` came from.
enum SearchResultOrigin: Sendable, Equatable {
    /// The live API.
    case network
    /// `OfflineCatalogue`, the bundled top-20,000-by-popularity index.
    /// - Parameter builtDate: the export's own date, e.g. "2026-09-13", for
    ///   the line `SearchView` shows above the results.
    case offlineIndex(builtDate: String)
}

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
    /// The most recent search's failure, when it had one — kept distinct from
    /// `results.isEmpty` on purpose (gap 7). A `nil` failure with empty
    /// results is a real answer: nothing matched. A failure with *non-empty*
    /// results means the ask that just ran did not land, but whatever the
    /// previous successful search found is still good and stays on screen —
    /// see `search()`'s catch branch below, which for exactly that reason
    /// does not touch `results` at all when the failure is blocking.
    private(set) var failure: APIError?
    private(set) var isLoadingMore = false
    /// Bumped by every fresh search. A page that comes back for an older
    /// generation belongs to a search the reader has since replaced, and is
    /// dropped rather than appended under the new one.
    private var generation = 0
    /// False once a page comes back short or empty. Starts false so the first
    /// page has to actually arrive before the view offers to fetch a second.
    private(set) var hasMore = false
    /// A page-2+ request that failed outright (gap 15). Kept separate from
    /// `failure`, which is about the current *search*: a reader thirty rows
    /// into good results who hits a throttled page 4 has not had their search
    /// fail, just its next page, and the two must not render as the same
    /// thing — `failure` would clear the whole grid via `FailureState`, where
    /// this instead becomes one trailing `InlineFailure` under the rows that
    /// did load.
    private(set) var pageFailure: APIError?
    /// True once `loadMore` has given up after `maxConsecutiveEmptyPages`
    /// filtered-empty pages in a row (gap 51). Distinct from a genuine
    /// end-of-feed (`hasMore == false` with this still `false`): the API may
    /// still have more, this just stopped looking for it, and the view owes
    /// the reader a line saying so rather than looking identical to having
    /// reached the real end.
    private(set) var stoppedEarly = false

    /// Where `results` came from. `.network` until a search actually falls
    /// back, so a screen that never checks this still behaves exactly as it
    /// did before offline browsing existed.
    private(set) var origin: SearchResultOrigin = .network

    /// Set by the reader from a toggle in `FilterSheet`. While true, `search()`
    /// answers from `OfflineCatalogue` and never calls the repository at all —
    /// "Zero requests in that mode" is the whole point of the toggle, not a
    /// side effect of the network happening to be down.
    var preferOffline = false

    /// Compatibility for a caller not yet reading `failure` directly —
    /// `SeedPickerSheet.swift` (owned by the Mix batch, gap 44) still reads
    /// `search.message` for its empty-state copy. Kept as a thin derivation
    /// rather than dropped outright so that file keeps compiling unchanged
    /// while its own fix lands separately; delete once that caller reads
    /// `failure` itself.
    var message: String? { failure?.userFacingMessage }

    private let repository: any SeriesRepositoryProtocol
    private let offline: OfflineCatalogue
    /// The reader's content-rating preference, read fresh on every offline
    /// search rather than copied in once — the repository's own filters are
    /// pushed to it the same way (`AppServices`'s `store.onChange`), and this
    /// mirrors that rather than going stale the moment a setting changes.
    /// Defaults match `SeriesRepository.init`'s own defaults, so a caller that
    /// does not wire these (a test, `SeedPickerSheet`) still filters mature
    /// content out by default rather than showing everything. Main-actor
    /// closures, like `SessionModels`' `allowedRatings`: the preference
    /// stores are main-actor and so is this model.
    private let allowedRatings: @MainActor () -> [String]
    private let allowedFormats: @MainActor () -> [String]
    private let blockedTagIDs: @MainActor () -> [Int]
    private var debounceTask: Task<Void, Never>?
    /// The text `apply(_:)` just set, so the field's own change observer can
    /// tell that edit from a keystroke. See `queryDidChange`.
    private var appliedText: String?

    init(
        repository: any SeriesRepositoryProtocol,
        offline: OfflineCatalogue = OfflineCatalogue(),
        allowedRatings: @escaping @MainActor () -> [String] = { ["safe", "suggestive"] },
        allowedFormats: @escaping @MainActor () -> [String] = { [] },
        blockedTagIDs: @escaping @MainActor () -> [Int] = { [] }
    ) {
        self.repository = repository
        self.offline = offline
        self.allowedRatings = allowedRatings
        self.allowedFormats = allowedFormats
        self.blockedTagIDs = blockedTagIDs
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
            failure = nil
            pageFailure = nil
            stoppedEarly = false
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
            failure = nil
            pageFailure = nil
            stoppedEarly = false
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

        // The toggle wins outright: "Browse offline" means the reader does
        // not want a request going out at all, not "try the network first".
        if preferOffline {
            await runOfflineSearch(mine: mine, page: 1, appending: false)
            return
        }

        let result = await repository.search(query)
        guard !Task.isCancelled, mine == generation else { return }
        // A fresh search always retires a stale page-2+ failure and the
        // "gave up early" note from the search it is replacing — both belong
        // to the previous run of pages, not this one.
        pageFailure = nil
        stoppedEarly = false

        // `blockingError` is FeedResult's own line between "asked and failed"
        // and "asked and got nothing": non-nil only when there is genuinely
        // nothing to show for this ask (`.staleAfter` with an empty page).
        // That is the one case where `results` must be left alone — a 429 on
        // a later keystroke used to blank the grid and throw away results
        // the reader was still looking at (gap 7, the headline complaint:
        // "SearchView.swift:275-285", "SearchModel.swift:104,112" before this
        // change). Everything the reader had stays under a `StaleBar` while
        // `failure` carries the live countdown.
        if let blockingError = result.blockingError {
            // Offline and a rate limit both mean "the network answer is not
            // coming right now" — falling back to the bundled index turns
            // that into a browsable catalogue instead of a dead end. Any
            // other blocking failure (a decode error, a genuine 4xx/5xx) says
            // nothing about whether the network itself works, so it is left
            // to read as the failure it is.
            // Two rules meet here. A rate limit with results already on
            // screen keeps them under the countdown: the network answer is
            // seconds away and auto-retry will fetch it, so swapping the
            // grid for the offline index would be a flicker. Nothing on
            // screen, or genuinely offline, falls back to the bundled index
            // — a browsable catalogue instead of a dead end.
            let keepWhatIsShown = !results.isEmpty && !Self.isOffline(blockingError)
            if Self.isOfflineEligible(blockingError), !keepWhatIsShown {
                await runOfflineSearch(mine: mine, page: 1, appending: false)
                return
            }
            failure = blockingError
            origin = .network
            return
        }
        results = result.series
        // The API's own signal (`pagination.next`), not the filtered count:
        // `search` drops rows locally for `isDiscoverable`/format, so a page
        // that had 30 on the wire can arrive with fewer, and comparing that
        // count to the limit stopped pagination dead after page one for any
        // tag common enough to have a filtered row on it — "Isekai" (7,105
        // results) never got past 30. See FeedResult.hasMore.
        hasMore = result.hasMore
        // A truly empty answer (no error at all) is a real "nothing matched"
        // — distinct from the blocking-failure branch above, so the view can
        // tell `EmptyState` from `FailureState` from the model alone.
        failure = nil
        origin = .network
    }

    nonisolated private static func isOffline(_ error: APIError) -> Bool {
        if case .offline = error { return true }
        return false
    }

    /// Whether a blocking failure should fall back to the offline index rather
    /// than read as a dead end. Offline and rate-limited both mean the network
    /// path is temporarily unusable, not that the ask itself was wrong.
    private static func isOfflineEligible(_ error: APIError) -> Bool {
        switch error {
        case .offline, .rateLimited: true
        case .server, .decoding, .transport, .cancelled: false
        }
    }

    /// Answers `query` from `OfflineCatalogue` instead of the network. Shared
    /// by `search()` (page one) and `loadMore()` (later pages, `appending:
    /// true`) so paging against the bundled index works the same way paging
    /// against the API does.
    private func runOfflineSearch(mine: Int, page: Int, appending: Bool) async {
        let offset = (page - 1) * query.limit
        let hits = await offline.matches(
            query,
            allowedRatings: allowedRatings(),
            allowedTypes: allowedFormats(),
            blockedTags: blockedTagIDs(),
            limit: query.limit,
            offset: offset
        )
        guard mine == generation else { return }
        let built = await offline.builtDate() ?? "unknown"

        if appending {
            let known = Set(results.map(\.id))
            results.append(contentsOf: hits.map(\.series).filter { !known.contains($0.id) })
        } else {
            results = hits.map(\.series)
        }
        query.page = page
        // A short page means the index has nothing further to offer — there
        // is no separate "next page exists" signal to read the way
        // `FeedResult.hasMore` reads the API's `pagination.next`.
        hasMore = hits.count == query.limit
        failure = nil
        pageFailure = nil
        stoppedEarly = false
        origin = .offlineIndex(builtDate: built)
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

    /// A page that contributes no new rows but a bound on how many of those
    /// this will tolerate in a row before giving up, even while the API says
    /// there is more. Local filtering (`isDiscoverable`/format) can zero out
    /// a whole page legitimately — every one of its 30 rows filtered — while
    /// later pages still have results, so stopping at the first empty page is
    /// wrong. But looping unbounded is also wrong: the search endpoint allows
    /// 30 requests/minute per IP, shared with everyone else on the same NAT,
    /// so an unlucky run of filtered pages must not spend that whole budget
    /// on one scroll. Three is arbitrary but small next to the 30/minute cap.
    private static let maxConsecutiveEmptyPages = 3

    /// Appends the next page. Driven by scroll position, not a button.
    func loadMore() async {
        guard hasMore, !isSearching, !isLoadingMore, !query.isEmpty else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }

        let mine = generation

        if case .offlineIndex = origin {
            await runOfflineSearch(mine: mine, page: query.page + 1, appending: true)
            return
        }

        var next = query
        var emptyPages = 0

        while true {
            next.page += 1
            let result = await repository.search(next)
            // The reader scrolled to the bottom of one search and typed
            // another before its page arrived: this page is for the old
            // search.
            guard !Task.isCancelled, mine == generation else { return }

            // A page that failed outright (`.staleAfter` with nothing on it)
            // is not the same event as a page that came back empty after
            // local filtering (gap 15). `SeriesRepository.search` already
            // keeps `hasMore == true` on that failure rather than reading it
            // as end-of-results — this mirrors that rather than re-deriving
            // it from emptiness, so a throttled page 4 cannot be mistaken for
            // three filtered-out pages in a row and silently trip
            // `stoppedEarly` instead of surfacing the real cause. `query.page`
            // is left at the last page that actually landed, so a retry from
            // the trailing `InlineFailure` asks for this same page again
            // rather than skipping it.
            if let pageError = result.blockingError {
                pageFailure = pageError
                hasMore = true
                return
            }
            pageFailure = nil

            // Deduplicate: the API repeats series across pages when the
            // underlying ordering shifts between requests, and a duplicate id
            // traps ForEach. Under sort_by=random it is not an edge case but
            // the normal outcome.
            let known = Set(results.map(\.id))
            let additions = result.series.filter { !known.contains($0.id) }

            query.page = next.page
            // The API's own signal, not the filtered count — see
            // FeedResult.hasMore. A genuinely last page (`hasMore == false`)
            // ends this regardless of whether this particular page added
            // anything.
            hasMore = result.hasMore

            if !additions.isEmpty {
                results.append(contentsOf: additions)
                return
            }
            guard hasMore else { return }

            emptyPages += 1
            guard emptyPages < Self.maxConsecutiveEmptyPages else {
                // Give up rather than keep spending the shared 30 req/min
                // budget chasing a run of filtered-out pages. This is not the
                // same as reaching the real end of the feed (gap 51) — the
                // API may still have more, this just stopped asking — so
                // `stoppedEarly` carries that difference for the view to say
                // out loud rather than looking identical to "that's all of
                // them".
                hasMore = false
                stoppedEarly = true
                return
            }
        }
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
        next.sort = "popularity_asc"
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
