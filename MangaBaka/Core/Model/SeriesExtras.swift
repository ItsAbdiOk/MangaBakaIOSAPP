import Foundation

/// Somewhere the series can actually be read.
struct SeriesLink: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let url: URL?
    /// Machine name, e.g. "manta.net".
    let name: String?
    /// Human name, e.g. "Manta". Prefer this when present.
    let nameDisplay: String?
    /// "webplatform", "official", and similar.
    let type: String?
    let language: String?

    var title: String { nameDisplay ?? name ?? "Link" }
}

/// A news item mentioning the series.
struct NewsItem: Decodable, Identifiable, Equatable, Sendable {
    let id: Int
    let title: String
    let url: URL?
    /// Where it came from, e.g. "ann" (Anime News Network).
    let sourceName: String?
    let publishedAt: Date?
    /// Whether the series is the article's main subject rather than a mention.
    let primary: Bool?
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
