import SwiftUI

/// Swipe from the left edge to leave, on a screen that is not pushed.
///
/// iOS gives the edge-swipe to pushed screens and drag-down to sheets, and a
/// reader does not think in those terms: they think "I came in from the right,
/// I go back to the left". Reported on 2026-09-10 about the screens with search
/// fields on them, which are exactly the ones presented as sheets — the tag
/// pickers and the seed picker.
///
/// Deliberately narrow. It only starts within 20 points of the leading edge,
/// only commits after 70 points of movement, and only when the movement is
/// clearly sideways: a sheet full of horizontally scrolling chips must not lose
/// them to this, and neither must the drag-down the sheet already has.
private struct EdgeSwipeToDismiss: ViewModifier {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.layoutDirection) private var direction

    @State private var width: CGFloat = 0

    func body(content: Content) -> some View {
        content
            // Measured in the BACKGROUND, not by wrapping the content: a
            // GeometryReader around a sheet's body takes over its layout and
            // pins everything to the top-left. The width comes from the view
            // rather than the screen because a sheet is not the screen — on
            // iPad it is a long way from being it.
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .task(id: proxy.size.width) { width = proxy.size.width }
                }
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 20, coordinateSpace: .local)
                    .onEnded { value in
                        guard isFromLeadingEdge(value, in: width), isSideways(value) else { return }
                        dismiss()
                    }
            )
    }

    private func isFromLeadingEdge(_ value: DragGesture.Value, in width: CGFloat) -> Bool {
        // Mirrored in Arabic and Hebrew, where "back" is the other way.
        direction == .rightToLeft
            ? value.startLocation.x > width - 20
            : value.startLocation.x < 20
    }

    private func isSideways(_ value: DragGesture.Value) -> Bool {
        let horizontal = direction == .rightToLeft
            ? -value.translation.width
            : value.translation.width
        return horizontal > 70 && abs(value.translation.height) < horizontal
    }
}

extension View {
    /// Adds the back-swipe to a sheet, which does not have one.
    func edgeSwipeToDismiss() -> some View {
        modifier(EdgeSwipeToDismiss())
    }
}
