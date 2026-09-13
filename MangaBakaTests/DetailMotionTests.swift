import Foundation
import Testing
@testable import MangaBaka

/// The series page's own arrival choreography — this batch's addition to the
/// shared motion vocabulary in `Motion.swift`/`MotionModifiers.swift`. Each
/// suite here covers one pure decision a view in `Features/Detail` makes, so
/// a mistake in the ordering or the maths fails a test rather than only
/// showing up as a section arriving out of turn on a device.
@Suite("The series page's section order")
struct SeriesDetailSectionIndexTests {
    @Test("Every section has the index the motion brief specifies")
    func matchesTheBrief() {
        #expect(SeriesDetailView.sectionIndex(for: .stats) == 0)
        #expect(SeriesDetailView.sectionIndex(for: .synopsis) == 1)
        #expect(SeriesDetailView.sectionIndex(for: .cast) == 2)
        #expect(SeriesDetailView.sectionIndex(for: .tags) == 3)
        #expect(SeriesDetailView.sectionIndex(for: .credits) == 4)
        #expect(SeriesDetailView.sectionIndex(for: .releases) == 5)
        #expect(SeriesDetailView.sectionIndex(for: .volumes) == 6)
        #expect(SeriesDetailView.sectionIndex(for: .editions) == 7)
        #expect(SeriesDetailView.sectionIndex(for: .onwardRows) == 8)
        #expect(SeriesDetailView.sectionIndex(for: .categories) == 9)
        #expect(SeriesDetailView.sectionIndex(for: .trackers) == 10)
    }

    @Test("The order is strictly increasing, so no two sections share a step")
    func strictlyIncreasing() {
        let indices = SeriesDetailView.Section.allCases.map(SeriesDetailView.sectionIndex(for:))
        #expect(indices == indices.sorted())
        #expect(Set(indices).count == indices.count)
    }
}

/// `DetailBackdrop`'s parallax: a few points of drift against scroll, capped
/// per the motion brief so the wash never visibly detaches from the artwork
/// it's washing.
@Suite("The backdrop's parallax")
struct DetailBackdropParallaxTests {
    @Test("Clamped to the given amount in both directions")
    func clamped() {
        // Opposes the scroll (the backdrop lags behind the content), so a big
        // positive scroll clamps to -amount.
        #expect(DetailBackdrop.parallaxOffset(scrollOffset: 10_000, amount: 6, isReduced: false) == -6)
        #expect(DetailBackdrop.parallaxOffset(scrollOffset: -10_000, amount: 6, isReduced: false) == 6)
    }

    @Test("Moves opposite the scroll direction, within the cap")
    func opposesScroll() {
        let offset = DetailBackdrop.parallaxOffset(scrollOffset: 40, amount: 6, isReduced: false)
        #expect(offset < 0, "Scrolling down should drift the wash up, not down")
        #expect(offset > -6)
    }

    @Test("No scroll, no drift")
    func zeroAtRest() {
        #expect(DetailBackdrop.parallaxOffset(scrollOffset: 0, isReduced: false) == 0)
    }

    @Test("Reduce Motion holds the wash still regardless of scroll")
    func stillUnderReducedMotion() {
        #expect(DetailBackdrop.parallaxOffset(scrollOffset: 500, isReduced: true) == 0)
        #expect(DetailBackdrop.parallaxOffset(scrollOffset: -500, isReduced: true) == 0)
    }
}

/// `DetailBackdrop`'s fallback wash colour, read from a cover's own BlurHash
/// the same way `RowAmbient.tint` reads a row's — see that type's own tests
/// for the reference hashes this reuses.
@Suite("The backdrop's ambient tint")
struct DetailBackdropAmbientTintTests {
    private func cover(hash: String?) -> Cover {
        Cover(raw: nil, x150: nil, x250: nil, x350: nil, blurhash: hash, width: nil, height: nil)
    }

    @Test("No BlurHash, no tint")
    func nilWithNoHash() {
        #expect(DetailBackdrop.ambientTint(for: cover(hash: nil)) == nil)
    }

    @Test("A malformed hash produces no tint rather than crashing")
    func nilWithGarbageHash() {
        #expect(DetailBackdrop.ambientTint(for: cover(hash: "LEH")) == nil)
    }

    @Test("A black hash is lifted off pure black, per the boost RowAmbient uses")
    func liftsBrightness() throws {
        let tint = try #require(DetailBackdrop.ambientTint(for: cover(hash: "L00000fQfQfQfQfQfQfQfQfQfQfQ")))
        // `UIColor.getHue` reports 0 saturation/brightness for true black,
        // and the boost floors brightness at 0.7 regardless — the same
        // floor `RowAmbient.tint` applies for exactly this case (a near-
        // black mean reading as an almost invisible wash otherwise).
        #expect(tint.brightness == 0.7)
    }

    @Test("The reference hash's warm tone survives the boost")
    func keepsHue() throws {
        let tint = try #require(
            DetailBackdrop.ambientTint(for: cover(hash: "LEHV6nWB2yk8pyo0adR*.7kCMdnj"))
        )
        #expect(tint.saturation > 0)
        #expect(tint.brightness >= 0.7)
    }
}

/// The bar title's handover from the hero: a fade over the last stretch of
/// the hero's travel, not a flip at the end of it.
@Suite("Bar title crossfade")
struct BarTitleCrossfadeTests {
    @Test("Zero before the fade starts, one at the hero's full travel, linear between")
    func progress() {
        let travel = DetailBarTitle.heroTitleTravel
        let span = DetailBarTitle.crossfadeSpan
        #expect(DetailBarTitle.crossfadeProgress(travelled: 0) == 0)
        #expect(DetailBarTitle.crossfadeProgress(travelled: travel - span) == 0)
        #expect(DetailBarTitle.crossfadeProgress(travelled: travel - span / 2) == 0.5)
        #expect(DetailBarTitle.crossfadeProgress(travelled: travel) == 1)
        #expect(DetailBarTitle.crossfadeProgress(travelled: travel * 3) == 1, "clamped")
        #expect(DetailBarTitle.crossfadeProgress(travelled: -50) == 0, "clamped")
    }
}
