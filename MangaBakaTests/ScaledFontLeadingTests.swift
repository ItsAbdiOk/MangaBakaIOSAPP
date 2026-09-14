import Testing
import CoreGraphics
@testable import MangaBaka

/// Leading has to scale with the text it separates.
///
/// `ScaledFont` resolved the spec's line-height multiplier in `init`, against
/// the unscaled literal passed in — and `@ScaledMetric` is not resolved at
/// `init` time at all, so it could not have been anything else. A paragraph
/// set at 1.55 therefore kept the leading of a 14pt line while the glyphs grew
/// to 30pt: the lines closed up exactly where a reader who enlarged the text
/// needed them furthest apart.
@Suite("Scaled leading")
struct ScaledFontLeadingTests {
    /// Expected to fail before the fix with: "type 'ScaledFont' has no member
    /// 'lineSpacing'". The conversion was a statement inside `init` with no
    /// name and no way to call it.
    @Test("Leading is the multiplier over the size actually rendered")
    func leadingFollowsTheRenderedSize() throws {
        // `typeBody`: 14pt at 1.55. Compared with a tolerance, not `==`:
        // 1.55 and 14 are not exactly representable in binary floating point,
        // so `(1.55 - 1.2) * 14` and the value `lineSpacing` computes from
        // the same inputs can differ in the last bit (4.900000000000001 vs.
        // 4.9) despite neither side having a bug.
        let tolerance: CGFloat = 0.0001
        let small = try #require(ScaledFont.lineSpacing(lineHeight: 1.55, size: 14))
        #expect(abs(small - (1.55 - 1.2) * 14) < tolerance)
        // The same style at an accessibility size, where `@ScaledMetric` has
        // roughly doubled the glyphs. The old code returned the 14pt answer
        // here, which is the bug.
        let large = try #require(ScaledFont.lineSpacing(lineHeight: 1.55, size: 30))
        #expect(abs(large - (1.55 - 1.2) * 30) < tolerance)
    }

    /// Leading grows strictly with size — the property that makes the two
    /// figures above different rather than a restatement of the formula.
    @Test("Bigger text is given more leading, always")
    func leadingGrowsWithSize() throws {
        let small = try #require(ScaledFont.lineSpacing(lineHeight: 1.45, size: 13))
        let large = try #require(ScaledFont.lineSpacing(lineHeight: 1.45, size: 30))
        #expect(large > small)
    }

    /// A style with no multiplier gets no leading at all, and one whose
    /// multiplier is tighter than SwiftUI's own 1.2 asks for negative extra
    /// space — which `body` drops rather than applying. `typeScreenTitle`
    /// (1.05) and `typeDetailHeroTitle` (1.15) are both in that group, and
    /// the sign does not change with size, so the `@ViewBuilder` branch is
    /// fixed per style and no `Text` changes identity as the reader resizes.
    @Test("No multiplier, no leading; a tight multiplier stays negative at every size")
    func absentAndTightMultipliers() {
        #expect(ScaledFont.lineSpacing(lineHeight: nil, size: 14) == nil)
        for size in [9, 14, 36, 80] as [CGFloat] {
            let tight = ScaledFont.lineSpacing(lineHeight: 1.05, size: size)
            #expect((tight ?? 0) < 0, "1.05 should never ask for extra space at \(size)pt")
        }
    }
}
