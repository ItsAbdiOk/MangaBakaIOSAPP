import Foundation

/// Fetches a series' Naver Webtoon feed — the Korean original — at most once a
/// week per series.
///
/// This is the only source that ever plays the role of "the original" in
/// `ReleaseFeedService`: it carries `totalCount` and `finished`, which no
/// English-side feed states, and which is what lets the app say "the Korean
/// original hasn't released in months" before the English translation runs
/// dry. See `TranslationGap`.
actor NaverFeedClient: ReleaseFeedProvider {
    /// A GUESS, matched to the other clients' spacing: Naver publishes no rate
    /// limit for this endpoint.
    static let minimumInterval: TimeInterval = 3.5
    static let cacheLife: TimeInterval = 7 * 24 * 3600

    nonisolated let source: ReleaseSource = .naverWebtoon

    private let session: URLSession
    private let clock: any Clock
    private let cacheDirectory: URL?
    private var spacing = RequestSpacing(minimumInterval: NaverFeedClient.minimumInterval)

    init(
        session: URLSession = .shared,
        clock: any Clock = SystemClock(),
        cacheDirectory: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("naver", isDirectory: true)
    ) {
        self.session = session
        self.clock = clock
        self.cacheDirectory = cacheDirectory
    }

    func feed(for series: Series, links: [SeriesLink]) async -> ReleaseFeed? {
        guard let titleID = Self.titleID(in: links.compactMap(\.safeURL)) else { return nil }
        let key = "v1-naver-\(titleID)"
        if let cached = readCache(key) { return cached }

        guard let url = Self.endpoint(titleID: titleID) else { return nil }

        let wait = spacing.claim(now: clock.now)
        if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }

        guard let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse
        else { return nil }
        if http.statusCode == 429 {
            spacing.backOff(until: clock.now.addingTimeInterval(60))
            return nil
        }
        guard (200..<300).contains(http.statusCode), let payload = try? JSONDecoder().decode(
            Payload.self, from: data
        ) else { return nil }

        let feed = payload.releaseFeed
        writeCache(key, feed)
        return feed
    }

    /// The `titleId` query item off a stored `comic.naver.com/webtoon/list`
    /// link, e.g. `.../webtoon/list?titleId=183559`.
    static func titleID(in candidates: [URL]) -> String? {
        for url in candidates {
            guard let host = url.host()?.lowercased(),
                  host == "comic.naver.com" || host.hasSuffix(".comic.naver.com")
            else { continue }
            if let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "titleId" })?.value {
                return id
            }
        }
        return nil
    }

    static func endpoint(titleID: String) -> URL? {
        URL(string: "https://comic.naver.com/api/article/list?titleId=\(titleID)&page=1")
    }

    // MARK: - Decoding

    /// The live shape, measured 2026-09-13. `no` is the article's position in
    /// Naver's own list and is deliberately not trusted as the episode number
    /// — Tower of God's newest `no` was 654 while its title read episode 235.
    /// The number comes from `WebtoonsTitle.read`, which already reads Korean
    /// 화 out of `subtitle`.
    struct Payload: Codable {
        let totalCount: Int?
        let finished: Bool?
        let articleList: [Article]?

        struct Article: Codable {
            let no: Int
            let subtitle: String?
            let serviceDateDescription: String?
        }

        var releaseFeed: ReleaseFeed {
            let entries = (articleList ?? []).compactMap { article -> ReleaseEntry? in
                guard let subtitle = article.subtitle,
                      let published = Self.date(from: article.serviceDateDescription)
                else { return nil }
                let read = WebtoonsTitle.read(subtitle)
                return ReleaseEntry(
                    title: subtitle, published: published, number: read?.number, season: read?.season
                )
            }
            return ReleaseFeed(
                title: "Naver Webtoon", entries: entries, source: .naverWebtoon,
                totalCount: totalCount, finished: finished
            )
        }

        /// "25.02.02" → 2025-02-02 at noon in Asia/Seoul.
        ///
        /// **Noon is a guess.** The API gives only a date, no time of day, and
        /// noon is the least wrong placeholder — it cannot fall on the wrong
        /// calendar day in either direction of a same-day comparison the way
        /// midnight can.
        private static func date(from description: String?) -> Date? {
            guard let description else { return nil }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "Asia/Seoul") ?? .current
            let parts = description.split(separator: ".").compactMap { Int($0) }
            guard parts.count == 3 else { return nil }
            var components = DateComponents()
            components.year = 2000 + parts[0]
            components.month = parts[1]
            components.day = parts[2]
            components.hour = 12
            return calendar.date(from: components)
        }
    }

    // MARK: - Cache

    private struct Cached: Codable {
        let storedAt: Date
        let feed: ReleaseFeed
    }

    private func file(_ key: String) -> URL? {
        cacheDirectory?.appendingPathComponent("\(key).json")
    }

    private func readCache(_ key: String) -> ReleaseFeed? {
        guard let file = file(key), let data = try? Data(contentsOf: file),
              let cached = try? JSONDecoder().decode(Cached.self, from: data),
              clock.now.timeIntervalSince(cached.storedAt) < Self.cacheLife
        else { return nil }
        return cached.feed
    }

    private func writeCache(_ key: String, _ feed: ReleaseFeed) {
        guard let directory = cacheDirectory, let file = file(key) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cached = Cached(storedAt: clock.now, feed: feed)
        try? JSONEncoder().encode(cached).write(to: file, options: .atomic)
    }
}
