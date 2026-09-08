import SwiftUI

/// Spacing, radii and control sizes from the design spec.
enum Metrics {
    // MARK: Gutters

    /// Screen gutter, everywhere except the stack and the status row.
    static let gutter: CGFloat = 18
    static let gutterStack: CGFloat = 22
    static let gutterStatus: CGFloat = 26

    // MARK: Rhythm

    /// Between home sections.
    static let sectionGap: CGFloat = 26
    /// Between detail rows.
    static let detailRowGap: CGFloat = 28

    // MARK: Gaps

    static let gapChips: CGFloat = 7
    static let gapStrip: CGFloat = 10
    /// Cover rows and grids.
    static let gapCovers: CGFloat = 12
    /// Hero cover to its text.
    static let gapHero: CGFloat = 16

    // MARK: Radii

    static let radiusSheet: CGFloat = 26
    static let radiusStackCard: CGFloat = 20
    /// Cards and primary CTAs.
    static let radiusCard: CGFloat = 16
    /// A cover inside a horizontal row.
    static let radiusCoverRow: CGFloat = 13
    /// A cover inside a grid.
    static let radiusCoverGrid: CGFloat = 12
    static let radiusSeed: CGFloat = 11
    static let radiusThumb: CGFloat = 10

    // MARK: Control heights

    static let ctaPrimary: CGFloat = 52
    static let ctaDetail: CGFloat = 48
    static let ctaSecondary: CGFloat = 46
    /// Search field and filter button.
    static let field: CGFloat = 40
    static let backButton: CGFloat = 38
    static let ratingSegment: CGFloat = 34
    static let headerPill: CGFloat = 30
    static let toggle: CGFloat = 28

    // MARK: Covers

    static let coverRowWidth: CGFloat = 118
    static let coverRowWidthCompact: CGFloat = 100
    static let coverDetailRowWidth: CGFloat = 106
    static let coverDetailHeroWidth: CGFloat = 126
    static let coverSeedWidth: CGFloat = 82
    static let coverSavedStripWidth: CGFloat = 74
    static let coverUpcomingThumb: CGFloat = 52

    /// Every cover in the app is 2:3.
    static let coverAspect: CGFloat = 2.0 / 3.0

    // MARK: Content insets
    //
    // The tab capsule floats over content, so scroll views need bottom room or
    // the last row hides behind it.
    static let scrollTopInset: CGFloat = 106
    static let scrollBottomInset: CGFloat = 150
}

extension View {
    /// A 0.5pt border, which is what the spec calls for everywhere.
    func hairlineBorder(_ color: Color, radius: CGFloat) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(color, lineWidth: 0.5)
        )
    }
}
