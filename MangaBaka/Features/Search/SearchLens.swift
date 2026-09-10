import Foundation

/// A saved search, shown on the search screen before anything is typed.
///
/// The mockup calls these "lenses" and names them personally — "Seinen I never
/// finished" — which implies the reader writes their own. These three are the
/// mockup's, shipped as presets: a reader with no saved searches should still
/// see the shape of the feature rather than an empty screen, and writing your
/// own needs a design that does not exist yet.
struct SearchLens: Identifiable, Equatable, Sendable, Codable {
    let id: String
    let name: String
    /// The filter in plain words, as the mockup writes it. Kept as text rather
    /// than generated from the query, because "rating ≥ 8" reads better than
    /// anything a formatter would produce from `minimumRating: 80`.
    let rule: String
    let query: SearchQuery
    /// False for the three that ship with the app, which cannot be deleted.
    var isOwn = false

    static let presets: [SearchLens] = [
        SearchLens(
            id: "cosy-fantasy",
            name: "Cosy fantasy, completed, 4+",
            rule: "type: manhwa · status: completed · rating ≥ 8",
            query: SearchQuery(
                types: ["manhwa"],
                statuses: ["completed"],
                sort: "score_desc",
                minimumRating: 80
            )
        ),
        SearchLens(
            id: "seinen-unfinished",
            name: "Seinen I never finished",
            rule: "tag: seinen · sort: popularity",
            query: SearchQuery(sort: "popularity_desc", tags: ["Seinen"])
        ),
        SearchLens(
            id: "regression-funny",
            name: "Regression, but funny",
            rule: "tags: regression AND comedy",
            query: SearchQuery(tags: ["Regression", "Comedy"], tagMode: "and")
        )
    ]
}

/// The reader's own saved searches, alongside the three the app ships with.
///
/// The mockup names its lenses personally — "Seinen I never finished" — which
/// implies the reader writes them. This is that: a lens is whatever filter is
/// currently applied, given a name.
@MainActor
@Observable
final class SearchLensStore {
    private static let key = "search.lenses"

    private(set) var own: [SearchLens] = []
    private let defaults: UserDefaults

    /// The presets first, then anything saved. Presets stay because a reader
    /// with none of their own should still see the shape of the feature.
    var all: [SearchLens] { SearchLens.presets + own }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let stored = try? JSONDecoder().decode([SearchLens].self, from: data) {
            own = stored
        }
    }

    /// Saves the current filter under a name.
    ///
    /// Refuses an empty query: a lens that matches everything is a control that
    /// does nothing, and it would return before reaching the network — the same
    /// way "Surprise me" once silently did.
    @discardableResult
    func save(name: String, query: SearchQuery) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !query.isEmpty else { return false }

        // A saved lens starts at page one whatever the screen had scrolled to.
        var stored = query
        stored.page = 1

        own.removeAll { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
        own.append(SearchLens(
            id: UUID().uuidString,
            name: trimmed,
            rule: SearchLens.describe(stored),
            query: stored,
            isOwn: true
        ))
        persist()
        return true
    }

    func delete(id: String) {
        own.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(own) {
            defaults.set(data, forKey: Self.key)
        }
    }
}

extension SearchLens {
    /// The filter in the same plain words the presets use, built from the query
    /// rather than typed by hand.
    static func describe(_ query: SearchQuery) -> String {
        var parts: [String] = []
        if let text = query.text?.trimmingCharacters(in: .whitespaces), !text.isEmpty {
            parts.append("\u{201C}\(text)\u{201D}")
        }
        if !query.types.isEmpty { parts.append("type: " + query.types.joined(separator: ", ")) }
        if !query.statuses.isEmpty {
            parts.append("status: " + query.statuses.joined(separator: ", "))
        }
        if !query.tags.isEmpty {
            let joiner = query.tags.count > 1 && query.tagMode == "and" ? " AND " : ", "
            parts.append("tags: " + query.tags.joined(separator: joiner))
        }
        if let publisher = query.publisher, !publisher.isEmpty {
            parts.append("publisher: \(publisher)")
        }
        if let rating = query.minimumRating { parts.append("rating \u{2265} \(rating / 10)") }
        if let sort = SortOrder.label(for: query.sort) { parts.append("sort: \(sort.lowercased())") }
        return parts.isEmpty ? "Everything" : parts.joined(separator: " \u{00B7} ")
    }
}
