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
        let data = try await rawData(path: path, query: query)
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

    /// How many results a query has, without downloading them.
    ///
    /// The API reports the total in its pagination block, so a count costs one
    /// request for one item rather than a page of twenty. That matters here:
    /// the lens rows on Search's idle screen each carry a live count, and the
    /// rate limit is per IP and shared with strangers on the same network.
    ///
    /// Nil when the response carried no total. A missing count is shown as a
    /// missing count, never as zero — "0 now" beside a saved search is a
    /// statement that it found nothing, which is a different and much worse
    /// thing to say.
    func total(_ path: String, query: [URLQueryItem] = []) async throws(APIError) -> Int? {
        let data = try await rawData(path: path, query: query)
        do {
            return try decoder.decode(APIEnvelope<[Series]>.self, from: data).pagination?.count
        } catch {
            throw APIError.decoding(underlying: String(describing: error))
        }
    }

    /// Performs the request and returns the raw body, having already turned
    /// every transport and status failure into a named `APIError`.
    private func rawData(path: String, query: [URLQueryItem]) async throws(APIError) -> Data {
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
        guard (200...299).contains(http.statusCode) else {
            // Errors always carry `message`, and it is documented as safe to
            // show users. Fall back only if the body is unreadable.
            let message = (try? decoder.decode(APIErrorEnvelope.self, from: data))?.message
            throw APIError.server(
                status: http.statusCode,
                message: message ?? "MangaBaka returned an unexpected response."
            )
        }

        // Only a success clears the backoff. A 500 says the server is unwell,
        // not that the rate-limit window has reopened, and treating it as
        // permission to resume would put us straight back into the limit.
        await limiter.recordSuccess()
        return data
    }

    /// Fetches from an endpoint that answers with `results` rather than `data`.
    ///
    /// Two shapes exist in this API and neither decodes as the other, so the
    /// distinction is explicit at the call site rather than guessed at.
    /// Creates something in the reader's own data, or reports that it is
    /// already there.
    ///
    /// Returns false when the server says the thing already exists (409) rather
    /// than throwing, because "already in your library" is an ordinary answer
    /// to "add this", not a failure.
    @discardableResult
    func post(
        _ path: String,
        body: [String: any Sendable]
    ) async throws(APIError) -> Bool {
        do {
            try await send("POST", path: path, body: body)
            return true
        } catch {
            // 409 means it is already there, which is an ordinary answer to
            // "add this" rather than a failure.
            if case let .server(status, _) = error, status == 409 { return false }
            throw error
        }
    }

    /// Removes something from the reader's own data.
    func delete(_ path: String) async throws(APIError) {
        try await send("DELETE", path: path, body: nil)
    }

    /// Sends a change to the reader's own data.
    ///
    /// Separate from every `get` on purpose: this is the only method in the
    /// client that alters something on the server, and it should be obvious at
    /// a call site which one is being used.
    ///
    /// Returns nothing. A 2xx is the whole answer — the caller re-reads rather
    /// than trusting a response body to describe what it now holds.
    func patch(
        _ path: String,
        body: [String: any Sendable]
    ) async throws(APIError) {
        try await send("PATCH", path: path, body: body)
    }

    /// The one place this client alters something on the server.
    private func send(
        _ method: String,
        path: String,
        body: [String: any Sendable]?
    ) async throws(APIError) {
        var request = try makeRequest(path: path, query: [])
        request.httpMethod = method
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            guard let encoded = try? JSONSerialization.data(withJSONObject: body) else {
                throw APIError.transport(underlying: "Could not encode the change.")
            }
            request.httpBody = encoded
        }

        if let header = await tokenProvider.authorizationHeader() {
            request.setValue(header.value, forHTTPHeaderField: header.field)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .notConnectedToInternet {
            throw APIError.offline
        } catch {
            throw APIError.transport(underlying: String(describing: error))
        }

        guard let http = response as? HTTPURLResponse else {
            throw APIError.transport(underlying: "Not an HTTP response.")
        }
        if http.statusCode == 429 {
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw APIError.rateLimited(retryAfter: retryAfter)
        }
        guard (200..<300).contains(http.statusCode) else {
            // 401 and 403 are worth separating from any other failure: they
            // mean the token is wrong or lacks permission, so retrying will
            // not help and the reader needs sending to Settings.
            let message = http.statusCode == 401 || http.statusCode == 403
                ? "MangaBaka would not accept that change. Check your token in Settings."
                : "MangaBaka could not save that change."
            throw APIError.server(status: http.statusCode, message: message)
        }
        _ = data
    }

    /// Decodes a response that has no envelope at all.
    ///
    /// This API has three response shapes, not two. Most endpoints wrap the
    /// payload in `data`, the personalised ones wrap it in `results`, and
    /// `/v1/my/series/recommendations/status` wraps it in nothing — its fields
    /// sit at the top level beside `status` (verified 2026-09-09).
    ///
    /// Decoding that one as a `results` envelope threw, the caller's `try?`
    /// turned it into nil, and the swipe stack concluded the reader had no
    /// profile to recommend from. Nothing surfaced; the stack just quietly used
    /// a worse source.
    func getRoot<Payload: Decodable>(
        _ path: String,
        query: [URLQueryItem] = [],
        as _: Payload.Type = Payload.self
    ) async throws(APIError) -> Payload {
        let data = try await rawData(path: path, query: query)
        do {
            return try decoder.decode(Payload.self, from: data)
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.decoding(underlying: String(describing: error))
        }
    }

    func getResults<Payload: Decodable>(
        _ path: String,
        query: [URLQueryItem] = [],
        as _: Payload.Type = Payload.self
    ) async throws(APIError) -> Payload {
        let data = try await rawData(path: path, query: query)
        do {
            let envelope = try decoder.decode(ResultsEnvelope<Payload>.self, from: data)
            guard let results = envelope.results else {
                throw APIError.decoding(underlying: "Response carried no `results`.")
            }
            return results
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.decoding(underlying: String(describing: error))
        }
    }

    /// Fetches the signed-in reader's profile, or `nil` when the credentials
    /// are missing or rejected. Used to confirm a token works at the moment it
    /// is entered, rather than letting it fail silently later.
    func profile() async -> Profile? {
        try? await get("/v1/my/profile", as: Profile.self)
    }

    /// The same fetch, keeping the reason it failed.
    ///
    /// `profile()` collapses offline, rate-limited, server-error and rejected
    /// into one nil, which is fine for "are we signed in" and wrong for "was
    /// this token any good". Settings used the collapsed answer to tell a
    /// reader on a train that MangaBaka had rejected their token, and then
    /// deleted it from the Keychain.
    func verifiedProfile() async throws(APIError) -> Profile {
        try await get("/v1/my/profile", as: Profile.self)
    }

    /// Query parameters that put the reader's identity into a URL.
    ///
    /// `blend_user_id` is listed although the app does not send it: if it is
    /// ever added, it must not be the change that quietly starts caching an
    /// account id to disk.
    private static let identifyingParameters: Set<String> = [
        "exclude_user_library",
        "blend_user_id"
    ]

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
        // Never let a response carrying the reader's own data sit in the shared
        // URLCache on disk. MangaBaka does send "private, no-store" on those
        // endpoints today (verified 2026-09-09), but that is their guarantee to
        // change, not ours to depend on.
        //
        // The path prefix is not sufficient on its own. `/v1/series/mix` is a
        // public endpoint by path, but once it carries `exclude_user_library`
        // the URL contains the reader's 32-character account id — and the URL
        // is the cache key, so that id would be written to a cache file on
        // disk, in a 256MB cache, for a response that gains nothing from being
        // cached there (blends are already cached in the app's own database).
        // So the test is what the request carries, not where it is going.
        let carriesIdentity = query.contains { Self.identifyingParameters.contains($0.name) }
        if path.hasPrefix("/v1/my") || path.hasPrefix("/v0/my") || carriesIdentity {
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }
}
