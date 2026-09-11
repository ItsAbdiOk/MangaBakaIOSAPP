import Foundation

/// Reads character lists from AniList's GraphQL API.
///
/// **This path is currently unverifiable against the live API.** Every request
/// to `graphql.anilist.co` answers HTTP 403 with AniList's own message, "The
/// AniList API has been temporarily disabled due to severe stability issues"
/// (checked repeatedly on 2026-09-10). The query and the decoding here are
/// written from their published schema and covered by tests against recorded
/// shapes; they have not been run against a real response. When AniList comes
/// back, that is the thing to check first.
///
/// A fourth API with a fourth set of rules: POST-only GraphQL, a single
/// endpoint, and errors returned as HTTP 200 with an `errors` array as often as
/// they are returned as a status code.
actor AniListClient {
    /// AniList publishes 90 requests a minute. The app makes one per series
    /// page opened, so 700ms is far under it and costs nothing.
    static let minimumInterval: TimeInterval = 0.7

    /// AniList's stand-in when a character has no portrait. Rendering it gives
    /// a row of identical grey silhouettes, the same defect Shikimori's
    /// `missing_x96.jpg` produces.
    static func isPlaceholderPortrait(_ url: String) -> Bool {
        url.contains("/default.jpg")
    }

    private let endpoint: URL
    private let session: URLSession
    private let clock: any Clock
    private var spacing = RequestSpacing(minimumInterval: AniListClient.minimumInterval)

    init(
        endpoint: URL = URL(string: "https://graphql.anilist.co").unsafeAniListFallback,
        session: URLSession = .shared,
        clock: any Clock = SystemClock()
    ) {
        self.endpoint = endpoint
        self.session = session
        self.clock = clock
    }

    /// Sorted by role then relevance, so main characters lead without the app
    /// re-sorting. `perPage` is capped by AniList at 25.
    static let query = """
    query Cast($id: Int, $perPage: Int) {
      Media(id: $id, type: MANGA) {
        characters(sort: [ROLE, RELEVANCE], perPage: $perPage) {
          edges { role node { id name { full } image { large medium } } }
        }
      }
    }
    """

    // MARK: Response

    /// Flattened rather than nested to match the GraphQL shape one-for-one,
    /// because SwiftLint caps nesting at two levels and the real response is
    /// five deep.
    struct Response: Decodable, Sendable {
        let data: Payload?
        let errors: [GraphQLError]?
    }

    struct GraphQLError: Decodable, Sendable { let message: String? }

    struct Payload: Decodable, Sendable {
        let media: Media?
        /// Capitalised in a GraphQL response, and decodes as absent without
        /// this — the same trap as the library's capitalised `Series` key,
        /// which cost this app a silent decode failure once already.
        enum CodingKeys: String, CodingKey { case media = "Media" }
    }

    struct Media: Decodable, Sendable {
        let characters: CharacterConnection?
    }

    struct CharacterConnection: Decodable, Sendable {
        let edges: [CharacterEdge]?
    }

    struct CharacterEdge: Decodable, Sendable {
        /// "MAIN", "SUPPORTING", "BACKGROUND".
        let role: String?
        let node: CharacterNode?
    }

    struct CharacterNode: Decodable, Sendable {
        let id: Int?
        let name: CharacterName?
        let image: CharacterImage?
    }

    struct CharacterName: Decodable, Sendable { let full: String? }

    struct CharacterImage: Decodable, Sendable {
        let large: String?
        let medium: String?
    }

    func characters(mediaId: Int, limit: Int = 20) async throws(APIError) -> [SeriesCharacter] {
        try await waitForSlot()

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "query": Self.query,
            "variables": ["id": mediaId, "perPage": min(limit, 25)]
        ])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIError.transport(underlying: String(describing: error))
        }

        guard let http = response as? HTTPURLResponse else {
            throw APIError.transport(underlying: "AniList sent a non-HTTP response.")
        }
        if http.statusCode == 429 {
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            spacing.backOff(until: clock.now.addingTimeInterval(retryAfter ?? 60))
            throw APIError.rateLimited(retryAfter: retryAfter)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.server(
                status: http.statusCode,
                message: "AniList returned \(http.statusCode)."
            )
        }

        let decoded: Response
        do {
            decoded = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw APIError.decoding(underlying: String(describing: error))
        }

        // GraphQL reports failure inside a 200 as often as through a status
        // code. Treating a body with errors and no data as success would show
        // an empty cast row rather than falling back.
        if let errors = decoded.errors, !errors.isEmpty, decoded.data?.media == nil {
            throw APIError.server(
                status: http.statusCode,
                message: errors.compactMap(\.message).first ?? "AniList refused the query."
            )
        }

        let cast = Self.cast(from: decoded, limit: limit)
        // An empty cast is not an error, but it is also not an answer worth
        // preferring over the other source's.
        guard !cast.isEmpty else {
            throw APIError.server(status: http.statusCode, message: "AniList knows no cast.")
        }
        return cast
    }

    /// AniList already sorts by role, so this only drops what cannot be shown.
    static func cast(from response: Response, limit: Int) -> [SeriesCharacter] {
        let edges = response.data?.media?.characters?.edges ?? []
        return edges.compactMap { edge -> SeriesCharacter? in
            guard let node = edge.node,
                  let id = node.id,
                  let name = node.name?.full,
                  !name.isEmpty
            else { return nil }

            let image = node.image?.large ?? node.image?.medium
            guard let image, !isPlaceholderPortrait(image) else { return nil }

            return SeriesCharacter(
                id: id,
                name: name,
                // AniList shouts its roles; the app only ever compares against
                // "Main", and Shikimori's own casing is what that comparison
                // was written for.
                role: edge.role?.capitalized,
                imageURL: URL(string: image)
            )
        }
        .prefix(limit)
        .reduce(into: []) { $0.append($1) }
    }

    private func waitForSlot() async throws(APIError) {
        let wait = spacing.claim(now: clock.now)
        guard wait > 0 else { return }
        do {
            try await Task.sleep(for: .seconds(wait))
        } catch {
            throw APIError.transport(underlying: "Cancelled while waiting for a request slot.")
        }
    }
}

private extension Optional where Wrapped == URL {
    var unsafeAniListFallback: URL {
        guard let self else { preconditionFailure("Hard-coded AniList URL failed to parse.") }
        return self
    }
}
