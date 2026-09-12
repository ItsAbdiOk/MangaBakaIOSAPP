import Foundation

/// Reads character lists and profiles from AniList's GraphQL API.
///
/// **Re-verified live on 2026-09-12.** From at least 2026-09-10, every request
/// to `graphql.anilist.co` answered HTTP 403 with AniList's own message, "The
/// AniList API has been temporarily disabled due to severe stability issues" —
/// long enough that the query and decoding below were written and tested only
/// against recorded shapes, never against a real response. That outage is
/// over: `POST https://graphql.anilist.co` now answers HTTP 200 with real
/// character data, checked directly with curl. Recorded here rather than
/// deleted, because the 403 was real and cost real time, and the next person
/// to see this client fail should know both that it has failed before and
/// that failure was not this.
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
                imageURL: URL(string: image),
                source: .aniList
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

/// The character-profile query, kept in its own extension (rather than in the
/// actor's own body above) purely to keep `AniListClient`'s type body under
/// SwiftLint's length cap — `private` members declared in the actor's primary
/// declaration stay reachable from an extension of the same type in the same
/// file, so `waitForSlot`, `endpoint`, `session` and `clock` are usable here
/// exactly as they are above.
extension AniListClient {
    /// One character's full profile: name, portrait, the facts AniList
    /// tracks, and the description. Verified live against character 138789
    /// (Cha Hae-In) on 2026-09-12 — this is the real response shape, not only
    /// the published schema.
    static let profileQuery = """
    query Profile($id: Int) {
      Character(id: $id) {
        id
        name { full native alternative }
        image { large medium }
        description
        gender
        age
        bloodType
        dateOfBirth { year month day }
        favourites
        siteUrl
      }
    }
    """

    struct ProfileResponse: Decodable, Sendable {
        let data: ProfilePayload?
        let errors: [GraphQLError]?
    }

    struct ProfilePayload: Decodable, Sendable {
        let character: ProfileCharacterNode?
        /// Same capitalisation trap as `Payload.CodingKeys` above.
        enum CodingKeys: String, CodingKey { case character = "Character" }
    }

    struct ProfileCharacterNode: Decodable, Sendable {
        let id: Int?
        let name: ProfileName?
        let image: CharacterImage?
        let description: String?
        let gender: String?
        /// A string, not an Int — AniList documents this field as freeform
        /// text and sends ranges like "17-18" for characters whose age
        /// changes across the story.
        let age: String?
        let bloodType: String?
        let dateOfBirth: ProfileDate?
        let favourites: Int?
        let siteUrl: String?
    }

    struct ProfileName: Decodable, Sendable {
        let full: String?
        let native: String?
        let alternative: [String]?
    }

    struct ProfileDate: Decodable, Sendable {
        let year: Int?
        let month: Int?
        let day: Int?
    }

    /// Fetches one character's AniList profile.
    ///
    /// - Parameter characterID: an id AniList itself issued. The only source
    ///   of one of these from a `SeriesCharacter` is
    ///   `CharacterProfileRequest.aniListID(for:)` — a Shikimori-issued id
    ///   passed here would return a real, wrong person with no sign anything
    ///   went wrong.
    func characterProfile(characterID: Int) async throws(APIError) -> CharacterProfile {
        try await waitForSlot()

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "query": Self.profileQuery,
            "variables": ["id": characterID]
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
            throw APIError.server(status: http.statusCode, message: "AniList returned \(http.statusCode).")
        }

        let decoded: ProfileResponse
        do {
            decoded = try JSONDecoder().decode(ProfileResponse.self, from: data)
        } catch {
            throw APIError.decoding(underlying: String(describing: error))
        }

        // Same trap as the cast query: GraphQL reports failure inside a 200
        // as often as through a status code.
        if let errors = decoded.errors, !errors.isEmpty, decoded.data?.character == nil {
            throw APIError.server(
                status: http.statusCode,
                message: errors.compactMap(\.message).first ?? "AniList refused the query."
            )
        }

        guard let profile = Self.profile(from: decoded) else {
            throw APIError.server(status: http.statusCode, message: "AniList knows no such character.")
        }
        return profile
    }

    /// Pure mapping from the decoded response to the display model, kept
    /// separate from the network call so it is testable against a recorded
    /// response without standing up a mock session.
    static func profile(from response: ProfileResponse) -> CharacterProfile? {
        guard let node = response.data?.character,
              let id = node.id,
              let name = node.name?.full,
              !name.isEmpty
        else { return nil }

        return CharacterProfile(
            id: id,
            fullName: name,
            nativeName: node.name?.native,
            alternativeNames: node.name?.alternative ?? [],
            imageURL: (node.image?.large ?? node.image?.medium).flatMap(URL.init(string:)),
            gender: node.gender,
            age: node.age,
            bloodType: node.bloodType,
            dateOfBirth: Self.formattedBirthday(node.dateOfBirth),
            favourites: node.favourites,
            siteURL: node.siteUrl.flatMap(URL.init(string:)),
            description: node.description.map(CharacterDescriptionParser.parse),
            source: .aniList
        )
    }

    /// The cheapest real request AniList will answer, asking for `id` alone
    /// off the same `Media(id:, type:)` shape as `query` and `profileQuery`
    /// above. Two things were tried and rejected first, both confirmed live
    /// with curl on 2026-09-12: a bare `Page { pageInfo { total } }` came
    /// back HTTP 400 ("No field provided"), and `Media(id: 1, ...)` came
    /// back HTTP 404 ("Not Found.") because id 1 is not a real manga — either
    /// would report a perfectly healthy AniList as down on every launch. Id
    /// 30013 is One Piece, real and long-lived, and returns HTTP 200.
    static let healthCheckQuery = "query { Media(id: 30013, type: MANGA) { id } }"

    /// Whether AniList is answering at all right now.
    ///
    /// Throws exactly the way `characters` and `characterProfile` do:
    /// `.server` for a refusal AniList itself sent, `.transport` for a
    /// network failure that says nothing about AniList, so the caller can
    /// apply the same "only a refusal counts as an outage" rule it already
    /// applies elsewhere.
    func healthCheck() async throws(APIError) {
        try await waitForSlot()

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["query": Self.healthCheckQuery])

        let response: URLResponse
        do {
            (_, response) = try await session.data(for: request)
        } catch {
            throw APIError.transport(underlying: String(describing: error))
        }

        guard let http = response as? HTTPURLResponse else {
            throw APIError.transport(underlying: "AniList sent a non-HTTP response.")
        }
        // A body-level GraphQL error is not checked here: this call only
        // asks "is AniList refusing us at the transport level", the same
        // question a 403 outage answers. A malformed query would be our own
        // bug, not an outage, and would recur on every launch rather than
        // clearing itself in fifteen minutes.
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.server(status: http.statusCode, message: "AniList returned \(http.statusCode).")
        }
    }

    /// "March 4", or "March" alone when AniList sent a month with no day —
    /// which it does, for characters whose birthday is known only
    /// approximately. Nil when there is no month at all: a day with no month
    /// names nothing, and a bare year answers "how old", which `age` already
    /// covers.
    static func formattedBirthday(_ date: ProfileDate?) -> String? {
        guard let month = date?.month, (1...12).contains(month) else { return nil }
        let symbols = DateFormatter().monthSymbols ?? []
        guard symbols.indices.contains(month - 1) else { return nil }
        let name = symbols[month - 1]
        guard let day = date?.day, day > 0 else { return name }
        return "\(name) \(day)"
    }
}
