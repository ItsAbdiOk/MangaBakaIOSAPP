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
    private let lineSpacing: CGFloat?

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
        // SwiftUI spaces lines rather than setting a line box, so convert the
        // spec's multiplier into the extra space between lines.
        self.lineSpacing = lineHeight.map { ($0 - 1.2) * size }
    }

    func body(content: Content) -> some View {
        let styled = content
            .font(.system(size: size, weight: weight))
            .tracking(tracking)
        if let lineSpacing, lineSpacing > 0 {
            return AnyView(styled.lineSpacing(lineSpacing))
        }
        return AnyView(styled)
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
        scaledFont(size: 12, weight: .bold, relativeTo: .caption, tracking: 1)
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
        scaledFont(size: 13, weight: .regular, relativeTo: .footnote, lineHeight: 1.45)
    }
    func typeChip() -> some View {
        scaledFont(size: 12.5, weight: .medium, relativeTo: .footnote)
    }
    func typeCardTitle() -> some View {
        scaledFont(size: 12, weight: .semibold, relativeTo: .caption, lineHeight: 1.25)
    }
    func typeWordmark() -> some View {
        scaledFont(size: 12, weight: .bold, relativeTo: .caption, tracking: 2.2)
    }
    func typeSmallMeta() -> some View {
        scaledFont(size: 11.5, weight: .regular, relativeTo: .caption)
    }
    func typeEyebrow() -> some View {
        scaledFont(size: 11, weight: .semibold, relativeTo: .caption2, tracking: 0.7)
    }
    func typeFootnote() -> some View {
        scaledFont(size: 11, weight: .regular, relativeTo: .caption2, lineHeight: 1.55)
    }
    func typeGridMeta() -> some View {
        scaledFont(size: 10.5, weight: .regular, relativeTo: .caption2)
    }
    func typeTabLabel() -> some View {
        scaledFont(size: 9.5, weight: .semibold, relativeTo: .caption2)
    }
}
