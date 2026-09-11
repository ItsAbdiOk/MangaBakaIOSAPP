import SwiftUI

/// The series title in the navigation bar, which stays out of the way until
/// the page's own title has gone.
///
/// The detail page showed BOTH before anything had moved: the inline
/// navigation title, and the same words again at 24pt a few points below it.
/// On the device they overlapped the moment you scrolled, with cover artwork
/// bleeding through both.
///
/// iOS does this for free for a large title — the bar's copy fades in as the
/// large one leaves. The hero here is not a large title, so the same effect is
/// built by hand: `navigationTitle` is kept, because it is what labels the
/// back button on the previous screen and what VoiceOver reads as the screen's
/// name, and the visible copy is a principal item that fades.
struct DetailBarTitle: ViewModifier {
    let title: String
    /// The page's link for the share sheet; nothing shown when nil.
    var shareURL: URL?
    /// How far the hero has to travel before its own title is gone. Measured
    /// against the hero on an iPhone 16 Pro rather than picked: the title sits
    /// beside the cover, and the bar's copy should arrive as it leaves.
    static let heroTitleTravel: CGFloat = 150

    @State private var heroTitleIsHidden = false

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top
            } action: { _, travelled in
                let hidden = travelled > Self.heroTitleTravel
                if hidden != heroTitleIsHidden {
                    Motion.run(.easeOut(duration: 0.2)) { heroTitleIsHidden = hidden }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // The series' page on mangabaka.org, which is the link that
                // will open in the app once the site hosts the association
                // file. Until then it opens the site, which is still the
                // right page.
                if let shareURL {
                    ToolbarItem(placement: .topBarTrailing) {
                        ShareLink(item: shareURL, subject: Text(title)) {
                            Image(systemName: "square.and.arrow.up")
                                // The back button beside it is white; an
                                // accent glyph there read as a different
                                // kind of control.
                                .foregroundStyle(Palette.textPrimary)
                        }
                        .accessibilityLabel("Share \(title)")
                    }
                }
                ToolbarItem(placement: .principal) {
                    Text(title)
                        .typeRowTitle()
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(1)
                        .opacity(heroTitleIsHidden ? 1 : 0)
                        // Announcing a title the reader cannot see would make
                        // VoiceOver read the same words twice on this screen.
                        .accessibilityHidden(!heroTitleIsHidden)
                }
            }
    }
}

extension View {
    func detailBarTitle(_ title: String, shareURL: URL? = nil) -> some View {
        modifier(DetailBarTitle(title: title, shareURL: shareURL))
    }
}
