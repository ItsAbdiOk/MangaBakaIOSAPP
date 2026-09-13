import SwiftUI
import UIKit

/// Hold artwork, copy it.
///
/// The system's own long-press menu, so it behaves the way every other image on
/// the phone does: hold, the artwork lifts, "Copy image" appears, and it lands
/// in Messages or Notes as an image rather than a link.
///
/// Opt-in rather than applied to every cover, for one concrete reason: the
/// swipe stack is a drag surface, and a context menu on its cards competes with
/// the drag for the same press. It is turned on where a cover is something to
/// look at — a series page, the gallery, a character portrait — and left off
/// where a cover is something to throw.
private struct CopyableArtwork: ViewModifier {
    let url: URL?
    /// What the menu item says, and what the toast confirms: "cover", "art",
    /// "portrait". Named so the reader knows which of the images they held.
    let noun: String
    /// Save / Mark read / Open ahead of the copy, when the surface offers
    /// them — one menu on one hold, rather than the pill `CoverQuickActions`
    /// used to hang under the cover on the same press (R F3).
    let quickActions: CoverQuickActions.Actions?

    @Environment(ToastCentre.self) private var toasts: ToastCentre?

    func body(content: Content) -> some View {
        content.contextMenu {
            if let quickActions {
                ForEach(CoverQuickActions.visibleActions(quickActions), id: \.title) { item in
                    Button {
                        CoverQuickActions.perform(item, in: quickActions)
                    } label: {
                        Label(item.title, systemImage: item.systemImage)
                    }
                }
            }
            if url != nil {
                Button {
                    copy()
                } label: {
                    Label("Copy \(noun)", systemImage: "doc.on.doc")
                }
            }
        }
    }

    private func copy() {
        guard let url else { return }
        // The already-decoded image where there is one, so the common case is
        // instant and does not go back to the network for something already on
        // screen. Otherwise fetch it — which is also how the full-size original
        // arrives, since what is on screen is a thumbnail.
        if let cached = CoverStore.shared.cached(url) {
            UIPasteboard.general.image = cached
            toasts?.show("Copied")
            return
        }
        Task {
            guard let image = await CoverStore.shared.image(for: url) else {
                toasts?.show("Could not copy that one")
                return
            }
            UIPasteboard.general.image = image
            toasts?.show("Copied")
        }
    }
}

extension View {
    /// Adds "Copy \(noun)" to a long press on this artwork.
    ///
    /// - Parameter url: the image to copy — the ORIGINAL where one exists, not
    ///   the thumbnail being displayed. Someone pasting a cover into a message
    ///   wants the artwork, not a 150-point rendering of it.
    /// - Parameter quickActions: Save / Mark read / Open, listed ahead of
    ///   the copy; nil for a surface with nothing to offer but the artwork.
    func copyableArtwork(
        _ url: URL?, noun: String = "cover", quickActions: CoverQuickActions.Actions? = nil
    ) -> some View {
        modifier(CopyableArtwork(url: url, noun: noun, quickActions: quickActions))
    }
}
