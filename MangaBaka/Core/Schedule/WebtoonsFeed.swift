import Foundation

/// A release feed, parsed — Webtoons' per-series RSS or a GigaViewer
/// publisher's magazine-wide RSS filtered to one series.
///
/// Webtoons publishes an RSS feed per series — an official one, meant to be
/// read by other software, unlike scraping the page. It carries the twenty most
/// recent entries with exact publication timestamps, which is the only place
/// this app can get a *real* release schedule: everything else it knows about
/// timing is inferred from when scanlations appeared. See `Cadence`, whose own
/// documentation says no source publishes real schedules — true everywhere
/// except here.
struct ReleaseFeed: Equatable, Sendable, Codable {
    let title: String
    let entries: [ReleaseEntry]
    /// Who this feed is from — set by the provider that fetched it, so
    /// `ReleaseSummary`/`ReleaseFeedService` never have to guess it back out
    /// of the shape of the data.
    let source: ReleaseSource
    /// The GigaViewer host this feed was matched from, e.g. "Tonari no Young
    /// Jump" — GigaViewer has no single brand name, only seven publisher
    /// sites on one engine, so the header names whichever one answered rather
    /// than a name fixed on `ReleaseSource`. Nil for every other source.
    let sourceName: String?

    // `totalCount` (the official episode count) and `finished` (the official
    // completion flag) were here until 2026-09-14. Both were documented "Naver
    // only" — Naver's `/api/article/list` was the one release endpoint that
    // stated either rather than leaving it to be counted from entries — and
    // both were permanently nil from the day that adapter was deleted under
    // the private-API rule. `WebtoonsFeedClient` and `GigaViewerFeedClient`
    // are the only constructors of `ReleaseFeed` in production and neither
    // ever passed them. See the tombstone in `ReleaseFeedService.swift` for
    // what they fed and what it would take to bring it back.

    init(
        title: String, entries: [ReleaseEntry], source: ReleaseSource,
        sourceName: String? = nil
    ) {
        self.title = title
        self.entries = entries
        self.source = source
        self.sourceName = sourceName
    }

    /// Entries that are actually episodes, newest first.
    var episodes: [ReleaseEntry] { entries.filter(\.isEpisode) }

    /// Release dates for `Cadence.estimate`, episodes only.
    ///
    /// Afterwords are excluded deliberately. All three of "The Knight Only
    /// Lives Today"'s share one timestamp, so they would add zero-length gaps
    /// to a median taken over real weekly ones.
    var releaseDates: [Date] { episodes.map(\.published) }

    /// The highest episode number the feed carries.
    ///
    /// Max, not the newest entry: the newest entry of a finished season is an
    /// afterword, and taking its position would report episode 3 for a series
    /// on 112.
    var latestEpisodeNumber: Int? { episodes.compactMap(\.number).max() }

    /// When the most recent episode actually landed.
    var lastEpisodeAt: Date? { episodes.map(\.published).max() }

    /// Whether the run ended rather than stalled.
    ///
    /// A season that has finished publishes its finale and then its afterwords,
    /// and stops. A gap-based estimate sees only "nothing for weeks" and calls
    /// that late. Reading the finale marker is what tells the two apart — and
    /// the difference is "Season 1 ended on 28 August" against "overdue since
    /// August", which are opposite claims to make to a reader.
    var endedSeason: Int? {
        guard let finale = entries.first(where: { WebtoonsTitle.marksFinale($0.title) }),
              let latest = lastEpisodeAt, finale.published >= latest
        else { return nil }
        return finale.season
    }
}

/// Everything specific to reading a Webtoons series feed: turning a stored
/// series link into its RSS URL, and parsing the RSS document itself. Kept
/// apart from the generic `ReleaseFeed` shape above so GigaViewer does not
/// inherit URL rules and an XML parser that are only ever true of Webtoons.
enum WebtoonsFeedParser {
    /// The feed URL for a series link, or nil when one cannot be built.
    ///
    /// Derived from the link MangaBaka already stores rather than assembled
    /// from a slug of our own: Webtoons keys the feed on `title_no` but still
    /// 404s or 500s when the genre and slug in the path are wrong, verified by
    /// getting exactly that wrong twice (2026-09-12).
    ///
    /// Returns nil for MangaBaka's placeholder links — see `lookupURL`, which
    /// recovers them.
    static func feedURL(for link: URL) -> URL? {
        guard isWebtoons(link), link.path().contains("/list"),
              !link.path().contains("/-/")
        else { return nil }
        var components = URLComponents(url: link, resolvingAgainstBaseURL: false)
        components?.path = link.path().replacingOccurrences(of: "/list", with: "/rss")
        // Only `title_no` identifies the series; anything else the stored link
        // carries is not ours to forward.
        components?.queryItems = URLComponents(url: link, resolvingAgainstBaseURL: false)?
            .queryItems?.filter { $0.name == "title_no" }
        guard components?.queryItems?.isEmpty == false else { return nil }
        return components?.url
    }

    /// A URL that redirects to the series' canonical page, for links whose path
    /// is a placeholder.
    ///
    /// **Measured 2026-09-12, and it changes what this feature is worth.** Only
    /// 16% of the Webtoons links in a 118-series sample of Abdi's library carry
    /// a real slug; the other 84% are stored as `/-/-/-/list?title_no=N`. Taken
    /// at face value that leaves five of every six series with no schedule.
    ///
    /// Webtoons ignores the genre and the slug entirely and keys the page on
    /// `title_no`, redirecting to the canonical path — and it corrects the
    /// *language* segment too: `title_no=5188` sent to `/en/x/y/` lands on
    /// `/fr/fantasy/estatedeveloper/`, and 7620 on `/id/drama/...`. So one
    /// redirect recovers the real path for any placeholder, and the language
    /// comes back right rather than forced to English.
    ///
    /// `en` here is a placeholder of our own, not a preference: the segment has
    /// to be a valid language for the redirect to happen at all, and whichever
    /// one is sent, the destination is the edition Webtoons actually has.
    static func lookupURL(for link: URL) -> URL? {
        guard isWebtoons(link), link.path().contains("/-/"),
              let number = seriesNumber(in: link)
        else { return nil }
        return URL(string: "https://www.webtoons.com/en/x/y/list?title_no=\(number)")
    }

    /// The feed URL for a page the redirect landed on.
    static func feedURL(fromResolved resolved: URL) -> URL? { feedURL(for: resolved) }

    /// The same feed with its language segment rewritten to `en`, or nil when
    /// it already is `en` (or the path is not `/<lang>/...` at all).
    ///
    /// The redirect in `lookupURL` corrects the language to whatever edition
    /// Webtoons actually has, which is not always English — `title_no=5188`
    /// lands on `/fr/`. That edition's feed exists and parses, but its
    /// `pubDate`s are localised (`ven., 24 mars 2023 15:01:24 GMT`), and
    /// `docs/release-sources-2026-09-12.md` already says to prefer the
    /// English feed for schedules. Tried first by the client; the landed
    /// language is the fallback, not dropped, in case the English edition
    /// does not exist for a given series.
    static func englishVariant(of feedURL: URL) -> URL? {
        var components = URLComponents(url: feedURL, resolvingAgainstBaseURL: false)
        var segments = feedURL.path().split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        // path() starts with "/", so segments[0] is "" and segments[1] is the
        // language — /fr/fantasy/estatedeveloper/rss → ["", "fr", ...].
        guard segments.count > 1, segments[1] != "en" else { return nil }
        segments[1] = "en"
        components?.path = segments.joined(separator: "/")
        return components?.url
    }

    static func isWebtoons(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        return host == "webtoons.com" || host.hasSuffix(".webtoons.com")
    }

    private static func seriesNumber(in link: URL) -> String? {
        URLComponents(url: link, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "title_no" }?.value
    }

    /// Parses an RSS document.
    ///
    /// `XMLParser` from Foundation rather than an HTML parsing dependency —
    /// this is well-formed XML from a feed, not a page being scraped, so there
    /// is nothing to be lenient about and no library to add.
    static func parse(_ data: Data) -> ReleaseFeed? {
        let delegate = FeedDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(), !delegate.channelTitle.isEmpty else { return nil }
        return ReleaseFeed(title: delegate.channelTitle, entries: delegate.entries, source: .webtoons)
    }
}

/// Collects the channel title and every `<item>` in document order.
///
/// `XMLParser` is push-based and its delegate is a class, so the accumulated
/// state lives here rather than in the struct above.
private final class FeedDelegate: NSObject, XMLParserDelegate {
    var channelTitle = ""
    var entries: [ReleaseEntry] = []

    private var element = ""
    private var text = ""
    private var insideItem = false
    private var itemTitle = ""
    private var itemDate = ""

    /// RFC 822, which is what RSS dates are. Fixed to POSIX so the device's
    /// locale cannot change how "Fri, 28 Aug 2026" reads.
    private static let rfc822: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()

    /// The same RFC-822 shape, but read with French weekday/month names.
    ///
    /// A non-English Webtoons edition localises `pubDate` — measured live,
    /// `/fr/fantasy/estatedeveloper/`: "ven., 24 mars 2023 15:01:24 GMT" for
    /// every entry, which `rfc822` above returns nil for, silently dropping
    /// the whole feed (`docs/reviews/reader.md`, finding 2, 2026-09-13). The
    /// client tries the English edition first (`WebtoonsFeedParser
    /// .englishVariant`) so this is a fallback, not the common path.
    /// Only French is verified this way; other localised editions (Indonesian,
    /// Spanish, German, Thai, zh-Hant) are an open question, not yet observed.
    private static let rfc822French: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()

    func parser(
        _ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
        qualifiedName: String?, attributes: [String: String] = [:]
    ) {
        element = name
        text = ""
        if name == "item" {
            insideItem = true
            itemTitle = ""
            itemDate = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        // Dropped rather than substituted if it is not UTF-8: a mangled title
        // would be parsed for an episode number as though it were sound.
        guard let decoded = String(bytes: CDATABlock, encoding: .utf8) else { return }
        text += decoded
    }

    func parser(
        _ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
        qualifiedName: String?
    ) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (name, insideItem) {
        case ("title", false) where channelTitle.isEmpty:
            channelTitle = value
        case ("title", true):
            itemTitle = value
        case ("pubDate", true):
            itemDate = value
        case ("item", _):
            insideItem = false
            append()
        default:
            break
        }
        text = ""
    }

    private func append() {
        guard !itemTitle.isEmpty,
              let date = Self.rfc822.date(from: itemDate) ?? Self.rfc822French.date(from: itemDate)
        else { return }
        let read = WebtoonsTitle.read(itemTitle)
        entries.append(ReleaseEntry(
            title: itemTitle, published: date, number: read?.number, season: read?.season
        ))
    }
}
