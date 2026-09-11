import SwiftUI

extension View {
    /// Makes a control reach Apple's 44pt minimum without changing how it
    /// looks.
    ///
    /// The mockup's chips are 30pt (`Metrics.headerPill`) and that is a
    /// deliberate number, not drift — so the pill keeps its height and the
    /// touch area grows around it. Apple's audit named eight of these by hand:
    /// the Library state chips, the sort control, the token field.
    ///
    /// Apply OUTSIDE the background, so the fill stays the size it was drawn.
    /// `contentShape` is what makes the grown area tappable rather than merely
    /// reserved.
    func tapTarget() -> some View {
        frame(minHeight: Metrics.tapTarget)
            .contentShape(Rectangle())
    }
}
