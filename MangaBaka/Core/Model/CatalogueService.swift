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
    /// The publisher a series names, by that name. The series carries names
    /// only, not ids, so this is a search — exact name first, else the first
    /// hit, else nil. Nil also on failure.
    func findPublisher(named name: String) async -> PublisherRecord? {
        guard let hits = await searchPublishers(name, limit: 10) else { return nil }
        let wanted = name.lowercased()
        return hits.first { $0.name.lowercased() == wanted } ?? hits.first
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
