import Foundation

/// Thin, dependency-free HTTP layer over the MangaBaka API.
///
/// Deliberately not a caching layer: caching belongs in the repository that
/// sits above this, so this type stays trivially testable with a stubbed
/// `URLProtocol`.
actor APIClient {
    private let baseURL: URL
    private let session: URLSession
    private let tokenProvider: TokenProvider
    private let decoder: JSONDecoder

    /// Identifies this client to MangaBaka.
    ///
    /// Not optional politeness: the API returns 403 to requests it does not
    /// recognise (verified 2026-09-08 — urllib's default agent is rejected
    /// where curl's is accepted). Naming the project and linking the repository
    /// also means they can contact us rather than silently blocking us.
    static let userAgent = "MangaBakaIOS/1.0 (+https://github.com/ItsAbdiOk/MangaBakaIOSAPP)"

    private let limiter = RateLimitGate()

    init(baseURL: URL, session: URLSession = .shared, tokenProvider: TokenProvider) {
        self.baseURL = baseURL
        self.session = session
        self.tokenProvider = tokenProvider

        let decoder = JSONDecoder()
        // The API uses snake_case throughout (`is_licensed`, `total_chapters`).
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        // Timestamps are ISO-8601, sometimes with fractional seconds and
        // sometimes without, so both are accepted rather than failing the whole
        // response over a missing ".000".
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            let withFraction = ISO8601DateFormatter()
            withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = withFraction.date(from: text) { return date }
            let plain = ISO8601DateFormatter()
            if let date = plain.date(from: text) { return date }
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Unrecognised date: \(text)"
            )
        }
        self.decoder = decoder
    }

    /// - Parameter query: query items, as a list rather than a dictionary
    ///   because the API takes repeated keys — `content_rating` must be sent as
    ///   `content_rating=safe&content_rating=suggestive`, and a comma-joined
    ///   value is rejected with HTTP 400.
    func get<Payload: Decodable>(
        _ path: String,
        query: [URLQueryItem] = [],
        as _: Payload.Type = Payload.self
    ) async throws(APIError) -> Payload {
        // Refuse before spending a request we already know will be refused.
        // The limit is per IP and shared with strangers on the same network, so
        // hammering it during a backoff makes their searches fail too.
        if let wait = await limiter.secondsUntilAllowed() {
            throw APIError.rateLimited(retryAfter: wait)
        }

        let request = try makeRequest(path: path, query: query)
        let header = await tokenProvider.authorizationHeader()

        var authorized = request
        if let header {
            authorized.setValue(header.value, forHTTPHeaderField: header.field)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: authorized)
        } catch let error as URLError where error.code == .notConnectedToInternet
            || error.code == .networkConnectionLost
            || error.code == .dataNotAllowed {
            throw APIError.offline
        } catch {
            throw APIError.transport(underlying: error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw APIError.transport(underlying: "Response was not HTTP.")
        }

        if http.statusCode == 429 {
            let retryAfter = (http.value(forHTTPHeaderField: "Retry-After")).flatMap(TimeInterval.init)
            await limiter.recordRateLimit(retryAfter: retryAfter)
            throw APIError.rateLimited(retryAfter: retryAfter)
        }
        await limiter.recordSuccess()

        guard (200...299).contains(http.statusCode) else {
            // Errors always carry `message`, and it is documented as safe to
            // show users. Fall back only if the body is unreadable.
            let message = (try? decoder.decode(APIErrorEnvelope.self, from: data))?.message
            throw APIError.server(
                status: http.statusCode,
                message: message ?? "MangaBaka returned an unexpected response."
            )
        }

        let envelope: APIEnvelope<Payload>
        do {
            envelope = try decoder.decode(APIEnvelope<Payload>.self, from: data)
        } catch {
            throw APIError.decoding(underlying: String(describing: error))
        }

        guard let payload = envelope.data else {
            throw APIError.decoding(underlying: "Successful response carried no `data`.")
        }
        return payload
    }

    /// Fetches the signed-in reader's profile, or `nil` when the credentials
    /// are missing or rejected. Used to confirm a token works at the moment it
    /// is entered, rather than letting it fail silently later.
    func profile() async -> Profile? {
        try? await get("/v1/my/profile", as: Profile.self)
    }

    private func makeRequest(path: String, query: [URLQueryItem]) throws(APIError) -> URLRequest {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        ) else {
            throw APIError.transport(underlying: "Could not build a URL for \(path).")
        }
        if !query.isEmpty {
            components.queryItems = query
        }
        guard let url = components.url else {
            throw APIError.transport(underlying: "Could not build a URL for \(path).")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }
}
