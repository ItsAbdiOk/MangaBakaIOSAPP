import Foundation

// Codable rather than Decodable, so a series page's extras can be cached whole.
// Eight requests a visit is worth writing to disk; the encode side is only ever
// used by that cache.

/// Somewhere the series can actually be read.
struct SeriesLink: Codable, Identifiable, Equatable, Sendable {
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

extension SeriesLink {
    /// What a link is for.
    ///
    /// The API's own vocabulary, checked against series 3397 on 2026-09-11:
    /// 13 `webplatform`, 4 `publisher`, 3 `info`, 1 `social`. Ordered as a
    /// reader wants them — somewhere to read it first, because that is what
    /// someone on a series page is usually after; social last, because it is
    /// about the creators rather than the work.
    enum Purpose: String, CaseIterable, Sendable {
        case webplatform, publisher, info, social

        var heading: String {
            switch self {
            case .webplatform: "Read it"
            case .publisher: "Publishers"
            case .info: "More about it"
            case .social: "Social"
            }
        }
    }

    /// One heading and the links under it.
    struct Group: Identifiable, Equatable, Sendable {
        let heading: String
        let links: [SeriesLink]
        var id: String { heading }
        var count: Int { links.count }
    }

    /// Links grouped by purpose, empty groups omitted.
    ///
    /// Kept out of the view so it can be tested: the old section took the
    /// first six links of any kind under one heading, which on a series with
    /// thirteen reading platforms lost the publisher and the official page
    /// purely to ordering.
    ///
    /// An unrecognised or absent `type` lands in "Elsewhere" rather than being
    /// dropped — MangaBaka's data is community-maintained and its vocabulary
    /// can grow, and a new kind appearing should not make a link vanish.
    ///
    /// `safeURL` filters throughout. These URLs come from other people, and an
    /// arbitrary scheme can trigger another installed app.
    static func grouped(_ links: [SeriesLink]) -> [Group] {
        let usable = links.filter { $0.safeURL != nil }
        var groups = Purpose.allCases.compactMap { purpose -> Group? in
            let matching = usable.filter { $0.type == purpose.rawValue }
            return matching.isEmpty ? nil : Group(heading: purpose.heading, links: matching)
        }
        let known = Set(Purpose.allCases.map(\.rawValue))
        let others = usable.filter { !known.contains($0.type ?? "") }
        if !others.isEmpty { groups.append(Group(heading: "Elsewhere", links: others)) }
        return groups
    }
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
struct NewsItem: Codable, Identifiable, Equatable, Sendable {
    /// Nullable on the wire (`V1_News.id`). Rows without one are told apart
    /// by their URL, then their title.
    let newsID: Int?
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

    var id: String { newsID.map(String.init) ?? url?.absoluteString ?? title }

    enum CodingKeys: String, CodingKey {
        case newsID = "id"
        case title, url, sourceName, publishedAt, primary
    }
}

/// A formal relationship to another series: a sequel, a spin-off, the novel a
/// manhwa was adapted from.
struct SeriesRelationship: Codable, Identifiable, Equatable, Sendable {
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

extension SeriesLink {
    /// The official reading platforms carrying the series in one language.
    ///
    /// Only `webplatform` links: a publisher's shop or a wiki is not somewhere
    /// to read. Only the reader's language: series 3397 lists thirteen
    /// platforms in seven languages, and a reader in English wants the four
    /// that are, not Piccoma in Japanese. The API's own order is kept.
    ///
    /// The language tags are compared on their primary subtag — the API writes
    /// "pt-br" for Planet Manga and the device says "pt" — so a Brazilian
    /// edition counts for a Portuguese reader. Regional mismatches are a far
    /// smaller wrong than an empty row.
    ///
    /// One chip per platform. ONE PIECE (377) lists MANGA Plus five times in
    /// English — the main run, the colour edition and the spin-offs — and the
    /// row read "MANGA Plus, MANGA Plus, MANGA Plus". The first listing is
    /// kept: on 377 it is the main title (100020), and the links section
    /// further down still shows all five.
    static func readable(_ links: [SeriesLink], in language: String) -> [SeriesLink] {
        let wanted = primarySubtag(language)
        guard !wanted.isEmpty else { return [] }
        var seen: Set<String> = []
        return links.filter {
            guard $0.type == Purpose.webplatform.rawValue,
                  $0.safeURL != nil,
                  primarySubtag($0.language ?? "") == wanted
            else { return false }
            return seen.insert($0.name ?? $0.title).inserted
        }
    }

    /// "pt-BR" → "pt"; "en" → "en". Case-insensitive, whitespace ignored.
    static func primarySubtag(_ tag: String) -> String {
        tag.trimmingCharacters(in: .whitespaces)
            .lowercased()
            .split(separator: "-", maxSplits: 1)
            .first
            .map(String.init) ?? ""
    }
}
