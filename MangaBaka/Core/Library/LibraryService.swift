import Foundation

/// Reads the signed-in reader's library and personalised data.
///
/// Read-only by design for now. Writing to someone's real library is a
/// different kind of action from browsing, and the screens that would justify
/// it do not exist yet — so the capability is deliberately absent rather than
/// present and unused.
/// What the swipe stack needs from the reader's account.
///
/// A protocol so the stack can be tested without a network: the concrete
/// service is an actor wrapping `APIClient`, and every test of "which source
/// did the queue come from" would otherwise have to go through URL stubbing to
/// answer a question that has nothing to do with URLs.
protocol LibraryProviding: Sendable {
    func recommendationStatus() async -> RecommendationStatus?
    func recommendations(limit: Int, page: Int, excluding: [Int]) async -> [PersonalRecommendation]
    func library(page: Int, limit: Int) async -> [LibraryEntry]
    /// Tags the reader has not opted into seeing named. Nil when unknown.
    func hiddenTagIDs() async -> Set<Int>?
}

actor LibraryService: LibraryProviding {
    private let client: APIClient
    /// Applied to personalised recommendations too.
    ///
    /// This is not optional politeness. Recommendations are built from the
    /// reader's own library, so without a filter a reader who has set the app
    /// to safe content still receives explicit suggestions — the setting would
    /// silently fail exactly where it matters most. The endpoint accepts
    /// content_rating, verified against the live API.
    private var contentRatings: [String]
    /// Formats to request, or empty for no filter. Mirrors the repository, so
    /// "no novels" means no novels here too rather than only in feeds.
    private var formats: [String] = []
    /// Cached because it is needed on nearly every blend and never changes for
    /// a given token.
    private var cachedProfileID: String?
    /// Keyed by the rating set it was built for, so changing the content
    /// setting rebuilds it rather than reusing a stale answer.
    private var cachedHiddenTags: (ratings: [String], ids: Set<Int>)?

    init(client: APIClient, contentRatings: [String] = ["safe", "suggestive"]) {
        self.client = client
        self.contentRatings = contentRatings
    }

    func updateContentRatings(_ ratings: [String]) {
        contentRatings = ratings
    }

    func updateFormats(_ formats: [String]) {
        self.formats = formats
    }

    /// The reader's own 32-character user id, or nil when unauthenticated.
    ///
    /// Needed because `exclude_user_library` is not the boolean its name
    /// suggests: it takes a user id string of at least 32 characters, and
    /// rejects `true` with "expected string, received boolean" (HTTP 400,
    /// verified 2026-09-09). Only ever the reader's own id — passing someone
    /// else's would be reading their library, which is a question for
    /// MangaBaka before it is a feature.
    func profileID() async -> String? {
        if let cachedProfileID { return cachedProfileID }
        let id = await client.profile()?.id
        cachedProfileID = id
        return id
    }

    /// Called when the token changes, so a second account cannot inherit the
    /// first account's cached id.
    func forgetProfile() {
        cachedProfileID = nil
    }

    private var filterQuery: [URLQueryItem] {
        contentRatings.map { URLQueryItem(name: "content_rating", value: $0) }
            + formats.map { URLQueryItem(name: "type", value: $0) }
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
        // Bare, not enveloped. See APIClient.getRoot — this endpoint is the
        // reason that method exists.
        try? await client.getRoot("/v1/my/series/recommendations/status")
    }

    /// Personalised recommendations, or an empty list when the library is too
    /// small to build a profile from.
    ///
    /// Built from the reader's whole library rather than from a handful of
    /// seeds, and unlike `mix` it takes `page` and `exclude_ids` — so it can
    /// keep going indefinitely without repeating itself.
    ///
    /// The content filter is honoured by the API, verified rather than assumed:
    /// requesting `safe` returned twenty series that all read back as `safe`,
    /// while allowing everything returned twenty that read back as
    /// `pornographic` (2026-09-09). That matters more here than anywhere else,
    /// because these are built from the reader's own library.
    func recommendations(
        limit: Int = 20,
        page: Int = 1,
        excluding excludedIDs: [Int] = []
    ) async -> [PersonalRecommendation] {
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if page > 1 { query.append(URLQueryItem(name: "page", value: String(page))) }
        // Repeated keys. Every list parameter on this API that has been checked
        // wants repeated keys, and the two that were comma-joined on a guess
        // both returned HTTP 400.
        query += excludedIDs.map { URLQueryItem(name: "exclude_ids", value: String($0)) }
        query += filterQuery

        let results: [PersonalRecommendation]? = try? await client.getResults(
            "/v1/my/series/recommendations",
            query: query
        )
        return results ?? []
    }

    /// Tag ids whose own content rating the reader has not opted into.
    ///
    /// Used to keep explicit tag names out of the recommender's explanations.
    /// Only 151 of the API's 7,105 tags are rated erotica or pornographic
    /// (measured 2026-09-09), so this is one or two requests, cached.
    ///
    /// Returns nil when the answer is not known — a failed fetch, say. Callers
    /// treat nil as "withhold the explanation", because showing an unverified
    /// tag name is the failure worth avoiding; a missing caption is not.
    func hiddenTagIDs() async -> Set<Int>? {
        let disallowed = ContentPreferences.Rating.allCases
            .map(\.rawValue)
            .filter { !contentRatings.contains($0) }
        // Nothing is disallowed, so nothing needs hiding and nothing is fetched.
        guard !disallowed.isEmpty else { return [] }

        if let cachedHiddenTags, cachedHiddenTags.ratings == contentRatings {
            return cachedHiddenTags.ids
        }

        var ids: Set<Int> = []
        // Two pages covers the 151 that exist, with room to grow. A cap rather
        // than a while-true: an unbounded loop against someone else's
        // pagination is how a client accidentally hammers an API.
        for page in 1...3 {
            var query = [URLQueryItem(name: "limit", value: "100")]
            if page > 1 { query.append(URLQueryItem(name: "page", value: String(page))) }
            query += disallowed.map { URLQueryItem(name: "content_rating", value: $0) }

            guard let batch: [Tag] = try? await client.get("/v1/tags", query: query) else {
                // Unknown, not empty. Returning an empty set here would read as
                // "nothing is explicit" and show every tag name.
                return nil
            }
            ids.formUnion(batch.map(\.id))
            if batch.count < 100 { break }
        }

        cachedHiddenTags = (contentRatings, ids)
        return ids
    }

    /// The reader's strongest tag affinities, highest first.
    func topGenres() async -> [TopGenre] {
        let results: [TopGenre]? = try? await client.getResults(
            "/v1/my/series/discover/top-genres"
        )
        return (results ?? []).sorted { ($0.affinityScore ?? 0) > ($1.affinityScore ?? 0) }
    }
}
