import Foundation
import Testing
@testable import MangaBaka

/// A cover fades its real artwork in over its BlurHash placeholder — except
/// when the load was fast enough to have come from cache, where a fade would
/// read as a flicker instead of an arrival.
@Suite("Cover fade-in")
struct CoverImageTests {
    @Test("A load at or above the cache-hit threshold fades")
    func slowLoadFades() {
        #expect(CoverImage.shouldFade(loadDuration: CoverImage.cacheHitThreshold))
        #expect(CoverImage.shouldFade(loadDuration: 0.25))
    }

    @Test("A load faster than the threshold does not fade — a cache hit")
    func fastLoadSkipsFade() {
        #expect(!CoverImage.shouldFade(loadDuration: 0))
        #expect(!CoverImage.shouldFade(loadDuration: 0.005))
        #expect(!CoverImage.shouldFade(loadDuration: CoverImage.cacheHitThreshold - 0.001))
    }
}

/// The cover's context menu (beside "Copy cover", since 2026-09-13 — R F3)
/// shows only the actions a cover was actually given, in a fixed order.
@Suite("Cover quick actions")
struct CoverQuickActionsTests {
    @Test("No actions supplied, nothing to show")
    func noActions() {
        #expect(CoverQuickActions.visibleActions(CoverQuickActions.Actions()).isEmpty)
    }

    @Test("Only the supplied actions appear, Save / Mark read / Open in that order")
    func orderedSubset() {
        let actions = CoverQuickActions.Actions(save: {}, open: {})
        let items = CoverQuickActions.visibleActions(actions)
        #expect(items.map(\.title) == ["Save", "Open"])
    }

    @Test("All three, in order")
    func allThree() {
        let actions = CoverQuickActions.Actions(save: {}, markRead: {}, open: {})
        let items = CoverQuickActions.visibleActions(actions)
        #expect(items.map(\.title) == ["Save", "Mark read", "Open"])
    }
}
