import Foundation

/// One title for a series, in one language.
struct SeriesTitle: Codable, Equatable, Sendable, Hashable {
    /// BCP-47-ish tag as the API returns it: "en", "ko", "pt-br", "ko-Latn".
    let language: String
    /// Zero or more of "official", "native", "alternative".
    let traits: [String]
    let title: String
    /// Whether this is the primary title *for its own language*.
    ///
    /// Measured against the live API on 2026-09-08: every title in a series
    /// carries `is_primary: true` (25 of 25, 14 of 14, 18 of 18 across the
    /// three series returned by `/v2/series/discover/rising`). It therefore
    /// does NOT identify a single display title — selecting on this field
    /// alone yields an arbitrary language. See `DisplayTitle`.
    let isPrimary: Bool?
}

extension SeriesTitle {
    /// One of a series' other names, with every language that uses it.
    struct Alternative: Identifiable, Equatable, Sendable {
        let title: String
        let languages: [String]
        var id: String { title }
        /// "English · Turkish · Portuguese (Brazil)". It was the codes —
        /// "EN · TR · PT-BR" — which a reader had to decode themselves.
        var languageLabel: String { languages.map(LanguageFlag.name(for:)).joined(separator: " · ") }
        /// "🇬🇧 🇹🇷 🇧🇷" — one per language that has one, in the same order.
        var flags: String {
            languages.compactMap(LanguageFlag.emoji(for:)).joined(separator: " ")
        }
    }

    /// Every title except the one already on screen, de-duplicated.
    ///
    /// Duplicates across languages are ordinary: "Solo Leveling" is the title
    /// in English, Turkish and Brazilian Portuguese. Listing it three times
    /// would make the section look broken rather than thorough, so the
    /// languages are gathered onto one row.
    ///
    /// The API's order is kept. It carries no meaning we can improve on, and
    /// sorting alphabetically would put Arabic first for every series.
    static func alternatives(in titles: [SeriesTitle], excluding shown: String?) -> [Alternative] {
        var byTitle: [String: [String]] = [:]
        var order: [String] = []
        for entry in titles where entry.title != shown && !entry.title.isEmpty {
            if byTitle[entry.title] == nil { order.append(entry.title) }
            byTitle[entry.title, default: []].append(entry.language)
        }
        return order.map { Alternative(title: $0, languages: byTitle[$0] ?? []) }
    }
}
