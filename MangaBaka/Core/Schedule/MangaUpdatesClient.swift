import Foundation

/// Reads release history from MangaUpdates.
///
/// A second API, with different rules from MangaBaka's: no auth, POST rather
/// than GET for search, and terms that ask for "reasonable spacing between
/// requests" without naming a number. An actor so the spacing cannot be
/// defeated by concurrent callers.
actor MangaUpdatesClient {
    /// Their terms ask for reasonable spacing and do not define it. Three
    /// seconds is the interval the reference implementation settled on and has
    /// run without incident. Slower than necessary is the correct error here:
    /// a ban costs the feature entirely.
    static let minimumInterval: TimeInterval = 3.0

    private let baseURL: URL
    private let session: URLSession
    private let clock: any Clock
    private var spacing = RequestSpacing(minimumInterval: MangaUpdatesClient.minimumInterval)
    /// Where `series(number:)` answers are cached — see `readSeriesCache`.
    /// Nil disables the cache rather than throwing, same as
    /// `WebtoonsFeedClient`: a directory that cannot be created costs a
    /// repeat request, not a crash.
    private let cacheDirectory: URL?

    /// Identifies the app, as their terms require. One string, in
    /// `AppUserAgent`; `ThirdPartySession` sends it for every client, and the
    /// explicit `setValue` below stays for the reason `ShikimoriClient`
    /// gives — a substituted session must not silently drop a header this
    /// host refuses requests without.
    static let userAgent = AppUserAgent.value

    init(
        baseURL: URL = URL(string: "https://api.mangaupdates.com/v1").unsafeScheduleFallback,
        session: URLSession = ThirdPartySession.shared,
        clock: any Clock = SystemClock(),
        cacheDirectory: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("mangaupdates", isDirectory: true)
    ) {
        self.baseURL = baseURL
        self.session = session
        self.clock = clock
        self.cacheDirectory = cacheDirectory
    }

    /// One release row. Only the fields the estimate needs are modelled.
    struct Release: Decodable, Sendable {
        let chapter: String?
        let volume: String?
        /// "2026-08-21". The field is `release_date`; the reference handoff
        /// calls it `released` in one place, which is wrong — verified against
        /// the live endpoint 2026-09-09.
        let releaseDate: String?

        /// The release reduced to what `SeasonReading` needs, where both
        /// numbers are actually there.
        var sample: SeasonReading.Sample? {
            guard let date,
                  let volume, let volumeNumber = Int(volume.trimmingCharacters(in: .whitespaces)),
                  let chapter, let chapterNumber = Self.firstNumber(in: chapter)
            else { return nil }
            return SeasonReading.Sample(
                volume: volumeNumber, chapter: chapterNumber, date: date
            )
        }

        /// Chapter text MangaUpdates uses for something that is not a
        /// numbered chapter. "Extra 3" and "Side Story 2" are ordinary
        /// MangaUpdates chapter strings with exactly the shape a
        /// leading-digit read mistakes for chapter 3 or chapter 2 — the same
        /// bug `WebtoonsEpisode`'s Afterword/외전 rules exist to prevent,
        /// here on MangaUpdates' own numbering. "Omake" carries no leading
        /// digit at all and would already return nil below, but is listed
        /// for the same reason.
        private static let nonChapterWords = ["extra", "side story", "omake", "special"]

        /// "57-58" and "c.12 (end)" both start with the number that matters.
        private static func firstNumber(in text: String) -> Double? {
            let lowered = text.lowercased()
            guard !nonChapterWords.contains(where: lowered.contains) else { return nil }
            let digits = text.drop { !$0.isNumber }.prefix { $0.isNumber || $0 == "." }
            return Double(digits)
        }

        var date: Date? {
            guard let releaseDate, releaseDate.count >= 10 else { return nil }
            return Self.formatter.date(from: String(releaseDate.prefix(10)))
        }

        private static let formatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            return formatter
        }()
    }

    private struct SearchResponse: Decodable {
        struct Row: Decodable { let record: Release }
        let results: [Row]?
    }

    /// Release history for a series, newest first.
    ///
    /// - Parameter seriesNumber: the **decoded numeric** MangaUpdates id. Never
    ///   the base-36 string — see `MangaUpdatesID`.
    func releases(seriesNumber: Int, limit: Int = 40) async throws(APIError) -> [Release] {
        try await waitForSlot()

        var request = URLRequest(url: baseURL.appendingPathComponent("releases/search"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        // `perpage` is not honoured — asking for 3 returns all 39 (verified
        // 2026-09-09). Sent anyway because it is the documented parameter, and
        // the result is truncated below rather than trusted.
        let body: [String: Any] = [
            "search": String(seriesNumber),
            "search_type": "series",
            "perpage": limit,
            "orderby": "date",
            "asc": "desc"
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where URLError.Code.offlineCodes.contains(error.code) {
            // Widened from the one code (`.notConnectedToInternet`) this used
            // to check to the same three `APIClient.perform` treats as
            // offline (gap 30) — `.networkConnectionLost` and
            // `.dataNotAllowed` used to fall through to `.transport` below,
            // which reads as "something broke" instead of "you're offline".
            throw APIError.offline
        } catch {
            throw APIError.transport(underlying: String(describing: error), party: .mangaUpdates)
        }

        guard let http = response as? HTTPURLResponse else {
            throw APIError.transport(underlying: "Not an HTTP response.", party: .mangaUpdates)
        }
        if http.statusCode == 429 {
            // Clamped and parsed in one place (`RequestSpacing.backOff`): a bare
            // `TimeInterval.init` accepted "nan" and "1e9" here, and either one
            // ended this client's spacing for the process. See that function.
            let retryAfter = spacing.backOff(
                retryAfterHeader: http.value(forHTTPHeaderField: "Retry-After"), now: clock.now
            )
            throw APIError.rateLimited(retryAfter: retryAfter, party: .mangaUpdates)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.server(
                status: http.statusCode,
                message: "MangaUpdates returned \(http.statusCode).",
                party: .mangaUpdates
            )
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            let decoded = try decoder.decode(SearchResponse.self, from: data)
            // Truncated here because the server ignores `perpage`.
            return Array((decoded.results ?? []).map(\.record).prefix(limit))
        } catch {
            throw APIError.decoding(underlying: String(describing: error), party: .mangaUpdates)
        }
    }

    /// One series record — categories, rating, and MangaUpdates' own
    /// status/licensed/completed flags — since they all come off the same
    /// `GET /v1/series/{number}` call.
    ///
    /// Cached on disk for a week, the same way `WebtoonsFeedClient` caches its
    /// feed: "what it's actually like" does not change day to day, and
    /// spending a request (and this client's 3 s spacing) on every series page
    /// visit would make the section the slowest thing on the screen for no
    /// reason.
    ///
    /// - Parameter number: the **decoded numeric** MangaUpdates id. Never the
    ///   base-36 string — see `MangaUpdatesID`.
    func series(number: Int) async throws(APIError) -> MangaUpdatesSeries {
        let key = MangaUpdatesCategories.cacheKey(seriesNumber: number)
        if let cached = readSeriesCache(key) { return cached }

        try await waitForSlot()

        var request = URLRequest(url: baseURL.appendingPathComponent("series/\(number)"))
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where URLError.Code.offlineCodes.contains(error.code) {
            throw APIError.offline
        } catch {
            throw APIError.transport(underlying: String(describing: error), party: .mangaUpdates)
        }

        guard let http = response as? HTTPURLResponse else {
            throw APIError.transport(underlying: "Not an HTTP response.", party: .mangaUpdates)
        }
        if http.statusCode == 429 {
            // Clamped and parsed in one place (`RequestSpacing.backOff`): a bare
            // `TimeInterval.init` accepted "nan" and "1e9" here, and either one
            // ended this client's spacing for the process. See that function.
            let retryAfter = spacing.backOff(
                retryAfterHeader: http.value(forHTTPHeaderField: "Retry-After"), now: clock.now
            )
            throw APIError.rateLimited(retryAfter: retryAfter, party: .mangaUpdates)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.server(
                status: http.statusCode,
                message: "MangaUpdates returned \(http.statusCode).",
                party: .mangaUpdates
            )
        }

        do {
            let decoded = try JSONDecoder().decode(MangaUpdatesSeries.self, from: data)
            writeSeriesCache(key, decoded)
            return decoded
        } catch {
            throw APIError.decoding(underlying: String(describing: error), party: .mangaUpdates)
        }
    }

    // MARK: - Series cache

    private struct CachedSeries: Codable {
        let storedAt: Date
        let series: MangaUpdatesSeries
    }

    private func seriesCacheFile(_ key: String) -> URL? {
        cacheDirectory?.appendingPathComponent("\(key).json")
    }

    private func readSeriesCache(_ key: String) -> MangaUpdatesSeries? {
        guard let file = seriesCacheFile(key), let data = try? Data(contentsOf: file),
              let cached = try? JSONDecoder().decode(CachedSeries.self, from: data),
              clock.now.timeIntervalSince(cached.storedAt) < MangaUpdatesCategories.cacheLife
        else { return nil }
        return cached.series
    }

    private func writeSeriesCache(_ key: String, _ series: MangaUpdatesSeries) {
        guard let directory = cacheDirectory, let file = seriesCacheFile(key) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cached = CachedSeries(storedAt: clock.now, series: series)
        try? JSONEncoder().encode(cached).write(to: file, options: .atomic)
    }

    /// Blocks until the spacing interval has elapsed since the last request.
    /// The slot is claimed before the wait; see `RequestSpacing` for why.
    private func waitForSlot() async throws(APIError) {
        let wait = spacing.claim(now: clock.now)
        guard wait > 0 else { return }
        do {
            try await Task.sleep(for: .seconds(wait))
        } catch {
            // `Task.sleep` only throws `CancellationError` — see the matching
            // comment on `AniListClient.waitForSlot` (gap 26).
            throw APIError.cancelled
        }
    }
}

private extension Optional where Wrapped == URL {
    var unsafeScheduleFallback: URL {
        guard let self else { preconditionFailure("Hard-coded MangaUpdates URL failed to parse.") }
        return self
    }
}
