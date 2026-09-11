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
