import SwiftUI

/// The browse screen, and the one thing that comes back out of it.
///
/// Browsing offers three ways in — a genre, a tag, a publisher — and every one
/// of them means the same thing to Search: replace the query with this. Wiring
/// three near-identical closures at the call site made `RootView` cross the
/// lint's body-length ceiling and said three times what this says once.
struct BrowseDestination: View {
    /// What the reader picked. Exactly one of these is ever set.
    struct Pick {
        var genre: String?
        var tag: String?
        var publisher: String?
    }

    let model: BrowseModel
    let blocked: BlockedTagsStore
    let catalogue: CatalogueService
    let onPick: (Pick) -> Void

    var body: some View {
        BrowseView(
            model: model,
            blocked: blocked,
            onPickGenre: { onPick(Pick(genre: $0.value)) },
            onPickTag: { onPick(Pick(tag: $0.name)) },
            catalogue: catalogue,
            onOpenPublisher: { onPick(Pick(publisher: $0.name)) }
        )
    }
}
