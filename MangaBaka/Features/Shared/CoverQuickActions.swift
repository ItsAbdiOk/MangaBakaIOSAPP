import SwiftUI

/// The long-press quick actions every cover can offer.
///
/// Deliberately not `.contextMenu`: the system menu is a flat list of text
/// rows that has to draw somewhere on screen, and on a cover as small as a
/// row's it tends to cover the very thing it names. This instead pops the
/// cover itself up a little and hangs a small glass pill of actions beneath
/// it, so the gesture reads as "here is what you can do with *this*" rather
/// than opening an unrelated menu.
///
/// `CoverImage` is the one call site that wires this in (`quickActions:`,
/// applied via `.coverQuickActions(_:)`), but the modifier is on `View`
/// precisely so nothing about that stays private to it — a row's own card,
/// or a future non-cover surface, can adopt the same gesture without
/// depending on `CoverImage`'s internals.
enum CoverQuickActions {
    /// What a cover can do on long-press. Every field is optional, and the
    /// pill shows only the ones that are set — a cover with nothing to
    /// offer here simply does not opt in at all (see `View.coverQuickActions`
    /// on a nil `Actions?`).
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

    /// One action's face in the pill: what it is called and which glyph
    /// stands for it. Not `Actions` itself, so `visibleActions` can return an
    /// ordered, `Equatable` list without dragging non-equatable closures
    /// into a test assertion.
    struct Item: Equatable {
        let title: String
        let systemImage: String
    }

    /// Which of `actions`' closures are set, as the pill (and VoiceOver, via
    /// the same list) should show them: Save, then Mark read, then Open,
    /// skipping whatever is nil. A pure decision, kept separate from the
    /// gesture and the glass so it can be tested without building either.
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
    fileprivate static func perform(_ item: Item, in actions: Actions) {
        switch item.title {
        case "Save": actions.save?()
        case "Mark read": actions.markRead?()
        case "Open": actions.open?()
        default: break
        }
    }
}

extension View {
    /// Adds the long-press quick-action pill to this view. A no-op when
    /// `actions` is nil — not just an empty pill — so a call site that has
    /// nothing to offer pays no cost and adds no gesture at all.
    func coverQuickActions(_ actions: CoverQuickActions.Actions?) -> some View {
        modifier(CoverQuickActionsModifier(actions: actions))
    }
}

private struct CoverQuickActionsModifier: ViewModifier {
    let actions: CoverQuickActions.Actions?

    /// Popped up and showing the pill, or not. One flag drives both: the
    /// brief's "long-press pops the cover, and shows a pill under it" is one
    /// state, not two that could disagree.
    @State private var isActive = false

    func body(content: Content) -> some View {
        if let actions {
            let items = CoverQuickActions.visibleActions(actions)
            content
                .scaleEffect(isActive && !Motion.isReduced ? 1.06 : 1)
                // Above its row neighbours while popped, so the pill below it
                // is not clipped or covered by the next cover over.
                .zIndex(isActive ? 1 : 0)
                .onLongPressGesture(minimumDuration: 0.4, maximumDistance: 24) {
                    // The actual activation happens in `onPressingChanged`,
                    // as soon as the hold is recognised — the pill should
                    // appear the moment the press commits, not wait for the
                    // finger to lift.
                } onPressingChanged: { pressing in
                    guard pressing, !isActive, !items.isEmpty else { return }
                    withAnimation(Motion.reduced(Motion.celebrate)) { isActive = true }
                }
                .sensoryFeedback(Haptics.selection, trigger: isActive) { old, new in new && !old }
                .overlay(alignment: .bottom) {
                    if isActive, !items.isEmpty {
                        ZStack {
                            outsideCatcher
                            pill(items, actions: actions)
                                // Below the (popped-up) cover, clear of its
                                // shadow. 14pt is a GUESS, not measured.
                                .offset(y: Metrics.radiusCoverRow + 14)
                        }
                        .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .top)))
                    }
                }
                // VoiceOver gets the same list, reachable without ever
                // triggering the long press — a hold gesture is not
                // something VoiceOver users perform the same way.
                .accessibilityActions {
                    ForEach(items, id: \.title) { item in
                        Button(item.title) { CoverQuickActions.perform(item, in: actions) }
                    }
                }
        } else {
            content
        }
    }

    /// Dismisses on a tap anywhere else, or the start of a scroll.
    ///
    /// This view has no way to ask its ancestors how big the screen is, so
    /// the catcher is just sized well past any plausible one — 2000pt is a
    /// GUESS, not a measurement. The drag threshold catches a scroll started
    /// on or near the cover; a scroll started elsewhere already falls under
    /// "somewhere else" and is a tap-outside dismiss instead. The main
    /// session should confirm on a device that a real scroll does not also
    /// get eaten by this once it lets go — a proper fix would coordinate
    /// through a root-level overlay host, which is out of this file's reach.
    private var outsideCatcher: some View {
        Color.black.opacity(0.0001)
            .frame(width: 2000, height: 2000)
            .contentShape(Rectangle())
            .onTapGesture { dismiss() }
            .gesture(DragGesture(minimumDistance: 8).onEnded { _ in dismiss() })
    }

    private func dismiss() {
        withAnimation(Motion.reduced(Motion.snappy)) {
            isActive = false
        }
    }

    @ViewBuilder
    private func pill(_ items: [CoverQuickActions.Item], actions: CoverQuickActions.Actions) -> some View {
        HStack(spacing: 16) {
            ForEach(items, id: \.title) { item in
                Button {
                    CoverQuickActions.perform(item, in: actions)
                    dismiss()
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: item.systemImage)
                            .font(.system(size: 15, weight: .semibold))
                        Text(item.title)
                            .font(.caption2)
                    }
                    .frame(minWidth: 44)
                }
                .buttonStyle(.press(haptic: Haptics.selection))
            }
        }
        .foregroundStyle(Palette.textPrimary)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background { Glass.floating(Capsule()) }
    }
}
