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
    static let radiusStackNeighbour: CGFloat = 14
    static let radiusBadge: CGFloat = 10
    static let radiusSavedThumb: CGFloat = 9
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

    // MARK: The stack, as the mockup specifies it

    /// The card area's fixed height. The cards centre inside it.
    static let stackArea: CGFloat = 452
    static let stackCardWidth: CGFloat = 268
    /// The neighbouring covers that peek in from either side.
    static let stackNeighbourWidth: CGFloat = 132
    /// How far off-screen they sit, so only an edge shows.
    static let stackNeighbourInset: CGFloat = 56
    static let stackNeighbourOpacity: CGFloat = 0.3

    static let actionSkip: CGFloat = 56
    static let actionDetails: CGFloat = 48
    static let actionSave: CGFloat = 64
    static let actionGap: CGFloat = 16

    // MARK: The floating chrome

    /// One tab inside the capsule.
    static let tabWidth: CGFloat = 62
    static let tabIcon: CGFloat = 21
    /// The capsule's own padding around its tabs.
    static let tabCapsulePadding: CGFloat = 6
    /// Between the capsule and the search button beside it.
    static let tabCapsuleGap: CGFloat = 10
    /// How far the whole assembly sits off the bottom.
    static let tabBarBottomInset: CGFloat = 30
    static let searchButton: CGFloat = 58
    static let coverUpcomingThumb: CGFloat = 52

    /// Every cover in the app is 2:3.
    static let coverAspect: CGFloat = 2.0 / 3.0

    // MARK: Content insets
    //
    // The tab capsule floats over content, so scroll views need bottom room or
    // the last row hides behind it.
    static let scrollTopInset: CGFloat = 106

    /// Bottom room for the floating tab bar.
    ///
    /// Content scrolling *under* the translucent bar is intended — that is what
    /// Liquid Glass is for. The bug is content that can never scroll clear of
    /// it: with only a few points of padding, the last line of the last row
    /// stays permanently behind the glass and cannot be read.
    ///
    /// Sized to the capsule plus the home indicator rather than guessed: the
    /// bar is 62pt tall and sits 22pt from the bottom, and a little slack keeps
    /// a descender off the edge.
    static let tabBarClearance: CGFloat = 96
    static let scrollBottomInset: CGFloat = 150
}

extension View {
    /// A 0.5pt border, which is what the spec calls for everywhere.
    ///
    /// The overlay is explicitly not hit-testable. It is decoration sitting on
    /// top of its content, and both places this wraps hold interactive controls
    /// — a stroke that competes for touches makes buttons and switches feel
    /// broken for no visible reason.
    func hairlineBorder(_ color: Color, radius: CGFloat) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(color, lineWidth: 0.5)
                .allowsHitTesting(false)
        )
    }
}
