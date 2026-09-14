import Foundation
import Testing
@testable import MangaBaka

/// Split out of `MixModelTests.swift` to stay under `swiftlint`'s
/// `file_length` (400): these are the pure, view-adjacent decision points
/// behind gaps 1(g), 43, 44 and 45 in FAILURES-SUMMARY.md's Batch 4 table —
/// `MixResults`, `SeedPickerSheet` and `BlendDNAView` each expose a
/// `nonisolated static` helper for exactly this, since this project has no
/// ViewInspector to render a view and read its content back.

/// Gap 43 (M6): a re-blend used to swap the whole grid for a bare spinner and
/// pop the count line and covers back in once it finished. `MixResults.state`
/// is the pure decision behind that branch.
@Suite("Mix results state")
struct MixResultsStateTests {
    /// Fails to compile before the fix: `MixResults.state` does not exist yet,
    /// and the view instead switches on `model.isRunning` first — a re-run
    /// with existing results replaced the grid with a spinner rather than
    /// dimming it in place.
    @Test("A re-run with existing results dims the grid instead of replacing it")
    func dimsExistingGrid() {
        let state = MixResults.state(isRunning: true, resultsEmpty: false, failure: nil, message: nil)
        #expect(state == .grid(dimmed: true))
    }

    @Test("A failed re-run with existing results still shows the grid, not failure")
    func failureWithResultsKeepsTheGrid() {
        let state = MixResults.state(isRunning: false, resultsEmpty: false, failure: .offline, message: nil)
        #expect(state == .grid(dimmed: false))
    }

    @Test("A failed first blend with nothing shown yet renders the failure state")
    func failureWithNoResultsShowsFailure() {
        let state = MixResults.state(isRunning: false, resultsEmpty: true, failure: .offline, message: nil)
        #expect(state == .failure(.offline))
    }

    @Test("A first blend still in flight is loading, not idle")
    func firstRunIsLoading() {
        let state = MixResults.state(isRunning: true, resultsEmpty: true, failure: nil, message: nil)
        #expect(state == .loading)
    }

    @Test("Nothing picked yet and nothing run is idle, not an empty message")
    func nothingRunIsIdle() {
        let state = MixResults.state(isRunning: false, resultsEmpty: true, failure: nil, message: nil)
        #expect(state == .idle)
    }
}

/// Gap 44 (M9): a real failure and a real zero-result search both fell
/// through to the idle prompt "Type a title you love." — wrong for a reader
/// who had, in fact, just typed one.
@Suite("Seed picker empty copy")
struct SeedPickerEmptyCopyTests {
    /// Fails to compile before the fix: `SeedPickerSheet.emptyCopy` does not
    /// exist yet, and the view always falls back to the idle prompt whenever
    /// `search.message` is nil — including a real, typed, zero-result search.
    @Test("A real failure keeps its own message")
    func failureMessageWins() {
        let copy = SeedPickerSheet.emptyCopy(message: "Couldn't reach MangaBaka.", queryText: "one")
        #expect(copy == "Couldn't reach MangaBaka.")
    }

    @Test("No query typed yet shows the idle prompt")
    func idlePromptBeforeTyping() {
        #expect(SeedPickerSheet.emptyCopy(message: nil, queryText: nil) == "Type a title you love.")
        #expect(SeedPickerSheet.emptyCopy(message: nil, queryText: "") == "Type a title you love.")
    }

    @Test("A real zero-result search names the query instead of repeating the idle prompt")
    func zeroResultsNamesTheQuery() {
        let copy = SeedPickerSheet.emptyCopy(message: nil, queryText: "Zzzqqq")
        #expect(copy == "Nothing called \u{201C}Zzzqqq\u{201D}.")
    }

    /// Screens F17 (2026-09-14): the picker read `isSearching` and ignored
    /// `isPending`, so every keystroke showed "Nothing called “x”." for the
    /// 300 ms debounce before flickering to a spinner. Expected to fail
    /// before the fix with: `copy == nil` → `"Nothing called “Zzz”."` (once
    /// the `isPending:` parameter exists at all; before that it does not
    /// compile, which proves nothing about behaviour).
    @Test("A pending search is not an empty answer")
    func pendingSearchIsNotEmpty() {
        let copy = SeedPickerSheet.emptyCopy(message: nil, queryText: "Zzz", isPending: true)
        #expect(copy == nil)
        // A failure still speaks over a pending re-ask: the reader tapped
        // "Try again" and the message stays until the answer replaces it.
        #expect(SeedPickerSheet.emptyCopy(message: "Offline", queryText: "Zzz", isPending: true) == "Offline")
    }
}

/// Gap 45 (M10): rows past the three-seed cap were dimmed with hit-testing
/// off and nothing said why.
@Suite("Seed picker cap footnote")
struct SeedPickerCapFootnoteTests {
    /// Fails to compile before the fix: `capFootnoteText` does not exist yet.
    @Test("A capped seed list explains why the rest are dimmed")
    func footnoteAppearsWhenFull() {
        #expect(SeedPickerSheet.capFootnoteText(isFull: true) != nil)
    }

    @Test("An unfilled seed list has nothing to explain")
    func noFootnoteWhenNotFull() {
        #expect(SeedPickerSheet.capFootnoteText(isFull: false) == nil)
    }
}

/// Gap 1(g) (§2(g)): `Int((weight * 100).rounded())` traps outside roughly
/// ±9.2×10¹⁸. `weight` is a `Double` straight off `/v1/series/mix`'s wire
/// answer, so a malformed response could crash this row rather than
/// misrender it.
@Suite("Blend DNA percent")
struct BlendDNAPercentTests {
    @Test("An ordinary weight renders as a percentage")
    func ordinaryWeight() {
        #expect(BlendDNAView.percent(0.5) == "50%")
    }

    /// Expected to fail today by crashing the test process — `Int(1e300 *
    /// 100)` traps — which is itself the proof, per this batch's evidence
    /// style for traps: the crash IS the demonstration.
    @Test("An extreme weight from a malformed answer does not crash")
    func extremeWeightDoesNotTrap() {
        #expect(BlendDNAView.percent(1e300) == "\(Int.max)%")
        #expect(BlendDNAView.percent(-1e300) == "\(Int.min)%")
    }
}
