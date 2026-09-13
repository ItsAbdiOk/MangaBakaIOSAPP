import Testing
@testable import MangaBaka

/// `yearFrom`/`yearTo`, added for `OfflineCatalogue`'s year filter — see
/// `SearchQuery.yearFrom`'s doc comment for why they are offline-only today.
/// A field `isEmpty`/`activeFilterCount` do not know about is a silent bug
/// waiting to happen: `queryDidChange()` reads `isEmpty` to decide whether to
/// search at all, so a year-only query that read as empty would never reach
/// `OfflineCatalogue` in the first place.
@Suite("SearchQuery's year range")
struct SearchQueryYearTests {
    @Test("A year-only query is not empty")
    func yearOnlyQueryIsNotEmpty() {
        var query = SearchQuery()
        query.yearFrom = 2010

        #expect(!query.isEmpty)
    }

    @Test("A year range counts as one active filter, not two")
    func yearRangeCountsAsOneFilter() {
        var query = SearchQuery()
        query.yearFrom = 2010
        query.yearTo = 2020

        #expect(query.activeFilterCount == 1)
    }

    @Test("clearingFilters drops the year range along with everything else")
    func clearingFiltersDropsYearRange() {
        var query = SearchQuery()
        query.text = "one piece"
        query.yearFrom = 2010
        query.yearTo = 2020

        let cleared = query.clearingFilters()

        #expect(cleared.text == "one piece")
        #expect(cleared.yearFrom == nil)
        #expect(cleared.yearTo == nil)
        #expect(cleared.isEmpty == false, "Text alone must still count as a real query")
    }
}
