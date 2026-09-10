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
    private var cached: Set<String>?
    private var cachedIDs: Set<Int>?
    private var inFlight: Task<Set<String>, Never>?

    init(library: any LibraryProviding) {
        self.library = library
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

    /// The same profile as tag ids.
    ///
    /// The reliable way to match. `/v1/my/series/discover/top-genres` is
    /// documented as returning *genre* tags — the coarse ones that drive the
    /// "Top in {genre}" rails — while a series page lists fine-grained tags, so
    /// comparing the two by name was nearly always going to miss. Ids are the
    /// same ids on both sides.
    func favouredTagIDs() async -> Set<Int> {
        if let cachedIDs { return cachedIDs }
        let genres = await library.topGenres()
        let ids = Set(genres.map(\.tagId))
        cachedIDs = ids
        return ids
    }

    /// Forgets the profile, so a change to the library is reflected.
    func invalidate() {
        cached = nil
        cachedIDs = nil
        inFlight = nil
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
