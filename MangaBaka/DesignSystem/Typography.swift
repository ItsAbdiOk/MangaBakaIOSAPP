import SwiftUI

/// The type ramp from the design spec.
///
/// The mockup uses fixed pixel sizes, but it says plainly that Dynamic Type is
/// a build requirement it does not demonstrate. So every size here scales:
/// `@ScaledMetric` grows it with the reader's text size, anchored to the text
/// style whose default size is closest, so the ramp keeps its proportions
/// instead of collapsing at the extremes.
struct ScaledFont: ViewModifier {
    @ScaledMetric private var size: CGFloat
    private let weight: Font.Weight
    private let tracking: CGFloat
    private let lineHeight: CGFloat?

    init(
        size: CGFloat,
        weight: Font.Weight,
        relativeTo textStyle: Font.TextStyle,
        tracking: CGFloat = 0,
        lineHeight: CGFloat? = nil
    ) {
        _size = ScaledMetric(wrappedValue: size, relativeTo: textStyle)
        self.weight = weight
        self.tracking = tracking
        self.lineHeight = lineHeight
    }

    /// SwiftUI spaces lines rather than setting a line box, so the spec's
    /// multiplier becomes the extra space between them.
    ///
    /// Computed from the *scaled* size, not the one passed to `init`. It was
    /// resolved in `init` against the unscaled literal, so a paragraph set at
    /// a 1.55 multiplier kept the leading of a 14pt line while the glyphs grew
    /// to 30 — the lines closed up exactly where a reader who enlarged the
    /// text needed them furthest apart. `@ScaledMetric` is not resolved at
    /// `init` time anyway, so the old expression was reading the raw literal
    /// by construction.
    private var lineSpacing: CGFloat? {
        Self.lineSpacing(lineHeight: lineHeight, size: size)
    }

    /// Pure, so the scaling rule above has a test that asserts a number
    /// rather than the file containing a word.
    nonisolated static func lineSpacing(lineHeight: CGFloat?, size: CGFloat) -> CGFloat? {
        lineHeight.map { ($0 - 1.2) * size }
    }

    // `@ViewBuilder`, not `AnyView`. Every `Text` in the app wears this
    // modifier, and boxing each one erased its structural identity, so SwiftUI
    // had to re-diff the whole subtree under it rather than matching views
    // position by position. The branch is decided by `lineHeight`, which is
    // fixed per ramp entry, so the `_ConditionalContent` never flips sides for
    // a given call site — every style's multiplier is either above 1.2 or
    // below it at every text size.
    @ViewBuilder
    func body(content: Content) -> some View {
        let styled = content
            .font(.system(size: size, weight: weight))
            .tracking(tracking)
        if let lineSpacing, lineSpacing > 0 {
            styled.lineSpacing(lineSpacing)
        } else {
            styled
        }
    }
}

extension View {
    func scaledFont(
        size: CGFloat,
        weight: Font.Weight,
        relativeTo textStyle: Font.TextStyle = .body,
        tracking: CGFloat = 0,
        lineHeight: CGFloat? = nil
    ) -> some View {
        modifier(ScaledFont(
            size: size, weight: weight, relativeTo: textStyle,
            tracking: tracking, lineHeight: lineHeight
        ))
    }

    // MARK: The named ramp
    //
    // Named by role rather than by size, so a change to the spec happens here
    // once rather than at every call site.
    //
    // **Every style under 14pt is anchored to `.subheadline`, not to the text
    // style nearest its size.** Apple's accessibility audit reported "Dynamic
    // Type font sizes are partially unsupported" on fifteen elements, all of
    // them small type, and the reason was measured rather than guessed at
    // (`DynamicTypeRampTests`): `UIFontMetrics` returns the SAME value for
    // `.caption2` at extraSmall, small, medium and large, so a caption2-anchored
    // style does not change at all across the bottom third of the range.
    //
    //   caption2     stalls=3   10.7 10.7 10.7 10.7 14.7 16.0 ... 38.7
    //   caption1     stalls=2    8.7  8.7  8.7 10.7 12.3 13.7 ... 33.3
    //   footnote     stalls=2    9.3  9.3  9.3 10.7 11.7 13.0 ... 30.3
    //   subheadline  stalls=0    8.3  9.3 10.0 10.7 11.7 12.7 ... 30.3
    //
    // (base size 10.5, every content size category, smallest first)
    //
    // `.subheadline` is the smallest anchor that moves at every step, and it
    // renders identically at the default size — large is the reference
    // category, so every anchor returns the base size there. The cost is at
    // the very top: a 10.5pt meta line reaches 30pt rather than 39pt at the
    // largest accessibility size. Still nearly triple, and it grows the whole
    // way rather than standing still for four steps.

    func typeScreenTitle() -> some View {
        scaledFont(size: 36, weight: .bold, relativeTo: .largeTitle, tracking: -1.2, lineHeight: 1.05)
    }
    func typeStackTitle() -> some View {
        scaledFont(size: 28, weight: .bold, relativeTo: .title, tracking: -0.9)
    }
    /// A stat, as in the stack's saved counter.
    func typeStatNumber() -> some View {
        scaledFont(size: 22, weight: .bold, relativeTo: .title2, tracking: -0.5)
    }
    /// The series title on a stack card. Not to be confused with
    /// `typeStackTitle`, which is the screen's own heading.
    func typeStackCardTitle() -> some View {
        scaledFont(size: 19, weight: .bold, relativeTo: .title3, tracking: -0.4, lineHeight: 1.25)
    }
    /// A line telling the reader how a surface works.
    func typeInstruction() -> some View {
        scaledFont(size: 12.5, weight: .regular, relativeTo: .footnote)
    }
    /// SKIP and SAVE on the stack card.
    func typeBadge() -> some View {
        scaledFont(size: 12, weight: .bold, relativeTo: .subheadline, tracking: 1)
    }
    func typeDetailHeroTitle() -> some View {
        scaledFont(size: 24, weight: .bold, relativeTo: .title2, tracking: -0.7, lineHeight: 1.15)
    }
    func typeSheetTitle() -> some View {
        scaledFont(size: 22, weight: .bold, relativeTo: .title2, tracking: -0.6)
    }
    func typeSectionHeader() -> some View {
        scaledFont(size: 20, weight: .bold, relativeTo: .title3, tracking: -0.5)
    }
    func typeDetailSectionHeader() -> some View {
        scaledFont(size: 18, weight: .bold, relativeTo: .headline, tracking: -0.4)
    }
    func typeSubsectionHeader() -> some View {
        scaledFont(size: 15, weight: .semibold, relativeTo: .subheadline)
    }
    func typeCTA() -> some View {
        scaledFont(size: 15, weight: .bold, relativeTo: .subheadline)
    }
    func typeBody() -> some View {
        scaledFont(size: 14, weight: .regular, relativeTo: .body, lineHeight: 1.55)
    }
    func typeRowTitle() -> some View {
        scaledFont(size: 13.5, weight: .semibold, relativeTo: .subheadline)
    }
    func typeSubtitle() -> some View {
        scaledFont(size: 13, weight: .regular, relativeTo: .subheadline, lineHeight: 1.45)
    }
    func typeChip() -> some View {
        scaledFont(size: 12.5, weight: .medium, relativeTo: .subheadline)
    }
    func typeCardTitle() -> some View {
        scaledFont(size: 12, weight: .semibold, relativeTo: .subheadline, lineHeight: 1.25)
    }
    func typeSmallMeta() -> some View {
        scaledFont(size: 11.5, weight: .regular, relativeTo: .subheadline)
    }
    func typeEyebrow() -> some View {
        scaledFont(size: 11, weight: .semibold, relativeTo: .subheadline, tracking: 0.7)
    }
    func typeFootnote() -> some View {
        scaledFont(size: 11, weight: .regular, relativeTo: .subheadline, lineHeight: 1.55)
    }
    func typeGridMeta() -> some View {
        scaledFont(size: 10.5, weight: .regular, relativeTo: .subheadline)
    }
    func typeTabLabel() -> some View {
        scaledFont(size: 9.5, weight: .semibold, relativeTo: .subheadline)
    }
    /// The second line of a compound control, under the figure it qualifies:
    /// `ch 69` under `+1` on the library button.
    func typeMicroLabel() -> some View {
        scaledFont(size: 9, weight: .semibold, relativeTo: .subheadline)
    }

    // MARK: Glyphs set beside the ramp

    /// An SF Symbol next to a line of the ramp: the chevron after "3 more tag
    /// groups", the arrow on an external link, the plus on "Add tags". A
    /// fixed-point glyph beside scaling text stays 10pt while its label
    /// reaches 30, and reads as a stray mark rather than part of the label
    /// (the 2026-09-13 sweep found 37 of them). Anchored like the ramp —
    /// `.subheadline` under 14pt, for the stalls measured above — so glyph
    /// and label grow in step; a larger glyph names the text style nearest
    /// its size, the same way the ramp does.
    func typeSymbol(
        size: CGFloat,
        weight: Font.Weight,
        relativeTo textStyle: Font.TextStyle = .subheadline
    ) -> some View {
        scaledFont(size: size, weight: weight, relativeTo: textStyle)
    }
}
