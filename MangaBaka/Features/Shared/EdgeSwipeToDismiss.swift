import SwiftUI

/// Swipe from the left edge to leave, on a screen that is not pushed.
///
/// iOS gives the edge-swipe to pushed screens and drag-down to sheets, and a
/// reader does not think in those terms: they think "I came in from the right,
/// I go back to the left". Reported on 2026-09-10 about the screens with search
/// fields on them, which are exactly the ones presented as sheets — the tag
/// pickers and the seed picker.
///
/// Deliberately narrow. It only starts tracking within 20 points of the
/// leading edge, only once the movement is clearly sideways, and only
/// commits on release past a third of the sheet's width or a fast enough
/// flick (see `shouldDismiss`): a sheet full of horizontally scrolling chips
/// must not lose them to this, and neither must the drag-down the sheet
/// already has.
///
/// **Interactive**, per the motion brief: the sheet now follows the finger
/// (`Motion.glide`, the scroll-linked spring with no overshoot) rather than
/// staying put until a single `onEnded` decides pass or fail, and it answers
/// the drag by either sliding back (`Motion.settle`) or finishing the exit
/// (`Motion.snappy`) — see `shouldDismiss(offset:velocity:width:)` for which.
/// Not `private`: `shouldDismiss` and `clampedOffset` are tested from
/// `MangaBakaTests`, which needs at least internal visibility to reach them
/// through `@testable import`.
struct EdgeSwipeToDismiss: ViewModifier {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.layoutDirection) private var direction

    @State private var width: CGFloat = 0
    /// How far the sheet has been dragged, in the reading direction (already
    /// sign-flipped for right-to-left — see `horizontal(_:)`). 0 while at
    /// rest.
    @State private var dragOffset: CGFloat = 0
    /// Set once a drag has actually started from the leading edge, so a
    /// vertical scroll or a horizontal chip-row drag that started elsewhere
    /// on the sheet never moves this view at all — only a leading-edge drag
    /// commits to owning the gesture.
    @State private var isTrackingEdgeDrag = false

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
            .offset(x: direction == .rightToLeft ? -dragOffset : dragOffset)
            .simultaneousGesture(
                DragGesture(minimumDistance: 20, coordinateSpace: .local)
                    .onChanged { value in
                        if !isTrackingEdgeDrag {
                            // Only the first frame that clears the 20pt
                            // `minimumDistance` decides whether this drag
                            // belongs to the edge swipe at all — a drag that
                            // did not start near the edge, or is not moving
                            // mostly sideways yet, releases the gesture
                            // rather than dragging the sheet from wherever
                            // it happened to begin. This is what keeps a
                            // vertical scroll starting near the edge, or a
                            // row of horizontally scrolling chips, from
                            // being read as this gesture instead.
                            guard isFromLeadingEdge(value, in: width), isSideways(value) else { return }
                            isTrackingEdgeDrag = true
                        }
                        Motion.run(Motion.glide) {
                            dragOffset = Self.clampedOffset(horizontal(value.translation.width), width: width)
                        }
                    }
                    .onEnded { value in
                        defer { isTrackingEdgeDrag = false }
                        guard isTrackingEdgeDrag || isFromLeadingEdge(value, in: width) else { return }
                        let flickWidth = value.predictedEndTranslation.width - value.translation.width
                        let commits = Self.shouldDismiss(
                            offset: dragOffset,
                            velocity: horizontal(flickWidth),
                            width: width
                        )
                        if commits {
                            // `Motion.snappy`: finishing the exit is answering
                            // a completed gesture, the same category taps and
                            // toggles are in — not content settling.
                            Motion.run(Motion.snappy) {
                                dragOffset = direction == .rightToLeft ? -width : width
                            }
                            // One run loop so the offset above actually
                            // reaches the screen before the view is torn
                            // down — a same-frame `dismiss()` would cut the
                            // slide-out short.
                            Task {
                                try? await Task.sleep(for: .milliseconds(16))
                                dismiss()
                            }
                        } else {
                            Motion.run(Motion.settle) { dragOffset = 0 }
                        }
                    }
            )
    }

    private func isFromLeadingEdge(_ value: DragGesture.Value, in width: CGFloat) -> Bool {
        // Mirrored in Arabic and Hebrew, where "back" is the other way.
        direction == .rightToLeft
            ? value.startLocation.x > width - 20
            : value.startLocation.x < 20
    }

    /// The drag's horizontal component, sign-flipped in right-to-left so
    /// "positive" always means "toward dismissing", the same convention
    /// `shouldDismiss` and `clampedOffset` share.
    private func horizontal(_ rawWidth: CGFloat) -> CGFloat {
        direction == .rightToLeft ? -rawWidth : rawWidth
    }

    /// Whether a drag not yet committed to this gesture is moving mostly
    /// sideways rather than up or down — a chip row's own horizontal scroll
    /// and the sheet's drag-down both start with *some* movement in this
    /// gesture's direction too, so this is a bias check, not a purity one.
    private func isSideways(_ value: DragGesture.Value) -> Bool {
        abs(horizontal(value.translation.width)) > abs(value.translation.height)
    }

    /// Never lets the sheet drag backwards past its resting position, or
    /// further than fully off-screen — both of which a fast, imprecise
    /// finger can otherwise ask for.
    nonisolated static func clampedOffset(_ raw: CGFloat, width: CGFloat) -> CGFloat {
        guard width > 0 else { return max(0, raw) }
        return min(max(0, raw), width)
    }

    /// Whether a drag that just ended should finish the dismiss rather than
    /// spring back — the pure decision behind the `onEnded` branch above, so
    /// it is testable without driving an actual `DragGesture`.
    ///
    /// Two ways in, matching how every other swipe-to-commit gesture in this
    /// app already reads a release (the mix's own card throw): dragged more
    /// than a third of the way, or moving fast even if not yet halfway — a
    /// flick reads as "let go", not as "changed their mind three inches in".
    /// `width <= 0` (not yet measured) never commits: with no known width
    /// "a third of the way" cannot be computed honestly, and refusing to
    /// dismiss loses nothing a reader cannot repeat, where a wrong dismiss
    /// cannot be undone.
    nonisolated static func shouldDismiss(offset: CGFloat, velocity: CGFloat, width: CGFloat) -> Bool {
        guard width > 0 else { return false }
        if offset > width / 3 { return true }
        return velocity > 700 && offset > 0
    }
}

extension View {
    /// Adds the back-swipe to a sheet, which does not have one.
    func edgeSwipeToDismiss() -> some View {
        modifier(EdgeSwipeToDismiss())
    }
}
