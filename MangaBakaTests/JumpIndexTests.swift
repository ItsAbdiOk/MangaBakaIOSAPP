import Testing
@testable import MangaBaka

/// `JumpIndex.letterIndex` is the maths behind the A-Z rail's drag gesture —
/// the letter under a finger, from the drag's y against the rail's height.
/// Pulled out as a pure static function because a `DragGesture` callback
/// cannot be driven from a test.
@Suite("JumpIndex letter-from-offset maths")
struct JumpIndexTests {
    @Test("Top of the rail is the first letter")
    func topIsFirst() {
        #expect(JumpIndex.letterIndex(atY: 0, height: 260, count: 26) == 0)
    }

    @Test("Bottom of the rail is the last letter")
    func bottomIsLast() {
        #expect(JumpIndex.letterIndex(atY: 260, height: 260, count: 26) == 25)
    }

    @Test("A finger above the rail clamps to the first letter")
    func aboveClamps() {
        #expect(JumpIndex.letterIndex(atY: -50, height: 260, count: 26) == 0)
    }

    @Test("A finger below the rail clamps to the last letter")
    func belowClamps() {
        #expect(JumpIndex.letterIndex(atY: 400, height: 260, count: 26) == 25)
    }

    @Test("The middle of the rail lands in the middle letter")
    func middleLandsMiddle() {
        #expect(JumpIndex.letterIndex(atY: 130, height: 260, count: 26) == 13)
    }

    @Test("A zero-height rail does not crash and reports the first letter")
    func zeroHeightDoesNotCrash() {
        #expect(JumpIndex.letterIndex(atY: 40, height: 0, count: 26) == 0)
    }

    @Test("A zero-count rail does not crash")
    func zeroCountDoesNotCrash() {
        #expect(JumpIndex.letterIndex(atY: 40, height: 260, count: 0) == 0)
    }
}
