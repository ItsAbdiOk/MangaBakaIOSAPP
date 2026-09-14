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
    /// Whether the reader has asked for anything yet — a keystroke, "Show
    /// results", a lens, "Surprise me". The screen's idle/answered split
    /// reads this, never `query.isEmpty`: a Type chip tapped on the idle
    /// panel is a query with filters and *nothing asked*, and deriving the
    /// screen from the query made that first tap replace the panel with
    /// "Nothing matched these filters" (review 2026-09-13, UX#1, seen on
    /// screen). Cleared when the field empties — × is "start over".
    private(set) var hasAsked = false
    /// A debounced search is scheduled but has not gone out. `isSearching`
    /// only turns on inside `search()`, so without this the ≥300 ms between
    /// the first keystroke and the request read as "asked, answered,
    /// nothing matched" (E F4) — the reader's first sight after one letter
    /// was a failure sentence.
    private(set) var isPending = false
    /// The API's `pagination.count` for the current search, nil when it did
    /// not carry one (the offline index, a failed page). Decoded into
    /// `FeedResult.total` from the start and never read here, so the
    /// heading said "30 shown" and the filter sheet spent a `limit=1`
    /// request asking for a number this model had already been handed
    /// (E F1, R F13).
    private(set) var total: Int?
    /// The page-one query the current `results` answer, text trimmed. Lets
    /// `search()` skip a byte-identical re-ask — Return after the debounce
    /// had already answered cost 2 of the shared 30/min for one answer
    /// (E F2), and `"one "` after `"one"` cost another (E F8).
    private var answered: SearchQuery?
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
    /// dropped rather than appended under the new one. Readable so the view
    /// can scroll back to the top when a new answer is on its way — a long
    /// grid followed by a short one left the offset wherever the clamp put
    /// it, and a new query's results opened partway down (R F5).
    private(set) var generation = 0
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
    var preferOffline = false {
        // The same query answered from the other source is a different
        // answer; forgetting the last one lets it be asked again.
        didSet { answered = nil }
    }

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
    /// What the debounce sleeps against. Injected so a test can move time
    /// rather than sleep through it — 25 tests spent 13.5 s of real
    /// `Task.sleep` waiting on debounces, and two of them waited less than
    /// the debounce they were racing, so a 150–220 ms stall failed them
    /// (item 129).
    ///
    /// Spelled with its module because this one does not: `MangaBaka` has its
    /// own `Clock` protocol (`Core/Persistence/Clock.swift`, a source of
    /// "now" for cache expiry), and an unqualified `Clock` resolves to that.
    nonisolated let clock: any _Concurrency.Clock<Duration>
    /// The text `apply(_:)` just set, so the field's own change observer can
    /// tell that edit from a keystroke. See `queryDidChange`. Stored as ""
    /// rather than nil for a text-less apply: a lens with no text applied
    /// over "naruto" fires the observer for "naruto" → nil, and a nil
    /// sentinel could not match it, so a second search was debounced and
    /// the generation bump threw the first answer away (E F5).
    private var appliedText: String?

    init(
        repository: any SeriesRepositoryProtocol,
        offline: OfflineCatalogue = OfflineCatalogue(),
        allowedRatings: @escaping @MainActor () -> [String] = { ["safe", "suggestive"] },
        allowedFormats: @escaping @MainActor () -> [String] = { [] },
        blockedTagIDs: @escaping @MainActor () -> [Int] = { [] },
        clock: any _Concurrency.Clock<Duration> = ContinuousClock()
    ) {
        self.repository = repository
        self.offline = offline
        self.allowedRatings = allowedRatings
        self.allowedFormats = allowedFormats
        self.blockedTagIDs = blockedTagIDs
        self.clock = clock
    }

    /// How long typing settles before a request goes out. Named rather than a
    /// literal so a test can read the same number the model sleeps for, and
    /// so the debounce's lower bound is testable at all (item 129). 300 ms
    /// arrived undated and underived; still a guess, not re-guessed here.
    static let queryDebounce: Duration = .milliseconds(300)

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
        if let appliedText, appliedText == query.text ?? "" {
            self.appliedText = nil
            return
        }
        appliedText = nil
        // Typing a title means you want that title, not a shuffle. "Surprise
        // me" sets `sort = "random"` and nothing ever unset it, so every search
        // after one tap of it was randomised: `q=one piece&sort_by=random`
        // answers 32 series and ONE PIECE is not among them, while relevance
        // answers 411 with it first. Measured on 2026-09-10. An emptied field
        // drops it too: the only way here with no text is the reader clearing
        // the field, and × after "Surprise me" used to run *another* shuffle
        // instead of going back to the idle panel (UX#5, 2026-09-13 walk).
        if query.sort == "random" {
            query.sort = nil
            query.randomSeed = nil
        }
        // An empty field is idle, whatever filters are still set: they stay
        // on the panel, visible and removable, rather than running as a
        // filter-only search under an unlabelled grid (UX#5, LW §1). One
        // character is "empty" here too (`SearchQuery.askedText`): it used
        // to fire a request the API answered with noise (LW §2).
        guard query.asAsked.text != nil else {
            resetToIdle()
            return
        }
        hasAsked = true
        scheduleDebouncedSearch()
    }

    /// The one debounce. Every caller that wants "search once the edits stop"
    /// goes through here, so a scope tap and a keystroke are spaced the same
    /// way rather than one of them going straight to the wire (item 51).
    private func scheduleDebouncedSearch() {
        isPending = true
        debounceTask = Task { [weak self, clock] in
            try? await clock.sleep(for: Self.queryDebounce)
            guard !Task.isCancelled else { return }
            await self?.search()
        }
    }

    /// The field's Cancel: text and tokens gone, back to the idle panel.
    /// Tokens are the tag, genre and publisher filters the field shows
    /// (`SearchToken`); the rest of the filters stay on the panel, where
    /// they live — Cancel clears what the field holds, not the panel.
    func cancelSearch() {
        cancelPendingDebounce()
        query.text = nil
        query.tags = []
        query.genres = []
        query.publisher = nil
        resetToIdle()
    }

    /// A token removed from the field, or a scope picked, mid-search: the
    /// grid must answer the query as it now stands, not the one the token
    /// was part of. Nothing asked yet (a token dropped, a scope picked, on
    /// the idle panel) stays nothing asked — the panel is not an ask (UX#1).
    ///
    /// Debounced, not immediate. A scope tap used to go straight to
    /// `search()`, so All → Manga → Manhwa → Manhua in two seconds was three
    /// `/v2/series/search` requests from a 30/min window shared with
    /// strangers, two of whose answers were downloaded and thrown away. The
    /// scope bar reads the query back rather than the results, so nothing on
    /// screen waits on the request (item 51).
    func filtersDidChange() {
        guard hasAsked else { return }
        cancelPendingDebounce()
        scheduleDebouncedSearch()
    }

    /// Back to the idle panel: nothing asked, nothing shown, nothing owed.
    private func resetToIdle() {
        results = []
        total = nil
        answered = nil
        failure = nil
        pageFailure = nil
        stoppedEarly = false
        isSearching = false
        isPending = false
        hasAsked = false
        hasMore = false
    }

    /// `total` when `query` is the search that produced it, else nil — so
    /// the filter sheet opened over results can label "Show N results"
    /// without a second request for a number already on screen (E F1).
    func knownTotal(for query: SearchQuery) -> Int? {
        query.asAsked == answered ? total : nil
    }

    /// How many rows the bundled index has for `query` under the reader's
    /// current rating/format/blocked-tag preferences — the panel's count
    /// while "Browse offline" is on, so the toggle's "zero requests" promise
    /// holds for the preview too (UX#2).
    func offlineCount(for query: SearchQuery) async -> Int? {
        await offline.count(
            query,
            allowedRatings: allowedRatings(),
            allowedTypes: allowedFormats(),
            blockedTags: blockedTagIDs()
        )
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
        isPending = false
        // Text too short to ask with is not a licence to ask without it.
        // `query.isEmpty` is false the moment any filter is set, so Return on
        // a one-character field with Type=Manhwa omitted `q` entirely and
        // answered 21,596 manhwa under a field showing "a" and a heading
        // reading "21,596 results". `RecentSearches` already refuses the same
        // term; the two rules now agree (item 49).
        if let text = query.text, !text.isEmpty, query.askedText == nil { return }
        guard !query.isEmpty else {
            resetToIdle()
            return
        }
        hasAsked = true
        // Already answered, and the answer is still good: Return after the
        // debounce, or "one " after "one", sends nothing. A failure is asked
        // again (that is what retry is), and random is a reshuffle every time.
        if let answered, answered == query.asAsked, failure == nil, query.sort != "random" {
            return
        }
        // Random pages against one seed, or page 2 is a fresh shuffle of
        // mostly-seen rows (E F7). Minted here when the sort chip set random
        // without one; `surpriseMe()` mints a new one per tap. Dropped the
        // moment the sort is anything else, so a stale seed cannot pin it.
        if query.sort == "random" {
            if query.randomSeed == nil { query.randomSeed = SearchQuery.freshRandomSeed() }
        } else {
            query.randomSeed = nil
        }
        isSearching = true
        // A deferred reset, so no early return can strand the spinner again.
        defer { isSearching = false }

        // A new search is page one by definition. Without this a reader who
        // paged to 4 and then typed a new query would get page 4 of it.
        query.page = 1
        generation += 1
        let mine = generation
        // No next page until this search's first one lands. Left over from
        // the previous search, `hasMore` let the view ask for page 2 of a
        // query that had not answered, and flipped true→false as a one-page
        // answer landed — firing the "end of results" haptic for it (R F10).
        hasMore = false
        total = nil
        answered = nil

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
        // Deduplicated like every later page: a repeated id within one page
        // (possible under `sort_by=random`) gave `ForEach` two views with
        // one identity (R F12).
        results = Self.uniqued(result.series)
        total = result.total
        answered = query.asAsked
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

    /// Answers `query` from `OfflineCatalogue` instead of the network. Shared
    /// by `search()` (page one) and `loadMore()` (later pages, `appending:
    /// true`) so paging against the bundled index works the same way paging
    /// against the API does.
    private func runOfflineSearch(mine: Int, page: Int, appending: Bool) async {
        let offset = (page - 1) * query.limit
        let offlinePage = await offline.page(
            query,
            allowedRatings: allowedRatings(),
            allowedTypes: allowedFormats(),
            blockedTags: blockedTagIDs(),
            limit: query.limit,
            offset: offset
        )
        let hits = offlinePage.hits
        guard mine == generation else { return }
        let built = await offline.builtDate() ?? "unknown"

        if appending {
            let known = Set(results.map(\.id))
            results.append(contentsOf: hits.map(\.series).filter { !known.contains($0.id) })
        } else {
            results = hits.map(\.series)
            // The size of the filtered set, computed once by the page slice
            // itself (`OfflineCatalogue.page`), so the heading reads "N
            // results" offline too.
            total = offlinePage.total
            answered = query.asAsked
        }
        query.page = page
        // Exact, from the filtered set's size — the offline equivalent of
        // reading the API's `pagination.next` rather than inferring the end
        // from a short page (which a locally filtered page cannot support).
        hasMore = offset + hits.count < offlinePage.total
        failure = nil
        pageFailure = nil
        stoppedEarly = false
        origin = .offlineIndex(builtDate: built)
    }

    /// "Surprise me": a random sort, searched at once. Keeps whatever else
    /// the query holds — the empty state's "Random with these filters" is
    /// the same gesture, and so is the panel's Random chip followed by
    /// "Show results": all three end in `search()`, which is the one place
    /// a seed is minted (UX#11, one implementation). The seed is dropped
    /// first so each tap is a new shuffle, whose later pages are the same
    /// shuffle.
    func surpriseMe() async {
        query.sort = "random"
        query.randomSeed = nil
        cancelPendingDebounce()
        await search()
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

    /// `/v2/series/search` accepts `page` up to 100 (`docs/schemas/
    /// mangabaka_openapi.json`). What page 101 answers is not on record; the
    /// walk used to ask for it and turn whatever came back into a retry
    /// button that could never succeed (E F9).
    private static let lastPage = 100

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
            guard next.page <= Self.lastPage else {
                hasMore = false
                return
            }
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
            if let count = result.total { total = count }

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
}

/// The explicit asks — a browse pick, a tag from a series page, a lens —
/// and the debounce control they share. An extension of the same file for
/// the lint's type-length ceiling; `private` is file-scoped, so nothing
/// widens.
extension SearchModel {
    /// Runs a search for a genre, tag or publisher picked while browsing.
    ///
    /// Adds to the query, the way the panel's Tags/Genres/Publishers pickers
    /// do. It used to replace it, so the two doors to the same vocabulary
    /// on one screen behaved differently after the pick (UX#11; decision
    /// 2026-09-13: Browse adds). The pick lands in the field as a token
    /// beside whatever was typed, removable on its own.
    ///
    /// A genre goes in `genres`, not `tags`: it used to ride in `tags` and
    /// reach the wire as `tag=`, which finds a fraction of the genre
    /// (`tag=romance` 14,065 against `genre=romance` 100,947, 2026-09-13 —
    /// see `SearchQuery.genres`). A sort only when there is none: paging
    /// drops ids already seen, so an unsorted query whose order shifts
    /// between pages loses rows.
    func applyBrowse(genre: String? = nil, tag: String? = nil, publisher: String? = nil) {
        var next = query
        if let genre, !next.genres.contains(genre) { next.genres.append(genre) }
        if let tag, !next.tags.contains(tag) { next.tags.append(tag) }
        if let publisher { next.publisher = publisher }
        if next.sort == nil { next.sort = "popularity_asc" }
        applyAtOnce(next)
    }

    /// A tag tapped on a series page: "show me this tag", not "this tag
    /// plus whatever my last search still held" — the reader left Search
    /// for that page and is arriving back through a different door than
    /// Browse's. Replaces the query outright, with the same stable sort.
    func openTag(_ tag: String) {
        var next = SearchQuery()
        next.tags = [tag]
        next.sort = "popularity_asc"
        applyAtOnce(next)
    }

    /// `apply(_:)` for a caller that cannot await: the query is assigned
    /// here, not in the task, so a caller reading it straight back sees the
    /// pick already in place.
    private func applyAtOnce(_ next: SearchQuery) {
        appliedText = next.text ?? ""
        query = next
        cancelPendingDebounce()
        Task { await search() }
    }

    /// Replaces the whole query and searches at once, without the debounce a
    /// keystroke gets. For the explicit triggers: a saved lens, a recent term,
    /// a browse. See `queryDidChange` for why the text is remembered first.
    func apply(_ next: SearchQuery) async {
        appliedText = next.text ?? ""
        query = next
        cancelPendingDebounce()
        await search()
    }

    /// Drops a pending debounce without touching an in-flight search. Call this
    /// before an explicit `search()` so a queued keystroke cannot re-fire after
    /// the reader has already submitted.
    func cancelPendingDebounce() {
        debounceTask?.cancel()
        isPending = false
    }
}

private extension SearchModel {
    nonisolated static func uniqued(_ series: [Series]) -> [Series] {
        var seen = Set<Int>()
        return series.filter { seen.insert($0.id).inserted }
    }

    nonisolated static func isOffline(_ error: APIError) -> Bool {
        if case .offline = error { return true }
        return false
    }

    /// Whether a blocking failure should fall back to the offline index rather
    /// than read as a dead end. Offline and rate-limited both mean the network
    /// path is temporarily unusable, not that the ask itself was wrong.
    nonisolated static func isOfflineEligible(_ error: APIError) -> Bool {
        switch error {
        case .offline, .rateLimited: true
        case .server, .decoding, .transport, .cancelled: false
        }
    }
}

private extension SearchQuery {
    /// This query as `SearchModel.answered` remembers it: page one, text
    /// trimmed (`"one "` is the same question as `"one"`), empty text as
    /// nil. The wire side trims too (`queryItems`); this is the comparison
    /// side (E F8).
    var asAsked: SearchQuery {
        var probe = self
        probe.page = 1
        probe.text = askedText
        return probe
    }
}
