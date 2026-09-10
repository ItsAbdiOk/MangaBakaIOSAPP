import Testing
import CoreGraphics
@testable import MangaBaka

/// The top scroll edge.
///
/// The scrim itself has to be looked at, and it was — the assertions here pin
/// the one part that is a decision rather than a drawing: when it appears.
@Suite("Scroll edge")
struct ScrollEdgeTests {
    @Test("Invisible at rest")
    func nothingAtRest() {
        // A band of solid ground over a screen that has not moved is a painted
        // stripe, not an edge.
        #expect(ScrollEdge.opacity(forTravel: 0) == 0)
    }

    @Test("A rubber-banded overscroll does not summon it")
    func negativeTravelIsClamped() {
        // Pulling down to refresh reports negative travel. Without the clamp
        // that is a negative opacity, which SwiftUI treats as zero anyway —
        // but the maths should say what it means.
        #expect(ScrollEdge.opacity(forTravel: -80) == 0)
    }

    @Test("Fully in before a line of text has passed under the island")
    func fullyInEarly() {
        // 12pt is under a single line's height on purpose: the failure being
        // fixed is a title cut in half by the Dynamic Island, so the edge has
        // to be there before the first line reaches it.
        #expect(ScrollEdge.opacity(forTravel: ScrollEdge.fadeIn) == 1)
        #expect(ScrollEdge.opacity(forTravel: 400) == 1)
    }

    @Test("It fades rather than snapping")
    func fadesInBetween() {
        let half = ScrollEdge.opacity(forTravel: ScrollEdge.fadeIn / 2)
        #expect(half > 0.4 && half < 0.6)
    }
}
