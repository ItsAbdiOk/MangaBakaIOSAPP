import SwiftUI

/// Cover-forward triage, laid out as the mockup specifies.
///
/// Physics come from the mockup's own script: 0.012 degrees of rotation per
/// point of drag, a 92pt commit threshold, and badge opacity tied to |dx| / 80
/// so the decision is legible before the reader lets go.
struct StackView: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var model: StackModel
    @Binding private var path: [Series]

    @State private var drag: CGSize = .zero
    /// What the last committed swipe was, and how many have happened.
    ///
    /// The count is what makes the trigger fire twice for two saves in a row —
    /// the kind alone would not change, so the second save would be silent.
    @State private var lastCommit: (kind: ShelfEntry.Kind, count: Int)?
    private let onOpenShelf: () -> Void
    /// Says a thing happened. A reset otherwise succeeds in silence, which is
    /// indistinguishable from a tap that missed.
    private let onConfirm: (String) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let commitThreshold: CGFloat = 92
    private let rotationPerPoint: Double = 0.012
    private let badgeDivisor: CGFloat = 80

    init(
        model: StackModel,
        path: Binding<[Series]>,
        onOpenShelf: @escaping () -> Void,
        onConfirm: @escaping (String) -> Void = { _ in }
    ) {
        _model = State(initialValue: model)
        _path = path
        self.onOpenShelf = onOpenShelf
        self.onConfirm = onConfirm
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                header
                cardArea
                if let current = model.current {
                    StackCaption(
                        series: current,
                        reason: model.currentReason,
                        warning: model.warning(for: current)
                    )
                    actions
                    StackSavedStrip(saved: model.saved, path: $path, onOpenShelf: onOpenShelf)
                }
            }
            .padding(.top, Metrics.scrollTopInset)
            .padding(.bottom, Metrics.scrollBottomInset)
        }
        .scrollIndicators(.hidden)
        .background(Palette.ground)
        .task { await model.loadIfNeeded() }
    }

    // MARK: - Header

    private var header: some View {
        StackHeader(savedCount: model.savedCount) {
            await model.resetStack()
            onConfirm("The stack has been reset")
        }
    }

    // MARK: - Cards

    @ViewBuilder
    private var cardArea: some View {
        ZStack {
            if let current = model.current {
                // Neighbours peek in from either side rather than stacking
                // behind, so the stack reads as a sequence with a behind and an
                // ahead rather than a pile.
                neighbour(model.previous, alignment: .leading)
                neighbour(model.next, alignment: .trailing)

                card(current)
                    .offset(drag)
                    .rotationEffect(.degrees(drag.width * rotationPerPoint))
                    .gesture(dragGesture)
                    // The stack is the one screen driven entirely by a gesture,
                    // so it is the one that most needs to answer the thumb. A
                    // save lands heavier than a skip because keeping something
                    // is the decision worth feeling.
                    .sensoryFeedback(trigger: lastCommit?.count ?? 0) { _, _ in
                        switch lastCommit?.kind {
                        case .saved: .impact(weight: .medium)
                        case .skipped: .impact(flexibility: .soft, intensity: 0.6)
                        case nil: nil
                        }
                    }
                    .onTapGesture { path.append(current) }
                    // VoiceOver cannot perform a drag, so saving and skipping
                    // are exposed as actions too. The buttons below are the
                    // visible equivalent.
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(current.displayTitle ?? "Untitled series")
                    .accessibilityHint("Double tap for details")
                    .accessibilityAction(named: "Save") { Task { await model.react(.saved) } }
                    .accessibilityAction(named: "Skip") { Task { await model.react(.skipped) } }
            } else if model.isLoading {
                ProgressView().tint(Palette.textTertiary)
            } else {
                emptyState
            }
        }
        .frame(height: model.current == nil ? nil : Metrics.stackArea)
        .frame(maxWidth: .infinity)
        .clipped()
    }

    @ViewBuilder
    private func neighbour(_ series: Series?, alignment: Alignment) -> some View {
        if let series {
            CoverImage(
                cover: series.cover,
                width: Metrics.stackNeighbourWidth,
                radius: Metrics.radiusStackNeighbour
            )
            .opacity(Metrics.stackNeighbourOpacity)
            .blur(radius: 1)
            .frame(maxWidth: .infinity, alignment: alignment)
            .offset(x: alignment == .leading ? -Metrics.stackNeighbourInset
                                             : Metrics.stackNeighbourInset)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private func card(_ series: Series) -> some View {
        CoverImage(
            cover: series.cover,
            width: Metrics.stackCardWidth,
            radius: Metrics.radiusStackCard,
            accessibilityText: series.displayTitle ?? "Untitled series"
        )
        .shadow(color: .black.opacity(0.65), radius: 30, y: 24)
        .overlay(alignment: .topLeading) {
            StackBadge(
                text: "SKIP",
                fill: Palette.surfaceBadge,
                textColour: Palette.textPrimary,
                bordered: true
            )
                .opacity(drag.width < 0 ? badgeStrength : 0)
                .padding(16)
        }
        .overlay(alignment: .topTrailing) {
            StackBadge(
                text: "SAVE",
                fill: Palette.accent,
                textColour: Palette.onAccent,
                bordered: false
            )
                .opacity(drag.width > 0 ? badgeStrength : 0)
                .padding(16)
        }
    }

    private var badgeStrength: Double {
        Double(min(abs(drag.width) / badgeDivisor, 1))
    }

    private var dragGesture: some Gesture {
        // The mockup's card sets `touch-action: pan-y`: the card takes
        // horizontal drags, the page keeps vertical scrolling. Without the
        // minimum distance this gesture swallowed every vertical swipe and the
        // page below the card — the actions and the saved strip — could not be
        // reached at all.
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                // Only claim the gesture once it is clearly horizontal.
                guard abs(value.translation.width) >= abs(value.translation.height)
                else { return }
                drag = value.translation
            }
            .onEnded { value in
                let dx = value.translation.width
                // A vertical swipe never moved the card, so there is nothing to
                // settle and nothing to commit.
                guard drag != .zero else { return }
                guard abs(dx) > commitThreshold else {
                    withAnimation(.spring(response: 0.36, dampingFraction: 0.78)) { drag = .zero }
                    return
                }
                let kind: ShelfEntry.Kind = dx > 0 ? .saved : .skipped
                lastCommit = (kind, (lastCommit?.count ?? 0) + 1)
                // A card thrown the width of the screen is a lot of motion.
                // With Reduce Motion on, it simply goes.
                if reduceMotion {
                    drag = .zero
                } else {
                    withAnimation(.easeOut(duration: 0.22)) { drag.width = dx > 0 ? 700 : -700 }
                }
                Task {
                    await model.react(kind)
                    drag = .zero
                }
            }
    }

    // MARK: - Caption, actions, saved

    private var actions: some View {
        HStack(spacing: Metrics.actionGap) {
            circleAction("xmark", size: Metrics.actionSkip, label: "Skip") {
                Task { await model.react(.skipped) }
            }

            Button { if let current = model.current { path.append(current) } } label: {
                Text("Details")
                    .typeRowTitle()
                    .foregroundStyle(Palette.textPrimary)
                    .padding(.horizontal, 20)
                    .frame(height: Metrics.actionDetails)
                    .background { Glass.floating(Capsule()) }
            }
            .buttonStyle(.plain)

            Button { Task { await model.react(.saved) } } label: {
                Image(systemName: "plus")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(Palette.onAccent)
                    .frame(width: Metrics.actionSave, height: Metrics.actionSave)
                    .background(Palette.accent, in: Circle())
                    .shadow(color: .black.opacity(0.5), radius: 13, y: 10)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Save")
        }
        .padding(.top, 22)
    }

    private func circleAction(
        _ symbol: String,
        size: CGFloat,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(Palette.textSecondary)
                .frame(width: size, height: size)
                .background { Glass.floating(Circle()) }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var emptyState: some View {
        EmptyState(
            symbol: model.message == nil ? "checkmark.circle" : "exclamationmark.triangle",
            title: model.message == nil ? "That's the stack for now" : "Can't load the stack",
            message: model.message
                ?? "Save a few and the next batch will lean towards them.",
            actionTitle: "Load more",
            action: { Task { await model.refill() } }
        )
    }
}
