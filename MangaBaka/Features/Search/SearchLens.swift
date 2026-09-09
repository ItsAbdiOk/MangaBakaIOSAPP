import Foundation

/// A saved search, shown on the search screen before anything is typed.
///
/// The mockup calls these "lenses" and names them personally — "Seinen I never
/// finished" — which implies the reader writes their own. These three are the
/// mockup's, shipped as presets: a reader with no saved searches should still
/// see the shape of the feature rather than an empty screen, and writing your
/// own needs a design that does not exist yet.
struct SearchLens: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    /// The filter in plain words, as the mockup writes it. Kept as text rather
    /// than generated from the query, because "rating ≥ 8" reads better than
    /// anything a formatter would produce from `minimumRating: 80`.
    let rule: String
    let query: SearchQuery

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
