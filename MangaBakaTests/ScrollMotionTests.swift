import Foundation
import Testing
@testable import MangaBaka

/// New pure decisions from the motion pass on the scrolling screens
/// (Discover, Search, Mix, Browse, Schedule): which DNA chips moved when a
/// blend reorders, and whether a schedule row's estimate just became a
/// confirmed rhythm. Row arrival order and the search content-state switch
/// have their own suites next to the models they describe
/// (`DiscoverRowArrivalTests`, `SearchContentKindTests`) — this file is for
/// decisions that did not already have an obvious home.
@Suite("Blend DNA chip diff")
struct BlendDNAChipDiffTests {
    @Test("A chip present in both orderings at the same index has not moved")
    func unchangedIsNotMoved() {
        let diff = BlendDNAView.diff(from: [1, 2, 3], to: [1, 2, 3])
        #expect(diff.entered.isEmpty)
        #expect(diff.left.isEmpty)
        #expect(diff.moved.isEmpty)
    }

    @Test("A chip present in both orderings at a different index has moved")
    func reorderedIsMoved() {
        let diff = BlendDNAView.diff(from: [1, 2, 3], to: [3, 1, 2])
        #expect(diff.moved == [1, 2, 3])
        #expect(diff.entered.isEmpty)
        #expect(diff.left.isEmpty)
    }

    @Test("A new strand id is entered, not moved")
    func newStrandEnters() {
        let diff = BlendDNAView.diff(from: [1, 2], to: [1, 2, 4])
        #expect(diff.entered == [4])
        #expect(diff.moved.isEmpty)
        #expect(diff.left.isEmpty)
    }

    @Test("A dropped strand id has left, not moved")
    func droppedStrandLeaves() {
        let diff = BlendDNAView.diff(from: [1, 2, 3], to: [1, 3])
        #expect(diff.left == [2])
        #expect(diff.moved.isEmpty)
        #expect(diff.entered.isEmpty)
    }

    @Test("Entering, leaving and moving can all happen from one re-blend")
    func mixedDiff() {
        let diff = BlendDNAView.diff(from: [1, 2, 3], to: [3, 1, 4])
        #expect(diff.entered == [4])
        #expect(diff.left == [2])
        #expect(diff.moved == [1, 3])
    }

    @Test("An empty starting point is all entries")
    func emptyOldIsAllEntered() {
        let diff = BlendDNAView.diff(from: [], to: [1, 2])
        #expect(diff.entered == [1, 2])
        #expect(diff.left.isEmpty)
        #expect(diff.moved.isEmpty)
    }
}

/// `ScheduleRow.isConfirmed` — the trigger `.celebrates(on:)` watches for a
/// row's estimate firming up into a real rhythm.
@Suite("Schedule row confirmation")
struct ScheduleRowConfirmationTests {
    private func cadence(regular: Bool) -> Cadence {
        Cadence(
            medianGapDays: 7,
            spreadDays: regular ? 0 : 9,
            lastRelease: Date(),
            due: Date(),
            samples: 20,
            gaps: 19,
            isRegular: regular
        )
    }

    @Test("No cadence at all is not confirmed")
    func noCadenceIsNotConfirmed() {
        #expect(ScheduleRow.isConfirmed(nil) == false)
    }

    @Test("A loose (irregular) cadence is not confirmed")
    func looseCadenceIsNotConfirmed() {
        #expect(ScheduleRow.isConfirmed(cadence(regular: false)) == false)
    }

    @Test("A regular cadence — likely confidence — is confirmed")
    func regularCadenceIsConfirmed() {
        #expect(ScheduleRow.isConfirmed(cadence(regular: true)) == true)
    }
}
