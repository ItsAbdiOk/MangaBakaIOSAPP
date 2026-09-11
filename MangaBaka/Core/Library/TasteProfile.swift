import Foundation

/// The tags this reader actually likes, from their own library.
///
/// Exists to answer one question cheaply: given a series' tags, which of them
/// matter to *this* reader? A series carries up to a hundred and sixteen tags
/// (Solo Leveling does), the page shows twelve, and without this the twelve are
/// whichever the API happened to list first. A reader who reads fantasy and
/// action can have both buried behind "+104 more".
///
/// **What it costs.** One request, once per session, to an endpoint the app
/// already calls for the taste screen — and the answer is a few dozen rows. The
/// match itself is a set lookup per tag: about a hundred lookups against a set
/// of twenty, which is nothing on any device that can render the page it sits
/// on. It cannot slow the page down, because it never blocks it: tags render
/// unsorted if the profile has not arrived, and the profile arrives with the
/// same fetch that brings the tags.
actor TasteProfile {
    private let library: any LibraryProviding
    /// Where the fine-grained half of the answer comes from. Optional so tests
    /// and previews can run without a database.
    private let ledger: TasteLedger?
    /// The shared library walk. Without it this walked the library itself, and
    /// the library is 24.7 MB.
    private let snapshot: LibrarySnapshot?
    private var cached: Set<String>?
    private var cachedIDs: Set<Int>?
    private var inFlight: Task<Set<String>?, Never>?
    private var inFlightIDs: Task<Set<Int>, Never>?

    init(
        library: any LibraryProviding,
        ledger: TasteLedger? = nil,
        snapshot: LibrarySnapshot? = nil
    ) {
        self.library = library
        self.ledger = ledger
        self.snapshot = snapshot
    }

    /// Favoured tag names, lowercased for matching.
    ///
    /// Empty for a reader with no account or no library — which is correct, not
    /// a failure: with nothing to learn from, no tag is more theirs than
    /// another and the API's own order stands.
    func favouredTagNames() async -> Set<String> {
        if let cached { return cached }
        // Two series pages opened at once must not make two requests.
        if let inFlight { return await inFlight.value ?? [] }

        let task = Task<Set<String>?, Never> { [library] in
            let genres = await library.topGenres()
            return genres.map { Set($0.map { $0.tagName.lowercased() }) }
        }
        inFlight = task
        let result = await task.value
        // A failed request is not cached as "likes nothing" for the session;
        // the next series page asks again.
        if let result { cached = result }
        inFlight = nil
        return result ?? []
    }

    /// The tags this reader's own reading is actually made of.
    ///
    /// Two sources, unioned:
    ///
    /// - **The ledger** — counted locally from the reader's library, so it can
    ///   name fine-grained tags like Regression or Murim. This is the half that
    ///   answers the question people actually ask.
    /// - **`top-genres`** — the API's own profile. Kept because it is computed
    ///   server-side from data we may not have paged through yet, and because
    ///   it costs one request that the taste screen makes anyway.
    ///
    /// Matched by id, never by name. The two endpoints spell tags differently
    /// and matching strings found exactly one tag in a series carrying 146.
    func favouredTagIDs() async -> Set<Int> {
        if let cachedIDs { return cachedIDs }
        // Two series pages opened at once must not both page the library.
        if let inFlightIDs { return await inFlightIDs.value }

        let task = Task<Set<Int>, Never> { [library, ledger, snapshot] in
            await Self.buildIDs(library: library, ledger: ledger, snapshot: snapshot)
        }
        inFlightIDs = task
        let ids = await task.value
        cachedIDs = ids
        inFlightIDs = nil
        return ids
    }

    /// Fills the ledger from the library, then reads both sources.
    ///
    /// The library pass is not an extra cost in the sense that matters: v1 list
    /// responses embed the whole `tags_v2` array, so the pages carry their own
    /// tags and nothing is fetched per series. The cap matches `LibraryModel`'s
    /// for the same reason: bounded, but far past any real library. Ten pages
    /// was not — Abdi's library is 937 entries against a 1,000 ceiling.
    private static func buildIDs(
        library: any LibraryProviding,
        ledger: TasteLedger?,
        snapshot: LibrarySnapshot?
    ) async -> Set<Int> {
        if let ledger, let snapshot {
            try? await ledger.absorb(await snapshot.all())
        }

        let local = (try? await ledger?.favouredIDs()) ?? []
        let genres = Set((await library.topGenres() ?? []).map(\.tagId))
        return local.union(genres)
    }

    /// Counts a series the app has just decoded in full, if the reader has it.
    ///
    /// The library's own payload may carry no tags — see `TasteLedger.absorb`.
    /// This is the path that definitely works: every series page and every feed
    /// row carries `tags_v2`, so the profile fills in as the reader moves
    /// around rather than depending on one endpoint's shape.
    func note(_ series: Series) async {
        guard let ledger, let snapshot, !series.richTags.isEmpty else { return }
        let entries = await snapshot.all()
        guard let entry = entries.first(where: { $0.seriesId == series.id }) else { return }
        try? await ledger.absorb(series, as: entry.state)
        // The cached answer was computed before this series was counted.
        cachedIDs = nil
    }

    /// What the ledger actually knows, for a screen that has to say so.
    func diagnostics() async -> (series: Int, tags: Int) {
        guard let ledger else { return (0, 0) }
        return (
            (try? await ledger.countedSeries()) ?? 0,
            (try? await ledger.knownTags()) ?? 0
        )
    }

    /// Forgets everything learned from the account that was signed in.
    ///
    /// For a token change, which is a change of person. The in-memory caches
    /// alone are not enough: the ledger is on disk and survives a relaunch, so
    /// without this a new reader inherits the last one's taste and every
    /// recommendation is quietly about somebody else's library.
    func forgetEverything() async {
        try? await ledger?.clear()
        invalidate()
    }

    /// Forgets the profile, so a change to the library is reflected.
    func invalidate() {
        cached = nil
        cachedIDs = nil
        inFlight = nil
        inFlightIDs = nil
    }
}

enum TagOrdering {
    /// A series' tags with the reader's own interests first.
    ///
    /// A stable partition, not a sort: the API's ordering is meaningful within
    /// each group — it leads with the tags most characteristic of the series —
    /// and reshuffling it would trade one arbitrary order for another.
    static func favouredFirst(_ tags: [String], favoured: Set<String>) -> [String] {
        guard !favoured.isEmpty else { return tags }
        let mine = tags.filter { favoured.contains($0.lowercased()) }
        let rest = tags.filter { !favoured.contains($0.lowercased()) }
        return mine + rest
    }

    static func isFavoured(_ tag: String, favoured: Set<String>) -> Bool {
        favoured.contains(tag.lowercased())
    }
}
