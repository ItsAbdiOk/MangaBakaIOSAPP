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

    /// Identifies the app, as their terms require.
    static let userAgent = "MangaBakaIOS/1.0 (+https://github.com/ItsAbdiOk/MangaBakaIOSAPP)"

    init(
        baseURL: URL = URL(string: "https://api.mangaupdates.com/v1").unsafeScheduleFallback,
        session: URLSession = .shared,
        clock: any Clock = SystemClock()
    ) {
        self.baseURL = baseURL
        self.session = session
        self.clock = clock
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

        /// "57-58" and "c.12 (end)" both start with the number that matters.
        private static func firstNumber(in text: String) -> Double? {
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
        } catch let error as URLError where error.code == .notConnectedToInternet {
            throw APIError.offline
        } catch {
            throw APIError.transport(underlying: String(describing: error))
        }

        guard let http = response as? HTTPURLResponse else {
            throw APIError.transport(underlying: "Not an HTTP response.")
        }
        if http.statusCode == 429 {
            let retryAfter = (http.value(forHTTPHeaderField: "Retry-After")).flatMap(TimeInterval.init)
            spacing.backOff(until: clock.now.addingTimeInterval(retryAfter ?? 60))
            throw APIError.rateLimited(retryAfter: retryAfter)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.server(
                status: http.statusCode,
                message: "MangaUpdates returned \(http.statusCode)."
            )
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            let decoded = try decoder.decode(SearchResponse.self, from: data)
            // Truncated here because the server ignores `perpage`.
            return Array((decoded.results ?? []).map(\.record).prefix(limit))
        } catch {
            throw APIError.decoding(underlying: String(describing: error))
        }
    }

    /// Blocks until the spacing interval has elapsed since the last request.
    /// The slot is claimed before the wait; see `RequestSpacing` for why.
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
    var unsafeScheduleFallback: URL {
        guard let self else { preconditionFailure("Hard-coded MangaUpdates URL failed to parse.") }
        return self
    }
}
