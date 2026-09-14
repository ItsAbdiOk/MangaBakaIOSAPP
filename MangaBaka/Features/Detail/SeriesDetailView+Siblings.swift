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
    /// (`wikidata.format(for: shown)`, line 48) — so this reuses it rather
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
}
