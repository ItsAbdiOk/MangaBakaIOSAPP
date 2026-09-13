import Foundation
import Testing
@testable import MangaBaka

/// Finding one tag among 7,127.
///
/// The pickers filtered the 500 tags they had loaded, so typing "romance" —
/// which is a tag on thousands of series — emptied the screen with no
/// explanation. Measured against the live API on 2026-09-10:
/// `/v1/tags?limit=500` does not contain Romance; `?q=romance` returns 35 tags
/// including it.
@Suite("Tag search")
struct TagSearchTests {
    private static func tag(_ id: Int, _ name: String, count: Int = 0) -> MangaBaka.Tag {
        MangaBaka.Tag(
            id: id, name: name, namePath: name, parentId: nil, level: nil,
            description: nil, seriesCount: count, isGenre: nil, isSpoiler: nil,
            mergedWith: nil, contentRating: nil
        )
    }

    @Test("Local hits lead, and the API's answer fills in behind them")
    func mergeKeepsBoth() {
        let local = [Self.tag(1, "Workplace Romance", count: 900)]
        let remote = [
            Self.tag(1, "Workplace Romance", count: 900),
            Self.tag(2, "Romance", count: 90_000)
        ]
        let merged = TagSearch.merge(local: local, remote: remote)

        #expect(merged.map(\.id) == [1, 2], "no duplicate, and the local hit stays first")
    }

    @Test("An empty local list still gets everything the API found")
    func remoteAlone() {
        let merged = TagSearch.merge(local: [], remote: [Self.tag(2, "Romance")])
        #expect(merged.map(\.name) == ["Romance"])
    }

    // MARK: - Local matching

    /// Control: case has never mattered locally (`localizedCaseInsensitiveContains`)
    /// and, measured 2026-09-13, `tag=isekai` and `tag=Isekai` both answer
    /// 7,116 on the API. Passes before and after the fix.
    @Test("\"isekai\" matches \"Isekai\"")
    func caseDoesNotMatter() {
        let found = TagSearch.localMatches(in: [Self.tag(94, "Isekai")], for: "isekai")
        #expect(found.map(\.id) == [94])
    }

    /// The one accented bundled name. The offline title index folds
    /// diacritics (`OfflineCatalogue.swift`, `.diacriticInsensitive`); the
    /// tag filter did not, so "cafe" found nothing until the API answered.
    /// Fails without the fix — expected to fail with: `found.map(\.id) == [624]`
    /// (`localizedCaseInsensitiveContains` answers `[]`).
    @Test("\"cafe\" matches \"Café\"")
    func diacriticsDoNotMatter() {
        let found = TagSearch.localMatches(in: [Self.tag(624, "Café")], for: "cafe")
        #expect(found.map(\.id) == [624])
    }

    /// A reader typing "rom" almost always means Romance, not Workplace
    /// Romance. The old filter kept load order, which is by series count —
    /// so a broad tag containing the word outranked the tag that *is* the
    /// word. Fails without the fix — expected to fail with:
    /// `found.map(\.id) == [2, 1, 3]` (load order gives `[1, 2, 3]`).
    @Test("A name that starts with the query outranks one that merely contains it")
    func prefixBeforeSubstring() {
        let loaded = [
            Self.tag(1, "Workplace Romance", count: 900),
            Self.tag(2, "Romance", count: 800),
            Self.tag(3, "Office Romance", count: 700)
        ]
        let found = TagSearch.localMatches(in: loaded, for: "rom")
        #expect(found.map(\.id) == [2, 1, 3], "prefix hit first, then the substring hits in load order")
    }

    @Test("A name without the query is not a match")
    func noMatchIsEmpty() {
        #expect(TagSearch.localMatches(in: [Self.tag(1, "Cooking")], for: "rom").isEmpty)
    }
}

/// The two halves of `TagSearch` a merge test cannot reach: waiting before it
/// asks, and what it says when the asking fails.
///
/// The file was 15.4% covered. Both of these are behaviours a reader feels —
/// one is whether typing a word costs one request or seven against a shared
/// rate limit, the other is whether an unreachable server is reported as "no
/// such tag".
@Suite("Tag search, over time")
@MainActor
struct TagSearchTimingTests {
    private static func tag(_ id: Int, _ name: String) -> MangaBaka.Tag {
        MangaBaka.Tag(
            id: id, name: name, namePath: name, parentId: nil, level: nil,
            description: nil, seriesCount: nil, isGenre: nil, isSpoiler: nil,
            mergedWith: nil, contentRating: nil
        )
    }

    /// Counts what the debounce is for.
    private final class Counter: @unchecked Sendable {
        private(set) var queries: [String] = []
        func record(_ query: String) { queries.append(query) }
    }

    @Test("Typing a word is one request, not one per letter")
    func debounceCollapsesTyping() async throws {
        let counter = Counter()
        let search = TagSearch { query in
            counter.record(query)
            return [Self.tag(1, "Romance")]
        }

        for prefix in ["r", "ro", "rom", "roma", "roman", "romance"] {
            search.update(query: prefix)
        }
        // Waits on TagSearch's own debounce timer, at 3x margin.
        try await Task.sleep(for: TagSearch.debounce * 3)

        #expect(counter.queries == ["romance"], "seven keystrokes should cost one request")
    }

    /// T#7 (docs/reviews/search/tests.md): `debounceCollapsesTyping` fires
    /// its keystrokes in a synchronous loop, so each `update` cancels the
    /// last before anything runs — it proves cancel-on-change, and passes
    /// with the sleep set to zero. A reader types with 80–150 ms between
    /// keys (a guess from ordinary typing; not measured here), so the gaps
    /// below are 100 ms: shorter than the 250 ms debounce, longer than a
    /// synchronous loop. Fails with `debounce` under ~100 ms — expected to
    /// fail with: `counter.queries == ["sol"]` (a 50 ms debounce records
    /// `["s", "so", "sol"]`).
    @Test("Keystrokes 100 ms apart are still one request")
    func debounceOutlastsRealTyping() async throws {
        let counter = Counter()
        let search = TagSearch { query in
            counter.record(query)
            return []
        }

        for prefix in ["s", "so", "sol"] {
            search.update(query: prefix)
            try await Task.sleep(for: .milliseconds(100))
        }
        // Waits on TagSearch's own debounce timer, at 3x margin.
        try await Task.sleep(for: TagSearch.debounce * 3)

        #expect(counter.queries == ["sol"])
    }

    /// The lower bound the old tests never pinned: nothing goes out before
    /// the debounce elapses.
    @Test("No request goes out before the debounce elapses")
    func nothingBeforeDebounce() async throws {
        let counter = Counter()
        let search = TagSearch { query in
            counter.record(query)
            return []
        }

        search.update(query: "s")
        try await Task.sleep(for: .milliseconds(100))

        #expect(counter.queries.isEmpty, "100 ms is inside the 250 ms window")
    }

    @Test("Local matches appear before anything is asked of the API")
    func localMatchesAreImmediate() {
        let search = TagSearch { _ in nil }
        search.loaded = [Self.tag(1, "Workplace Romance"), Self.tag(2, "Cooking")]

        search.update(query: "roman")

        #expect(search.results.map(\.id) == [1], "the local hit is on screen at once")
        #expect(search.isSearching)
    }

    @Test("A failure with nothing to show says so")
    func failureIsReportedWhenThereIsNothing() async throws {
        // "Could not search" and "no such tag" are different sentences and the
        // screen picks between them on this flag.
        let search = TagSearch { _ in nil }
        search.update(query: "romance")
        // Waits on TagSearch's own debounce timer, at 3x margin.
        try await Task.sleep(for: TagSearch.debounce * 3)

        #expect(search.didFail)
        #expect(!search.isSearching)
    }

    @Test("A failure with local matches on screen is not called a failure")
    func failureIsSilentWhenLocalHitsStand() async throws {
        // The reader can see results. Telling them the search failed would
        // contradict the screen.
        let search = TagSearch { _ in nil }
        search.loaded = [Self.tag(1, "Workplace Romance")]
        search.update(query: "romance")
        // Waits on TagSearch's own debounce timer, at 3x margin.
        try await Task.sleep(for: TagSearch.debounce * 3)

        #expect(!search.didFail)
        #expect(search.results.map(\.id) == [1])
    }

    @Test("Emptying the field abandons the search")
    func clearingResets() async throws {
        let search = TagSearch { _ in [Self.tag(9, "Romance")] }
        search.update(query: "romance")
        search.update(query: "  ")
        // Waits on TagSearch's own debounce timer, at 3x margin.
        try await Task.sleep(for: TagSearch.debounce * 3)

        #expect(search.results.isEmpty)
        #expect(!search.isSearching)
    }
}

/// What the pickers say when a search finds nothing.
///
/// Both tag pickers wrote their own copy of this sentence. They are two
/// different claims — one about the network, one about the tag — and two
/// copies is two chances for them to drift apart.
@Suite("Empty tag search copy")
@MainActor
struct TagSearchCopyTests {
    @Test("Finding nothing is about the tag")
    func nothingFoundNamesTheQuery() async throws {
        let search = TagSearch { _ in [] }
        search.update(query: "zzzz")
        // Waits on TagSearch's own debounce timer, at 3x margin.
        try await Task.sleep(for: TagSearch.debounce * 3)
        #expect(search.emptyMessage(for: "zzzz") == "No tag matches \"zzzz\".")
    }

    @Test("Failing is about the network, and does not blame the tag")
    func failureDoesNotBlameTheTag() async throws {
        // "No tag matches 'romance'" when the request never arrived is a false
        // statement about the database.
        let search = TagSearch { _ in nil }
        search.update(query: "romance")
        // Waits on TagSearch's own debounce timer, at 3x margin.
        try await Task.sleep(for: TagSearch.debounce * 3)
        #expect(search.emptyMessage(for: "romance") == "Could not search tags just now.")
    }
}
