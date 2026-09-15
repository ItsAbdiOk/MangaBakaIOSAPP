import Foundation

/// Loads "Also exists as" — see `SeriesSiblingsSection`.
///
/// Its own file, beside `+Editions.swift` and `+Store.swift`, for the same
/// reason both are split out: the lint's ceiling on `SeriesDetailView`.
extension SeriesDetailView {
    /// Asks the page's own `wikidata` instance for this series' siblings and
    /// turns them into rows.
    ///
    /// On-device only, and never a second table: `wikidata` is the one
    /// instance the page already holds — `SeriesDetailView+Editions.swift`
    /// asks the same actor for this series' own format
    /// (`wikidata.format(for: shown)` in `loadEditions`) — so this reuses it rather
    /// than constructing another `WikidataIdentityTable`, which would
    /// decompress and hold a second copy of the 451 KB bundled file for no
    /// reason.
    ///
    /// No failure state to show, and none needed: `siblings(for:)` either
    /// finds rows in the on-device table or returns `[]`, and `[]` hides the
    /// section (`SeriesSiblingsSection.body`) rather than claiming "no other
    /// formats exist" — see `WikidataIdentityTable`'s own doc comment on how
    /// much of the catalogue it actually reaches.
    func loadSiblings() async {
        siblingRows = SeriesSiblingRow.rows(for: await wikidata.siblings(for: shown))
    }

    /// A `Series` carrying only an id and a title — enough for a cover card or
    /// a push, after which `shown` fills the rest in once `loadCore` runs for
    /// the new id.
    ///
    /// The one definition. `loadSimilarByDescription()` builds one per
    /// embedding neighbour and `SeriesSiblingsSection` one per tapped sibling;
    /// the second used to be a copy "because that one is private", which is
    /// the duplication this project rejects.
    nonisolated static func stub(id: Int, title: String) -> Series {
        Series(
            id: id, state: "active", mergedWith: nil,
            titles: [SeriesTitle(language: "en", traits: ["official"], title: title, isPrimary: true)],
            cover: .empty, description: nil, authors: nil, artists: nil, status: nil, rating: nil,
            type: nil, contentRating: nil, totalChapters: nil, finalVolume: nil, publishers: nil,
            anime: nil, source: nil
        )
    }
}
