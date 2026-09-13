import Foundation

/// A picked tag, genre or publisher, as the search field shows it.
///
/// The field's tokens are the query's `tags`, `genres` and `publisher`
/// (UX#6): visible beside the typed text, removable one at a time with the
/// system's own ×, gone with Cancel. Status, sort, rating and year stay in
/// `FilterPanel` — a token says "is Isekai" well and "rating ≥ 8, 2020–2024"
/// badly. The two directions below are pure so the round trip has a test
/// without a live field.
enum SearchToken: Hashable, Identifiable {
    case tag(String)
    case genre(String)
    case publisher(String)

    var id: String {
        switch self {
        case let .tag(name): "tag:\(name)"
        case let .genre(name): "genre:\(name)"
        case let .publisher(name): "publisher:\(name)"
        }
    }

    /// What the token reads. A genre arrives as the API spells it
    /// (`slice_of_life`); the field shows the words.
    var label: String {
        switch self {
        case let .tag(name): name
        case let .genre(name): name.replacingOccurrences(of: "_", with: " ").capitalized
        case let .publisher(name): name
        }
    }

    /// The query's tokens, in the order the field shows them: tags, then
    /// genres, then the publisher.
    nonisolated static func tokens(for query: SearchQuery) -> [SearchToken] {
        var out = query.tags.map(SearchToken.tag) + query.genres.map(SearchToken.genre)
        if let publisher = query.publisher, !publisher.isEmpty {
            out.append(.publisher(publisher))
        }
        return out
    }

    /// `query` with its tags, genres and publisher replaced by `tokens` —
    /// what the field writes back when one is removed. Every other field of
    /// the query is left exactly as it was.
    nonisolated static func applying(_ tokens: [SearchToken], to query: SearchQuery) -> SearchQuery {
        var next = query
        next.tags = []
        next.genres = []
        next.publisher = nil
        for token in tokens {
            switch token {
            case let .tag(name): next.tags.append(name)
            case let .genre(name): next.genres.append(name)
            case let .publisher(name): next.publisher = name
            }
        }
        return next
    }
}

/// The search field's scope bar: type, one at a time (UX#6 — the "manga vs
/// manhwa" ask in one tap, no panel).
///
/// Single-select by the platform's design; the panel's Type chips stay
/// multi-select. The two share `query.types`: a scope writes exactly one
/// type, and the bar reads the query back — one type shows as its scope,
/// none or several as All, since a scope bar cannot show two at once.
enum SearchScope: String, CaseIterable, Identifiable {
    case all, manga, manhwa, manhua, novel, oel

    var id: String { rawValue }

    /// "All", "Manga", "OEL" — the series page's own spelling of a type.
    var label: String {
        switch self {
        case .all: "All"
        default: DetailHero.typeLabel(rawValue) ?? rawValue.capitalized
        }
    }

    /// The scope the query's types show as.
    nonisolated static func scope(for types: [String]) -> SearchScope {
        guard types.count == 1, let only = types.first else { return .all }
        return SearchScope(rawValue: only.lowercased()) ?? .all
    }

    /// The types a chosen scope writes.
    nonisolated static func types(for scope: SearchScope) -> [String] {
        scope == .all ? [] : [scope.rawValue]
    }
}
