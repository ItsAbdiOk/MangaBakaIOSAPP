import Foundation

/// The iTunes Search API, for a series' volumes on Apple Books.
///
/// Keyless and public. Apple's documented limit is about 20 calls a minute
/// per IP, so requests are spaced like MangaUpdates' are, and every answer
/// is cached on disk for a week: a page's volumes do not change hourly, and
/// a reader opening the same series twice should not cost two calls.
actor AppleBooksClient {
    /// Twenty a minute, with margin. A GUESS at the margin; the limit itself
    /// is Apple's documented one.
    static let minimumInterval: TimeInterval = 3.5
    static let cacheLife: TimeInterval = 7 * 24 * 3600

    private let baseURL: URL
    private let session: URLSession
    private let clock: any Clock
    private let cacheDirectory: URL?
    private var spacing = RequestSpacing(minimumInterval: AppleBooksClient.minimumInterval)

    init(
        baseURL: URL = URL(string: "https://itunes.apple.com/search").unsafeStoreFallback,
        session: URLSession = ThirdPartySession.shared,
        clock: any Clock = SystemClock(),
        cacheDirectory: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("applebooks", isDirectory: true)
    ) {
        self.baseURL = baseURL
        self.session = session
        self.clock = clock
        self.cacheDirectory = cacheDirectory
    }

    /// The series' volumes in one store.
    ///
    /// `.success([])` means asked and none — a series with no English ebook —
    /// and is a different answer from `.failure`, which is the whole point of
    /// the `Result`. This returned `[AppleBooksVolume]?` until 2026-09-14, and
    /// the reason it changed is what `VolumesSection` could draw from a bare
    /// nil: offline, a 429, a 5xx and a decode failure all arrived as the same
    /// `appleUnreachable: Bool` and came out as one unexplained line of text
    /// with no retry. The reason was thrown away here, at the source, so no
    /// amount of work on the view could recover it.
    ///
    /// - Parameters:
    ///   - language: the reader's language; a volume whose blurb is
    ///     confidently in another is not theirs, whatever store it is sold in.
    ///   - format: what Wikidata says this series is, or nil when the bundled
    ///     table has never heard of it. See `isNovel(series:format:)` for what
    ///     it changes and — measured — what it does not.
    func volumes(
        for series: Series, country: String, language: String? = nil, format: WikidataFormat? = nil
    ) async -> Result<[AppleBooksVolume], APIError> {
        guard let query = series.displayTitle, !query.isEmpty else { return .success([]) }
        // Versioned: a match rule that tightens must not be outlived by a
        // week of cached answers made under the looser one. v5: the
        // tagged-vs-untagged and bracket-before-marker rules changed again
        // (T1/F3/T4, 2026-09-13). v6: Wikidata can now overrule MangaBaka's
        // `type` on the novel question, so an answer matched under the old
        // rule must not outlive it.
        let key = "v6-\(series.id)-\(country.lowercased())-\(language ?? "any")"
        if let cached = readCache(key) { return .success(cached.volumes) }

        let results: [AppleBooksResult]
        switch await search(query, country: country) {
        case let .success(found): results = found
        case let .failure(error): return .failure(error)
        }
        let titles = [series.displayTitle].compactMap { $0 } + (series.titles?.map(\.title) ?? [])
        let isNovel = Self.isNovel(series: series, format: format)
        let creators = (series.authors ?? []) + (series.artists ?? [])
        let matched = AppleBooksMatch.volumes(
            in: results, titles: titles, creators: creators, isNovel: isNovel, language: language
        )
        writeCache(key, matched)
        return .success(matched)
    }

    /// Whether the shelf being built is a novel's, and which source decided.
    ///
    /// **What this was before Wikidata, and what the table actually buys.**
    /// The rule was `series.type?.lowercased().contains("novel") ?? false` and
    /// nothing else. That is a good rule when MangaBaka states a type; it has
    /// exactly one failure, and it is the failure mode this project keeps
    /// finding — **an absent field read as a negative**. A series MangaBaka
    /// gives no `type` for built a *comic* shelf, and every light-novel volume
    /// in the store's answer was then judged by `AppleBooksMatch`'s tag rules
    /// alone.
    ///
    /// **The Apothecary Diaries bug is not one this fixes, and saying so is the
    /// point.** That series' `type` is "manga", so the old rule already
    /// answered `false` correctly; the novel leaked in because the store's
    /// untagged "The Apothecary Diaries: Volume 1" rows outranked the tagged
    /// comic ones, and `matchedVolumes`' `comicShelfHasTaggedEdition` guard
    /// (T4, 2026-09-13) is what fixed it. Wikidata does not touch that path. A
    /// fix with no before-number is not a result, and the honest before-number
    /// here is: unknown, because nobody has counted how many series MangaBaka
    /// returns with a nil `type`. This is a real improvement on a case that is
    /// currently silent, not a fix for the bug that was loud.
    ///
    /// MangaBaka wins a disagreement. It is the series the reader is looking
    /// at; Wikidata is joined to it by id and the join is exact, but the table
    /// reaches a quarter of the catalogue by row and its `P31` is one
    /// statement. Wikidata is consulted **only** where MangaBaka said nothing.
    ///
    /// `nonisolated static` so the tests can assert the rule without a client
    /// and a request.
    nonisolated static func isNovel(series: Series, format: WikidataFormat?) -> Bool {
        if let stated = series.type?.lowercased(), !stated.isEmpty {
            return stated.contains("novel")
        }
        // Nil, or `.other` (Wikidata knows the item and calls it an anime or a
        // film): no answer, so the old default stands.
        return format?.isProse ?? false
    }

    /// The Japanese edition, from the Japanese store, when the reader's own
    /// store has nothing: covers and a count for a series with no English
    /// ebook. No creator check — the store credits "尾田栄一郎" and MangaBaka
    /// says "Eiichirou Oda" — but the blurb must be Japanese and the name
    /// must be the title with a bare number, the way that store writes it.
    func japaneseVolumes(for series: Series) async -> Result<[AppleBooksVolume], APIError> {
        guard let query = series.displayTitle, !query.isEmpty else { return .success([]) }
        let key = "v5-\(series.id)-jp-ja-bare"
        if let cached = readCache(key) { return .success(cached.volumes) }

        let results: [AppleBooksResult]
        switch await search(query, country: "jp") {
        case let .success(found): results = found
        case let .failure(error): return .failure(error)
        }
        let titles = [series.displayTitle].compactMap { $0 } + (series.titles?.map(\.title) ?? [])
        let matched = AppleBooksMatch.volumes(
            in: results, titles: titles, isNovel: false, language: "ja", numbering: .bare
        )
        writeCache(key, matched)
        return .success(matched)
    }

    private struct Envelope: Decodable {
        let results: [AppleBooksResult]
    }

    private func search(
        _ term: String, country: String
    ) async -> Result<[AppleBooksResult], APIError> {
        let wait = spacing.claim(now: clock.now)
        if wait > 0 {
            try? await Task.sleep(for: .seconds(wait))
            // Gap 28: `try?` alone swallows cancellation and falls straight
            // through to firing the request — for a page the reader already
            // left. Checked once, right after the wait, rather than folded
            // into the `guard` above: the slot is claimed either way, so a
            // cancelled wait must still not spend the request that slot paid
            // for.
            guard !Task.isCancelled else { return .failure(.cancelled) }
        }

        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "media", value: "ebook"),
            URLQueryItem(name: "entity", value: "ebook"),
            URLQueryItem(name: "country", value: country),
            // The API's maximum. Solo Leveling's 15 volumes came back among
            // 60 results; a long-running series needs the room.
            URLQueryItem(name: "limit", value: "200")
        ]
        guard let url = components?.url else {
            return .failure(.transport(underlying: "Could not build the search URL.", party: .appleBooks))
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: url)
        } catch let error {
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                return .failure(.cancelled)
            }
            if (error as? URLError)?.code == .notConnectedToInternet { return .failure(.offline) }
            return .failure(.transport(underlying: error.localizedDescription, party: .appleBooks))
        }
        guard let http = response as? HTTPURLResponse else {
            return .failure(.transport(underlying: "Not an HTTP response.", party: .appleBooks))
        }
        if http.statusCode == 429 {
            let retryAfter = spacing.backOff(
                retryAfterHeader: http.value(forHTTPHeaderField: "Retry-After"), now: clock.now
            )
            // `unstatedBackOff` rather than a literal 60: `backOff` has just
            // pushed the slot out by exactly that when the header was unusable,
            // and a second copy of the number means the screen could one day
            // name a wait the client is not taking.
            return .failure(
                .rateLimited(retryAfter: retryAfter ?? RequestSpacing.unstatedBackOff, party: .appleBooks)
            )
        }
        // Gap 73: 403 used to get the same 60s backoff as 429, on the theory
        // that Apple answers an over-limit client with 403 as often as with
        // 429. It also answers 403 for a store the requested `country` does
        // not sell ebooks in — a fact about that one country, not about this
        // client having asked too much — and backing every future request off
        // for a minute over that would stall `japaneseVolumes` (a different
        // country) for a reason that has nothing to do with it. No backoff
        // here.
        guard (200..<300).contains(http.statusCode) else {
            return .failure(.server(status: http.statusCode, message: "", party: .appleBooks))
        }
        // No `.dateDecodingStrategy` needed: `releaseDate` decodes as a
        // plain `String` now (T9) — a strict `.iso8601` `Date` here used to
        // fail the whole 200-row envelope over one row with a fractional
        // second or a missing zone, for a field nothing reads.
        do {
            return .success(try JSONDecoder().decode(Envelope.self, from: data).results)
        } catch let error {
            return .failure(.decoding(underlying: error.localizedDescription, party: .appleBooks))
        }
    }

    // MARK: - Cache

    private struct Cached: Codable {
        let storedAt: Date
        let volumes: [AppleBooksVolume]
    }

    private func file(_ key: String) -> URL? {
        cacheDirectory?.appendingPathComponent("\(key).json")
    }

    /// - Returns: the cached volumes and when they were written, or nil when
    ///   there is nothing usable cached. `storedAt` (gap 72) is read by
    ///   nothing yet — no caller here needs a value's age today — but the
    ///   file already carried it and threw it away on every read, which is
    ///   exactly the shape a future `StaleBar` ("volumes from 6 days ago")
    ///   needs and could not have been built from `[AppleBooksVolume]?` alone.
    ///
    /// Internal rather than `private`, purely so `AppleBooksTests` can assert
    /// on `storedAt` directly without a caller for it to flow through yet.
    func readCache(_ key: String) -> (volumes: [AppleBooksVolume], storedAt: Date)? {
        guard let file = file(key), let data = try? Data(contentsOf: file),
              let cached = try? JSONDecoder().decode(Cached.self, from: data),
              clock.now.timeIntervalSince(cached.storedAt) < Self.cacheLife
        else { return nil }
        return (cached.volumes, cached.storedAt)
    }

    private func writeCache(_ key: String, _ volumes: [AppleBooksVolume]) {
        guard let directory = cacheDirectory, let file = file(key) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cached = Cached(storedAt: clock.now, volumes: volumes)
        try? JSONEncoder().encode(cached).write(to: file, options: .atomic)
    }
}

private extension Optional where Wrapped == URL {
    var unsafeStoreFallback: URL {
        guard let self else { preconditionFailure("Hard-coded iTunes Search URL failed to parse.") }
        return self
    }
}
