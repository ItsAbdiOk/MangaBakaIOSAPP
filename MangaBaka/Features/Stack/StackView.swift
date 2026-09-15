import SwiftUI

/// Cover-forward triage, laid out as the mockup specifies.
///
/// Physics come from the mockup's own script: 0.012 degrees of rotation per
/// point of drag, a 92pt commit threshold, and badge opacity tied to |dx| / 80
/// so the decision is legible before the reader lets go.
struct StackView: View {
    /// Shared between this card and `StackHeader`'s counter anchor so a
    /// saved card can `matchedGeometryEffect` its way there. A `static let`
    /// rather than a literal at each call site, so the two halves of the
    /// flight can never drift out of sync by a typo.
    static let saveFlightID = "stack.saveFlightTarget"

    @State private var model: StackModel
    @Binding private var path: [Series]
    @Environment(\.zoomRoute) private var zoomRoute
    @Namespace private var saveFlightNamespace

    @State private var drag: CGSize = .zero
    @State private var hint = StackHint()
    /// Bumped when a drag falls short and the card settles back. A cancelled
    /// swipe should feel cancelled; see `Haptics`.
    @State private var settles = 0
    /// Commit counts, for the symbol bounces on the two circles.
    @State private var saves = 0
    @State private var skips = 0
    /// Bumped each time the drag crosses `commitThreshold` — a latch via
    /// `StackGesture.crossedThreshold`, not a level, so holding the card past
    /// the line ticks once rather than buzzing every frame.
    @State private var thresholdTicks = 0
    /// The series flying toward the saved counter, and how far into that
    /// flight it is. Non-nil only for the ~duration of `Motion.celebrate`
    /// after a save commits; see `beginSaveFlight`.
    /// Whether a reaction is mid-flight.
    ///
    /// Work-list 83: nothing rejected a second reaction while the first was
    /// animating, and `StackModel.removeFirst` runs before the first `await`,
    /// so a double-tap on "+" — or a tap landing during a drag's release —
    /// saved a card the reader never saw and POSTed it as `plan_to_read`.
    /// One guard in `react`, which all three triggers go through, plus the
    /// two controls disabling themselves so it is visible rather than silent.
    @State private var isReacting = false
    @State private var flightSeries: Series?
    @State private var flightArrived = false
    /// True for one `Motion.settle` beat after a new card becomes current,
    /// while it rises and un-rotates from the deck. Reset by the same
    /// `onChange` that clears the drag offset.
    @State private var cardArriving = false
    /// Whether the very first card of this screen's lifetime has faded in
    /// over the loading skeleton yet. One-shot: every card after the first
    /// arrives via `cardArriving`'s rise instead, not this fade.
    @State private var firstCardArrived = false
    /// Guards "Deal another now" (gap 12, FAILURES-SUMMARY.md K3): it used to
    /// call `resetStack()` directly and erase every local save with no
    /// confirmation and no toast, unlike the header's own reset. Behind the
    /// same `ConfirmDestructive` dialog as that one now.
    @State private var isConfirmingDealAnother = false
    private let onOpenShelf: () -> Void
    /// Says a thing happened. A reset otherwise succeeds in silence, which is
    /// indistinguishable from a tap that missed.
    private let onConfirm: (String) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let commitThreshold: CGFloat = 92
    private let rotationPerPoint: Double = 0.012
    /// A guess: past this, rotation stopped reading as a card tipping and
    /// started reading as it spinning.
    private let rotationCap: Double = 8
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
                    lowQueueStatus
                    StackSavedStrip(saved: model.saved, path: $path, onOpenShelf: onOpenShelf)
                }
            }
            .padding(.top, Metrics.scrollTopInset)
            .padding(.bottom, Metrics.scrollBottomInset)
        }
        .scrollIndicators(.hidden)
        .background(Palette.ground)
        .task { await model.loadIfNeeded() }
        // Work-list 88: `StackModel.isVisible` was read by the request-
        // priority split and written by nobody, so every refill went out as
        // `.userInitiated` — including the ones this app starts on its own
        // while the reader is on Discover, competing for the search window a
        // foreground search needs.
        .onAppear { model.isVisible = true }
        .onDisappear { model.isVisible = false }
        // The queue advanced: whatever offset the thrown card had belongs to
        // the card that has gone, not the one now on top. The new card on
        // top rises and un-rotates from the deck instead, per `cardArriving`
        // — except the very first card of this screen's lifetime, which
        // fades in over the loading skeleton instead (`firstCardArrived`).
        .onChange(of: model.current?.id) { oldValue, newValue in
            resetThrow()
            guard newValue != nil else { return }
            guard firstCardArrived else {
                firstCardArrived = true
                return
            }
            guard oldValue != nil, !reduceMotion else { return }
            cardArriving = true
            Motion.run(Motion.settle) { cardArriving = false }
        }
    }

    // MARK: - Header

    private var header: some View {
        StackHeader(
            savedCount: model.savedCount,
            provenance: model.caption,
            showsInstruction: !hint.hasDragged,
            todayAnswered: model.todayProgress.answered,
            todayDealt: model.todayProgress.dealt,
            saveFlightNamespace: saveFlightNamespace
        ) {
            let succeeded = await model.resetStack()
            onConfirm(succeeded ? "The stack has been reset" : "Couldn't reset — try again")
        }
    }

}

// MARK: - Cards, gesture, and reactions
//
// Split from the type's own body only to stay under `type_body_length` —
// `private` here still resolves against `StackView`'s own private state,
// since an extension in the same file shares its enclosing type's private
// access.
extension StackView {
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
                    .rotationEffect(.degrees(cardRotation))
                    // The new card rises 8pt and un-rotates from a 2° tilt as
                    // it becomes current, so the deck reads as a physical
                    // stack settling rather than a swap. Suppressed while a
                    // drag is in progress or the flight overlay is standing
                    // in for this card (`flightSeries != nil`), and identity
                    // under Reduce Motion via `Motion.reduced` inside `run`.
                    .offset(y: cardArriving ? 8 : 0)
                    .opacity(flightSeries != nil ? 0 : 1)
                    .appearsSoftly(when: firstCardArrived)
                    .gesture(dragGesture)
                    // The stack is the one screen driven entirely by a gesture,
                    // so it is the one that most needs to answer the thumb.
                    // `skips`/`saves` bump in `react` itself — the one path
                    // shared by the drag, the buttons and the VoiceOver
                    // actions — so all three trigger points feel the same.
                    // A save's own reward haptic fires from the counter it
                    // flies to instead (`StackHeader`), keyed off the count
                    // that actually persisted rather than the gesture alone.
                    .haptic(Haptics.selection, onEach: skips)
                    .haptic(Haptics.tick, onEach: thresholdTicks)
                    .haptic(Haptics.settled, onEach: settles)
                    .onTapGesture { open(current) }
                    .zoomSource("stack", current.id)
                    // VoiceOver cannot perform a drag, so saving and skipping
                    // are exposed as actions too. The buttons below are the
                    // visible equivalent.
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(current.displayTitle ?? "Untitled series")
                    .accessibilityHint("Double tap for details")
                    .accessibilityAction(named: "Save") { Task { await react(.saved) } }
                    .accessibilityAction(named: "Skip") { Task { await react(.skipped) } }
            } else if model.isLoading {
                // A card-shaped placeholder rather than a bare spinner: the
                // spinner collapsed the card area to zero height, so the
                // layout jumped the instant a real card landed (gap 38,
                // FAILURES-SUMMARY.md K12).
                RoundedRectangle(cornerRadius: Metrics.radiusStackCard, style: .continuous)
                    .fill(Palette.imagePlaceholder)
                    .frame(
                        width: Metrics.stackCardWidth,
                        height: Metrics.stackCardWidth / Metrics.coverAspect
                    )
                    .shimmering()
                    .accessibilityHidden(true)
            } else {
                emptyState
            }

            // A saved card shrinks and travels here instead of being thrown
            // off screen — a save is a keep, not a dismissal. Sits above the
            // real card (which fades out for the duration, see `card`'s
            // opacity binding) so the two never double-render the cover.
            if let flightSeries {
                CoverImage(
                    cover: flightSeries.cover,
                    width: Metrics.stackCardWidth,
                    radius: Metrics.radiusStackCard
                )
                    .frame(
                        width: Metrics.stackCardWidth,
                        height: Metrics.stackCardWidth / Metrics.coverAspect
                    )
                    // `isSource: false`: this ghost's geometry is the one
                    // that should be overridden to interpolate toward the
                    // header's anchor, not the other way around — with both
                    // sides defaulting to `true` the match is ambiguous and
                    // the flight can resolve backwards (the tiny anchor
                    // stretching to card size instead of the card shrinking).
                    .matchedGeometryEffect(id: Self.saveFlightID, in: saveFlightNamespace, isSource: false)
                    .scaleEffect(flightArrived ? 0.05 : 1)
                    .opacity(flightArrived ? 0 : 1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .frame(height: (model.current != nil || model.isLoading) ? Metrics.stackArea : nil)
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
                .animation(Motion.reduced(Motion.glide), value: badgeStrength)
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
                .animation(Motion.reduced(Motion.glide), value: badgeStrength)
                .padding(16)
        }
    }

    private var badgeStrength: Double {
        Double(min(abs(drag.width) / badgeDivisor, 1))
    }

    /// Drag rotation, capped at `rotationCap`, plus the deck's own 2° tilt
    /// while a new card is arriving (`cardArriving`) — the two never overlap
    /// in practice since a drag only ever acts on a settled card, but adding
    /// rather than switching keeps this a single, always-correct expression.
    private var cardRotation: Double {
        let dragRotation = min(max(Double(drag.width) * rotationPerPoint, -rotationCap), rotationCap)
        return dragRotation + (cardArriving ? 2 : 0)
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
                let previousWidth = drag.width
                drag = value.translation
                // One tick per crossing, not one per frame past it — see
                // `StackGesture.crossedThreshold`.
                let crossed = StackGesture.crossedThreshold(
                    previous: previousWidth, current: drag.width, threshold: commitThreshold
                )
                if crossed { thresholdTicks += 1 }
            }
            .onEnded { value in
                let dx = value.translation.width
                // A vertical swipe never moved the card, so there is nothing to
                // settle and nothing to commit.
                guard drag != .zero else { return }
                // A release landing while a reaction is still in flight is
                // the same double-commit as a double-tap (work-list 83).
                guard !isReacting else {
                    drag = .zero
                    return
                }
                guard abs(dx) > commitThreshold else {
                    Motion.run(.spring(response: 0.36, dampingFraction: 0.78)) { drag = .zero }
                    settles += 1
                    return
                }
                let kind: ShelfEntry.Kind = dx > 0 ? .saved : .skipped
                hint.markDragged()
                // A skip tips and slides out on its own spring; a save has
                // no throw of its own — the card fades as `react` starts the
                // fly-to-counter overlay instead (see `beginSaveFlight`).
                if kind == .skipped {
                    if reduceMotion {
                        drag = .zero
                    } else {
                        Motion.run(Motion.snappy) { drag.width = dx > 0 ? 700 : -700 }
                    }
                }
                Task {
                    await react(kind)
                }
            }
    }

    /// Opens the current card's page, growing out of the card.
    private func open(_ series: Series) {
        zoomRoute?.source = ZoomRoute.id("stack", series.id)
        path.append(series)
    }

    /// The one path for a reaction from any of its three triggers — the drag,
    /// the buttons, the VoiceOver actions — so the confirmation cannot be
    /// missed by one of them. Said after the save has landed, because only
    /// then does the model know whether it reached the library.
    private func react(_ kind: ShelfEntry.Kind) async {
        guard !isReacting else { return }
        isReacting = true
        defer { isReacting = false }
        if kind == .saved {
            saves += 1
            // Captured before `model.react` advances the queue: by the time
            // that returns, `model.current` is already the next card.
            if let series = model.current { beginSaveFlight(series) }
        } else {
            skips += 1
        }
        await model.react(kind)
        // `shouldConfirmSave` is false only when the local shelf write itself
        // failed — confirming "Saved here" for that write used to be
        // unconditional (gap 36, FAILURES-SUMMARY.md K8).
        if kind == .saved, model.shouldConfirmSave { onConfirm(model.saveConfirmation) }
    }

    /// Shrinks the card and sends it toward the saved counter instead of
    /// throwing it off screen: a save is a keep, not a dismissal, so it
    /// travels to where the kept thing now lives. Pairs with the
    /// `matchedGeometryEffect` anchor in `StackHeader`'s counter and its own
    /// `.celebrates`/`Haptics.success` there.
    ///
    /// The 550ms hold is a guess, chosen to sit inside the 600ms reward
    /// budget (`CelebratesModifier`'s own doc comment) alongside
    /// `Motion.celebrate`'s spring — unverified on a device; flagged for the
    /// main session to time and shorten if the whole flight runs long.
    private func beginSaveFlight(_ series: Series) {
        guard !reduceMotion else { return }
        flightSeries = series
        flightArrived = false
        Motion.run(Motion.celebrate) { flightArrived = true }
        Task {
            try? await Task.sleep(for: .milliseconds(550))
            // Only this flight's own ending clears it (work-list 83). The
            // clear used to be unconditional, so a second save starting
            // inside the 550 ms window had the first one's timer pop the real
            // card back to full opacity underneath it.
            guard flightSeries?.id == series.id else { return }
            flightSeries = nil
            flightArrived = false
        }
    }

    /// The card's offset is reset the moment the queue advances, not when
    /// the write behind it finishes. `react` removes the card first and then
    /// awaits the shelf write, a library POST and possibly a refill — and
    /// throughout, the 700pt throw was still applied to `card(current)`,
    /// which by then was the next card: on a slow save the stack looked empty
    /// until the POST returned.
    private func resetThrow() {
        drag = .zero
    }

    // MARK: - Caption, actions, saved

    private var actions: some View {
        HStack(spacing: Metrics.actionGap) {
            StackCircleAction(symbol: "xmark", size: Metrics.actionSkip, label: "Skip", bounces: skips) {
                Task { await react(.skipped) }
            }
            .disabled(isReacting)

            Button { if let current = model.current { open(current) } } label: {
                Text("Details")
                    .typeRowTitle()
                    .foregroundStyle(Palette.textPrimary)
                    .padding(.horizontal, 20)
                    .frame(minHeight: Metrics.actionDetails)
                    .background { Glass.floating(Capsule()) }
            }
            .buttonStyle(.press)

            Button { Task { await react(.saved) } } label: {
                Image(systemName: "plus")
                    .typeSymbol(size: 24, weight: .medium, relativeTo: .title2)
                    .foregroundStyle(Palette.onAccent)
                    // The glyph answers the commit it stands for, whichever
                    // way the card went.
                    .symbolEffect(.bounce, value: reduceMotion ? 0 : saves)
                    .frame(minWidth: Metrics.actionSave, minHeight: Metrics.actionSave)
                    .background(Palette.accent, in: Circle())
                    .shadow(color: .black.opacity(0.5), radius: 13, y: 10)
            }
            .buttonStyle(.press)
            .disabled(isReacting)
            .accessibilityLabel("Save")
        }
        .padding(.top, 14)
    }

    /// D7 (discovery-ui review, 2026-09-15): a refill under a full gate with
    /// one or two cards still in hand used to show nothing at all — the
    /// disabled state only ever appeared once the queue was completely
    /// empty (`emptyState`, below), so a stalled or failed top-up while the
    /// reader still had a card to look at read as the app having simply
    /// stopped, with no visible cause. Mirrors the pattern Discover already
    /// uses for a row-level throttle: content stays up, a small line
    /// underneath says why nothing new has arrived yet.
    @ViewBuilder
    private var lowQueueStatus: some View {
        if model.queue.count <= 2 {
            if let failure = model.failure {
                InlineFailure(error: failure, retry: { await model.refill() })
                    .padding(.top, 10)
            } else if model.isLoading {
                Text("Finding more…")
                    .typeSmallMeta()
                    .foregroundStyle(Palette.textMuted)
                    .padding(.top, 10)
                    .padding(.horizontal, Metrics.gutter)
            }
        }
    }

    /// Run out, or failed to load. Two different things, said differently:
    /// a real failure gets `FailureState` — a countdown for a rate limit, but
    /// no auto-retry, since Stack is not Search (decision 4,
    /// FAILURES-SUMMARY.md §3) — and genuine exhaustion gets the calmer
    /// `EmptyState`, which used to be shown for both (gap 33, K1).
    ///
    /// This used to say "a new one is dealt tomorrow morning", crediting the
    /// rising feed's one-day cache life — but the queue here is built from
    /// `.mix` (1 h) or `.surprise` (never cached), not the rising feed, so
    /// nothing was actually scheduled for the morning (gap 35, K4). Dropped
    /// rather than made true, because the header's own reset already re-deals
    /// immediately and is what a reader who has just run out actually wants.
    ///
    /// The header already carries a reset, and a reader who has just run out
    /// is exactly the person who wants it. Abdi's call, 2026-09-10: keep the
    /// reset reachable from here rather than making them find the ... menu —
    /// now behind the same confirmation as the header's own reset (gap 12,
    /// K3), since it throws away every local save exactly as that one does.
    @ViewBuilder
    private var emptyState: some View {
        if let failure = model.failure {
            FailureState(error: failure, retry: { await model.refill() })
                .padding(.top, Metrics.sectionGap)
        } else {
            EmptyState(
                title: "That's today's stack",
                message: "\(model.seenThisRun) seen, \(model.savedThisRun) saved.",
                actionTitle: "See what you saved",
                actionWeight: .aside,
                action: onOpenShelf,
                secondaryTitle: "Deal another now",
                secondaryAction: { isConfirmingDealAnother = true }
            )
            .confirmDestructive(
                isPresented: $isConfirmingDealAnother,
                title: "Deal a new stack now?",
                consequence: """
                Forgets every save and skip on this device, and deals a fresh \
                stack. Anything already added to your MangaBaka library stays \
                there.
                """,
                label: "Deal another",
                action: {
                    let succeeded = await model.resetStack()
                    onConfirm(succeeded ? "The stack has been reset" : "Couldn't reset — try again")
                }
            )
        }
    }
}
