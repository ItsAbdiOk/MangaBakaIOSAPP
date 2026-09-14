import Foundation

/// Where a shared link points, before it becomes an open request.
///
/// Every case but `.mangaBaka` carries a *tracker's* id, not a MangaBaka
/// series id yet — `OpenSharedURLIntent.seriesID(for:wikidata:)` still has to
/// look the series up, and for `.mangaDex` (and, until a public accessor
/// exists, `.myAnimeList`/`.mangaUpdates` — see that function's own doc and
/// this task's "Wiring needed") there is nothing to look it up with.
enum SharedURLTarget: Equatable, Sendable {
    case mangaBaka(id: Int)
    case aniList(id: Int)
    case myAnimeList(id: Int)
    /// Base-36 text, the same shape `Series.mangaUpdatesID` carries — not
    /// always parseable as `Int`, so kept as a string rather than narrowed.
    case mangaUpdates(id: String)
    case mangaDex(uuid: String)
}

/// Parses a link the reader was sent — from Safari's share sheet, a message,
/// anywhere the share sheet reaches — into a tracker id.
///
/// No network request anywhere in this file: every one of these hosts
/// publishes a plain path-based series URL, so this is string parsing of a
/// URL the app was already handed, not scraping a page for one (the brief's
/// "no scraping" rule is about fetching HTML to read; nothing here fetches
/// anything).
enum SharedURLResolver {
    /// Recognised tracker hosts, `www.`-stripped and lowercased before the
    /// lookup. `anilist.co` also serves anime pages at this same host
    /// (`/anime/{id}`) — see the `.aniList` branch below for why those must
    /// come back `nil` rather than misread as a manga id.
    private enum Host: String {
        case aniList = "anilist.co"
        case myAnimeList = "myanimelist.net"
        case mangaUpdates = "mangaupdates.com"
        case mangaDex = "mangadex.org"
    }

    /// `nonisolated static` — pure string parsing, no actor to hop to, same
    /// as `SeriesWebLink.seriesID(from:)` this delegates to first.
    nonisolated static func target(from url: URL) -> SharedURLTarget? {
        // A mangabaka.org link (or the app's own `mangabaka://` scheme) is
        // already a MangaBaka series id — reusing `SeriesWebLink` rather
        // than re-deriving the same parse keeps this and `RootView`'s
        // `onOpenURL` agreeing on what such a link means, instead of two
        // parsers that could quietly drift apart.
        if let id = SeriesWebLink.seriesID(from: url) {
            return .mangaBaka(id: id)
        }
        guard let rawHost = url.host()?.lowercased() else { return nil }
        let host = rawHost.hasPrefix("www.") ? String(rawHost.dropFirst(4)) : rawHost
        guard let tracker = Host(rawValue: host) else { return nil }
        // Trailing slashes and title slugs after the id: `pathComponents`
        // already drops an empty trailing segment and a query string, so
        // "/manga/30013/one-piece?ref=x" and "/manga/30013/" both leave
        // `parts` exactly `["manga", "30013", ...]` — no extra stripping
        // needed here beyond dropping the leading "/" entry it always adds.
        let parts = url.pathComponents.filter { $0 != "/" }
        return Self.target(tracker, parts: parts)
    }

    /// The path's second segment, when its first is the tracker's own word
    /// for a series. Split from `target(from:)` for the lint's complexity
    /// ceiling, not for reuse.
    nonisolated private static func target(_ tracker: Host, parts: [String]) -> SharedURLTarget? {
        guard parts.count > 1, !parts[1].isEmpty else { return nil }
        let second = parts[1]
        switch tracker {
        case .aniList:
            // "/anime/{id}" is a different work; must stay nil rather than
            // reading the anime's id as if it were the manga's.
            guard parts.first == "manga", let id = Int(second), id > 0 else { return nil }
            return .aniList(id: id)
        case .myAnimeList:
            guard parts.first == "manga", let id = Int(second), id > 0 else { return nil }
            return .myAnimeList(id: id)
        case .mangaUpdates:
            return parts.first == "series" ? .mangaUpdates(id: second) : nil
        case .mangaDex:
            return parts.first == "title" ? .mangaDex(uuid: second) : nil
        }
    }
}
