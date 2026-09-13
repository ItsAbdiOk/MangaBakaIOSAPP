import Foundation
import Testing
@testable import MangaBaka

/// Pure decisions the failure-fix work added to the series page's section
/// views (`docs/reviews/FAILURES-SUMMARY.md` §6, batch 2) — each is a
/// static function so a fail-first test does not need to build a live view
/// or a running screen.
///
/// Gap 10: a series page opened offline or throttled used to say nothing at
/// all beyond the hero — every section fed by a failed request simply had
/// nothing to show, with no line anywhere on the page naming why.
@Suite("The series page names a page-wide failure")
struct SeriesDetailPageFailureTests {
    @Test("Any one leg's staleness surfaces as the page failure")
    func staleLegSurfaces() {
        let extras = SeriesExtras()
        #expect(
            SeriesDetailView.pageFailure(
                extras: extras, similarOrigin: .staleAfter(.offline), alsoOrigin: .network
            ) == .offline
        )
        #expect(
            SeriesDetailView.pageFailure(
                extras: extras, similarOrigin: .network, alsoOrigin: .staleAfter(.offline)
            ) == .offline
        )
    }

    @Test("extras.failure wins even when both feeds are fresh")
    func extrasFailureWins() {
        var extras = SeriesExtras()
        extras.failure = .rateLimited(until: nil)
        #expect(
            SeriesDetailView.pageFailure(extras: extras, similarOrigin: .network, alsoOrigin: .cache)
                == .rateLimited(until: nil)
        )
    }

    @Test("Nothing is shown when every leg answered from cache or the network")
    func nilWhenEverythingIsCurrent() {
        #expect(
            SeriesDetailView.pageFailure(extras: SeriesExtras(), similarOrigin: .cache, alsoOrigin: .network)
                == nil
        )
    }
}

/// Gap 16: `Similar` and `Readers also like` used to vanish identically
/// whether they had genuinely nothing to show or had asked and failed —
/// today's fix is `DetailOnwardRows.onwardRowState`, the same pure decision
/// `CharacterRow.state` makes for the cast.
@Suite("Onward rows tell a failure apart from an empty answer")
struct DetailOnwardRowStateTests {
    @Test("A failure with nothing to show is .failed, not .hidden")
    func failedWhenEmpty() {
        #expect(
            DetailOnwardRows.onwardRowState(items: [], isLoading: false, failure: .offline)
                == .failed(.offline)
        )
    }

    @Test("Nothing asked and nothing found stays hidden")
    func hiddenWithNoFailure() {
        #expect(DetailOnwardRows.onwardRowState(items: [], isLoading: false, failure: nil) == .hidden)
    }

    @Test("A real answer wins even over a stored failure")
    func listWinsOverFailure() {
        let series = SeriesFactory.make(id: 1)
        #expect(
            DetailOnwardRows.onwardRowState(items: [series], isLoading: false, failure: .offline) == .list
        )
    }

    @Test("Loading takes priority while nothing has arrived yet")
    func loadingBeforeFailure() {
        #expect(DetailOnwardRows.onwardRowState(items: [], isLoading: true, failure: nil) == .loading)
    }

    /// Gap 6: unverified whether the API ever repeats an id within one page,
    /// but a duplicate id traps `ForEach` regardless of how it got there.
    @Test("Items are de-duplicated by series id")
    func deduplicatesByID() {
        let first = SeriesFactory.make(id: 1)
        let duplicate = SeriesFactory.make(id: 1)
        let second = SeriesFactory.make(id: 2)
        #expect(DetailOnwardRows.deduplicated([first, duplicate, second]).map(\.id) == [1, 2])
    }
}

/// Gap 17: the cast row used to vanish identically whether both sources
/// answered empty or both actually failed.
@Suite("The cast row tells a failure apart from an empty cast")
struct CharacterRowStateTests {
    @Test("Both sources failing shows .failed even with an empty cast")
    func failedWithEmptyCast() {
        #expect(CharacterRow.state(characters: [], isLoading: false, failure: .offline) == .failed(.offline))
    }

    @Test("An empty cast with no failure stays hidden")
    func hiddenWhenQuiet() {
        #expect(CharacterRow.state(characters: [], isLoading: false, failure: nil) == .hidden)
    }
}

/// Gap 18: a failed cadence ask used to read exactly like "too few dated
/// releases to estimate from" — both were silence.
@Suite("The schedule block tells a failed ask apart from a settled non-answer")
struct DetailScheduleBlockStateTests {
    @Test("A failed ask shows .failed, not silence")
    func failedAskIsShown() {
        #expect(
            DetailScheduleBlock.blockState(estimate: nil, isLoading: false, failure: .rateLimited(until: nil))
                == .failed(.rateLimited(until: nil))
        )
    }

    @Test("A settled measurement wins even over a stored failure")
    func measuredWinsOverFailure() {
        let due = Date()
        let cadence = Cadence(
            medianGapDays: 7, spreadDays: 0, lastRelease: due.addingTimeInterval(-7 * 86_400),
            due: due, samples: 10, gaps: 9, isRegular: true
        )
        #expect(
            DetailScheduleBlock.blockState(estimate: cadence, isLoading: false, failure: .offline)
                == .measured(cadence)
        )
    }

    @Test("Nothing measured, no failure, not loading: hidden")
    func hiddenWhenNothingToSay() {
        #expect(DetailScheduleBlock.blockState(estimate: nil, isLoading: false, failure: nil) == .hidden)
    }
}

/// Gap 21: a series with none of MangaBaka's own volumes and a store that
/// could not be reached used to show nothing at all — the note was dropped
/// along with the empty shelf it was meant to explain.
@Suite("The volumes section shows a note even with nothing to shelve")
struct VolumesSectionShowsTests {
    @Test("A note alone is enough to show the section")
    func noteAloneShows() {
        #expect(VolumesSection.shows(volumes: [], note: "Apple Books couldn't be reached"))
    }

    @Test("Nothing to shelve and no note: hidden")
    func nothingHides() {
        #expect(!VolumesSection.shows(volumes: [], note: nil))
    }

    @Test("Checking the store shows the section even before anything is known")
    func checkingShows() {
        #expect(VolumesSection.shows(volumes: [], note: nil, isCheckingStore: true))
    }
}
