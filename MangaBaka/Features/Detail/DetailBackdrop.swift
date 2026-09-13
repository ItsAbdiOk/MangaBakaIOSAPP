import SwiftUI

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

    @Environment(\.displayScale) private var displayScale

    /// `scale` before `blur` — blurring first leaves the edges transparent and
    /// the corners of the page read as lighter than the middle.
    var body: some View {
        GeometryReader { proxy in
            // Deliberately not CoverImage: that frames every cover at a fixed
            // 2:3 and adds a shadow, both wrong for a full-bleed wash, and its
            // placeholder would paint a grey rectangle behind the hero on a
            // slow connection rather than nothing.
            let url = cover.url(forHeight: proxy.size.height, scale: displayScale)
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
                    .accessibilityIgnoresInvertColors()
            } placeholder: {
                Color.clear
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
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
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
