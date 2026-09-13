import Foundation

/// Fetches a Japanese publisher's magazine-wide RSS feed and filters it down
/// to one series.
///
/// **Per-episode JSON was tried first and rejected.** GigaViewer (the engine
/// behind these seven sites) answers `<episode url>.json`, but reading a
/// series' schedule that way needs one request per episode, and the payload
/// carries the page image URLs — which must never be rendered, matching the
/// rule Webtoons' feed already lives by. The magazine-wide RSS at `<host>/rss`
/// costs one request for an entire magazine, and carries none of that.
///
/// That shape has a cost the per-series feeds do not: the feed is the whole
/// magazine, not one series, and a magazine changes every day, unlike a
/// series' own feed which only moves on its own schedule — so the cache here
/// is a day, not a week, and it is keyed on the host rather than the series,
/// so every series read from the same magazine shares one request.
actor GigaViewerFeedClient: ReleaseFeedProvider {
    /// A GUESS: none of these seven publish a documented limit.
    static let minimumInterval: TimeInterval = 3.5
    /// One day, not one week: a magazine feed turns over daily, and the
    /// per-series feeds' week-long cache would leave a new chapter unseen for
    /// most of that week.
    static let cacheLife: TimeInterval = 24 * 3600

    nonisolated let source: ReleaseSource = .gigaViewer

    private let session: URLSession
    private let clock: any Clock
    private let cacheDirectory: URL?
    private var spacing = RequestSpacing(minimumInterval: GigaViewerFeedClient.minimumInterval)

    init(
        session: URLSession = .shared,
        clock: any Clock = SystemClock(),
        cacheDirectory: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("gigaviewer", isDirectory: true)
    ) {
        self.session = session
        self.clock = clock
        self.cacheDirectory = cacheDirectory
    }

    func feed(for series: Series, links: [SeriesLink]) async -> FeedAnswer {
        guard let host = Self.matchingHost(in: links.compactMap(\.safeURL)) else { return .notCarried }
        let (items, failure) = await magazineItems(host: host)
        guard let items else {
            let fallback = APIError.transport(
                underlying: "GigaViewer feed did not parse.", party: .gigaViewer
            )
            return .failed(failure ?? fallback)
        }

        return .answered(Self.answer(matching: series, in: items, host: host))
    }

    /// See `ReleaseFeedProvider.cachedFeed`: the same per-host magazine cache
    /// `feed(for:links:)` reads, filtered the same way — no request for the
    /// magazine feed, and no spacing claim.
    func cachedFeed(for series: Series, links: [SeriesLink]) async -> ReleaseFeed? {
        guard let host = Self.matchingHost(in: links.compactMap(\.safeURL)) else { return nil }
        guard let items = readCacheIgnoringAge("v1-giga-\(host)")?.items else { return nil }
        return Self.answer(matching: series, in: items, host: host)
    }

    /// Filters a magazine's items down to one series' feed. Shared by
    /// `feed(for:links:)` and `cachedFeed(for:links:)` so a network answer and
    /// a cached one are turned into a `ReleaseFeed` by exactly the same rule.
    private static func answer(matching series: Series, in items: [Item], host: String) -> ReleaseFeed? {
        let titles = candidateTitles(for: series)
        let matched = items.filter { item in titles.contains(normalise(item.seriesTitle)) }
        // The magazine answered; this series just is not in this issue. A
        // real answer with nothing usable, not a failure.
        guard !matched.isEmpty else { return nil }

        let entries = matched.map { item in
            let read = WebtoonsTitle.read(item.episodeTitle)
            return ReleaseEntry(
                title: item.episodeTitle, published: item.published,
                number: read?.number, season: read?.season
            )
        }
        // `matchingHost` only ever returns a key of this same dictionary, so
        // the fallback is unreachable — kept pointing at
        // `ReleaseSource.gigaViewer.displayName` rather than its own copy of
        // the string, so there is one name to update, not two.
        let hostName = ReleaseSource.gigaViewerHostNames[host] ?? ReleaseSource.gigaViewer.displayName
        return ReleaseFeed(title: hostName, entries: entries, source: .gigaViewer, sourceName: hostName)
    }

    /// The host from a series' links that is one of the seven confirmed
    /// GigaViewer magazines, or nil.
    static func matchingHost(in candidates: [URL]) -> String? {
        for url in candidates {
            guard let host = url.host()?.lowercased() else { continue }
            let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            if ReleaseSource.gigaViewerHostNames.keys.contains(bare) { return bare }
        }
        return nil
    }

    /// Every name this series could appear under in a magazine feed: its
    /// display title plus every language's title it carries, normalised the
    /// same way the feed titles are.
    static func candidateTitles(for series: Series) -> Set<String> {
        var names = (series.titles ?? []).map(\.title)
        if let display = series.displayTitle { names.append(display) }
        return Set(names.map(normalise))
    }

    /// Trimmed, and full-width Latin/space forms folded to half-width, so
    /// "カテナチオ" from an RSS title compares equal to itself regardless of
    /// which width variant either side used, and case differences in a
    /// Latin title do not cause a false miss.
    static func normalise(_ title: String) -> String {
        let folded = title.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? title
        return folded.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    // MARK: - Magazine feed

    /// - Returns: the magazine's items, or nil with the reason it could not
    ///   be read (`APIError`, nil only when there was genuinely no candidate
    ///   URL to build — should not happen, `host` always comes from
    ///   `matchingHost`'s own dictionary of hosts it can build a URL for).
    private func magazineItems(host: String) async -> (items: [Item]?, failure: APIError?) {
        let key = "v1-giga-\(host)"
        if let cached = readCache(key) { return (cached, nil) }
        guard let url = URL(string: "https://\(host)/rss") else { return (nil, nil) }

        let wait = spacing.claim(now: clock.now)
        if wait > 0 {
            try? await Task.sleep(for: .seconds(wait))
            // Gap 28: see `WebtoonsFeedClient.feed(for:seriesID:)`.
            guard !Task.isCancelled else { return (nil, .cancelled) }
        }

        guard let (data, response) = try? await session.data(from: url) else {
            return (nil, .transport(underlying: "GigaViewer request failed.", party: .gigaViewer))
        }
        guard let http = response as? HTTPURLResponse else {
            return (nil, .transport(underlying: "GigaViewer sent a non-HTTP response.", party: .gigaViewer))
        }
        if http.statusCode == 429 {
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            spacing.backOff(until: clock.now.addingTimeInterval(retryAfter ?? 60))
            return (nil, .rateLimited(retryAfter: retryAfter, party: .gigaViewer))
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = "GigaViewer returned \(http.statusCode)."
            return (nil, .server(status: http.statusCode, message: message, party: .gigaViewer))
        }
        guard let items = MagazineFeedParser.parse(data) else {
            return (nil, .decoding(underlying: "GigaViewer feed did not parse.", party: .gigaViewer))
        }
        writeCache(key, items)
        return (items, nil)
    }

    /// One item off a magazine feed: an episode of some series in the
    /// magazine, before it is known whether that series is the one asked for.
    struct Item: Codable {
        /// "[第33話] カテナチオ" split at the closing bracket.
        let episodeTitle: String
        let seriesTitle: String
        let published: Date
        let link: URL?
    }

    // MARK: - Cache

    private struct Cached: Codable {
        let storedAt: Date
        let items: [Item]
    }

    private func file(_ key: String) -> URL? {
        cacheDirectory?.appendingPathComponent("\(key).json")
    }

    private func readCache(_ key: String) -> [Item]? {
        guard let cached = readCacheIgnoringAge(key),
              clock.now.timeIntervalSince(cached.storedAt) < Self.cacheLife
        else { return nil }
        return cached.items
    }

    /// `readCache` without the freshness gate — see the `WebtoonsFeedClient`
    /// sibling of the same name for why `cachedFeed` needs this.
    private func readCacheIgnoringAge(_ key: String) -> Cached? {
        guard let file = file(key), let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(Cached.self, from: data)
    }

    private func writeCache(_ key: String, _ items: [Item]) {
        guard let directory = cacheDirectory, let file = file(key) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cached = Cached(storedAt: clock.now, items: items)
        try? JSONEncoder().encode(cached).write(to: file, options: .atomic)
    }
}

/// Parses a GigaViewer magazine RSS document into `GigaViewerFeedClient.Item`s.
///
/// A sibling of `WebtoonsFeedParser`'s delegate rather than a shared one: the
/// two feeds carry different fields (this one has no season-free episode
/// concept and instead splits title into series name and episode title at the
/// closing bracket), and `<description>`/`<enclosure>` are dropped here
/// deliberately — the description carries the episode's own thumbnail, which
/// must never be rendered, matching the rule for Webtoons' feed.
enum MagazineFeedParser {
    static func parse(_ data: Data) -> [GigaViewerFeedClient.Item]? {
        let delegate = MagazineFeedDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { return nil }
        return delegate.items
    }

    /// "[第33話] カテナチオ" → episode "[第33話] カテナチオ", series "カテナチオ" —
    /// the text after the first closing bracket, trimmed. A title with no
    /// bracket at all (should not happen on these feeds) yields the whole
    /// string as both, so a match still has something to compare against.
    static func splitSeriesTitle(_ title: String) -> String {
        guard let range = title.range(of: "]") else { return title }
        return String(title[range.upperBound...]).trimmingCharacters(in: .whitespaces)
    }
}

private final class MagazineFeedDelegate: NSObject, XMLParserDelegate {
    var items: [GigaViewerFeedClient.Item] = []

    private var text = ""
    private var insideItem = false
    private var itemTitle = ""
    private var itemDate = ""
    private var itemLink = ""

    private static let rfc822: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()

    func parser(
        _ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
        qualifiedName: String?, attributes: [String: String] = [:]
    ) {
        text = ""
        if name == "item" {
            insideItem = true
            itemTitle = ""
            itemDate = ""
            itemLink = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard let decoded = String(bytes: CDATABlock, encoding: .utf8) else { return }
        text += decoded
    }

    func parser(
        _ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
        qualifiedName: String?
    ) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // `<description>` (page thumbnails) and `<enclosure>` are read by
        // neither branch below, so their content never reaches `items`.
        switch (name, insideItem) {
        case ("title", true):
            itemTitle = value
        case ("pubDate", true):
            itemDate = value
        case ("link", true):
            itemLink = value
        case ("item", _):
            insideItem = false
            append()
        default:
            break
        }
        text = ""
    }

    private func append() {
        guard !itemTitle.isEmpty, let date = Self.rfc822.date(from: itemDate) else { return }
        let series = MagazineFeedParser.splitSeriesTitle(itemTitle)
        items.append(GigaViewerFeedClient.Item(
            episodeTitle: itemTitle, seriesTitle: series, published: date, link: URL(string: itemLink)
        ))
    }
}
