import Foundation

/// Reads the signed-in reader's library and personalised data.
///
/// Read-only by design for now. Writing to someone's real library is a
/// different kind of action from browsing, and the screens that would justify
/// it do not exist yet — so the capability is deliberately absent rather than
/// present and unused.
actor LibraryService {
    private let client: APIClient
    /// Applied to personalised recommendations too.
    ///
    /// This is not optional politeness. Recommendations are built from the
    /// reader's own library, so without a filter a reader who has set the app
    /// to safe content still receives explicit suggestions — the setting would
    /// silently fail exactly where it matters most. The endpoint accepts
    /// content_rating, verified against the live API.
    private var contentRatings: [String]

    init(client: APIClient, contentRatings: [String] = ["safe", "suggestive"]) {
        self.client = client
        self.contentRatings = contentRatings
    }

    func updateContentRatings(_ ratings: [String]) {
        contentRatings = ratings
    }

    private var contentQuery: [URLQueryItem] {
        contentRatings.map { URLQueryItem(name: "content_rating", value: $0) }
    }

    /// A page of the reader's library, newest first as the API returns it.
    func library(page: Int = 1, limit: Int = 50) async -> [LibraryEntry] {
        let items: [LibraryEntry]? = try? await client.get(
            "/v1/my/library",
            query: [
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "limit", value: String(limit))
            ]
        )
        return items ?? []
    }

    /// Whether personalisation is available, and how much it has to work with.
    func recommendationStatus() async -> RecommendationStatus? {
        try? await client.getResults("/v1/my/series/recommendations/status")
    }

    /// Personalised recommendations, or an empty list when the library is too
    /// small to build a profile from.
    func recommendations(limit: Int = 20) async -> [PersonalRecommendation] {
        let results: [PersonalRecommendation]? = try? await client.getResults(
            "/v1/my/series/recommendations",
            query: [URLQueryItem(name: "limit", value: String(limit))] + contentQuery
        )
        return results ?? []
    }

    /// The reader's strongest tag affinities, highest first.
    func topGenres() async -> [TopGenre] {
        let results: [TopGenre]? = try? await client.getResults(
            "/v1/my/series/discover/top-genres"
        )
        return (results ?? []).sorted { ($0.affinityScore ?? 0) > ($1.affinityScore ?? 0) }
    }
}
