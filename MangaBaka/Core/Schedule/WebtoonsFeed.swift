import Foundation

/// A Webtoons series feed, parsed.
///
/// Webtoons publishes an RSS feed per series — an official one, meant to be
/// read by other software, unlike scraping the page. It carries the twenty most
/// recent entries with exact publication timestamps, which is the only place
/// this app can get a *real* release schedule: everything else it knows about
/// timing is inferred from when scanlations appeared. See `Cadence`, whose own
/// documentation says no source publishes real schedules — true everywhere
/// except here.
struct WebtoonsFeed: Equatable, Sendable, Codable {
    let title: String
    let entries: [WebtoonsEntry]

    /// Entries that are actually episodes, newest first.
    var episodes: [WebtoonsEntry] { entries.filter(\.isEpisode) }

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

    /// The feed URL for a series link, or nil when one cannot be built.
    ///
    /// Derived from the link MangaBaka already stores rather than assembled
    /// from a slug of our own: Webtoons keys the feed on `title_no` but still
    /// 404s or 500s when the genre and slug in the path are wrong, verified by
    /// getting exactly that wrong twice (2026-09-12).
    ///
    /// Returns nil for MangaBaka's placeholder links. Its French, Spanish,
    /// Thai, Indonesian and German entries are stored literally as
    /// `webtoons.com/-/-/-/list?title_no=5188`, and a `-` in the path is not a
    /// slug the feed will answer to. English and Traditional Chinese links
    /// carry real slugs and work.
    static func feedURL(for link: URL) -> URL? {
        guard let host = link.host()?.lowercased(),
              host == "webtoons.com" || host.hasSuffix(".webtoons.com"),
              link.path().contains("/list"),
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

    /// Parses an RSS document.
    ///
    /// `XMLParser` from Foundation rather than an HTML parsing dependency —
    /// this is well-formed XML from a feed, not a page being scraped, so there
    /// is nothing to be lenient about and no library to add.
    static func parse(_ data: Data) -> WebtoonsFeed? {
        let delegate = FeedDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(), !delegate.channelTitle.isEmpty else { return nil }
        return WebtoonsFeed(title: delegate.channelTitle, entries: delegate.entries)
    }
}

/// Collects the channel title and every `<item>` in document order.
///
/// `XMLParser` is push-based and its delegate is a class, so the accumulated
/// state lives here rather than in the struct above.
private final class FeedDelegate: NSObject, XMLParserDelegate {
    var channelTitle = ""
    var entries: [WebtoonsEntry] = []

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
        guard !itemTitle.isEmpty, let date = Self.rfc822.date(from: itemDate) else { return }
        let read = WebtoonsTitle.read(itemTitle)
        entries.append(WebtoonsEntry(
            title: itemTitle, published: date, number: read?.number, season: read?.season
        ))
    }
}
