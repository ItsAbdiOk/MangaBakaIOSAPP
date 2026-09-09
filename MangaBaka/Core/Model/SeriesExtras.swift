import Foundation

/// Somewhere the series can actually be read.
struct SeriesLink: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    /// The raw URL as the API gave it. Prefer `safeURL` for anything that
    /// actually opens.
    let url: URL?
    /// Machine name, e.g. "manta.net".
    let name: String?
    /// Human name, e.g. "Manta". Prefer this when present.
    let nameDisplay: String?
    /// "webplatform", "official", and similar.
    let type: String?
    let language: String?

    var title: String { nameDisplay ?? name ?? "Link" }

    /// The URL only if it is safe to hand to the system.
    ///
    /// MangaBaka's data is community-maintained, so these come from other
    /// people. Opening an arbitrary scheme on someone's behalf hands a
    /// contributor the ability to trigger another installed app — a deep link,
    /// a payment sheet, a shortcut — with none of the deliberation a normal
    /// web link implies. Only http and https are opened.
    var safeURL: URL? { url.flatMap(SafeLink.web) }
}

/// Scheme filtering for URLs that arrive from other people.
enum SafeLink {
    /// Returns the URL only when it is an ordinary web link.
    static func web(_ url: URL?) -> URL? {
        guard let url, let scheme = url.scheme?.lowercased() else { return nil }
        guard scheme == "http" || scheme == "https" else { return nil }
        // A scheme with no host is not a web link either, whatever it claims.
        guard let host = url.host(), !host.isEmpty else { return nil }
        return url
    }
}

/// A news item mentioning the series.
struct NewsItem: Decodable, Identifiable, Equatable, Sendable {
    let id: Int
    let title: String
    /// Raw as received; use `safeURL` to open it.
    let url: URL?
    /// Where it came from, e.g. "ann" (Anime News Network).
    let sourceName: String?
    let publishedAt: Date?
    /// Whether the series is the article's main subject rather than a mention.
    let primary: Bool?

    /// The URL only if it is an ordinary web link. Same reasoning as
    /// `SeriesLink.safeURL`: news URLs are contributed data too.
    var safeURL: URL? { SafeLink.web(url) }
}

/// A formal relationship to another series: a sequel, a spin-off, the novel a
/// manhwa was adapted from.
struct SeriesRelationship: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    /// "source", "sequel", "prequel", "spin_off", and similar.
    let relationType: String?
    let note: String?
    let series: Series

    /// The relation as something worth reading, e.g. "Source" or "Spin off".
    var label: String {
        guard let relationType else { return "Related" }
        return relationType
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }
}
