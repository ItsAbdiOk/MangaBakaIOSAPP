import Foundation
import Testing
@testable import MangaBaka

/// The same series, reached by different doors.
///
/// A feed's v2 payload carries no description, no chapter count, no status and
/// no `source`; `/v1/series/{id}` carries all four. The series page is built
/// from whichever copy the reader arrived with, so opening a series from the
/// swipe stack showed a page with no synopsis, no length and no next-chapter
/// estimate — the estimate needs the MangaUpdates id, which lives in `source`.
/// Verified against the live API on 2026-09-09; reported from the app by Abdi
/// on 2026-09-10.
@Suite("Filling a lean series from a full one")
struct SeriesMergeTests {
    private var lean: Series {
        SeriesFactory.make(
            id: 638, title: "Lout of Count's Family",
            description: nil, status: nil, totalChapters: nil, source: nil
        )
    }

    private var full: Series {
        SeriesFactory.make(
            id: 638, title: "Baekjakgaui Mangnaniga Doeeotda",
            description: "Cha Kyung-Hoon dies and wakes up as Cale Henituse.",
            status: "releasing",
            totalChapters: 125,
            source: ["manga_updates": Series.TrackerEntry(
                id: "abc123", rating: nil, ratingNormalized: nil
            )]
        )
    }

    @Test("The gaps are filled")
    func fillsGaps() {
        let merged = lean.filling(gapsFrom: full)
        #expect(merged.description == "Cha Kyung-Hoon dies and wakes up as Cale Henituse.")
        #expect(merged.status == "releasing")
        #expect(merged.totalChapters == 125)
        #expect(merged.mangaUpdatesID == "abc123", "no id, no release estimate")
    }

    @Test("What the reader is already looking at is never replaced")
    func keepsWhatItHas() {
        // Otherwise the title on screen changes under them a second after the
        // page opens, which is worse than the missing synopsis.
        let merged = lean.filling(gapsFrom: full)
        #expect(merged.displayTitle == "Lout of Count's Family")
    }

    @Test("Two different series are never merged")
    func refusesMismatch() {
        let other = SeriesFactory.make(id: 999, description: "A different book entirely.")
        #expect(lean.filling(gapsFrom: other).description == nil)
    }
}
