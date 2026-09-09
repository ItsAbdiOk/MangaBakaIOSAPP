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

    init(client: APIClient) {
        self.client = client
    }

    func genres() async -> [Genre] {
        if let cachedGenres { return cachedGenres }
        let fetched: [Genre]? = try? await client.get("/v1/genres")
        cachedGenres = fetched ?? []
        return cachedGenres ?? []
    }

    /// - Parameter limit: the API paginates; a browsing screen wants the
    ///   heavily-used tags rather than all of them.
    func tags(limit: Int = 200) async -> [Tag] {
        if let cachedTags { return cachedTags }
        let fetched: [Tag]? = try? await client.get(
            "/v1/tags",
            query: [URLQueryItem(name: "limit", value: String(limit))]
        )
        // Merged tags point at a survivor and should never be shown or linked
        // to. Ordered by how many series carry them, because a tag on three
        // series does not deserve the same row as one on nine thousand.
        cachedTags = (fetched ?? [])
            .filter(\.isUsable)
            .sorted { ($0.seriesCount ?? 0) > ($1.seriesCount ?? 0) }
        return cachedTags ?? []
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
