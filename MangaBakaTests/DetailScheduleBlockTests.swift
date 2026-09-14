import Foundation
import Testing
@testable import MangaBaka

/// `DetailScheduleBlock.blockState`'s new fifth outcome: a labelled
/// MangaUpdates approximation for a series with no measured cadence and no
/// feed answer — Korean webtoons' fallback, since no lawful source publishes
/// a next-episode date for one (`docs/sources/webtoon-episodes.md`).
///
/// `DetailSectionStateTests.swift` (not owned by this task) already pins the
/// four pre-existing outcomes over the three-argument call; every test here
/// exercises the two new `originalRun`/`language` parameters, which are
/// additive and defaulted so that file keeps compiling and passing unchanged.
@Suite("DetailScheduleBlock — approximated state")
struct DetailScheduleBlockOriginalRunStateTests {
    private let run = OriginalRun(
        chapters: 652, volumes: 18, isOngoing: true,
        editedAt: Date(timeIntervalSince1970: 1_754_000_000)
    )

    /// Expected failure before this case existed: `blockState` took only
    /// three parameters, so this call would not compile — there was nowhere
    /// for an `OriginalRun` to go and the block could only ever be `.hidden`
    /// for a Korean webtoon with no feed.
    @Test("Nothing measured, no failure, not loading, but an OriginalRun: approximated")
    func approximatedWhenNothingElseToSay() {
        let state = DetailScheduleBlock.blockState(
            estimate: nil, isLoading: false, failure: nil, originalRun: run, language: "Korean"
        )
        #expect(state == .approximated(run, language: "Korean"))
    }

    /// The ranking the brief asks for: "never compete with a real next
    /// date". A settled cadence must win even when an OriginalRun is also
    /// available.
    @Test("A measured cadence outranks an available OriginalRun")
    func measuredOutranksApproximation() {
        let due = Date()
        let cadence = Cadence(
            medianGapDays: 7, spreadDays: 0, lastRelease: due.addingTimeInterval(-7 * 86_400),
            due: due, samples: 10, gaps: 9, isRegular: true
        )
        let state = DetailScheduleBlock.blockState(
            estimate: cadence, isLoading: false, failure: nil, originalRun: run, language: "Korean"
        )
        #expect(state == .measured(cadence))
    }

    /// A live or failed ask must also outrank the approximation — it is a
    /// fallback for "nothing left to try", not a state a retry could still
    /// overtake.
    @Test("A failed ask outranks an available OriginalRun")
    func failureOutranksApproximation() {
        let state = DetailScheduleBlock.blockState(
            estimate: nil, isLoading: false, failure: .offline, originalRun: run, language: "Korean"
        )
        #expect(state == .failed(.offline))
    }

    @Test("A live ask outranks an available OriginalRun")
    func loadingOutranksApproximation() {
        let state = DetailScheduleBlock.blockState(
            estimate: nil, isLoading: true, failure: nil, originalRun: run, language: "Korean"
        )
        #expect(state == .loading)
    }

    /// The pre-existing behaviour, unchanged: omitting the new parameters
    /// (their default) with nothing else to say is still `.hidden`, exactly
    /// as `DetailSectionStateTests.hiddenWhenNothingToSay` already pins over
    /// the three-argument call.
    @Test("No OriginalRun and nothing else to say is still hidden")
    func hiddenWithNoOriginalRun() {
        let state = DetailScheduleBlock.blockState(estimate: nil, isLoading: false, failure: nil)
        #expect(state == .hidden)
    }

    @Test("A nil language still approximates, with a nil language carried through")
    func approximatesWithNoLanguage() {
        let state = DetailScheduleBlock.blockState(
            estimate: nil, isLoading: false, failure: nil, originalRun: run, language: nil
        )
        #expect(state == .approximated(run, language: nil))
    }
}
