import Foundation
import Testing
@testable import MangaBaka

/// The three-column cover grid Search, Mix and Publisher share — its column
/// count, its card width, and the per-card decisions the Search grid makes
/// (meta line, stagger, announcement, prefetch). Every assertion here is on
/// a pure function: this project has no ViewInspector, so a grid that
/// overflowed at accessibility sizes (R F4) was only ever guarded by a test
/// that grepped the source for the word `scaledWidth` and passed while the
/// third column ran off the screen.
@Suite("The cover grid's layout")
struct CoverGridLayoutTests {
    /// The control: the width the literal `111` was derived for. (393 − 2×18
    /// − 2×12) / 3 = 111 on the 393pt phone, per R F11. If this stops
    /// reproducing 111 the function is wrong, not the phones.
    @Test("Three columns on a 393pt phone give the 111pt card the literal used to hard-code")
    func reproducesTheLiteral() {
        let layout = CoverGridLayout.resolve(
            availableWidth: 393 - 2 * Metrics.gutter, isAccessibilitySize: false
        )
        #expect(layout.columns == 3)
        #expect(layout.cardWidth == 111)
    }

    /// The two phones the literal was wrong for: 105 (card overhung its
    /// column by 6pt) and 123 (12pt of dead space on the right) — R F11.
    @Test("Other widths derive their own card width instead of inheriting 111",
          arguments: [(375.0, 105.0), (430.0, 123.0)])
    func derivesPerWidth(screen: Double, expected: Double) {
        let layout = CoverGridLayout.resolve(
            availableWidth: screen - 2 * Metrics.gutter, isAccessibilitySize: false
        )
        // 430 gives 123.3; the report rounded.
        #expect(abs(layout.cardWidth - expected) < 0.5, "\(layout.cardWidth) for \(screen)")
    }

    /// R F4: at accessibility sizes three widened cards needed 523pt inside
    /// 357. Two columns, sized to the row, fit by construction.
    @Test("Two columns at accessibility sizes, and they fit the row")
    func twoColumnsAtAccessibilitySizes() {
        let available = 393 - 2 * Metrics.gutter
        let layout = CoverGridLayout.resolve(availableWidth: available, isAccessibilitySize: true)
        #expect(layout.columns == 2)
        let needed = Double(layout.columns) * layout.cardWidth
            + Double(layout.columns - 1) * Metrics.gapCovers
        #expect(needed <= available, "\(needed)pt of cards in \(available)pt")
        #expect(layout.cardWidth > 111, "The point of dropping a column is a wider card")
    }

    /// A row card still widens with the text (that is what the horizontal
    /// rows have room for); a grid card must not, because the grid already
    /// spent that room on dropping a column.
    @Test("Row cards widen 1.5× at accessibility sizes; grid cards keep their column")
    func rowCardsWidenGridCardsDoNot() {
        #expect(CoverCard.scaledWidth(118, sizing: .row, isAccessibilitySize: true) == 177)
        #expect(CoverCard.scaledWidth(118, sizing: .row, isAccessibilitySize: false) == 118)
        #expect(CoverCard.scaledWidth(172, sizing: .gridColumn, isAccessibilitySize: true) == 172)
    }
}

@Suite("Search result cards")
struct SearchResultCardTests {
    /// R F15: "Manhwa · 8.6" was Discover's line, borrowed. On a
    /// disambiguation surface year and status are what tell a 1990s
    /// original from its 2019 remake.
    @Test("Meta reads type, year, status")
    func metaIsTypeYearStatus() {
        let series = SeriesFactory.make(id: 1, status: "releasing", rating: 86, type: "manga", year: 2019)
        #expect(SearchView.meta(for: series) == "Manga · 2019 · Releasing")
    }

    /// `/v2/series/search` returns `year: null` (curl, 2026-09-13, three
    /// rows of `q=one piece`), so online results have no year to show; the
    /// offline index does. Each half only when present.
    @Test("Missing halves are left out rather than printed as blanks")
    func metaSkipsMissingHalves() {
        let noYear = SeriesFactory.make(id: 1, status: "completed", type: "manhwa")
        #expect(SearchView.meta(for: noYear) == "Manhwa · Completed")
        let nothing = SeriesFactory.make(id: 2)
        #expect(SearchView.meta(for: nothing) == nil)
    }

    /// R F14: `.arrives(index:)` delayed every card past the sixth by 270ms
    /// after it scrolled into view. The stagger is for the first screen
    /// assembling; a card that appears by scrolling arrives at once.
    @Test("Only the first screen of cards staggers", arguments: [(0, 0), (4, 4), (8, 8), (9, 0), (20, 0)])
    func staggerStopsAfterTheFirstScreen(position: Int, expected: Int) {
        #expect(SearchView.arrivalIndex(position: position, columns: 3) == expected)
    }

    /// Two columns means a first screen of six, not nine.
    @Test("The first screen is three rows of whatever the column count is")
    func firstScreenFollowsColumns() {
        #expect(SearchView.arrivalIndex(position: 6, columns: 2) == 0)
        #expect(SearchView.arrivalIndex(position: 5, columns: 2) == 5)
    }

    /// R F7: VoiceOver heard nothing when results landed, or when none did.
    @Test("Results and no-results are announced; in-flight is not")
    func announcements() {
        #expect(SearchView.announcement(kind: .results, shown: 30, total: 411) == "411 results")
        #expect(SearchView.announcement(kind: .results, shown: 30, total: nil) == "30 results shown")
        #expect(SearchView.announcement(kind: .results, shown: 1, total: 1) == "1 result")
        #expect(SearchView.announcement(kind: .empty, shown: 0, total: nil) == "Nothing matched")
        #expect(SearchView.announcement(kind: .skeleton, shown: 0, total: nil) == nil)
        #expect(SearchView.announcement(kind: .idle, shown: 0, total: nil) == nil)
    }

    /// The old check did an O(n) `firstIndex` per cell appearance while the
    /// `ForEach` already had the index in hand (R minor). Two rows from the
    /// end, whatever the column count.
    @Test("The next page is asked for two rows from the end",
          arguments: [(23, false), (24, true), (29, true)])
    func loadMoreDistance(index: Int, expected: Bool) {
        let layout = CoverGridLayout(columns: 3, cardWidth: 111)
        let decision = layout.shouldLoadMore(index: index, count: 30, hasMore: true, isLoadingMore: false)
        #expect(decision == expected)
    }

    @Test("No page request while one is loading, or at the true end")
    func loadMoreGates() {
        let layout = CoverGridLayout(columns: 3, cardWidth: 111)
        #expect(!layout.shouldLoadMore(index: 29, count: 30, hasMore: true, isLoadingMore: true))
        #expect(!layout.shouldLoadMore(index: 29, count: 30, hasMore: false, isLoadingMore: false))
    }

    /// R minor: a fresh page's off-screen covers only started loading on
    /// scroll. The rows just under the first screen are warmed; the rest of
    /// the page is left alone, per Discover's "spending someone's data on
    /// covers they may never reach".
    @Test("The two rows under the first screen are warmed, no more")
    func prefetchWindow() {
        #expect(SearchView.coverPrefetchRange(count: 30, columns: 3) == 9..<15)
        #expect(SearchView.coverPrefetchRange(count: 10, columns: 3) == 9..<10)
        #expect(SearchView.coverPrefetchRange(count: 6, columns: 3) == 6..<6)
    }
}
