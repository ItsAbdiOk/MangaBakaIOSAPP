import Foundation
import Testing
@testable import MangaBaka

/// Pure, view-facing rules for the Search screen that do not belong in
/// `SearchModelTests` — this project has no ViewInspector, so each of these
/// was pulled out of a live view into a plain function specifically so it
/// could be tested at all.
@Suite("Search heading")
struct SearchHeadingTests {
    /// Gap 50: `SearchView.swift:194`'s "N shown" heading used to read
    /// `model.results.count` directly, which during a new search is still the
    /// *previous* query's count — hanging over the incoming skeleton and
    /// claiming a number that has nothing to do with what is about to load.
    @Test("The heading is nil while a new search is in flight")
    func nilWhileSearching() {
        let heading = SearchHeading.text(
            hasAsked: true, isSearching: true, shown: 12, total: 411, sortLabel: nil
        )
        #expect(heading == nil)
    }

    /// Not `query.isEmpty`: a filter chosen on the idle panel is a query
    /// with nothing asked yet, and a heading over the panel said "0 shown"
    /// (UX#1, UX#13).
    @Test("The heading is nil before anything is asked")
    func nilWhenIdle() {
        let heading = SearchHeading.text(
            hasAsked: false, isSearching: false, shown: 0, total: nil, sortLabel: "Score"
        )
        #expect(heading == nil)
    }

    /// UX#13: "0 shown" sat directly above "Nothing matched …", saying the
    /// same thing twice.
    @Test("The heading is nil over the empty state")
    func nilWhenNothingShown() {
        let heading = SearchHeading.text(
            hasAsked: true, isSearching: false, shown: 0, total: 0, sortLabel: nil
        )
        #expect(heading == nil)
    }

    /// E F1 / R F13: the API's `pagination.count` is what a reader wants when
    /// deciding whether to refine; "shown" was covering for it being thrown
    /// away.
    @Test("The heading names the total once a search has landed")
    func showsTotalOnceSettled() {
        let heading = SearchHeading.text(
            hasAsked: true, isSearching: false, shown: 30, total: 4118, sortLabel: nil
        )
        #expect(heading == "4,118 results")
    }

    /// The offline index and a cached answer carry no total.
    @Test("Without a total the heading falls back to the number shown")
    func fallsBackToShown() {
        let heading = SearchHeading.text(
            hasAsked: true, isSearching: false, shown: 12, total: nil, sortLabel: nil
        )
        #expect(heading == "12 shown")
    }

    @Test("A sort is appended after the count")
    func appendsSort() {
        let heading = SearchHeading.text(
            hasAsked: true, isSearching: false, shown: 3, total: 3, sortLabel: "Score"
        )
        #expect(heading == "3 results · Score")
    }
}

/// The offline-index `StaleBar` line's date, e.g. "From the offline index
/// (built 13 Sep)".
@Suite("Offline index date label")
struct OfflineIndexDateLabelTests {
    @Test("An ISO date shortens to day and month")
    func shortensKnownDate() {
        #expect(OfflineIndexDateLabel.short("2026-09-13") == "13 Sep")
    }

    @Test("An unparsable string is shown as-is rather than hidden")
    func fallsBackOnUnparsable() {
        #expect(OfflineIndexDateLabel.short("not a date") == "not a date")
    }
}

/// Whether the idle screen's inline filter panel can be submitted at all —
/// "Show results" must stay disabled until a filter would actually narrow
/// anything, the same rule `FilterSheet`'s old "Clear all"/save-lens buttons
/// already applied via `query.isEmpty`.
@Suite("Filter panel enablement")
struct FilterPanelCanShowTests {
    @Test("An untouched query cannot be shown")
    func emptyQueryDisabled() {
        #expect(!FilterPanel.canShow(query: SearchQuery()))
    }

    @Test("Any one filter set is enough to enable it")
    func oneFilterEnables() {
        var query = SearchQuery()
        query.types = ["manga"]
        #expect(FilterPanel.canShow(query: query))
    }

    @Test("Free text alone also enables it")
    func textAloneEnables() {
        #expect(FilterPanel.canShow(query: SearchQuery(text: "solo")))
    }
}

/// Whether the tag picker sheet is showing the live catalogue, a bundled
/// fallback, or nothing — gap 41 (the fallback rendered with no label) and
/// gap 42 (both sources failing left a blank sheet).
@Suite("Tag picker status")
struct TagPickerStatusTests {
    private func tag(_ id: Int) -> MangaBaka.Tag {
        MangaBaka.Tag(
            id: id, name: "T\(id)", namePath: nil, parentId: nil, level: 0,
            description: nil, seriesCount: 10, isGenre: nil, isSpoiler: nil,
            mergedWith: nil, contentRating: nil
        )
    }

    @Test("Live tags win even when a bundled fallback is also present")
    func liveWins() {
        #expect(TagPickerStatus.resolve(bundled: [tag(1)], live: [tag(2)]) == .live)
    }

    /// Today's code has no such state at all: the sheet shows `tags` — which
    /// silently stayed the bundled 2026-08-27 list — with nothing on screen
    /// distinguishing it from a fresh answer.
    @Test("A failed or empty live fetch falls back to the bundled list, labelled")
    func fallsBackToBundled() {
        #expect(TagPickerStatus.resolve(bundled: [tag(1)], live: []) == .bundledOnly)
    }

    /// Gap 42: both sources empty used to render a blank sheet.
    @Test("Nothing from either source is its own state")
    func bothEmptyIsNothing() {
        #expect(TagPickerStatus.resolve(bundled: [], live: []) == .nothing)
    }
}

/// The live count beside each saved lens on Search's idle screen, and what
/// happens to a lens saved while that walk is already counting the others.
@Suite("Lens counts queue rather than drop")
@MainActor
struct LensCountsQueueTests {
    /// Polls instead of sleeping a fixed amount, matching `LensTests`'s own
    /// `waitUntil` — bounded so a genuine regression fails rather than hangs.
    private func waitUntil(_ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline {
            await Task.yield()
        }
    }

    private func lens(_ id: String, text: String) -> SearchLens {
        SearchLens(id: id, name: id, rule: "q: \(text)", query: SearchQuery(text: text), isOwn: true)
    }

    /// A repository whose count for "a" blocks until the test resumes it, so
    /// a second `load` call can be made deterministically *while* the walk is
    /// still holding "a" in flight — the exact window gap 53 is about. "b"
    /// answers immediately once the walk reaches it.
    private final class GatedRepository: StubRepositoryBase, @unchecked Sendable {
        var gate: CheckedContinuation<Void, Never>?

        override func count(_ query: SearchQuery) async -> Int? {
            if query.text == "a" {
                await withCheckedContinuation { gate = $0 }
            }
            return 1
        }
    }

    /// Gap 53: `LensCounts.load`'s old `guard running == nil` bailed out of
    /// scheduling anything new for the lifetime of a walk already in
    /// progress, so a lens saved mid-walk was neither in the running task's
    /// fixed snapshot nor marked `asked` — it was silently dropped until the
    /// idle screen was torn down and rebuilt. `load` now appends to a shared
    /// queue the running task keeps draining, so a second call during the
    /// walk is picked up before it ends.
    @Test("A lens saved while the walk is running is counted, not dropped")
    func lensSavedDuringWalkIsCounted() async throws {
        let repository = GatedRepository()
        let counts = LensCounts(repository: repository)
        let lensA = lens("a", text: "a")
        let lensB = lens("b", text: "b")

        counts.load([lensA])
        // Wait for "a"'s count request to actually be in flight before
        // saving "b", rather than guessing at a sleep.
        await waitUntil { repository.gate != nil }

        // The moment a new lens is saved, mid-walk.
        counts.load([lensA, lensB])
        repository.gate?.resume()

        await waitUntil { counts.counts["b"] != nil }
        #expect(counts.counts["b"] == 1, "The lens saved mid-walk must be counted, not dropped")
        #expect(counts.counts["a"] == 1)
    }
}

/// What `SearchView.content` shows, decided in one pure place (mirrors
/// `MixResults.ResultsState`) so the swap between the idle screen, the
/// skeleton, a blocking failure, the empty state and the grid — each
/// `.blurReplace`d inside `Motion.settle` — has a test without rendering the
/// view (this project has no ViewInspector).
///
/// The inputs are what was *asked* and whether an answer is *pending* —
/// never `query.isEmpty`. Deriving the screen from the query (review
/// 2026-09-13, cause A) is what made a chip tap on the idle panel read as a
/// search with no results.
@Suite("Search content state")
struct SearchContentKindTests {
    /// UX#1, seen on screen in the 2026-09-13 walk: tap "Manga" on the idle
    /// panel and the panel vanished under "Nothing matched these filters".
    /// A filter chosen is not an ask; the panel stays until "Show results"
    /// or a keystroke.
    @Test("Nothing asked is idle, whatever the query holds")
    func nothingAskedIsIdle() {
        let kind = SearchView.contentKind(
            hasAsked: false, isPending: false, isSearching: false,
            hasBlockingFailure: false, resultsEmpty: true
        )
        #expect(kind == .idle)
    }

    /// E F4: the ≥300 ms debounce after the first keystroke used to render
    /// as "Nothing matched 'n'" before a request had gone out.
    @Test("A pending answer with nothing on screen is the skeleton, not the empty state")
    func pendingWithNothingIsSkeleton() {
        let kind = SearchView.contentKind(
            hasAsked: true, isPending: true, isSearching: false,
            hasBlockingFailure: false, resultsEmpty: true
        )
        #expect(kind == .skeleton)
    }

    @Test("A search in flight with nothing on screen is the skeleton")
    func searchingWithNothingIsSkeleton() {
        let kind = SearchView.contentKind(
            hasAsked: true, isPending: false, isSearching: true,
            hasBlockingFailure: true, resultsEmpty: true
        )
        #expect(kind == .skeleton)
    }

    /// R F1: every debounced request replaced the grid the reader was
    /// looking at with six shimmering placeholders, then blurred the results
    /// back in with the stagger re-run from scratch — about a second of
    /// motion per pause in "one piece", for results that were mostly the
    /// same. The grid stays (dimmed by the view) while the next answer is
    /// on its way.
    @Test("A search in flight keeps the results already on screen")
    func searchingKeepsResults() {
        let kind = SearchView.contentKind(
            hasAsked: true, isPending: false, isSearching: true,
            hasBlockingFailure: false, resultsEmpty: false
        )
        #expect(kind == .results)
    }

    @Test("A pending answer keeps the results already on screen")
    func pendingKeepsResults() {
        let kind = SearchView.contentKind(
            hasAsked: true, isPending: true, isSearching: false,
            hasBlockingFailure: false, resultsEmpty: false
        )
        #expect(kind == .results)
    }

    @Test("A failure with nothing to show is a blocking failure")
    func failureWithNoResultsBlocks() {
        let kind = SearchView.contentKind(
            hasAsked: true, isPending: false, isSearching: false,
            hasBlockingFailure: true, resultsEmpty: true
        )
        #expect(kind == .failure)
    }

    /// Only after an answer: asked, nothing pending, nothing in flight.
    @Test("No results and no failure after an answer is the empty state")
    func noResultsNoFailureIsEmpty() {
        let kind = SearchView.contentKind(
            hasAsked: true, isPending: false, isSearching: false,
            hasBlockingFailure: false, resultsEmpty: true
        )
        #expect(kind == .empty)
    }

    @Test("Results present is the grid, even with a non-blocking failure alongside them")
    func resultsPresentIsGrid() {
        let kind = SearchView.contentKind(
            hasAsked: true, isPending: false, isSearching: false,
            hasBlockingFailure: false, resultsEmpty: false
        )
        #expect(kind == .results)
    }
}

/// Screens F26 (2026-09-14): the "Show N results" count is a `limit=1`
/// search-window request, and the year fields wrote `query` per digit — so
/// "2020" was up to four of them, and every toggle in a picker sheet was one
/// more under a sheet that hid the number. The panel's `scheduleCount` acts
/// on this rule; a held source books nothing.
@Suite("The filter panel's count is held while the reader is mid-edit")
struct FilterPanelCountHoldTests {
    private var narrowed: SearchQuery {
        var query = SearchQuery()
        query.yearFrom = 2_020
        return query
    }

    /// Expected to fail before the fix with: `.held` did not exist — the
    /// source was `.network` whatever the panel was doing, and each digit
    /// booked a count.
    @Test("A year field with the keyboard, or a picker sheet up, holds the count")
    func heldWhileEditing() {
        let source = FilterPanel.countSource(
            query: narrowed, preferOffline: false, hasNetworkCounter: true, hasOfflineCounter: false,
            isHeld: true
        )
        #expect(source == .held)
        // Held wins over the offline toggle too: no count from either source.
        let offline = FilterPanel.countSource(
            query: narrowed, preferOffline: true, hasNetworkCounter: true, hasOfflineCounter: true,
            isHeld: true
        )
        #expect(offline == .held)
    }

    /// The control: the same query with nothing held counts as before.
    @Test("Released, the same query counts")
    func countsWhenReleased() {
        let source = FilterPanel.countSource(
            query: narrowed, preferOffline: false, hasNetworkCounter: true, hasOfflineCounter: false
        )
        #expect(source == .network)
    }

    /// A held panel with nothing set keeps no stale number: `.none`, so the
    /// label reads "Show results" rather than a count for filters gone.
    @Test("A query that cannot show is .none even while held")
    func emptyQueryIsNoneEvenWhenHeld() {
        let source = FilterPanel.countSource(
            query: SearchQuery(), preferOffline: false, hasNetworkCounter: true, hasOfflineCounter: false,
            isHeld: true
        )
        #expect(source == .none)
    }
}
