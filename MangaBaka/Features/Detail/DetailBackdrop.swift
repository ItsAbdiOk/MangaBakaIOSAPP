import SwiftUI
import UIKit

/// The blurred, over-saturated wash the mockup puts behind a series page, so
/// the page takes its colour from the artwork instead of sitting on flat
/// black.
///
/// It is a background on the whole scroll view rather than a layer inside the
/// hero, because the mockup runs it up under the navigation bar — the bar
/// there is transparent and the back button floats on the artwork. Drawn
/// inside the hero it stopped at the safe area and left a black band above,
/// which made the page read as two screens stacked.
struct DetailBackdrop: View {
    /// The mockup's numbers, named so a test can hold them rather than grep
    /// for literals in this file. Measured against the design board, not
    /// derived; changing one changes the page's whole tone.
    nonisolated static let scale: CGFloat = 1.6
    nonisolated static let blurRadius: CGFloat = 72
    nonisolated static let saturation: Double = 1.7
    nonisolated static let opacity: Double = 0.34

    let cover: Cover
    /// How tall the wash is. Beyond the hero it is solid ground anyway, and
    /// blurring a full-page image costs more the taller it is.
    var height: CGFloat = 420
    /// The page's scroll position, for the few points of parallax below —
    /// see `parallaxOffset`. Passed in rather than read here: this view sits
    /// in `.background` on the ScrollView itself (see the type doc comment),
    /// outside the scrolled content, where `.parallax()` from
    /// `MotionModifiers` — built on `.scrollTransition`, which only ever
    /// fires for a view inside the scrolled content — cannot reach it.
    ///
    /// A `ScrollTracker` rather than a plain `CGFloat` so the per-frame write
    /// invalidates this view and nothing else (item 54). Nil where there is
    /// no parallax to do — `CoverGallery` draws two of these as a static
    /// wash behind its pager.
    var tracker: ScrollTracker?

    @Environment(\.displayScale) private var displayScale
    /// Flips once the AsyncImage phase reports `.success` — see
    /// `appearsSoftly(when:)` on the image layer below.
    @State private var isImageReady = false

    /// A few points of drift against scroll, capped at 6pt per the motion
    /// brief — past that a wash this large stopped reading as depth and
    /// started reading as misregistration, the same ceiling `.parallax()`
    /// itself enforces. Nil movement under Reduce Motion.
    /// `isReduced` is injectable, the same reasoning `Motion.reduced` gives
    /// its own parameter: `DetailMotionTests` pins the clamp and the sign
    /// without depending on this machine's own accessibility settings.
    nonisolated static func parallaxOffset(
        scrollOffset: CGFloat, amount: CGFloat = 6, isReduced: Bool = Motion.isReduced
    ) -> CGFloat {
        guard !isReduced else { return 0 }
        // A GUESS: the wash drifts at 5% of the foreground's own scroll
        // distance, clamped to `amount` — enough to read as a background
        // plane moving slower than the content in front of it, not enough
        // that a long scroll drags it visibly off its own image.
        return max(-amount, min(amount, scrollOffset * -0.05))
    }

    /// The colour the wash shows before its own blurred cover has finished
    /// loading — the DC term of the cover's BlurHash, boosted the same way
    /// `RowAmbient.tint` lifts a row's averaged colour off grey. Returned as
    /// HSB components rather than a `Color` so `DetailMotionTests` can
    /// assert on it without resolving a `Color` value.
    ///
    /// Duplicated from `RowAmbient` rather than shared: that type takes a
    /// row of `Series` and averages several covers, and it lives in
    /// `Features/Shared`, outside this batch's file list — there is nowhere
    /// this batch can put a helper both files would reach.
    struct AmbientTint: Equatable, Sendable {
        var hue: Double
        var saturation: Double
        var brightness: Double
    }

    nonisolated static func ambientTint(for cover: Cover) -> AmbientTint? {
        guard let hash = cover.blurhash, let average = BlurHash.averageColour(of: hash) else {
            return nil
        }
        let colour = UIColor(red: average.red, green: average.green, blue: average.blue, alpha: 1)
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0
        colour.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)
        return AmbientTint(
            hue: hue,
            saturation: min(1, saturation * 2.2 + 0.2),
            brightness: max(brightness, 0.7)
        )
    }

    private var ambientColour: Color? {
        Self.ambientTint(for: cover).map {
            Color(hue: $0.hue, saturation: $0.saturation, brightness: $0.brightness)
        }
    }

    /// `scale` before `blur` — blurring first leaves the edges transparent and
    /// the corners of the page read as lighter than the middle.
    var body: some View {
        GeometryReader { proxy in
            // Deliberately not CoverImage: that frames every cover at a fixed
            // 2:3 and adds a shadow, both wrong for a full-bleed wash, and its
            // placeholder would paint a grey rectangle behind the hero on a
            // slow connection rather than nothing.
            // The wash's own height, not the ScrollView's: `height` caps it
            // (see the property), so asking the CDN for a full-page image
            // downloads and blurs artwork nobody sees.
            let washHeight = min(height, proxy.size.height)
            let url = cover.url(forHeight: washHeight, scale: displayScale)
            ZStack {
                // The ambient tint, always in place under the image layer —
                // it is what a reader sees for however long the network
                // takes, in place of the flat ground the wash used to have
                // nothing else to fall back to.
                // No `.opacity` of its own: the whole `ZStack` (this tint and
                // the image both) gets `Self.opacity` together, below, so
                // the handover from one to the other doesn't change the
                // wash's overall strength.
                if let ambientColour {
                    ambientColour
                }
                AsyncImage(url: url) { phase in
                    switch phase {
                    case let .success(image):
                        image.resizable().scaledToFill()
                            .accessibilityIgnoresInvertColors()
                            .onAppear { isImageReady = true }
                    default:
                        Color.clear
                    }
                }
                .appearsSoftly(when: isImageReady)
            }
            // `height` applied at last. It was declared, documented
            // ("blurring a full-page image costs more the taller it is") and
            // never read, so a 72pt Gaussian ran over the whole scroll view
            // on a 1.6x-scaled layer, every frame (item 55). Top-aligned:
            // below the hero the page is solid ground anyway, which
            // `SeriesDetailView` paints behind this.
            .frame(width: proxy.size.width, height: washHeight, alignment: .top)
            .scaleEffect(Self.scale)
            .blur(radius: Self.blurRadius, opaque: false)
            .saturation(Self.saturation)
            .opacity(Self.opacity)
            .overlay {
                LinearGradient(
                    stops: [
                        .init(color: Palette.ground.opacity(0.55), location: 0),
                        .init(color: Palette.ground.opacity(0.28), location: 0.26),
                        .init(color: Palette.ground.opacity(0.88), location: 0.74),
                        .init(color: Palette.ground, location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .clipped()
            // Flattened before the parallax moves it, so a scroll frame
            // offsets one finished bitmap instead of re-running the blur,
            // the saturation and the gradient (item 55). It is also what
            // makes `CoverGallery`'s cross-fade of two of these blend two
            // rendered layers rather than two live blur pipelines.
            .compositingGroup()
            .offset(y: Self.parallaxOffset(scrollOffset: tracker?.offset ?? 0))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
