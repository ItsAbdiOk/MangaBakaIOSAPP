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
    private var tagsInFlight: Task<[Tag], Never>?
    private var genresInFlight: Task<[Genre], Never>?

    init(client: APIClient) {
        self.client = client
    }

    func genres() async -> [Genre] {
        if let cachedGenres { return cachedGenres }
        // Two screens opening at once are one request, not two.
        if let genresInFlight { return await genresInFlight.value }

        let task = Task<[Genre], Never> { [client] in
            (try? await client.get("/v1/genres")) ?? []
        }
        genresInFlight = task
        let fetched = await task.value
        cachedGenres = fetched
        genresInFlight = nil
        return fetched
    }

    /// - Parameter limit: the API paginates; a browsing screen wants the
    ///   heavily-used tags rather than all of them.
    func tags(limit: Int = 200) async -> [Tag] {
        // Serves a smaller ask from a bigger cache, refetches for a bigger one.
        if let cachedTags, cachedTagLimit >= limit { return cachedTags }
        if let tagsInFlight, cachedTagLimit >= limit { return await tagsInFlight.value }

        let task = Task<[Tag], Never> { [client] in
            let fetched: [Tag]? = try? await client.get(
                "/v1/tags",
                query: [URLQueryItem(name: "limit", value: String(limit))]
            )
            // Merged tags point at a survivor and should never be shown or
            // linked to. Ordered by how many series carry them, because a tag
            // on three series does not deserve the same row as one on nine
            // thousand.
            return (fetched ?? [])
                .filter(\.isUsable)
                .sorted { ($0.seriesCount ?? 0) > ($1.seriesCount ?? 0) }
        }
        tagsInFlight = task
        let fetched = await task.value
        cachedTags = fetched
        cachedTagLimit = limit
        tagsInFlight = nil
        return fetched
    }

    /// Tags that sit directly under a parent, for walking the tree.
    func children(of parentId: Int?) async -> [Tag] {
        await tags().filter { $0.parentId == parentId }
    }

    func searchPublishers(_ text: String, limit: Int = 30) async -> [PublisherRecord] {
        let results: [PublisherRecord]? = try? await client.get(
            "/v1/publishers/search",
            query: [
                URLQueryItem(name: "q", value: text),
                URLQueryItem(name: "limit", value: String(limit))
            ]
        )
        return results ?? []
    }
}
