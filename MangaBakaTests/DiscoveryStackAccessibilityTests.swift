import SwiftUI
import Testing
@testable import MangaBaka

/// Contrast and clipping on the tab roots, computed rather than believed.
///
/// The 2026-09-13 accessibility audit filed 20 contrast failures and 8
/// "Text clipped" rows against the five tabs. Most of them are not defects:
/// sampling the audit's own screenshots at the frames it reported gives
/// 18.37:1 for the Discover card titles it called failures and 7.29:1 for
/// "See all". What survived that check is in here, with the figure that made
/// it survive. `WCAGContrast` lives in `DetailSettingsContrastTests`.
@Suite("Discover and Stack accessibility")
@MainActor
struct DiscoveryStackAccessibilityTests {

    /// The control.
    ///
    /// Two figures measured somewhere other than this file, so a drift in the
    /// calculator shows up as this test rather than as a silent pass below:
    /// `Palette.textMuted` on the ground was recorded at 4.66:1 in
    /// `docs/todo-next-week.md` on 2026-09-13, and `Palette.textTertiary` was
    /// sampled at 3.95:1 out of the audit's own Settings screenshot on
    /// 2026-09-14 (see `DetailSettingsContrastTests`).
    ///
    /// The second figure used to be `Palette.textQuaternary` at 2.52:1, taken
    /// from the comment at `SearchClearButton.swift:31`. That token was
    /// retired on 2026-09-14 — the reasoning is in `Palette.swift` and the
    /// arithmetic is in `PaletteContrastFloorTests` — so the control now pins
    /// a level that still exists. 2.52:1 is not lost: it is the figure the
    /// retirement note quotes.
    @Test("Control: the calculator reproduces two figures measured elsewhere")
    func calculatorReproducesKnownRatios() {
        let muted = WCAGContrast.ratio(Palette.textMuted, on: Palette.ground)
        #expect(
            abs(muted - 4.66) < 0.05,
            "textMuted on ground was recorded at 4.66:1 on 2026-09-13; this says \(muted)"
        )
        let tertiary = WCAGContrast.ratio(Palette.textTertiary, on: Palette.ground)
        #expect(
            abs(tertiary - 3.95) < 0.05,
            "textTertiary was sampled at 3.95:1 from the audit screenshot; this says \(tertiary)"
        )
    }

    /// The second control, and the reason the fix below exists.
    ///
    /// `RowAmbient` lifts the ground under a Discover row, so every figure
    /// `Palette` quotes is measured against a colour the row does not have.
    /// This pins the size of that shift: on the sampled ground the same
    /// `textMuted` that reaches 4.66:1 on the page reaches 4.48:1, which is
    /// the wrong side of AA by 0.02. Small, and still a miss.
    @Test("Control: the row's ambient tint really does cost contrast")
    func ambientTintCostsContrast() {
        let onGround = WCAGContrast.ratio(Palette.textMuted, on: Palette.ground)
        let onRow = WCAGContrast.ratio(Palette.textMuted, on: RowAmbient.sampledGround)
        #expect(onRow < onGround, "the tint should lower contrast, not raise it")
        #expect(
            abs(onRow - 4.48) < 0.05,
            "textMuted on the sampled row ground computed to 4.48:1; this says \(onRow)"
        )
        #expect(
            onRow < WCAGContrast.aaNormalText,
            "if this passes, the meta line below no longer needs moving"
        )
    }

    /// The fix.
    ///
    /// `CoverCard`'s meta line — "Manhwa · 8.6", "Manga · 8.9" — was five of
    /// the audit's twenty contrast rows on the tabs, and it is the one shared
    /// control behind all five: the same card draws Discover's rows, Search's
    /// grid, Mix's grid and the publisher pages. It was `textMuted`, which
    /// `ambientTintCostsContrast` above puts at 4.48:1 on the ground the card
    /// actually sits on.
    ///
    /// Expected to fail before the change, with: "the meta line measures
    /// 4.48:1 on a row's own ground, under AA's 4.5" — 4.48 is not >= 4.5.
    /// It is a 0.02 margin, which is exactly why it needed computing rather
    /// than eyeballing.
    @Test("A cover card's meta line reaches AA on the ground a row gives it")
    func rowMetaSurvivesTheAmbientTint() {
        let onRow = WCAGContrast.ratio(CoverCard.metaColour, on: RowAmbient.sampledGround)
        #expect(
            onRow >= WCAGContrast.aaNormalText,
            "the meta line measures \(onRow):1 on a row's own ground, under AA's 4.5"
        )
        // And on the plain ground, for the grids that have no row tint.
        let onGround = WCAGContrast.ratio(CoverCard.metaColour, on: Palette.ground)
        #expect(onGround >= WCAGContrast.aaNormalText, "\(onGround):1 on the page ground")
    }

    /// Every group label in the app is one component, so one default decided
    /// eleven of the audit's "Contrast nearly passed" rows — MINIMUM RATING
    /// and REQUIRE TAGS on Mix, TYPE / STATUS / SORT / MINIMUM RATING / YEAR
    /// and NARROW BY on Search, and three more on the series page and in
    /// Settings. An eyebrow is 11pt semibold: not large text, so AA is 4.5.
    ///
    /// Expected to fail before the change, with "an eyebrow measures 3.95:1"
    /// — `Palette.textTertiary` was the default.
    @Test("The eyebrow's default colour reaches AA")
    func eyebrowDefaultReachesAA() {
        let ratio = WCAGContrast.ratio(Eyebrow(text: "MINIMUM RATING").color, on: Palette.ground)
        #expect(
            ratio >= WCAGContrast.aaNormalText,
            "an eyebrow measures \(ratio):1 on the ground, under AA's 4.5"
        )
    }

    /// Both stack badges pass when they are actually drawn, which is the
    /// negative result behind hiding them from the audit rather than
    /// recolouring them.
    ///
    /// SKIP is `textPrimary` on `surfaceBadge`, a 60% black over whatever the
    /// cover happens to be, so the worst case is a white cover — computed
    /// here rather than assumed, because a *darker* cover only helps. SAVE is
    /// on the opaque accent and the cover behind it does not reach the text
    /// at all.
    @Test("SKIP and SAVE pass on the worst cover they can land on")
    func stackBadgesPassWhenDrawn() {
        let onWhite = WCAGContrast.composite(Palette.surfaceBadge, over: .white)
        let skipGround = Color(red: onWhite.red, green: onWhite.green, blue: onWhite.blue)
        let skip = WCAGContrast.ratio(Palette.textPrimary, on: skipGround)
        #expect(skip >= WCAGContrast.aaNormalText, "SKIP over a white cover: \(skip):1")

        let save = WCAGContrast.ratio(Palette.onAccent, on: Palette.accent)
        #expect(save >= WCAGContrast.aaNormalText, "SAVE on the accent: \(save):1")
    }

    /// The audit's "Text clipped" rows on Discover were the card's own two
    /// clamps: the title at two lines and the meta at one. A 118pt card is
    /// 177pt once widened and `typeCardTitle` reaches about 30pt at the
    /// largest size, so neither clamp can hold a real title there.
    ///
    /// `nil`, not a larger number, because any number is a fresh guess about
    /// the longest title MangaBaka carries.
    ///
    /// This one cannot be said to fail against the old code: `titleLineLimit`
    /// was a private computed property returning 4 and `metaLineLimit` did
    /// not exist, so the previous version does not compile against this test
    /// rather than failing it. What it pins is the number, from here on.
    @Test("A cover card stops clamping its lines at accessibility text sizes")
    func cardLinesAreUnclampedAtAccessibilitySizes() {
        #expect(CoverCard.titleLineLimit(isAccessibilitySize: true) == nil)
        #expect(CoverCard.metaLineLimit(isAccessibilitySize: true) == nil)
        // Unchanged at ordinary sizes: the mockup's two-line title and
        // one-line meta are the design, not an accident.
        #expect(CoverCard.titleLineLimit(isAccessibilitySize: false) == 2)
        #expect(CoverCard.metaLineLimit(isAccessibilitySize: false) == 1)
    }
}
