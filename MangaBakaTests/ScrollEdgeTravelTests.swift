import Testing
import CoreGraphics
@testable import MangaBaka

/// The scroll edge stops reacting once it has nothing left to say.
///
/// `opacity(forTravel:)` is pinned at 1 from `fadeIn` on and at 0 below zero,
/// but the raw offset was stored anyway, so `onScrollGeometryChange` ran its
/// action — and a `withAnimation` inside it — for every sample of a 2000pt
/// fling. Clamping in the transform means the stored value stops changing
/// after 12pt and the action stops firing, which is what the "count the
/// invocations over a 2s scroll" check would show on a device.
@Suite("Scroll edge travel")
struct ScrollEdgeTravelTests {
    /// Expected to fail before the fix with: "type 'ScrollEdge' has no member
    /// 'travel'". The transform passed the offset through untouched.
    @Test("Past the fade-in, every offset is the same value")
    func pastFadeInIsPinned() {
        #expect(ScrollEdge.travel(forOffset: ScrollEdge.fadeIn) == ScrollEdge.fadeIn)
        #expect(ScrollEdge.travel(forOffset: 400) == ScrollEdge.fadeIn)
        #expect(ScrollEdge.travel(forOffset: 2000) == ScrollEdge.fadeIn)
    }

    /// A rubber-banded overscroll at the top reports a negative offset, and
    /// every one of them renders as an invisible scrim.
    @Test("Above the top, every offset is the same value")
    func overscrollIsPinned() {
        #expect(ScrollEdge.travel(forOffset: 0) == 0)
        #expect(ScrollEdge.travel(forOffset: -80) == 0)
    }

    /// Inside the range it still tracks, or the edge would snap instead of
    /// fading.
    @Test("Inside the fade the value still moves")
    func insideTheFadeItTracks() {
        let half = ScrollEdge.fadeIn / 2
        #expect(ScrollEdge.travel(forOffset: half) == half)
        #expect(ScrollEdge.opacity(forTravel: ScrollEdge.travel(forOffset: half)) > 0.4)
    }

    /// The clamp must not change what the scrim looks like at any offset —
    /// the control for the change above.
    @Test("Clamping renders identically to not clamping")
    func clampingChangesNothingVisible() {
        for offset in [-200, -1, 0, 3, 11, 12, 13, 500] as [CGFloat] {
            #expect(
                ScrollEdge.opacity(forTravel: ScrollEdge.travel(forOffset: offset))
                    == ScrollEdge.opacity(forTravel: offset),
                "offset \(offset) renders differently once clamped"
            )
        }
    }
}
