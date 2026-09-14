import Foundation
import Testing
@testable import MangaBaka

/// The pure decision behind "Similar by description" — see
/// `DetailOnwardRows.showsSimilarByDescription`. Unlike `Similar` and
/// `Readers also like`, this row never asks a network that can fail (it
/// reads a bundled file through `EmbeddingIndex`), so there is no loading or
/// failed branch to test here — only "has something" vs. "stays silent".
@Suite("Similar by description row state")
struct SimilarByDescriptionRowTests {
    @Test("shows when there is at least one resolved item")
    func showsWithItems() {
        let series = SeriesFactory.make(id: 1, title: "A Series")
        #expect(DetailOnwardRows.showsSimilarByDescription([series]))
    }

    @Test("stays hidden when empty — no vector for this series, or none resolved to a title")
    func hiddenWhenEmpty() {
        #expect(!DetailOnwardRows.showsSimilarByDescription([]))
    }

    /// A row of covers with no covers and nothing saying why.
    ///
    /// Walked on the simulator 2026-09-14 on ONE PIECE: three of four cards
    /// in this row were flat dark rectangles with no image, no glyph and no
    /// caption — which reads as the app failing to load them, not as the
    /// state it actually is. These cards come from `OfflineCatalogue`, which
    /// carries titles and no artwork on purpose (a cover per neighbour would
    /// be twelve requests for one row), so `Series.cover` is `.empty` and
    /// there is nothing in flight to wait for. The volumes shelf already met
    /// this and answers it with "No cover from the publisher"; the same rule
    /// applies here, with wording that fits what is actually true — the cover
    /// does arrive, on the page the card opens.
    @Test("A card with no artwork says so rather than sitting blank")
    func coverlessCardCarriesANote() {
        // Exactly what `loadSimilarByDescription` builds: an id, a title from
        // the bundled index, and `Cover.empty`.
        let series = SeriesFactory.make(id: 5171, title: "One Piece Party", cover: .empty)
        #expect(DetailOnwardRows.coverNote(for: series) != nil)
    }

    /// The control. A note on every card would be worse than none: it would
    /// caption artwork the reader can plainly see.
    @Test("A card that has artwork is not captioned")
    func cardWithArtworkIsNotCaptioned() {
        // `SeriesFactory.make` defaults to `Cover.empty`, so the artwork has
        // to be passed in explicitly or this control proves nothing.
        let artwork = Cover(
            raw: URL(string: "https://media.mangabaka.dev/3397/cover@1.jpg"),
            x150: nil, x250: nil, x350: nil, blurhash: nil, width: nil, height: nil
        )
        let series = SeriesFactory.make(id: 3397, title: "Solo Leveling", cover: artwork)
        #expect(series.cover.hasArtwork)
        #expect(DetailOnwardRows.coverNote(for: series) == nil)
    }

    /// The case `== .empty` would have got wrong, which is why the predicate
    /// is `hasArtwork` and not equality with the empty cover: the API sends
    /// the intrinsic dimensions for layout, and a cover carrying those and no
    /// image at all still draws the same blank box.
    @Test("Dimensions without an image is still no cover")
    func sizedButImagelessStillCarriesTheNote() {
        let series = SeriesFactory.make(id: 1, title: "Sized, imageless", cover: .sized)
        #expect(series.cover != .empty)
        #expect(DetailOnwardRows.coverNote(for: series) != nil)
    }
}
