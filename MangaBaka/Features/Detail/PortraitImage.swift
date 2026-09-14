import SwiftUI

/// A character or voice-actor portrait, over `CoverStore`.
///
/// `AsyncImage` was the bug `CoverStore` was written to fix, and the portraits
/// kept it. `AsyncImage` cancels its own load the moment the view scrolls out
/// of a horizontal row, and remembers the resulting `.failure` per view
/// identity — so a portrait that lost that race stayed a grey square for the
/// life of the screen, no matter how many times the reader scrolled it back.
/// That is the same failure already fixed once for covers (item 121);
/// `CoverStore` caches the decoded image and `.task(id:)` retries on
/// scroll-back.
///
/// Square, because every call site frames a portrait square and crops it to a
/// rounded shape of its own choosing — the caller keeps the clip so the row's
/// 16pt rounded square and the sheet's 36pt circle stay their own decisions.
struct PortraitImage: View {
    let url: URL?
    let size: CGFloat

    @State private var loaded: UIImage?
    /// Kept apart from `loaded` so the fade can start a tick after the decode,
    /// the same two-step `CoverImage` uses.
    @State private var isReady = false

    var body: some View {
        ZStack {
            Palette.imagePlaceholder
            if let loaded {
                Image(uiImage: loaded)
                    .resizable()
                    .scaledToFill()
                    // Portrait art is a photograph, not UI: Smart Invert must
                    // leave it alone, same as `CoverImage`.
                    .accessibilityIgnoresInvertColors()
                    .appearsSoftly(when: isReady)
            }
        }
        // Top-aligned, because these portraits are taller than they are wide
        // and the face is at the top of them. Centring the crop — what a plain
        // fill does — trades the head for the torso.
        .frame(width: size, height: size, alignment: .top)
        .clipped()
        .accessibilityHidden(true)
        // Keyed on the URL so a recycled cell loads its own portrait rather
        // than keeping the previous one's.
        .task(id: url) {
            guard let image = await CoverStore.shared.image(for: url) else { return }
            loaded = image
            isReady = true
        }
    }
}
