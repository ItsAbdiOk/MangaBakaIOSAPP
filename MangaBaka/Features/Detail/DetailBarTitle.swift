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
    /// The page's one scroll observer — see `ScrollTracker`. This modifier
    /// used to mount a second `onScrollGeometryChange` of its own and
    /// recompute the same number the backdrop was already being told
    /// (item 54); now it reads the crossfade the tracker keeps.
    let tracker: ScrollTracker
    /// How far the hero has to travel before its own title is gone. Measured
    /// against the hero on an iPhone 16 Pro rather than picked: the title sits
    /// beside the cover, and the bar's copy should arrive as it leaves.
    nonisolated static let heroTitleTravel: CGFloat = 150

    /// 0 while the hero title is fully on screen, 1 once it has travelled
    /// out. A continuous value, not a flip: the bar's copy fades in over the
    /// last `crossfadeSpan` points of the hero's travel, so the handover
    /// reads as one title moving rather than two cutting.
    private var crossfade: CGFloat { tracker.crossfade }

    /// How many points of travel the fade takes. A guess: long enough to
    /// read as a fade at scroll speed, short enough that the bar copy is
    /// solid by the time the hero is gone.
    nonisolated static let crossfadeSpan: CGFloat = 60

    /// Maps travel to 0…1, finishing exactly at `heroTitleTravel`.
    nonisolated static func crossfadeProgress(travelled: CGFloat) -> CGFloat {
        let start = heroTitleTravel - crossfadeSpan
        return min(max((travelled - start) / crossfadeSpan, 0), 1)
    }

    private var heroTitleIsHidden: Bool { crossfade >= 1 }

    /// Whether the bar's copy is in the view at all.
    ///
    /// It used to be mounted always and drawn at `opacity(crossfade)`, so at
    /// the top of the page — where every reader starts, and where the
    /// accessibility audit measures — a fully transparent copy of the title
    /// sat in the layout at 72,76 200x16. Apple's audit on 2026-09-13 filed
    /// three separate issues against it there: "Contrast failed" (nothing
    /// against nothing), "Text clipped" (the `lineLimit(1)` below) and
    /// "Dynamic Type font sizes are partially unsupported". None of the three
    /// is something a reader meets: at that scroll position the words are
    /// invisible, and the hero is showing the same title at 24pt a few points
    /// below. An element drawn at zero opacity should not be in the tree.
    ///
    /// `> 0` rather than a threshold, so the fade itself is untouched — the
    /// copy mounts on the first frame of the crossfade and leaves on the last.
    /// `accessibilityHidden` is still applied while it fades, for the reason
    /// recorded below.
    nonisolated static func showsBarTitle(crossfade: CGFloat) -> Bool { crossfade > 0 }

    func body(content: Content) -> some View {
        content
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
                    if Self.showsBarTitle(crossfade: crossfade) {
                        Text(title)
                            .typeRowTitle()
                            .foregroundStyle(Palette.textPrimary)
                            .lineLimit(1)
                            .opacity(crossfade)
                            // Announcing a title the reader cannot see would
                            // make VoiceOver read the same words twice on
                            // this screen.
                            .accessibilityHidden(!heroTitleIsHidden)
                    }
                }
            }
    }
}

extension View {
    func detailBarTitle(
        _ title: String, shareURL: URL? = nil, tracker: ScrollTracker
    ) -> some View {
        modifier(DetailBarTitle(title: title, shareURL: shareURL, tracker: tracker))
    }
}
