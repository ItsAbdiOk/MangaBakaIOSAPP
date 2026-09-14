import Foundation

/// The reader's own library, grouped into shelves.
@MainActor
@Observable
final class LibraryModel {
    /// One state's worth of the library.
    struct Shelf: Identifiable, Equatable, Hashable {
        let state: LibraryEntry.State
        let entries: [LibraryEntry]
        /// A line saying what this shelf actually is, built from its contents.
        let note: String

        var id: String { state.rawValue }

        static func == (lhs: Shelf, rhs: Shelf) -> Bool { lhs.id == rhs.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
        var label: String { state.title }
        var count: Int { entries.count }
    }

    private(set) var entries: [LibraryEntry] = []
    private(set) var shelves: [Shelf] = []
    /// Filters every shelf. Local: the whole library is already in memory, and
    /// a request per keystroke against a shared rate limit would be absurd for
    /// something already on the device.
    var searchText = "" { didSet { refreshListed() } }

    /// Which state the list is narrowed to, or nil for all of them.
    var filter: LibraryEntry.State? { didSet { refreshListed() } }

    /// How the list is ordered.
    var sort: LibrarySort = .recentlyUpdated { didSet { refreshListed() } }
    private(set) var isLoading = false
    /// Whether a walk is still fetching pages.
    ///
    /// Distinct from `isLoading`, which goes false the moment the *first*
    /// page is drawn (that is the point of it — the screen appears in 270 ms
    /// rather than three and a half seconds). Work-list 4: `LibraryView`'s
    /// page-cap branch read `isLoading` for "still walking", so from page 2
    /// to the last page of every healthy walk the reader was shown
    /// "Showing the first 100" with its this-is-all-you-get icon.
    private(set) var isWalking = false
    /// Bumped whenever `entries` changes in any way a derived screen would
    /// care about — including a one-row patch through `apply(_:to:)`.
    ///
    /// Work-list 85: Insights and Wrapped keyed their `.task(id:)` on
    /// `"\(count)-\(isComplete)"`, which a rating or state change does not
    /// move, so "It finished without telling you" kept listing a series the
    /// reader had just marked Completed.
    private(set) var revision = 0
    /// Whether every page arrived. False means the counts on screen are a floor,
    /// not a total, and nothing may be stated as absent on the strength of them.
    private(set) var isComplete = true
    private(set) var failure: APIError?

    /// What the screen shows, decided in one place.
    enum ScreenState: Equatable {
        case loading
        case noAccount
        /// The walk failed before anything arrived. `failure` used to be
        /// stored here and read by no view, so a reader offline with 937
        /// series was shown "Nothing saved yet".
        case failed(APIError)
        case empty
        case list
    }

    var screenState: ScreenState {
        if isLoading && entries.isEmpty { return .loading }
        // Gap 84/85/89 (f): this used to be `!entries.isEmpty || !isComplete`
        // — a row count standing in for whether a token exists at all — which
        // read a signed-in reader with a genuinely empty library as having no
        // account, and (inverted) read an unreachable 937-series library as
        // having one. Whether there is an account to ask is its own question,
        // answered by `hasCredentials`, not guessed from what came back.
        guard hasCredentials() else { return .noAccount }
        if entries.isEmpty {
            if let failure { return .failed(failure) }
            return .empty
        }
        return .list
    }

    /// Deprecated alias kept only so call sites outside this batch that still
    /// read `hasAccount` keep compiling; `screenState` is the real decision
    /// now. See the report accompanying this change for the two assertions in
    /// `NonsenseGuardTests.swift` this inverts.
    var hasAccount: Bool { screenState != .noAccount }

    /// Set only once the walk has stopped short without emptying the screen —
    /// `!entries.isEmpty && !isComplete`. Distinct from `failure` alone: a
    /// walk still in flight is also incomplete, and a `StaleBar` drawn while
    /// page 4 of 13 is still landing would flash off again a moment later, so
    /// callers combine this with `isLoading` (see `LibraryView.partialLoad`)
    /// to tell "still walking" from "gave up" from "hit the page cap" (gap 83).
    var partialFailure: APIError? {
        guard !entries.isEmpty, !isComplete else { return nil }
        return failure
    }

    /// Whether the reader has narrowed the list at all — by typing or by
    /// picking a shelf. A search or filter matching nothing is a real answer
    /// ("Nothing matches"), not the same empty screen as never having saved
    /// anything (gap 91).
    var isFiltering: Bool { isSearching || filter != nil }

    private let library: any LibraryProviding
    private let snapshot: LibrarySnapshot
    /// Whether the reader has a MangaBaka credential to walk the library
    /// with, checked before any walk rather than inferred from what one
    /// returned. Defaulted to `true` so a test double that has no token
    /// store keeps its current behaviour; the app passes
    /// `{ tokenStore.hasToken }` from where `session.library` is built
    /// (work-list 86). Before that wiring, `ScreenState.noAccount` and the
    /// screen behind it were dead code and a reader with no token paid a 401
    /// per Library visit to be shown the generic failure.
    private let hasCredentials: () -> Bool
    /// Bumped by `reload()`, so a walk started before it and still landing
    /// pages cannot interleave its results with the newer walk's (gap 117).
    private var generation = 0

    init(
        library: any LibraryProviding,
        snapshot: LibrarySnapshot? = nil,
        hasCredentials: @escaping () -> Bool = { true }
    ) {
        self.library = library
        self.snapshot = snapshot ?? LibrarySnapshot(library: library)
        self.hasCredentials = hasCredentials
    }

    var total: Int { entries.count }
    /// What the "All" filter actually lists: everything but dropped. The pill
    /// used to show `total`, 937 over a list of about 500.
    private(set) var allCount = 0
    /// Chapters the reader has recorded across the whole library. Stored for
    /// the same reason `shape` and `subtitle` are — see `refreshFromEntries`.
    private(set) var chaptersRead = 0

    /// Every state that has anything in it, in reading order.
    ///
    /// Dropped is last on purpose — it is the one state a reader wants counted
    /// but not offered first.
    /// The shape bar's bands, the filtered list, and the jump rail.
    ///
    /// **Stored rather than computed.** SwiftUI evaluates a body far more often
    /// than a person changes a filter, and measured against a 1,000-entry
    /// library these cost 3ms, 4ms and another sort respectively — every pass,
    /// against a 16.7ms frame. They are recomputed when their inputs change and
    /// at no other time.
    private(set) var shape: [(state: LibraryEntry.State, count: Int)] = []
    private(set) var listed: [LibraryEntry] = []
    private(set) var jumpTargets: [(letter: String, id: Int)] = []

    /// Recomputes what depends only on `entries`.
    ///
    /// Work-list 93: these four used to be recomputed by the three `didSet`s
    /// too, so every keystroke in the search box rebuilt the shape bar, two
    /// whole-library counts and a filter-plus-sort that none of them could
    /// have changed. Called from both `apply`s and `forget`, and nowhere
    /// else.
    private func refreshFromEntries() {
        shape = Self.shape(of: entries)
        allCount = entries.count { $0.state != .dropped }
        subtitle = Self.subtitle(of: entries, isComplete: isComplete)
        inProgress = Self.inProgress(in: entries)
        // Work-list 106: `RootView` reduced all ~939 entries on every body
        // pass — every toast, every selection, every path change — to show
        // one number. It changes when `entries` does and at no other time.
        chaptersRead = ReadingInsights.chaptersRead(in: entries)
        revision += 1
        refreshListed()
    }

    /// Recomputes what the filter, the search box and the sort decide.
    private func refreshListed() {
        listed = Self.listed(from: entries, filter: filter, search: searchText, sort: sort)
        jumpTargets = Self.jumpTargets(in: listed)
    }

    /// Every state that has anything in it, in reading order.
    ///
    /// Dropped is last on purpose — it is the one state a reader wants counted
    /// but not offered first.
    private static func shape(of entries: [LibraryEntry]) -> [(state: LibraryEntry.State, count: Int)] {
        let order: [LibraryEntry.State] = [
            .reading, .rereading, .paused, .completed, .planToRead, .considering, .dropped
        ]
        // One pass rather than seven: counting the whole library once per state
        // is seven thousand comparisons on a real one.
        var counts: [LibraryEntry.State: Int] = [:]
        for entry in entries { counts[entry.state, default: 0] += 1 }
        return order.compactMap { state in
            let count = counts[state] ?? 0
            return count > 0 ? (state, count) : nil
        }
    }

    /// The list, after the filter, the search box and the sort.
    ///
    /// **Dropped is absent unless it is what you asked for.** It is a real part
    /// of the library and it is counted everywhere — the shape bar, the
    /// filter — but a list of everything you read that opens with the things
    /// you gave up on is a worse answer than one that does not.
    private static func listed(
        from entries: [LibraryEntry],
        filter: LibraryEntry.State?,
        search: String,
        sort: LibrarySort
    ) -> [LibraryEntry] {
        var rows = entries
        if let filter {
            rows = rows.filter { $0.state == filter }
        } else {
            rows = rows.filter { $0.state != .dropped }
        }

        let trimmed = search.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            rows = rows.filter { entry in
                guard let series = entry.series else { return false }
                return series.matches(trimmed)
            }
        }
        return sort.sorted(rows)
    }

    /// The letters actually present, in order, each paired with the first entry
    /// filed under it — which is what the rail scrolls to.
    ///
    /// The letters present, not A to Z: a rail offering Q and X to a library
    /// with neither is a rail that lies about where it can take you.
    private static func jumpTargets(in listed: [LibraryEntry]) -> [(letter: String, id: Int)] {
        var targets: [(letter: String, id: Int)] = []
        // A set, not `targets.last` (work-list 89). `Ø`, `Æ`, `Ł`, `Đ`, `Þ`
        // and `ß` fail `indexLetter`'s ASCII gate and bucket under "…", while
        // the collation sorts them among O, A, L, D, T and S — so a
        // title-sorted library can emit "O", "…", "O", and the rail's
        // `ForEach(id: \.element.letter)` gets a duplicate id, whose SwiftUI
        // behaviour is undefined. First occurrence wins, which is also right
        // for any future non-adjacent case.
        var seen = Set<String>()
        for entry in listed where seen.insert(entry.indexLetter).inserted {
            targets.append((entry.indexLetter, entry.seriesId))
        }
        return targets
    }

    /// Whether a jump index is worth the space.
    ///
    /// The design board draws one on a screen sorted by "Recently updated",
    /// and its own caption says the index only appears when sorted by title and
    /// above about two hundred entries. The caption wins: an A-Z rail down a
    /// list ordered by date points at nothing.
    var showsJumpIndex: Bool {
        sort == .title && listed.count >= 200
    }

    /// "1,204 series · 512 rated".
    ///
    /// Rated rather than shelved. The shape bar below says how the library is
    /// divided far better than a count of shelves ever did, and how much of it
    /// you have actually formed an opinion on is a thing nothing else answers.
    ///
    /// Stored, like `shape`: the two properties the first audit missed. On a
    /// 1,000-entry library, fifty reads of `inProgress` and `subtitle` cost
    /// 43 ms against 17 µs for the three already stored — 0.86 ms per body
    /// pass, measured 2026-09-11 in `RedrawPerformanceTests`.
    /// Gap 112: this used to default to "Nothing here yet" and stay there
    /// until the first page landed, which read as a genuinely empty library
    /// for every reader during the walk. Blank until `refreshFromEntries` has run
    /// at least once — see `screenState`, which is what actually decides
    /// whether "Nothing here yet" belongs on screen.
    private(set) var subtitle = ""

    private static func subtitle(of entries: [LibraryEntry], isComplete: Bool) -> String {
        guard !entries.isEmpty else { return "Nothing here yet" }
        return subtitle(
            count: entries.count,
            dropped: entries.count { $0.state == .dropped },
            rated: entries.count { ($0.rating ?? 0) > 0 },
            isComplete: isComplete
        )
    }

    /// The one rule for the two counts that sit a few points apart on the
    /// screen: this line and the "All" pill (`allCount`, everything but
    /// dropped). Seen on the simulator 2026-09-13: "942 series" over
    /// "All 513", with nothing on screen saying the 429 between them were
    /// the dropped shelf — two numbers for what read as one thing. The
    /// series count stays the whole library, but the dropped count is said
    /// beside it so the pill's number is derivable from this line
    /// (`count - dropped == allCount`, which the test asserts), and while the
    /// walk is still landing pages the count is labelled "so far", because
    /// until then it is a floor (see `isComplete`), not the library.
    nonisolated static func subtitle(count: Int, dropped: Int, rated: Int, isComplete: Bool) -> String {
        var parts = ["\(count.formatted()) series\(isComplete ? "" : " so far")"]
        if dropped > 0 { parts.append("\(dropped.formatted()) dropped") }
        parts.append("\(rated.formatted()) rated")
        return parts.joined(separator: " · ")
    }

    /// Mid-way through something, and still on it.
    ///
    /// Reading and rereading only. `tracksProgress` also covers paused, which
    /// put 226 series in "pick back up" on a real library — paused is a
    /// deliberate act of setting something down, not a thing to be nudged
    /// about.
    private(set) var inProgress: [LibraryEntry] = []

    private static func inProgress(in entries: [LibraryEntry]) -> [LibraryEntry] {
        entries
            .filter {
                ($0.state == .reading || $0.state == .rereading)
                    && ($0.progressChapter ?? 0) > 0
            }
            // An explicit tiebreak, for the reason `LibrarySort` records:
            // `sort` is not documented stable and most entries share
            // priority 0, so "Pick back up" — and Discover's copy of it —
            // could reorder between two refreshes of identical data
            // (work-list 94).
            .sorted {
                let left = $0.priority ?? 0
                let right = $1.priority ?? 0
                if left != right { return left > right }
                return $0.seriesId < $1.seriesId
            }
    }

    /// Re-reads after a write, so the screen reflects the server rather than
    /// what was typed into a sheet.
    ///
    /// Prefer `apply(_:to:)` at a call site that already knows what it wrote —
    /// decision 5 exists precisely because this is expensive (13 requests,
    /// 24.7 MB on a real account) and closes the sheet no sooner than the
    /// slowest of them. This stays for a write `apply` cannot patch locally
    /// (the entry is not currently loaded) and for an explicit Retry.
    func reload() async {
        // Bumped first: a page from the walk this replaces can still be in
        // flight, and without this its `apply` would interleave with the new
        // walk's (gap 117) — two page counts racing into `entries`.
        generation += 1
        // The shared snapshot has to be told, or a reload re-reads the copy
        // that was already wrong. Caught by three existing tests the moment the
        // snapshot was introduced: a write landed, the screen refetched, and
        // the cache handed back the library as it had been before the write.
        await snapshot.invalidate()
        entries = []
        // Work-list 5: the previous walk's "Some of your library didn't
        // load" bar used to stand through the whole of the new walk, so Retry
        // looked like it had failed again before it had asked anything.
        failure = nil
        await load()
    }

    func load() async {
        await Signposts.measure("Library load") { await fetchAll() }
    }

    private func fetchAll() async {
        guard entries.isEmpty else { return }
        let myGeneration = generation
        isLoading = true
        isWalking = true
        failure = nil
        defer {
            // Only this walk's own end clears the flags: a `reload()` fired
            // mid-walk has already started a newer one, and clearing them for
            // it would put the page-cap copy back on screen (work-list 4).
            // Written as an `if`, not a `guard ... else { return }`: a defer
            // body cannot transfer control out of itself.
            if generation == myGeneration {
                isLoading = false
                isWalking = false
            }
        }

        // One walk per session, shared with the taste ledger and the release
        // reminders. Measured on a real account: 939 entries is 24.7 MB, and
        // three separate walks was 74 MB to draw one screen.
        //
        // Drawn page by page as it arrives. Thirteen requests at ~270ms each is
        // three and a half seconds of blank screen if you wait for all of them,
        // and the first hundred entries land in the first one.
        await snapshot.observePages { @Sendable [weak self] partial in
            guard !partial.isEmpty else { return }
            Task { @MainActor in
                // Gap 117: a `reload()` fired while this walk's pages are
                // still landing must not let a page from the walk it replaced
                // land in `entries` after the newer walk has already reset it.
                guard let self, self.generation == myGeneration else { return }
                self.apply(partial, isComplete: false)
            }
        }
        let result = await snapshot.load()
        guard generation == myGeneration else { return }
        apply(result.entries, isComplete: result.isComplete)
        failure = result.failure
        // Work-list 15: anything the reader edited between two pages was
        // overwritten by `entries = rows` and is now replayed. The snapshot
        // does the same to its own copy before caching, so the two agree.
        pendingChanges.removeAll()
    }

    /// Patches one entry after a write lands, in memory and in the shared
    /// snapshot's cache, instead of re-walking the whole library to reflect
    /// it (gap 88/j, decision 5).
    ///
    /// The one-line call the shell needs at its write site, replacing a
    /// `reload()` there:
    /// ```
    /// await session.library.apply(change, to: seriesId)
    /// ```
    /// Falls back to doing nothing when the entry is not currently loaded —
    /// a series added for the first time has no local row to patch, and the
    /// caller should `reload()` (or just let the next natural load pick it
    /// up) in that case rather than this silently failing to show it.
    func apply(_ change: LibraryChange, to seriesId: Int) async {
        // Work-list 15: while the walk is still running, the next page
        // replaces `entries` wholesale and takes the edit with it — and the
        // pre-edit row is what the snapshot then caches for six hours. Held
        // here and replayed onto every page until the walk completes.
        if !isComplete {
            pendingChanges[seriesId] = pendingChanges[seriesId]?.merging(change) ?? change
        }
        guard let index = entries.firstIndex(where: { $0.seriesId == seriesId }) else { return }
        entries[index] = entries[index].applying(change)
        shelves = Self.shelves(from: entries)
        refreshFromEntries()
        await snapshot.apply(seriesId: seriesId, change: change)
    }

    /// Edits made while the walk was still landing pages, newest per series.
    /// See `apply(_:to:)` and work-list 15.
    private var pendingChanges: [Int: LibraryChange] = [:]

    /// Clears everything this model remembers about who was signed in.
    ///
    /// Gap 89 (f): `forgetPreviousAccount` clears seven other stores on an
    /// account change but not the library, so the previous account's shelves
    /// stayed on screen until relaunch. This is the call it needs:
    /// ```
    /// await session.library.forget()
    /// ```
    func forget() async {
        generation += 1
        await snapshot.invalidate()
        entries = []
        shelves = []
        failure = nil
        isComplete = true
        isWalking = false
        pendingChanges.removeAll()
        refreshFromEntries()
    }

    /// Shows what has arrived so far.
    ///
    /// `isComplete` stays false until the last page lands, so the screen keeps
    /// saying the counts are a floor rather than a total — a partial library
    /// presented as the whole one is how "Add to library" got offered for
    /// something already in it.
    private func apply(_ rows: [LibraryEntry], isComplete complete: Bool) {
        // Never guarded on rows being empty. A walk that failed on page one has
        // no rows and is emphatically not complete, and returning early here
        // left `isComplete` at its optimistic default — which is the exact bug
        // this whole partial-data idea exists to prevent. The page observer
        // skips empty emissions instead.
        // Work-list 15: `entries = rows` is what used to lose a mid-walk
        // edit. The patch is re-applied to every page it survives into.
        entries = pendingChanges.isEmpty ? rows : rows.map { row in
            guard let change = pendingChanges[row.seriesId] else { return row }
            return row.applying(change)
        }
        isComplete = complete
        shelves = Self.shelves(from: entries)
        refreshFromEntries()
        // The first page is enough to draw the screen; the spinner should stop
        // there rather than at the thirteenth.
        isLoading = false
    }

    var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Grouped by state and sorted by size, largest first.
    ///
    /// Size order rather than the reading-order most apps use, because the
    /// reading-order arrangement puts a 71-item shelf above a 429-item one and
    /// misrepresents the library. The measurement that settled this: 46%
    /// dropped, 8% reading.
    static func shelves(from entries: [LibraryEntry]) -> [Shelf] {
        Dictionary(grouping: entries, by: \.state)
            .map { state, entries in
                Shelf(state: state, entries: entries, note: note(for: state, entries: entries))
            }
            .sorted { $0.count > $1.count }
    }

    /// Says something true about the shelf rather than repeating its name.
    private static func note(for state: LibraryEntry.State, entries: [LibraryEntry]) -> String {
        switch state {
        case .dropped:
            let withNote = entries.filter { !($0.note ?? "").isEmpty }.count
            return withNote > 0
                ? "\(withNote) \(withNote == 1 ? "carries" : "carry") a note about why you stopped."
                : "What you gave up on. The strongest signal you have."
        case .reading, .rereading:
            let withProgress = entries.filter { ($0.progressChapter ?? 0) > 0 }.count
            // "1 have chapter progress recorded" and "0 of these you rated" are
            // both reachable on a real shelf, and this string is the screen's
            // subtitle, so they read as the headline description of it.
            return withProgress > 0
                ? "\(withProgress) \(withProgress == 1 ? "has" : "have") chapter progress recorded."
                : "Where you are partway through."
        case .completed:
            let rated = entries.filter { $0.rating != nil }.count
            return rated > 0
                ? "\(rated) of these you rated."
                : "Finished. None of them rated yet."
        case .paused:
            return "Set down rather than abandoned."
        case .planToRead:
            return "Queued, not started."
        case .considering:
            return "Maybes. The stack's pile, on the server."
        }
    }
}
