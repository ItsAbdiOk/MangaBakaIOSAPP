import Testing
import Foundation
@testable import MangaBaka

/// Gathering a series' other names.
///
/// A series carries one title per language — 25 on Solo Leveling, verified
/// live on 2026-09-11 — and the page showed one. A reader who knows a series
/// as "Ore Dake Level-Up na Ken" had no way to confirm they were looking at
/// the same book.
@Suite("Other titles")
struct AlternativeTitleTests {
    private func title(_ text: String, _ language: String) -> SeriesTitle {
        SeriesTitle(language: language, traits: [], title: text, isPrimary: true)
    }

    @Test("The title already on screen is not listed again")
    func shownTitleIsExcluded() {
        let rows = SeriesTitle.alternatives(
            in: [title("Solo Leveling", "en"), title("나 혼자만 레벨업", "ko")],
            excluding: "Solo Leveling"
        )
        #expect(rows.map(\.title) == ["나 혼자만 레벨업"])
    }

    @Test("One title in several languages is one row")
    func duplicatesAreGathered() {
        // Ordinary, not exotic: "Solo Leveling" is the title in English,
        // Turkish and Brazilian Portuguese. Three identical rows would make
        // the section look broken rather than thorough.
        let rows = SeriesTitle.alternatives(
            in: [
                title("Solo Leveling", "en"),
                title("Solo Leveling", "tr"),
                title("Solo Leveling", "pt-br")
            ],
            excluding: nil
        )
        #expect(rows.count == 1)
        #expect(rows.first?.languages == ["en", "tr", "pt-br"])
    }

    @Test("The API's order is kept")
    func orderIsPreserved() {
        // The order is the API's own and carries no meaning we can improve on;
        // re-sorting alphabetically would put Arabic first for every series.
        let rows = SeriesTitle.alternatives(
            in: [title("B", "en"), title("A", "ko")],
            excluding: nil
        )
        #expect(rows.map(\.title) == ["B", "A"])
    }

    @Test("Empty titles are dropped")
    func emptyTitlesAreDropped() {
        let rows = SeriesTitle.alternatives(in: [title("", "en"), title("A", "ko")], excluding: nil)
        #expect(rows.map(\.title) == ["A"])
    }
}
