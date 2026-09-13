import Foundation

/// The browsing vocabulary: genres, tags and publishers.
///
/// These change rarely and are large, so they are fetched once and held rather
/// than requested per screen — the tag list alone runs to thousands of entries,
/// and re-fetching it while browsing would burn a rate limit shared with
/// strangers on the same network.
actor CatalogueService {
    private let client: APIClient

    private var cachedGenres: [Genre]?
    private var cachedTags: [Tag]?
    /// How many were asked for when the cache was filled.
    ///
    /// **The cache used to ignore the limit**, so whichever screen asked first
    /// decided for everyone: Browse asks for 200 and the tag picker asks for
    /// 500, and the picker silently got 200 and told the reader it was
    /// searching all of them. A cache keyed on nothing is a cache that answers
    /// a different question than the one asked.
    private var cachedTagLimit = 0
    /// The limit of the fetch in progress, so a second caller can join it.
    /// This used to compare against `cachedTagLimit`, which is only set once
    /// the fetch lands — so two screens opening together never joined.
    private var inFlightTagLimit = 0
    private var tagsInFlight: Task<[Tag]?, Never>?
    private var genresInFlight: Task<[Genre]?, Never>?

    /// Whether the most recent `genres()`/`tags()` call answered `[]` because
    /// the request failed, as opposed to the vocabulary genuinely being
    /// empty. Both methods keep returning `[]` for either case — every
    /// existing caller (`BrowseModel`, `TagPickerSheet`,
    /// `BlockedTagsSection`) reads only the array and needs no change — this
    /// is purely additive, for a caller that wants to tell "nothing there"
    /// from "the network is down" without widening the return type
    /// everywhere `[Genre]`/`[Tag]` is already relied on.
    private(set) var genresFetchFailed = false
    private(set) var tagsFetchFailed = false

    init(client: APIClient) {
        self.client = client
    }

    func genres() async -> [Genre] {
        if let cachedGenres { return cachedGenres }
        // Two screens opening at once are one request, not two.
        if let genresInFlight { return await genresInFlight.value ?? [] }

        let task = Task<[Genre]?, Never> { [client] in
            try? await client.get("/v1/genres")
        }
        genresInFlight = task
        let fetched = await task.value
        // Only an answer is cached. A dropped packet used to cache an empty
        // vocabulary for the whole process; the next ask now tries again.
        if let fetched { cachedGenres = fetched }
        genresFetchFailed = fetched == nil
        genresInFlight = nil
        return fetched ?? []
    }

    /// - Parameter limit: the API paginates; a browsing screen wants the
    ///   heavily-used tags rather than all of them.
    func tags(limit: Int = 200) async -> [Tag] {
        // Serves a smaller ask from a bigger cache, refetches for a bigger one.
        if let cachedTags, cachedTagLimit >= limit { return cachedTags }
        if let tagsInFlight, inFlightTagLimit >= limit { return await tagsInFlight.value ?? [] }

        let task = Task<[Tag]?, Never> { [client] in
            let fetched: [Tag]? = try? await client.get(
                "/v1/tags",
                query: [URLQueryItem(name: "limit", value: String(limit))]
            )
            // Merged tags point at a survivor and should never be shown or
            // linked to. Ordered by how many series carry them, because a tag
            // on three series does not deserve the same row as one on nine
            // thousand.
            return fetched?
                .filter(\.isUsable)
                .sorted { ($0.seriesCount ?? 0) > ($1.seriesCount ?? 0) }
        }
        tagsInFlight = task
        inFlightTagLimit = limit
        let fetched = await task.value
        if let fetched {
            cachedTags = fetched
            cachedTagLimit = limit
        }
        tagsFetchFailed = fetched == nil
        tagsInFlight = nil
        return fetched ?? []
    }

    /// Tags that sit directly under a parent, for walking the tree.
    func children(of parentId: Int?) async -> [Tag] {
        await tags().filter { $0.parentId == parentId }
    }

    /// Tags matching a typed query, asked of the API rather than filtered here.
    ///
    /// **There are 7,127 tags.** The screens that let you pick one load 500 and
    /// filtered that list locally, so searching "romance" — a tag on thousands
    /// of series — found nothing at all and the screen simply emptied. Measured
    /// against the live API on 2026-09-10: `/v1/tags?limit=500` does not
    /// contain Romance, and `?q=romance` returns 35 tags including it.
    ///
    /// Returns nil, not an empty array, when the request fails: "no tags match"
    /// and "the network is down" must not look the same on screen.
    func searchTags(_ text: String, limit: Int = 60) async -> [Tag]? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let results: [Tag]? = try? await client.get(
            "/v1/tags",
            query: [
                URLQueryItem(name: "q", value: trimmed),
                URLQueryItem(name: "limit", value: String(limit))
            ]
        )
        guard let results else { return nil }
        return results
            .filter(\.isUsable)
            .sorted { ($0.seriesCount ?? 0) > ($1.seriesCount ?? 0) }
    }

    /// Nil on failure, for the same reason as `searchTags`: "no publisher by
    /// that name" and "the request failed" must not look the same on screen.
    /// It used to return `[]` for both, eight lines under the comment saying
    /// not to.
    ///
    /// The publisher a series names, by that name. The series carries names
    /// only, not ids, so this is a search.
    ///
    /// Measured live 2026-09-13: `q=Ize Press (Yen Press)` returns `[]` —
    /// the directory does not index the composite string a series' credit
    /// sometimes is — so a name with a parenthetical is also tried as its two
    /// halves ("Ize Press", then "Yen Press"). Within whichever candidate
    /// gets hits: exact name first, else a hit this candidate is a *prefix*
    /// of, else the next candidate. `?? hits.first` used to fall back to an
    /// unrelated publisher whenever nothing matched exactly — measured the
    /// same day: `q=Kodansha` returns `["Kodansha USA","Kodansha Manga",
    /// "Kodansha"]`, so plain "Kodansha" must still resolve to the exact
    /// "Kodansha" (not the alphabetically-first "Kodansha USA"), and
    /// "Kodansha Comics" — naming nothing in that list — must resolve to nil
    /// rather than decorating its page with one of the other three.
    func findPublisher(named name: String) async -> PublisherRecord? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        for candidate in Self.searchCandidates(for: trimmed) {
            guard let hits = await searchPublishers(candidate, limit: 10) else { continue }
            if let match = Self.bestMatch(for: candidate, in: hits) { return match }
        }
        return nil
    }

    /// The name as given, plus — for "X (Y)" — "X" and "Y" on their own, in
    /// that order: the composite is tried first because it is occasionally
    /// exactly right, and splitting first would cost an extra request for
    /// every ordinary, non-composite name.
    private static func searchCandidates(for name: String) -> [String] {
        var candidates = [name]
        guard let openParen = name.firstIndex(of: "("),
              let closeParen = name.lastIndex(of: ")"),
              openParen < closeParen
        else { return candidates }
        let before = name[name.startIndex..<openParen].trimmingCharacters(in: .whitespaces)
        let inside = name[name.index(after: openParen)..<closeParen].trimmingCharacters(in: .whitespaces)
        if !before.isEmpty { candidates.append(before) }
        if !inside.isEmpty { candidates.append(inside) }
        return candidates
    }

    /// An exact, case-insensitive name match, else a hit this name is a
    /// prefix of ("Yen Press" finding "Yen Press LLC"). Never the reverse —
    /// a longer wanted name being a prefix of a shorter hit would have
    /// matched "Kodansha Comics" against "Kodansha", a different publisher
    /// that merely starts the same way.
    private static func bestMatch(for wanted: String, in hits: [PublisherRecord]) -> PublisherRecord? {
        let lowered = wanted.lowercased()
        return hits.first { $0.name.lowercased() == lowered }
            ?? hits.first { $0.name.lowercased().hasPrefix(lowered) }
    }

    func publisher(id: Int) async -> PublisherDetail? {
        try? await client.get("/v1/publishers/\(id)/full")
    }

    func searchPublishers(_ text: String, limit: Int = 30) async -> [PublisherRecord]? {
        try? await client.get(
            "/v1/publishers/search",
            query: [
                URLQueryItem(name: "q", value: text),
                URLQueryItem(name: "limit", value: String(limit))
            ]
        )
    }
}
