import SwiftUI

/// Liquid Glass surfaces.
///
/// The design spec gives a CSS approximation (`rgba(26,26,32,0.60)` plus a
/// 26px blur at 180% saturation) and says explicitly to use the system material
/// instead, because the real thing is adaptive and specular and hand-tuned blur
/// looks wrong beside it. So these use `.glassEffect`, and the CSS numbers are
/// recorded only as the intent they encode.
///
/// The spec also limits glass to exactly six things: the top bar, the tab
/// capsule, the search button, the filter sheet, the toast, and the stack's
/// back button — plus, as of the long-press quick actions
/// (`CoverQuickActions`), the small pill of actions a cover pops up on long
/// press. That pill is momentary and appears over content that has already
/// stopped scrolling (the reader is holding a finger down on it), so it does
/// not reopen the performance question the "nothing that scrolls is glass"
/// rule below is guarding against — but it does mean "exactly six" is now
/// seven, and whoever does the design pass this brief promised should decide
/// whether that stands. Nothing that scrolls is glass — that is a performance
/// decision as much as an aesthetic one, since live blur under a moving feed
/// is expensive on both GPU and battery.
enum Glass {
    /// Floating controls: the tab capsule and floating buttons.
    /// CSS intent: rgba(26,26,32,0.60), blur 26px, saturate 190%.
    static func floating<S: InsettableShape>(_ shape: S) -> some View {
        Color.clear
            .glassEffect(.regular, in: shape)
            .overlay(shape.strokeBorder(Palette.glassEdge, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.50), radius: 17, y: 14)
    }
}
