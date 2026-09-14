import SwiftUI
import Testing
@testable import MangaBaka

/// The floor each `Palette` text level has to clear, computed rather than
/// pinned.
///
/// A hex pinned in a test only catches an edit to that hex; it says nothing
/// about whether the colour is legible. These compute the WCAG 2.1 ratio the
/// accessibility audit is actually deciding on, against both grounds the app
/// draws text over: the page ground, and the tinted ground `RowAmbient` puts
/// under a Discover row. `WCAGContrast` lives in `DetailSettingsContrastTests`
/// and is deliberately not copied here.
///
/// This suite is the record of why `Palette.textQuaternary` was retired on
/// 2026-09-14 rather than repaired. It measured 2.52:1 on the page ground,
/// which fails 4.5:1 for text (WCAG 1.4.3) and also 3:1 for non-text
/// (1.4.11) — a failure on every reading, at all 15 of its call sites, in an
/// app going to the App Store.
@Suite("Palette contrast floors")
@MainActor
struct PaletteContrastFloorTests {

    /// WCAG 1.4.11, for marks that are not text: a chevron, a spinner, an
    /// empty star, a status dot.
    nonisolated static let nonTextFloor: Double = 3.0

    /// The two grounds anything in this app is drawn on. `sampledGround` is
    /// `RowAmbient`'s own sampled figure, not a second copy of it.
    nonisolated static let grounds: [(name: String, colour: Color)] = [
        ("the page ground", Palette.ground),
        ("a row's tinted ground", RowAmbient.sampledGround)
    ]

    // MARK: Controls

    /// The control, reproducing a figure measured outside this file.
    ///
    /// `Palette.textMuted` on the page ground was recorded at 4.66:1 in
    /// `docs/todo-next-week.md` on 2026-09-13, from the audit's own
    /// screenshot rather than from this calculator. If this drifts, every
    /// figure below is measuring nothing.
    @Test("Control: the calculator reproduces a figure measured elsewhere")
    func reproducesAMeasuredRatio() {
        let muted = WCAGContrast.ratio(Palette.textMuted, on: Palette.ground)
        #expect(
            abs(muted - 4.66) < 0.05,
            "textMuted on the ground was measured at 4.66:1 on 2026-09-13; this says \(muted)"
        )
    }

    /// The second control: the row tint's cost, which `RowAmbient`'s doc
    /// comment records as `textTertiary` 3.96:1 → 3.89:1 and `textBody`
    /// 9.53:1 → 8.34:1. Those were computed on 2026-09-14 by a different
    /// implementation of the same maths; agreeing with them to two decimal
    /// places is what makes the arithmetic below trustworthy.
    @Test("Control: the row tint moves the numbers by the recorded amount")
    func reproducesTheRecordedRowShift() {
        let tertiaryOnRow = WCAGContrast.ratio(Palette.textTertiary, on: RowAmbient.sampledGround)
        #expect(
            abs(tertiaryOnRow - 3.89) < 0.02,
            "RowAmbient records textTertiary at 3.89:1 on a row; this says \(tertiaryOnRow)"
        )
        let bodyOnRow = WCAGContrast.ratio(Palette.textBody, on: RowAmbient.sampledGround)
        #expect(
            abs(bodyOnRow - 8.34) < 0.02,
            "textBody on a row computed to 8.34:1 on 2026-09-14; this says \(bodyOnRow)"
        )
    }

    // MARK: The floors

    /// Every level the app draws running text in clears AA on the page
    /// ground.
    ///
    /// `textSecondary` is absent on purpose: it is `Color(.secondaryLabel)`,
    /// a dynamic system colour, and resolving one in a test process with no
    /// trait collection can give the light-appearance value — a figure for a
    /// colour this app never renders, since it pins `.dark` everywhere. It is
    /// `#EBEBF5` @ 0.60, which computes to 6.32:1, comfortably clear either
    /// way; it is left out because a test that resolves the wrong appearance
    /// would be lying rather than because the colour is in doubt.
    ///
    /// Before 2026-09-14 this list also held `textQuaternary`, and this test
    /// failed on it at 2.52:1.
    @Test(
        "Text levels clear AA on the page ground",
        arguments: [
            ("textPrimary", Palette.textPrimary),
            ("textEmphasis", Palette.textEmphasis),
            ("textBody", Palette.textBody),
            ("textMuted", Palette.textMuted)
        ] as [(name: String, colour: Color)]
    )
    func textLevelsClearAA(level: (name: String, colour: Color)) {
        let ratio = WCAGContrast.ratio(level.colour, on: Palette.ground)
        #expect(
            ratio >= WCAGContrast.aaNormalText,
            """
            Palette.\(level.name) draws at \(ratio):1 on the page ground and \
            AA wants \(WCAGContrast.aaNormalText):1 for normal text.
            """
        )
    }

    /// `textTertiary` is the marks-and-inactive-controls level, and its job is
    /// 3:1 on both grounds — not 4.5:1, which it has never reached.
    @Test("The mark level clears the non-text floor on both grounds", arguments: Self.grounds)
    func markLevelClearsNonTextFloor(ground: (name: String, colour: Color)) {
        let ratio = WCAGContrast.ratio(Palette.textTertiary, on: ground.colour)
        #expect(
            ratio >= Self.nonTextFloor,
            """
            Palette.textTertiary draws at \(ratio):1 on \(ground.name) and \
            WCAG 1.4.11 wants \(Self.nonTextFloor):1 for a non-text mark.
            """
        )
    }

    /// Why there is no fifth level, as arithmetic rather than as taste.
    ///
    /// The retired token sat at `#EBEBF5` @ 0.32. Search for the alpha that
    /// first reaches 4.5:1 on this ground and it lands at about 0.489 — above
    /// `textTertiary`'s 0.45 and all but on top of `textMuted`'s 0.50. A
    /// level fainter than the fourth cannot both exist and pass, so raising
    /// the token's opacity was never an option and the level was removed.
    ///
    /// If this ever fails, the ground has changed and the four levels need
    /// respacing, not patching.
    @Test("No level fainter than textTertiary can reach AA on this ground")
    func aFifthLevelCannotPass() {
        let swatch = Color(hex: 0xEBEBF5)
        let retired = WCAGContrast.ratio(swatch.opacity(0.32), on: Palette.ground)
        #expect(
            abs(retired - 2.52) < 0.02,
            "the retired quaternary level measured 2.52:1; this says \(retired)"
        )
        // Binary search for the first alpha reaching AA. 40 halvings is far
        // past the precision of an 8-bit channel.
        var low = 0.0, high = 1.0
        for _ in 0..<40 {
            let mid = (low + high) / 2
            if WCAGContrast.ratio(swatch.opacity(mid), on: Palette.ground)
                < WCAGContrast.aaNormalText {
                low = mid
            } else {
                high = mid
            }
        }
        #expect(
            high > 0.45,
            """
            Alpha \(high) reaches AA, which is at or below textTertiary's \
            0.45 — a fifth, fainter level would now be possible and the note \
            in Palette.swift is out of date.
            """
        )
    }
}
