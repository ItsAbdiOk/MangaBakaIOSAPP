import SwiftUI

/// The quick actions a cover can offer on a hold: Save, Mark read, Open.
///
/// These live in the cover's context menu, beside "Copy cover"
/// (`CopyableArtwork`), since 2026-09-13. They were a glass pill hung under
/// the cover by a long-press gesture of their own — complete, tested, and
/// presented nowhere (R F3): `CoverImage` took the actions and no screen
/// passed any, and the pill's press competed with the card's context menu
/// for the same hold (`CopyableArtwork`'s own warning). One hold, one menu:
/// the system's, which draws itself clear of the cover and reads to
/// VoiceOver without a custom-actions rotor.
///
/// What is left here is the decision — which actions exist and in what
/// order — kept pure so the menu's contents have a test without a menu.
enum CoverQuickActions {
    /// What a cover can do on a hold. Every field is optional, and the menu
    /// shows only the ones that are set — a cover with nothing to offer
    /// passes nil to `copyableArtwork(_:noun:quickActions:)` and gets the
    /// copy alone.
    struct Actions {
        var save: (() -> Void)?
        var markRead: (() -> Void)?
        var open: (() -> Void)?

        init(save: (() -> Void)? = nil, markRead: (() -> Void)? = nil, open: (() -> Void)? = nil) {
            self.save = save
            self.markRead = markRead
            self.open = open
        }
    }

    /// One action's face in the menu: what it is called and which glyph
    /// stands for it. Not `Actions` itself, so `visibleActions` can return an
    /// ordered, `Equatable` list without dragging non-equatable closures
    /// into a test assertion.
    struct Item: Equatable {
        let title: String
        let systemImage: String
    }

    /// Which of `actions`' closures are set, as the menu should show them:
    /// Save, then Mark read, then Open, skipping whatever is nil.
    nonisolated static func visibleActions(_ actions: Actions) -> [Item] {
        var items: [Item] = []
        if actions.save != nil {
            items.append(Item(title: "Save", systemImage: "bookmark"))
        }
        if actions.markRead != nil {
            items.append(Item(title: "Mark read", systemImage: "checkmark.circle"))
        }
        if actions.open != nil {
            items.append(Item(title: "Open", systemImage: "arrow.up.right"))
        }
        return items
    }

    /// Runs whichever closure `item` names. `visibleActions` is the only
    /// place that decides an item exists at all, so this is the one place
    /// that has to agree with it on the name.
    static func perform(_ item: Item, in actions: Actions) {
        switch item.title {
        case "Save": actions.save?()
        case "Mark read": actions.markRead?()
        case "Open": actions.open?()
        default: break
        }
    }
}
