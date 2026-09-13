import Foundation

/// The browsing vocabulary: genres, tags and publishers.
///
/// These change rarely and are large, so they are fetched once and held rather
/// than requested per screen — the tag list alone runs to thousands of entries,
/// and re-fetching it while browsing would burn a rate limit shared with
/// strangers on the same network.
actor CatalogueService {
    private let client: APIClient

    /// The vocabulary, and whether it can be trusted as final. Doubles as the
    /// cache: once a call lands on `.loaded`, later callers within the limit
    /// it was fetched at are served from here rather than the network. A
    /// failure is never stored here — see `genres()`/`tags(limit:)` — so it
    /// stays `.idle` (or a previous success) and the next ask tries again.
    ///
    /// Replaces the `[Genre]?`/`[Tag]?` pair plus the `genresFetchFailed`/
    /// `tagsFetchFailed` flags nothing read (gap 39, 40, 41, 42,
    /// FAILURES-SUMMARY.md): those collapsed "the vocabulary is genuinely
    /// empty" and "the request failed" into the same `[]`, and the flags that
    /// were meant to tell them apart had no caller.
    private var genresState: Fetched<[Genre]> = .idle
    private var tagsState: Fetched<[Tag]> = .idle
    /// How many were asked for when `tagsState` was last filled.
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
    private var tagsInFlight: Task<Fetched<[Tag]>, Never>?
    private var genresInFlight: Task<Fetched<[Genre]>, Never>?

    init(client: APIClient) {
        self.client = client
    }

    func genres() async -> Fetched<[Genre]> {
        if case .loaded = genresState { return genresState }
        // Two screens opening at once are one request, not two.
        if let genresInFlight { return await genresInFlight.value }

        let task = Task<Fetched<[Genre]>, Never> { [client] in
            do throws(APIError) {
                let fetched: [Genre] = try await client.get("/v1/genres")
                return .loaded(fetched, fetchedAt: Date(), isPartial: false)
            } catch {
                // Not cached: a dropped packet used to cache an empty
                // vocabulary for the whole process; the next ask now tries
                // again.
                return .failed(error, stale: nil)
            }
        }
        genresInFlight = task
        let result = await task.value
        if case .loaded = result { genresState = result }
        genresInFlight = nil
        return result
    }

    /// - Parameter limit: the API paginates; a browsing screen wants the
    ///   heavily-used tags rather than all of them.
    func tags(limit: Int = 200) async -> Fetched<[Tag]> {
        // Serves a smaller ask from a bigger cache, refetches for a bigger one.
        if case .loaded = tagsState, cachedTagLimit >= limit { return tagsState }
        if let tagsInFlight, inFlightTagLimit >= limit { return await tagsInFlight.value }

        let task = Task<Fetched<[Tag]>, Never> { [client] in
            do throws(APIError) {
                let (fetched, pagination) = try await client.getWithPagination(
                    "/v1/tags",
                    query: [URLQueryItem(name: "limit", value: String(limit))],
                    as: [Tag].self
                )
                // Merged tags point at a survivor and should never be shown
                // or linked to. Ordered by how many series carry them,
                // because a tag on three series does not deserve the same
                // row as one on nine thousand.
                let usable = fetched
                    .filter(\.isUsable)
                    .sorted { ($0.seriesCount ?? 0) > ($1.seriesCount ?? 0) }
                // `next` is nil only on the last page. This was stamped
                // `isPartial: false` unconditionally while `?limit=500`
                // answered 500 of 7,146 with `next` set (live 2026-09-13) —
                // so the picker could not tell "the whole vocabulary" from
                // "the first four roots of it" and replaced its bundled
                // list with the latter. See `TagTaxonomy.merge`.
                return .loaded(usable, fetchedAt: Date(), isPartial: pagination?.next != nil)
            } catch {
                return .failed(error, stale: nil)
            }
        }
        tagsInFlight = task
        inFlightTagLimit = limit
        let result = await task.value
        if case .loaded = result {
            tagsState = result
            cachedTagLimit = limit
        }
        tagsInFlight = nil
        return result
    }

    /// Tags that sit directly under a parent, for walking the tree.
    func children(of parentId: Int?) async -> [Tag] {
        (await tags().value ?? []).filter { $0.parentId == parentId }
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
