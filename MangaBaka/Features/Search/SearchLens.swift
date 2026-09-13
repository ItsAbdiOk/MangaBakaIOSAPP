import Foundation

/// A saved search, shown on the search screen before anything is typed.
///
/// The mockup calls these "lenses" and names them personally — "Seinen I never
/// finished" — which implies the reader writes their own.
///
/// **Where the three presets went.** This type used to ship three hard-coded
/// lenses — "Cosy fantasy, completed, 4+", "Seinen I never finished",
/// "Regression, but funny" — the mockup's own sample lenses, kept so a reader
/// with none of their own did not land on an empty screen. They were never
/// derived from anything: not usage, not the catalogue, just the mockup's
/// placeholder copy. Abdi asked (2026-09-13) to scrap them — laid out full
/// width above the fold, they crowded the presets/genres/tags into one dense
/// wall on the very screen meant to make searching feel simple. The idle
/// screen now leads with recent searches and the filter panel instead; a
/// reader who wants the shape of a saved search sees it the first time they
/// save one of their own.
struct SearchLens: Identifiable, Equatable, Sendable, Codable {
    let id: String
    let name: String
    /// The filter in plain words. Kept as text rather than generated fresh
    /// every render, because "rating ≥ 8" reads better than anything a
    /// formatter would produce from `minimumRating: 80` on the fly — see
    /// `describe(_:)`, which is what actually generates it at save time.
    let rule: String
    let query: SearchQuery
    /// Always true now that there are no presets left to be false for. Kept
    /// rather than removed: `SaveLensSheet`/`SearchIdleView` read it to
    /// decide whether a lens can be deleted, and a future re-introduction of
    /// any non-deletable lens (a "starred" one, say) would want the flag
    /// back rather than reinvented.
    var isOwn = true
}

/// The reader's own saved searches.
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
    /// The filter in plain words, built from the query rather than typed by
    /// hand, so it cannot drift from what the lens actually stores.
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
