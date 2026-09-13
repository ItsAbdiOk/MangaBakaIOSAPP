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
}
