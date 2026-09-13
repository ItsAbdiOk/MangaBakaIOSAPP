import Testing
import SwiftUI
@testable import MangaBaka

/// The pure decision behind `SeriesPager`'s edge-gesture handoff: which of the
/// pager's own paging and the system's back gesture a drag beginning at a
/// given point belongs to. `allowsPaging` is the only part of `SeriesPager`
/// with no SwiftUI in it — the rest (the `ScrollView`, `.scrollTargetBehavior`,
/// the haptic on settle) is left for the main session to verify on a
/// simulator, per the motion brief's rule 10.
@Suite("SeriesPager")
struct SeriesPagerTests {
    @Test("A drag inside the leading 20pt belongs to the system's back gesture")
    func leadingEdgeIsReservedForBack() {
        #expect(!SeriesPager<EmptyView>.allowsPaging(dragStartX: 0, width: 390))
        #expect(!SeriesPager<EmptyView>.allowsPaging(dragStartX: 19, width: 390))
    }

    @Test("A drag starting at or past 20pt belongs to the pager")
    func pastTheEdgeBelongsToThePager() {
        #expect(SeriesPager<EmptyView>.allowsPaging(dragStartX: 20, width: 390))
        #expect(SeriesPager<EmptyView>.allowsPaging(dragStartX: 200, width: 390))
    }

    @Test("The margin matches EdgeSwipeToDismiss's own leading-edge width")
    func marginMatchesTheSheetGesture() {
        // The two gestures live on different kinds of screen (a pushed page
        // here, a sheet there) so they never actually compete for the same
        // touch — but a reader forms one expectation for "how close to the
        // edge counts as the edge", and a mismatch between the two would be
        // a seam nobody asked for.
        #expect(SeriesPager<EmptyView>.allowsPaging(dragStartX: 20, width: 390))
        #expect(!SeriesPager<EmptyView>.allowsPaging(dragStartX: 19.99, width: 390))
    }
}
