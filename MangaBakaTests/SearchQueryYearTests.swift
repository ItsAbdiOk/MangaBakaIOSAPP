import Foundation
import Testing
@testable import MangaBaka

/// `yearFrom`/`yearTo` were added for `OfflineCatalogue`'s year filter and
/// spent their first days offline-only. A field `isEmpty`/`activeFilterCount`
/// do not know about is a silent bug waiting to happen: `queryDidChange()`
/// reads `isEmpty` to decide whether to search at all, so a year-only query
/// that read as empty would never reach `OfflineCatalogue` in the first place.
/// The wire half is pinned here too, since "drawn, counted as active, never
/// sent" is exactly how the filter lied for a while (review finding UX#3/E F6).
@Suite("SearchQuery's year range")
struct SearchQueryYearTests {
    private func value(_ name: String, in query: SearchQuery) -> String? {
        query.queryItems.first { $0.name == name }?.value
    }

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

    /// The parameter names come from the schema and were confirmed live
    /// 2026-09-13: `type=manhwa` answers 21,596; with
    /// `published_start_date_lower=2020&published_start_date_upper=2020`
    /// it answers 1,527. See `SearchQuery.yearFrom`'s doc comment.
    @Test("A year range goes to the wire as the API's start-date bounds")
    func yearRangeIsSent() {
        var query = SearchQuery()
        query.yearFrom = 2020
        query.yearTo = 2021

        #expect(value("published_start_date_lower", in: query) == "2020")
        #expect(value("published_start_date_upper", in: query) == "2021")
    }

    /// Half-open on purpose: "from 2020" must not invent an upper bound, or a
    /// series starting this year would vanish from the results.
    @Test("An open-ended year range sends only the bound that was set")
    func openEndedYearSendsOneBound() {
        var from = SearchQuery()
        from.yearFrom = 2020
        #expect(value("published_start_date_lower", in: from) == "2020")
        #expect(value("published_start_date_upper", in: from) == nil)

        var upTo = SearchQuery()
        upTo.yearTo = 1999
        #expect(value("published_start_date_lower", in: upTo) == nil)
        #expect(value("published_start_date_upper", in: upTo) == "1999")
    }

    /// Control: a query with no year set sends neither key, so an untouched
    /// filter cannot narrow anything by accident.
    @Test("No year set means no date bounds on the wire")
    func noYearSendsNothing() {
        let names = Set(SearchQuery(text: "x").queryItems.map(\.name))
        #expect(!names.contains("published_start_date_lower"))
        #expect(!names.contains("published_start_date_upper"))
    }
}

/// Everything else `queryItems` was found to get wrong at the wire in the
/// 2026-09-13 search review: an untrimmed `q`, a seedless random sort, genres
/// disguised as tags, and a tag mode the API does not honour.
@Suite("SearchQuery's wire shape")
struct SearchQueryWireTests {
    private func value(_ name: String, in query: SearchQuery) -> String? {
        query.queryItems.first { $0.name == name }?.value
    }

    /// Measured 2026-09-13: `q=one` and `q=one%20` answer the same 4,926
    /// series in the same order, so the pause after a word is a request for
    /// an answer we already have (E F8).
    @Test("A trailing space does not make a different request")
    func trailingSpaceIsTrimmed() {
        var padded = SearchQuery()
        padded.text = "one "
        var bare = SearchQuery()
        bare.text = "one"

        #expect(padded.queryItems == bare.queryItems)
        #expect(value("q", in: padded) == "one")
    }

    /// Measured 2026-09-13: `sort_by=random&random_seed=0.42&limit=3` answered
    /// ids 512345, 58172, 308177 on two consecutive calls, so a seeded page 2
    /// really is page 2 and not a reshuffle of page 1 (E F7).
    @Test("A random sort carries its seed so later pages continue the same shuffle")
    func randomSortCarriesSeed() {
        var query = SearchQuery()
        query.sort = "random"
        query.randomSeed = 0.42

        #expect(value("sort_by", in: query) == "random")
        #expect(value("random_seed", in: query) == "0.42")
    }

    /// The API rejects `random_seed=0` and `random_seed=-0.7` with HTTP 503
    /// "A database error occurred" (2 of 2 tries each, 2026-09-13) though the
    /// schema says −1…1. Every seed the app mints has to land in (0, 1].
    @Test("A fresh seed is always one the API accepts")
    func freshSeedIsPositive() {
        for _ in 0..<200 {
            let seed = SearchQuery.freshRandomSeed()
            #expect(seed > 0 && seed <= 1)
        }
    }

    /// Control: the seed belongs to the random sort. Sent with any other sort
    /// it is noise, and sent alone it is a stale seed that would pin
    /// "Surprise me" to last week's shuffle.
    @Test("A seed without a random sort is not sent")
    func seedNeedsRandomSort() {
        var scored = SearchQuery()
        scored.sort = "score_desc"
        scored.randomSeed = 0.42
        #expect(value("random_seed", in: scored) == nil)

        var seedOnly = SearchQuery()
        seedOnly.randomSeed = 0.42
        #expect(value("random_seed", in: seedOnly) == nil)
        #expect(seedOnly.isEmpty, "A leftover seed is not a filter")
    }

    /// Measured 2026-09-13 (catalogue review C#2): `tag=slice_of_life` answers
    /// 2,017 and `genre=slice_of_life` 34,220; `tag=romance` 14,065 against
    /// `genre=romance` 100,947. Sending a genre as a tag shows 6–14% of it.
    @Test("Genres go out as genre=, never as tag=")
    func genresAreNotTags() {
        var query = SearchQuery()
        query.genres = ["romance"]

        let sent = query.queryItems
        #expect(sent.contains(URLQueryItem(name: "genre", value: "romance")))
        #expect(!sent.contains { $0.name == "tag" })
        #expect(!query.isEmpty)
        #expect(query.activeFilterCount == 1)
        #expect(query.clearingFilters().genres.isEmpty)
    }

    @Test("Tags keep their own key when genres are set beside them")
    func tagsAndGenresAreSeparateKeys() {
        var query = SearchQuery()
        query.genres = ["romance", "comedy"]
        query.tags = ["Regression"]

        let sent = query.queryItems
        #expect(sent.filter { $0.name == "genre" }.compactMap(\.value) == ["romance", "comedy"])
        #expect(sent.filter { $0.name == "tag" }.compactMap(\.value) == ["Regression"])
    }

    /// Measured 2026-09-13: `tag=Isekai&tag=Regression` answers 164 with no
    /// mode, with `tag_mode=or`, and with `tag_mode=and`; `/v1/series/mix`
    /// with the same two tags returns the same 50 ids with and without
    /// `tag_mode=or`. "Match any" cannot exist on this API, so the wire only
    /// ever says `and` — a stored "or" (an old lens, Mix's toggle) must not
    /// leak out and read as if it worked (C#1).
    @Test("A stored 'or' mode is sent as 'and'")
    func orModeIsNeverSent() {
        var query = SearchQuery()
        query.tags = ["Isekai", "Regression"]
        query.tagMode = "or"

        #expect(value("tag_mode", in: query) == "and")
    }

    /// A lens saved before `genres` and `randomSeed` existed has neither key.
    /// The synthesised decoder throws on a missing non-optional array, and
    /// `SearchLensStore` decodes with `try?`, so without this every saved
    /// lens would vanish on first launch after the update. The JSON is a
    /// lens as the store wrote it on 2026-09-12, before either field.
    @Test("A query saved before the new fields existed still decodes")
    func decodesWithoutNewKeys() throws {
        let saved = Data(#"""
        {"types":["manhwa"],"statuses":[],"tags":["Regression"],"limit":30,"page":1}
        """#.utf8)

        let query = try JSONDecoder().decode(SearchQuery.self, from: saved)

        #expect(query.types == ["manhwa"])
        #expect(query.tags == ["Regression"])
        #expect(query.genres.isEmpty)
        #expect(query.randomSeed == nil)
    }

    @Test("Two tags with no mode set still say 'and', so the request states what it does")
    func combinedTagsAlwaysSayAnd() {
        var query = SearchQuery()
        query.tags = ["Isekai", "Regression"]
        query.tagMode = nil

        #expect(value("tag_mode", in: query) == "and")
    }
}
