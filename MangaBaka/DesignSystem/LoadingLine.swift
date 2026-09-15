import SwiftUI

/// A hairline under the title bar that says "still asking", for a screen
/// whose sections fill in from several requests.
///
/// Asked for by Abdi (2026-09-15): a series page fires eight requests and the
/// last to answer (Apple's volumes, the cast, a throttled covers leg waiting
/// out its window) lands seconds after the page reads as done, so a section
/// that then pops in looks like a glitch rather than an arrival. The line is
/// the one place that says the page is still filling in, and it goes the
/// moment the last leg answers or fails — it is never over content that is
/// settled.
///
/// Indeterminate: a soft band gliding left to right on a two-second loop, a
/// guess tuned by feel. Under Reduce Motion the band stands still — the
/// line still shows, because "still loading" is information, and only the
/// movement is what the setting asks to be spared.
struct LoadingLine: View {
    var isActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Two points: the same weight as the hard scroll edge it sits under.
    private static let height: CGFloat = 2
    /// The loop, and how wide the band is as a share of the line.
    private static let loop: TimeInterval = 2.0
    private static let bandShare: CGFloat = 0.35

    var body: some View {
        // Kept in the tree either way so the fade out is a fade, not a cut
        // — `if isActive` would remove the view before it could animate.
        GeometryReader { proxy in
            Group {
                if reduceMotion {
                    band(width: proxy.size.width)
                } else {
                    // DT4/S7: `.animation` alone re-evaluates every frame for
                    // as long as this view is in the tree, whether or not it
                    // is visible — at `opacity(isActive ? 1 : 0)` that is a
                    // moving gradient layer holding the display at its top
                    // refresh rate for the page's whole life after the last
                    // leg has answered. `paused: !isActive` stops the clock
                    // the instant it goes inactive; the fade above still
                    // animates because `.opacity`/`.animation` are unrelated
                    // to the timeline schedule — the band just freezes
                    // mid-position while it fades out, which is invisible at
                    // opacity → 0.
                    TimelineView(.animation(paused: !isActive)) { timeline in
                        let phase = timeline.date.timeIntervalSinceReferenceDate
                            .truncatingRemainder(dividingBy: Self.loop) / Self.loop
                        band(width: proxy.size.width)
                            // From fully off the left to fully off the right.
                            .offset(x: (CGFloat(phase) * (1 + Self.bandShare) - Self.bandShare)
                                * proxy.size.width)
                    }
                }
            }
        }
        .frame(height: Self.height)
        .clipped()
        .opacity(isActive ? 1 : 0)
        .animation(Motion.reduced(Motion.settle), value: isActive)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func band(width: CGFloat) -> some View {
        LinearGradient(
            colors: [.clear, Palette.accent, .clear],
            startPoint: .leading, endPoint: .trailing
        )
        .frame(width: width * Self.bandShare)
    }
}
