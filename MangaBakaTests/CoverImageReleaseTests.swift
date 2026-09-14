import Foundation
import Testing
@testable import MangaBaka

/// A cover released on disappear must come back without a fade.
///
/// Every row's decoded `UIImage` used to live in `@State` for the life of the
/// screen — `LazyVStack` retains every row it has created — which measured
/// ~70 MB of row state for 513 library rows on top of `CoverStore`'s 96 MB
/// cache holding the same pixels. Releasing it on `.onDisappear` is only safe
/// if a returning row repaints in the same frame, and that is a decision, so
/// it has a name and a test rather than a hope.
///
/// What this cannot check is the memory figure itself: that is the Xcode
/// memory gauge, 513 rows to the bottom and back, with the release and
/// without it, and the reading before any scrolling as the control.
@Suite("Cover release and return")
struct CoverImageReleaseTests {
    /// Expected to fail before the fix with: "type 'CoverImage' has no member
    /// 'arrival'". The old `shouldFade(loadDuration:)` could not express the
    /// returning-row case at all — it only ever saw a duration.
    @Test("A returning row whose cover is still cached repaints instantly")
    func cachedReturnIsInstant() {
        #expect(CoverImage.arrival(wasCached: true, loadDuration: 0) == .instant)
        // However long the original download took. The duration belongs to a
        // fetch that already happened; this row is reading memory.
        #expect(CoverImage.arrival(wasCached: true, loadDuration: 5) == .instant)
    }

    /// The case the release is allowed to produce: the cover was let go *and*
    /// `CoverStore` evicted it, so the BlurHash placeholder was genuinely on
    /// screen first and a fade reads as arrival rather than flicker.
    @Test("A cover that had to be fetched again fades")
    func evictedReturnFades() {
        #expect(
            CoverImage.arrival(
                wasCached: false, loadDuration: CoverImage.cacheHitThreshold
            ) == .fading
        )
        #expect(CoverImage.arrival(wasCached: false, loadDuration: 0.25) == .fading)
    }

    /// The threshold still decides the uncached case, unchanged: a round trip
    /// answered inside a frame never had a visible placeholder to fade from.
    @Test("An uncached load faster than a frame still does not fade")
    func fastUncachedLoadIsInstant() {
        #expect(CoverImage.arrival(wasCached: false, loadDuration: 0) == .instant)
        #expect(
            CoverImage.arrival(
                wasCached: false, loadDuration: CoverImage.cacheHitThreshold - 0.001
            ) == .instant
        )
    }
}
