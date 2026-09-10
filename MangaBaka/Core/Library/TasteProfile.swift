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
    private var cached: Set<String>?
    private var cachedIDs: Set<Int>?
    private var inFlight: Task<Set<String>, Never>?
    private var inFlightIDs: Task<Set<Int>, Never>?

    init(library: any LibraryProviding, ledger: TasteLedger? = nil) {
        self.library = library
        self.ledger = ledger
    }

    /// Favoured tag names, lowercased for matching.
    ///
    /// Empty for a reader with no account or no library — which is correct, not
    /// a failure: with nothing to learn from, no tag is more theirs than
    /// another and the API's own order stands.
    func favouredTagNames() async -> Set<String> {
        if let cached { return cached }
        // Two series pages opened at once must not make two requests.
        if let inFlight { return await inFlight.value }

        let task = Task<Set<String>, Never> { [library] in
            let genres = await library.topGenres()
            return Set(genres.map { $0.tagName.lowercased() })
        }
        inFlight = task
        let result = await task.value
        cached = result
        inFlight = nil
        return result
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

        let task = Task<Set<Int>, Never> { [library, ledger] in
            await Self.buildIDs(library: library, ledger: ledger)
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
    /// tags and nothing is fetched per series. It is capped at ten pages of a
    /// hundred for the same reason `LibraryModel` is — a thousand entries is
    /// past the point where one more page changes what the reader is told about
    /// themselves.
    private static func buildIDs(
        library: any LibraryProviding,
        ledger: TasteLedger?
    ) async -> Set<Int> {
        if let ledger {
            for page in 1...10 {
                guard let batch = try? await library.libraryPage(page: page, limit: 100),
                      !batch.isEmpty
                else { break }
                try? await ledger.absorb(batch)
                if batch.count < 100 { break }
            }
        }

        let local = (try? await ledger?.favouredIDs()) ?? []
        let genres = Set(await library.topGenres().map(\.tagId))
        return local.union(genres)
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
