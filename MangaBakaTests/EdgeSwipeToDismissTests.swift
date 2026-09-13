import Testing
@testable import MangaBaka

/// The pure decisions behind the interactive edge-swipe-to-dismiss gesture —
/// see `EdgeSwipeToDismiss.swift`. Not listed among this agent's designated
/// test files in the motion brief, but rule 10 asks a test for every pure
/// decision and this component gained two with the interactive rewrite, so
/// this file exists to cover them rather than leave them unverified.
@Suite("Edge swipe to dismiss")
struct EdgeSwipeToDismissTests {
    // MARK: - shouldDismiss

    @Test("Dragged past a third of the way commits, regardless of speed")
    func farEnoughCommitsRegardlessOfSpeed() {
        #expect(EdgeSwipeToDismiss.shouldDismiss(offset: 140, velocity: 0, width: 390))
    }

    @Test("A short drag with no speed behind it springs back")
    func shortSlowDragSpringsBack() {
        #expect(!EdgeSwipeToDismiss.shouldDismiss(offset: 40, velocity: 0, width: 390))
    }

    @Test("A fast flick commits even short of the distance threshold")
    func fastFlickCommits() {
        #expect(EdgeSwipeToDismiss.shouldDismiss(offset: 40, velocity: 900, width: 390))
    }

    @Test("A fast flick backwards (negative offset) never commits")
    func backwardsFlickNeverCommits() {
        #expect(!EdgeSwipeToDismiss.shouldDismiss(offset: -10, velocity: 900, width: 390))
    }

    @Test("An unmeasured width never commits — there is no honest 'a third of the way'")
    func unmeasuredWidthNeverCommits() {
        #expect(!EdgeSwipeToDismiss.shouldDismiss(offset: 1000, velocity: 2000, width: 0))
    }

    @Test("Exactly a third of the way is the boundary, not past it")
    func exactlyOneThirdDoesNotCommit() {
        #expect(!EdgeSwipeToDismiss.shouldDismiss(offset: 130, velocity: 0, width: 390))
        #expect(EdgeSwipeToDismiss.shouldDismiss(offset: 130.01, velocity: 0, width: 390))
    }

    // MARK: - clampedOffset

    @Test("A backwards drag never pulls the sheet past its resting position")
    func clampedOffsetNeverGoesNegative() {
        #expect(EdgeSwipeToDismiss.clampedOffset(-50, width: 390) == 0)
    }

    @Test("A drag cannot push the sheet further than fully off-screen")
    func clampedOffsetNeverExceedsWidth() {
        #expect(EdgeSwipeToDismiss.clampedOffset(600, width: 390) == 390)
    }

    @Test("Within range, the raw offset passes through unchanged")
    func clampedOffsetPassesThroughInRange() {
        #expect(EdgeSwipeToDismiss.clampedOffset(120, width: 390) == 120)
    }

    @Test("An unmeasured width still refuses a negative offset")
    func clampedOffsetWithZeroWidth() {
        #expect(EdgeSwipeToDismiss.clampedOffset(-20, width: 0) == 0)
        #expect(EdgeSwipeToDismiss.clampedOffset(20, width: 0) == 20)
    }
}
