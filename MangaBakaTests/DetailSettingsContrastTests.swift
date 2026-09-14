import SwiftUI
import Testing
import UIKit
@testable import MangaBaka

/// WCAG contrast, computed rather than asserted about.
///
/// Apple's accessibility audit reports "Contrast failed" and "Contrast nearly
/// passed" with no number, which leaves the reader of the report guessing at
/// which of the two colours involved is the problem — and on 2026-09-13 the
/// guess was wrong twice on the series page (see `contrastOfTheAuditsOwnRun`).
/// This computes the ratio the audit is deciding on, so a claim about a token
/// is a figure and not an opinion.
enum WCAGContrast {
    struct Components: Equatable, Sendable {
        var red: Double
        var green: Double
        var blue: Double
        var alpha: Double

        /// WCAG 2.1's relative luminance, sRGB. Alpha is ignored: composite
        /// first, then ask.
        var luminance: Double {
            func linear(_ value: Double) -> Double {
                value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        }
    }

    nonisolated static func components(_ colour: Color) -> Components {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        // `getRed` returns false for a colour outside an RGB space; none of
        // the app's tokens is one, and defaulting to black rather than
        // force-unwrapping keeps a future pattern fill from crashing a test.
        _ = UIColor(colour).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return Components(
            red: Double(red), green: Double(green), blue: Double(blue), alpha: Double(alpha)
        )
    }

    /// What a `Color` with alpha actually resolves to on screen: the app's
    /// text tokens are `#EBEBF5` at 0.32…0.96, and a ratio computed from the
    /// unmultiplied hex is a ratio for a colour nothing ever draws.
    nonisolated static func composite(_ colour: Color, over ground: Color) -> Components {
        let top = components(colour)
        let bottom = components(ground)
        let alpha = top.alpha
        return Components(
            red: top.red * alpha + bottom.red * (1 - alpha),
            green: top.green * alpha + bottom.green * (1 - alpha),
            blue: top.blue * alpha + bottom.blue * (1 - alpha),
            alpha: 1
        )
    }

    /// The ratio `colour` reaches when drawn on `ground`, alpha composited.
    nonisolated static func ratio(_ colour: Color, on ground: Color) -> Double {
        let light = composite(colour, over: ground).luminance
        let dark = components(ground).luminance
        return (max(light, dark) + 0.05) / (min(light, dark) + 0.05)
    }

    /// WCAG AA for text below the large-text threshold. Every eyebrow in the
    /// app is 11pt semibold, which is not large text by any reading of the
    /// rule (18pt regular, or 14pt bold).
    nonisolated static let aaNormalText: Double = 4.5
}

@Suite("Contrast on the series page and in Settings")
@MainActor
struct DetailSettingsContrastTests {

    /// The control.
    ///
    /// A contrast calculator that is wrong is worse than none, so this pins
    /// two figures that were measured somewhere other than this file:
    /// `Palette.textMuted` on the ground was recorded as 4.66:1 in
    /// `docs/todo-next-week.md` on 2026-09-13, and `Palette.textTertiary` was
    /// sampled at 3.95:1 straight out of the audit's own Settings screenshot
    /// (`/tmp/mb-a11y-settings.png`, the "ACCOUNT" label at 18,209 61x13) on
    /// 2026-09-14. If this test drifts, the two below are measuring nothing.
    @Test("The calculator reproduces two figures measured elsewhere")
    func reproducesMeasuredRatios() {
        let muted = WCAGContrast.ratio(Palette.textMuted, on: Palette.ground)
        #expect(
            abs(muted - 4.66) < 0.05,
            "textMuted on ground was measured at 4.66:1 on 2026-09-13; this says \(muted)"
        )
        let tertiary = WCAGContrast.ratio(Palette.textTertiary, on: Palette.ground)
        #expect(
            abs(tertiary - 3.95) < 0.05,
            "textTertiary was sampled at 3.95:1 from the audit screenshot; this says \(tertiary)"
        )
    }

    /// The one contrast failure on these two screens that a reader meets.
    ///
    /// "GENRES" and "THEMES" on the series page, "ACCOUNT", "SERIES TITLES"
    /// and "FORMATS" in Settings are all one component — `Eyebrow` — and all
    /// five were reported as "Contrast nearly passed" on 2026-09-13. They are
    /// 11pt semibold on the ground, so AA wants 4.5:1 and the default colour
    /// gives 3.95. "Nearly" is the audit being polite about a real miss.
    @Test("An eyebrow label reaches AA against the ground it is drawn on")
    func eyebrowMeetsAA() {
        let ratio = WCAGContrast.ratio(Eyebrow(text: "GENRES").color, on: Palette.ground)
        #expect(
            ratio >= WCAGContrast.aaNormalText,
            """
            Eyebrow draws at \(ratio):1 on Palette.ground and AA wants \
            \(WCAGContrast.aaNormalText):1 for 11pt semibold.
            """
        )
    }

    /// The two the 2026-09-13 audit called contrast failures on the series
    /// page and which are not.
    ///
    /// Recorded as a test rather than deleted, because both will be reported
    /// again on the next run and somebody will go looking for a colour to
    /// change. The synopsis is `Palette.textBody`; "3 more tag groups" is
    /// `Palette.accent`. Sampling the audit's own screenshot of that run
    /// (`/tmp/mb-a11y-series-detail.png`) on 2026-09-14 read 9.38:1 at the
    /// synopsis' frame and 7.28:1 at the tag line's, within 0.2 of what this
    /// computes — so the pixels and the tokens agree with each other and
    /// disagree with the audit. Why the audit says otherwise is unexplained;
    /// both are combined elements (`children: .combine`, and a `Button` whose
    /// label holds a `Text` and an `Image`), which is the only thing they
    /// share and the eyebrows do not.
    @Test("The synopsis and the tag-groups line pass AA comfortably")
    func theAuditsTwoNamedFailuresAreNotFailures() {
        let synopsis = WCAGContrast.ratio(Palette.textBody, on: Palette.ground)
        #expect(synopsis > 9, "The synopsis draws at \(synopsis):1, not a failure")
        let tagGroups = WCAGContrast.ratio(Palette.accent, on: Palette.ground)
        #expect(tagGroups > 7, "'3 more tag groups' draws at \(tagGroups):1, not a failure")
    }
}

@Suite("The series page's navigation-bar title")
struct DetailBarTitleVisibilityTests {

    /// The bar's copy of the title used to be mounted at every scroll
    /// position and merely drawn at `opacity(crossfade)`. At the top of the
    /// page that is a fully transparent string sitting in the layout, and
    /// Apple's audit filed three issues against it there on 2026-09-13 —
    /// contrast, text clipped, Dynamic Type — at 72,76 200x16. Sampling the
    /// audit's own screenshot over exactly that rectangle on 2026-09-14 gives
    /// 1.01:1: there is nothing drawn there at all.
    @Test("Nothing is in the bar while the hero still has the title")
    func absentAtTheTopOfThePage() {
        #expect(DetailBarTitle.showsBarTitle(crossfade: 0) == false)
    }

    /// The fade itself is untouched: the copy mounts on the first frame of
    /// the crossfade, not at some later threshold, so the handover still
    /// reads as one title moving rather than two cutting.
    @Test(
        "It is present for every frame of the fade and after it",
        arguments: [0.001, 0.25, 0.5, 0.75, 1.0] as [CGFloat]
    )
    func presentThroughoutTheFade(crossfade: CGFloat) {
        #expect(DetailBarTitle.showsBarTitle(crossfade: crossfade))
    }

    /// `crossfadeProgress` is what feeds it, and it is clamped at both ends —
    /// so "not yet travelled" and "travelled backwards" both mean absent.
    @Test("A page scrolled to the top, or bounced past it, has no bar title")
    func absentAtAndBeforeZeroTravel() {
        for travelled in [CGFloat(-40), 0, 50, DetailBarTitle.heroTitleTravel - 61] {
            let progress = DetailBarTitle.crossfadeProgress(travelled: travelled)
            #expect(
                DetailBarTitle.showsBarTitle(crossfade: progress) == false,
                "travelled \(travelled) gave progress \(progress)"
            )
        }
    }
}
