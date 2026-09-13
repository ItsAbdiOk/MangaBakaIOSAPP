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

    /// The configuration every default session for this client is built with.
    ///
    /// `timeoutIntervalForRequest = 20`: **a guess.** Nothing on record times
    /// how long MangaBaka itself typically takes to answer; 20s is chosen as
    /// long enough that no ordinary request on a slow connection should ever
    /// hit it, short enough that a hung host (gap 27 — nothing in this app
    /// ever timed out; one third-party outage held a request open 60s+) gives
    /// up inside one screen's patience rather than several. Revisit once
    /// `NetworkLedger`'s recorded latencies give a real p99 to size this
    /// against instead.
    static let defaultSessionConfiguration: URLSessionConfiguration = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        return configuration
    }()

    /// The session every caller gets unless a test substitutes its own.
    ///
    /// Not `.shared`: `.shared` is built from `URLSessionConfiguration.default`
    /// with Apple's own (much longer) timeout, so callers that relied on the
    /// old default silently kept the old, untimed behaviour.
    static let defaultSession = URLSession(configuration: defaultSessionConfiguration)

    init(baseURL: URL, session: URLSession = APIClient.defaultSession, tokenProvider: TokenProvider) {
        self.baseURL = baseURL
        self.session = session
        self.tokenProvider = tokenProvider
        self.decoder = Self.makeDecoder()
    }

    /// - Parameter query: query items, as a list rather than a dictionary
    ///   because the API takes repeated keys — `content_rating` must be sent as
    ///   `content_rating=safe&content_rating=suggestive`, and a comma-joined
    ///   value is rejected with HTTP 400.
    func get<Payload: Decodable>(
        _ path: String,
        query: [URLQueryItem] = [],
        priority: RequestPriority = .userInitiated,
        as _: Payload.Type = Payload.self
    ) async throws(APIError) -> Payload {
        let data = try await rawData(path: path, query: query, priority: priority)
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

    /// The same fetch as `get`, but keeping the envelope's `pagination`
    /// alongside the payload.
    ///
    /// A second method rather than widening `get`'s return type: `get` is
    /// called all over the app for payloads nobody needs pagination for, and
    /// changing its signature would touch every one of those call sites for
    /// nothing. This exists because `next` — nil only on the last page — is
    /// the API's own end-of-list signal, and it was being decoded and then
    /// thrown away; callers were instead inferring "more pages exist" from
    /// how many rows survived a local filter, which undercounts whenever the
    /// filter drops even one row on a page (see `Pagination.next`'s doc
    /// comment).
    func getWithPagination<Payload: Decodable>(
        _ path: String,
        query: [URLQueryItem] = [],
        priority: RequestPriority = .userInitiated,
        as _: Payload.Type = Payload.self
    ) async throws(APIError) -> (payload: Payload, pagination: Pagination?) {
        let data = try await rawData(path: path, query: query, priority: priority)
        let envelope: APIEnvelope<Payload>
        do {
            envelope = try decoder.decode(APIEnvelope<Payload>.self, from: data)
        } catch {
            throw APIError.decoding(underlying: String(describing: error))
        }
        guard let payload = envelope.data else {
            throw APIError.decoding(underlying: "Successful response carried no `data`.")
        }
        return (payload, envelope.pagination)
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
    ///
    /// Only the pagination block is decoded. It used to decode the whole
    /// `Series` that came back in the one-item page, which made the count
    /// hostage to that row's shape — any of the decode failures this app has
    /// had would have cost a saved lens its count.
    func total(
        _ path: String,
        query: [URLQueryItem] = [],
        priority: RequestPriority = .userInitiated
    ) async throws(APIError) -> Int? {
        let data = try await rawData(path: path, query: query, priority: priority)
        do {
            return try decoder.decode(PaginationOnly.self, from: data).pagination?.count
        } catch {
            throw APIError.decoding(underlying: String(describing: error))
        }
    }

    private struct PaginationOnly: Decodable {
        let pagination: Pagination?
    }

    /// The one path every request takes, read or write: the rate-limit gate,
    /// the token, the transport, the ledger, and the 429. Reads and writes had
    /// two copies of this that disagreed — the write's offline detection
    /// caught one URLError code where the read's caught three, so a
    /// connection dropping mid-save was reported as the app breaking rather
    /// than the signal dropping; and writes were invisible to the ledger, so every
    /// request-budget number excluded the bursty half of the traffic.
    private func perform(
        _ request: URLRequest,
        path: String,
        priority: RequestPriority = .userInitiated
    ) async throws(APIError) -> (data: Data, http: HTTPURLResponse) {
        // Refuse before spending a request already known to be refused (gap
        // 8); `.background` may wait here instead — see `RateLimitGate`.
        try await limiter.reserveSlot(for: path, priority: priority)

        var authorized = request
        if let header = await tokenProvider.authorizationHeader() {
            authorized.setValue(header.value, forHTTPHeaderField: header.field)
        }

        // Measured rather than estimated. Every "is the API fast?" answer this
        // project has given was about response shapes; this one is about time.
        let began = ContinuousClock.now
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: authorized)
        } catch let error as URLError where error.code == .notConnectedToInternet
            || error.code == .networkConnectionLost
            || error.code == .dataNotAllowed {
            throw APIError.offline
        } catch let error as URLError where error.code == .cancelled {
            // The reader left, or a newer request superseded this one — not a
            // network failure. `.transport("…cancelled…")` used to reach here,
            // which told the kit to hide cached content
            // (`staleContentRemainsUseful == false` for `.transport`) over a
            // screen the reader simply isn't looking at anymore (gap 26).
            throw APIError.cancelled
        } catch {
            throw APIError.transport(underlying: error.localizedDescription)
        }

        let elapsed = began.duration(to: .now)
        await NetworkLedger.shared.record(
            path: path,
            bytes: data.count,
            seconds: Double(elapsed.components.seconds)
                + Double(elapsed.components.attoseconds) / 1e18,
            // Only a real failure, never a 304: a run of "nothing changed"
            // conditional GETs used to count as a run of failures here, which
            // is exactly the shape `NetworkLedger`'s own success rate reads
            // as a client falling over (services audit finding).
            failed: (response as? HTTPURLResponse).map { $0.statusCode >= 400 } ?? true
        )

        guard let http = response as? HTTPURLResponse else {
            throw APIError.transport(underlying: "Response was not HTTP.")
        }
        if http.statusCode == 429 {
            let retryAfter = Self.parseRetryAfter(http.value(forHTTPHeaderField: "Retry-After"))
            await limiter.recordRateLimit(retryAfter: retryAfter, path: path)
            // Capped the same way the gate caps what it honours (see
            // `RateLimitGate.maxHonouredRetryAfter`) — otherwise the gate
            // could reopen in 15 minutes while the screen still read
            // "Retrying in 3 hours," which is the app calling itself wrong.
            let displayed = retryAfter.map { min($0, RateLimitGate.maxHonouredRetryAfter) }
            let isSearch = RateLimitGate.family(for: path) == .search
            throw APIError.rateLimited(retryAfter: displayed, party: isSearch ? .mangaBakaSearch : .mangaBaka)
        }
        return (data, http)
    }

    /// Performs the request and returns the raw body, having already turned
    /// every transport and status failure into a named `APIError`.
    private func rawData(
        path: String,
        query: [URLQueryItem],
        priority: RequestPriority = .userInitiated
    ) async throws(APIError) -> Data {
        let request = try makeRequest(path: path, query: query)
        let (data, http) = try await perform(request, path: path, priority: priority)

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
        await limiter.recordSuccess(path: path)
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
            if case let .server(status, _, _) = error, status == 409 { return false }
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
            // `JSONSerialization.data(withJSONObject:)` raises an
            // Objective-C `NSInvalidArgumentException` for a body containing
            // `.infinity` or `.nan` — not a Swift error, so the `try?` below
            // cannot catch it and the process crashes. `isValidJSONObject`
            // checks for exactly this (a `NSNumber` that is NaN or infinite)
            // without raising, so it must run first. Reachable from real
            // input: a chapter field typed as "inf" via a hardware keyboard
            // or paste parses with `Double("inf")` before it ever reaches
            // here.
            guard JSONSerialization.isValidJSONObject(body),
                  let encoded = try? JSONSerialization.data(withJSONObject: body)
            else {
                throw APIError.transport(underlying: "Could not encode the change.")
            }
            request.httpBody = encoded
        }

        let (data, http) = try await perform(request, path: path)
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
        await limiter.recordSuccess(path: path)
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
    ///
    /// `/v0/frontpage/community-pulse` is the same shape (verified 2026-09-11)
    /// and briefly had its own copy of this function under another name.
    func getRoot<Payload: Decodable>(
        _ path: String,
        query: [URLQueryItem] = [],
        as _: Payload.Type = Payload.self
    ) async throws(APIError) -> Payload {
        let data = try await rawData(path: path, query: query)
        do {
            return try decoder.decode(Payload.self, from: data)
        } catch {
            // Only a DecodingError can land here: rawData's typed throw
            // happens before the do. The `catch let error as APIError` that
            // stood above this could never fire.
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
    static let identifyingParameters: Set<String> = [
        "exclude_user_library",
        "blend_user_id"
    ]

    private func makeRequest(
        path: String,
        query: [URLQueryItem],
        ifModifiedSince: String? = nil
    ) throws(APIError) -> URLRequest {
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
        // Sent verbatim — the server's own `Last-Modified` string, never
        // reformatted. A re-formatted date can miss the byte-for-byte match
        // the server is comparing against and never answer 304 at all.
        if let ifModifiedSince, !ifModifiedSince.isEmpty {
            request.setValue(ifModifiedSince, forHTTPHeaderField: "If-Modified-Since")
        }
        return request
    }
}

/// The conditional-GET half of the client, split from the actor body itself
/// so the primary type stays under `type_body_length` — same reason the
/// decoding/date-parsing extension below exists. `private` members
/// (`perform`, `decoder`, `limiter`, `makeRequest`) stay reachable: Swift's
/// `private` is scoped to the enclosing declaration and its extensions *in
/// the same file*, and this is that file.
extension APIClient {
    /// What a conditional `get` produced.
    enum Conditional<Payload: Sendable>: Sendable {
        /// HTTP 304: the server confirms the cached copy is still current.
        /// MEASURED 2026-09-13 against api.mangabaka.org: the body is
        /// zero bytes, so there is nothing here to decode.
        case notModified
        /// HTTP 2xx: a payload, and the response's own `Last-Modified` value
        /// — kept as the server sent it, byte for byte, so the next request's
        /// `If-Modified-Since` is an exact echo rather than a reformatting
        /// that could miss the match.
        case fresh(Payload, lastModified: String?)
    }

    /// The same fetch as `get`, but conditional on `ifModifiedSince`, and
    /// answering whether anything actually changed rather than always paying
    /// for the full body.
    ///
    /// MEASURED 2026-09-13 against api.mangabaka.org: responses carry no
    /// `ETag` at all — only `Last-Modified` (e.g.
    /// "Sun, 13 Sep 2026 13:56:53 GMT") and `cache-control: public,
    /// max-age=60`. Repeating that exact value back as `If-Modified-Since`
    /// gets a 304 with a zero-byte body; `/v1/series/{id}` carries
    /// `Last-Modified` too. So this is Last-Modified/If-Modified-Since, not
    /// the ETag scheme `get` has no need of.
    ///
    /// A separate method rather than widening `get`: every existing caller
    /// wants a payload or nothing, and changing what `get` returns for a 304
    /// would force all of them to switch over a case they never asked for.
    ///
    /// A 304 is a success path, never an `APIError` — it goes through
    /// `perform`, so it still counts against the rate-limit gate's own
    /// per-IP/per-window counters exactly like any other request (it *was* a
    /// real request against the limit), but it must never trip the 429
    /// backoff, and it clears any backoff already standing exactly like any
    /// other 2xx would.
    ///
    /// - Parameter ifModifiedSince: the value to send verbatim, or `nil` to
    ///   send no conditional header at all — which makes this behave exactly
    ///   like an ordinary `get` (always 200, decoded and returned as
    ///   `.fresh`). Used for the "no cached copy yet" case, so a caller does
    ///   not need two code paths.
    func get<Payload: Decodable & Sendable>(
        _ path: String,
        query: [URLQueryItem] = [],
        ifModifiedSince: String?,
        priority: RequestPriority = .userInitiated,
        as _: Payload.Type = Payload.self
    ) async throws(APIError) -> Conditional<Payload> {
        let request = try makeRequest(path: path, query: query, ifModifiedSince: ifModifiedSince)
        let (data, http) = try await perform(request, path: path, priority: priority)

        if http.statusCode == 304 {
            // A success, not a failure: a run of "nothing changed" answers
            // must not be mistaken for a run of failures and trip the 429
            // backoff logic that lives only in `perform`'s 429 branch.
            await limiter.recordSuccess(path: path)
            return .notModified
        }

        guard (200...299).contains(http.statusCode) else {
            let message = (try? decoder.decode(APIErrorEnvelope.self, from: data))?.message
            throw APIError.server(
                status: http.statusCode,
                message: message ?? "MangaBaka returned an unexpected response."
            )
        }
        await limiter.recordSuccess(path: path)

        let envelope: APIEnvelope<Payload>
        do {
            envelope = try decoder.decode(APIEnvelope<Payload>.self, from: data)
        } catch {
            throw APIError.decoding(underlying: String(describing: error))
        }
        guard let payload = envelope.data else {
            throw APIError.decoding(underlying: "Successful response carried no `data`.")
        }
        return .fresh(payload, lastModified: http.value(forHTTPHeaderField: "Last-Modified"))
    }
}

/// Decoding and date-parsing helpers, split from the actor body itself so
/// the primary type stays under `type_body_length` — none of this needs
/// actor isolation; it is all `static`.
extension APIClient {
    /// The decoder every request in this client decodes with.
    ///
    /// `nonisolated static` and exposed so tests can decode fixtures through
    /// the same rules production does, rather than a second, hand-rolled
    /// decoder that quietly drifts from this one. `Fixture.decoder()` calls
    /// this rather than building its own — see `FixtureLoading.swift`.
    nonisolated static func makeDecoder() -> JSONDecoder {
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
            // A bare calendar day, no time at all — `"start_date": "2026-08-27"`,
            // seen on the wire alongside the two timestamped forms above. Fixed
            // to UTC for the same reason `SeriesWork.date` is: parsing a
            // date-only string in the device's own zone can push it onto the
            // previous day west of UTC.
            if let date = Self.dateOnlyFormatter.date(from: text) { return date }
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Unrecognised date: \(text)"
            )
        }
        return decoder
    }

    /// A UTC-fixed formatter for a given pattern — both the date-only
    /// fallback above and `Retry-After`'s HTTP-date form below need one, and
    /// a shared factory beats two near-identical closures.
    private static func utcFormatter(_ pattern: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = pattern
        return formatter
    }

    /// A bare `yyyy-MM-dd` day. Third and last date-decoding fallback.
    fileprivate static let dateOnlyFormatter = utcFormatter("yyyy-MM-dd")

    /// `Retry-After`'s HTTP-date form (RFC 7231 §7.1.3), e.g.
    /// "Wed, 21 Oct 2015 07:28:00 GMT". The delta-seconds form is far more
    /// common and is tried first; this exists so a server sending the other
    /// legal form is not silently ignored and quietly falls to the local
    /// exponential fallback instead of the deadline it actually gave.
    private static let retryAfterDateFormatter = utcFormatter("EEE, dd MMM yyyy HH:mm:ss zzz")

    /// `Retry-After` may be delta-seconds or an HTTP-date; only the first was
    /// ever parsed, so the second silently vanished.
    ///
    /// `TimeInterval("nan")` and `TimeInterval("inf")` both parse successfully
    /// to non-finite doubles rather than failing — confirmed on device, not an
    /// assumption — so `isFinite` must be checked explicitly. Without it, a
    /// malformed header of literally `Retry-After: nan` survives `max(_, 0)`
    /// (`max` with a NaN operand returns NaN in Swift) into
    /// `RateLimitGate.recordRateLimit`, which then blocks every request until
    /// the process relaunches, because every future
    /// `blockedUntil.timeIntervalSince(now)` compares against a NaN deadline
    /// and never reads `<= 0` (gap 5).
    static func parseRetryAfter(_ header: String?) -> TimeInterval? {
        guard let header, !header.isEmpty else { return nil }
        if let seconds = TimeInterval(header) {
            guard seconds.isFinite else { return nil }
            return max(seconds, 0)
        }
        guard let date = retryAfterDateFormatter.date(from: header) else { return nil }
        return max(date.timeIntervalSinceNow, 0)
    }
}
