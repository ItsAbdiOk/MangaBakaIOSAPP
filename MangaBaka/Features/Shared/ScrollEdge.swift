import SwiftUI

/// A scroll edge for screens that draw their own title inside a `ScrollView`.
///
/// iOS gives a navigation bar a scroll edge effect for free: content passing
/// underneath is blurred and dimmed, so the clock, the Dynamic Island and the
/// bar's own text stay legible. Three of the four tab roots draw the mockup's
/// title inside the scroll view and have no navigation bar, so they never got
/// one. Search is the exception since 2026-09-13: its `.searchable` field
/// needs a real bar (UX#6), so that tab lets iOS draw the edge and does not
/// use this.
///
/// On the device that was the worst-looking defect in the app: a library row
/// title cut in half by the Dynamic Island with the clock printed over the
/// words, and a series detail rendering its large title and its inline title on
/// top of each other with cover art bleeding through both.
///
/// A ground-coloured gradient rather than a system material on purpose. The
/// app's ground is `#08080B`; `.ultraThinMaterial` over it renders as a pale
/// grey band, which reads as a mistake rather than as depth.
enum ScrollEdge {
    /// Below this the screen is at rest and the scrim would be a band of solid
    /// colour over nothing.
    static let fadeIn: CGFloat = 12

    /// How opaque the edge is for a given scroll travel.
    ///
    /// Pulled out of the view so the behaviour that matters can be asserted
    /// without rendering anything: nothing at rest, fully in before a line of
    /// text has passed under the island, and never overshooting.
    static func opacity(forTravel travelled: CGFloat) -> Double {
        Double(min(1, max(0, travelled / fadeIn)))
    }

    /// The scroll offset, reduced to the only part of it the scrim can see.
    ///
    /// `opacity(forTravel:)` is pinned at 1 from `fadeIn` onward and at 0
    /// below zero, so every sample outside [0, 12] renders identically. Applied
    /// in the `onScrollGeometryChange` transform rather than in the action, the
    /// stored value stops changing once the reader is 12pt down — and an
    /// `onScrollGeometryChange` whose value does not change does not run its
    /// action. Before this the action ran a `withAnimation` for every scroll
    /// sample of a 2000pt fling, all but the first few redrawing the same
    /// fully-opaque scrim.
    static func travel(forOffset offset: CGFloat) -> CGFloat {
        min(max(0, offset), fadeIn)
    }

    /// The status bar and Dynamic Island's height on this device.
    @MainActor static var windowTopInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }?
            .safeAreaInsets.top ?? 0
    }
}

private struct ScrollEdgeScrim: ViewModifier {
    /// How far the content has travelled under the edge, clamped to the range
    /// that changes anything. Only the first few points matter: the scrim is
    /// fully in before anything has moved a line.
    @State private var travelled: CGFloat = 0
    /// The safe-area inset, read on appear rather than per frame. It is a
    /// property of the window, not of the scroll position, and it was being
    /// recomputed by walking
    /// `connectedScenes` → `windows` → `first(where: isKeyWindow)` twice per
    /// `scrim` evaluation — i.e. twice per scroll tick, on the three busiest
    /// screens. Re-read on every appear rather than once per process so a
    /// rotation or a Stage-Manager-style resize between appearances is picked
    /// up; it cannot change while a scroll is in flight.
    @State private var topInset: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .onAppear { topInset = ScrollEdge.windowTopInset }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                ScrollEdge.travel(
                    forOffset: geometry.contentOffset.y + geometry.contentInsets.top
                )
            } action: { _, offset in
                // `Motion.glide` — fully damped, no overshoot — rather than
                // a bare assignment: the scrim used to snap to each scroll
                // sample, which reads as flicker over the twelve points it
                // has to travel. A guess: this is scroll-linked but not
                // itself a drag-follow, so it gets a curve rather than
                // `.interactive`.
                withAnimation(Motion.reduced(Motion.glide)) {
                    travelled = offset
                }
            }
            .overlay(alignment: .top) { scrim }
    }

    private var scrim: some View {
        // Not measured with a GeometryReader. Inside a ScrollView's overlay the
        // safe area has already been consumed and propagated to the content, so
        // a reader there reports `top == 0` even when it ignores the safe area
        // — measured, and it rendered a 14pt band above the clock instead of a
        // scrim behind it. The window is the only thing here that still knows.
        let height = topInset + Metrics.scrollEdgeFade
        // Solid for the whole safe area, then fading. Even stops would put the
        // half-way point of the fade inside the status bar, which is the part
        // that has to stay legible.
        return LinearGradient(
            stops: [
                .init(color: Palette.ground, location: 0),
                .init(color: Palette.ground, location: topInset / height),
                .init(color: Palette.ground.opacity(0), location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: height)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .opacity(ScrollEdge.opacity(forTravel: travelled))
        .allowsHitTesting(false)
        .ignoresSafeArea(edges: .top)
    }
}

extension View {
    /// Keeps the status bar and the Dynamic Island legible while content passes
    /// under them. For screens with no navigation bar of their own; a screen
    /// that has one should let iOS draw the edge instead.
    func scrollEdge() -> some View {
        modifier(ScrollEdgeScrim())
    }
}
