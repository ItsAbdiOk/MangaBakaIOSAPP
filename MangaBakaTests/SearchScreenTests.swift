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
        #expect(SearchHeading.text(isEmpty: false, isSearching: true, count: 12, sortLabel: nil) == nil)
    }

    @Test("The heading is nil before anything is typed")
    func nilWhenIdle() {
        #expect(SearchHeading.text(isEmpty: true, isSearching: false, count: 0, sortLabel: "Score") == nil)
    }

    @Test("The heading names the count once a search has landed")
    func showsCountOnceSettled() {
        let heading = SearchHeading.text(isEmpty: false, isSearching: false, count: 12, sortLabel: nil)
        #expect(heading == "12 shown")
    }

    @Test("A sort is appended after the count")
    func appendsSort() {
        let heading = SearchHeading.text(isEmpty: false, isSearching: false, count: 3, sortLabel: "Score")
        #expect(heading == "3 shown · Score")
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
