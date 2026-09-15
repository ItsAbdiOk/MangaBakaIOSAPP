import SwiftUI

/// The motion vocabulary's view-level half: `Motion` and `Haptics` hold the
/// presets and pure decisions, these modifiers are how a view actually wears
/// them. Every one degrades to no movement (state change still happens,
/// instantly) under Reduce Motion, reading `Motion.isReduced` directly on
/// the main actor rather than threading `@Environment(\.accessibilityReduceMotion)`
/// through — consistent with how `Motion` itself reads the system flag, and
/// one fewer thing a new modifier here can forget to wire.

/// A view's first appearance: it rises 8pt, unblurs, and fades in, delayed by
/// its place in a staggered group (`Motion.arrival(index:)`). Identity at
/// once under Reduce Motion — no delay, no rise.
///
/// `.transition(.blurReplace)` covers the case a parent is *inserting* this
/// view into a list it is already animating (e.g. a filtered list changing);
/// the `onAppear` path covers first render, where SwiftUI's own transition
/// machinery does not apply because nothing was removed to make room for it.
/// Opacity/blur/offset are purely visual — nothing here removes or renames
/// the view's accessibility element.
private struct ArrivesModifier: ViewModifier {
    let index: Int
    @State private var hasArrived = Motion.isReduced

    func body(content: Content) -> some View {
        content
            .opacity(hasArrived ? 1 : 0)
            .blur(radius: hasArrived ? 0 : 6)
            .offset(y: hasArrived ? 0 : 8)
            .transition(.blurReplace)
            .onAppear {
                guard !hasArrived else { return }
                // S2/S9J — measure-first, no behaviour change: a Signpost
                // interval spanning this view's own arrival blur (radius
                // 6→0 over `Motion.arrival`), so an Instruments run on a
                // 30-card fling can attribute frame cost to this rather
                // than guessing between it and the cover pipeline's own
                // cost (S1/S3/S4, `CoverStore` — outside this agent's
                // files). Ends via the animation's own completion, not a
                // timer, so it is exact regardless of `Motion.arrival`'s
                // duration or Reduce Motion collapsing it to instant.
                let signpostID = Signposts.signposter.makeSignpostID()
                let state = Signposts.signposter.beginInterval("row arrival blur", id: signpostID)
                withAnimation(Motion.arrival(index: index), completionCriteria: .logicallyComplete) {
                    hasArrived = true
                } completion: {
                    Signposts.signposter.endInterval("row arrival blur", state)
                }
            }
    }
}

extension View {
    /// This view arrives rather than appears, in step `index` of whatever
    /// group is assembling. See `ArrivesModifier`.
    func arrives(index: Int) -> some View {
        modifier(ArrivesModifier(index: index))
    }
}

/// An image (or anything) fading up over its placeholder — a BlurHash, a
/// skeleton — once `isReady` flips true. Opacity and blur only: nothing
/// moves, so this is safe over content whose final size is already
/// reserved. Instant under Reduce Motion, per `Motion.reduced`.
private struct AppearsSoftlyModifier: ViewModifier {
    let isReady: Bool

    func body(content: Content) -> some View {
        content
            .opacity(isReady ? 1 : 0)
            .blur(radius: isReady ? 0 : 4)
            .animation(Motion.reduced(Motion.settle), value: isReady)
    }
}

extension View {
    /// Fades and unblurs in when `isReady` becomes true. For an image
    /// arriving over its BlurHash placeholder.
    func appearsSoftly(when isReady: Bool) -> some View {
        modifier(AppearsSoftlyModifier(isReady: isReady))
    }
}

/// `Motion.glide`, as a scroll transition config, instant instead under
/// Reduce Motion. Shared by `EnterScaleModifier` and `ParallaxModifier`.
private var glideTransitionConfig: ScrollTransitionConfiguration {
    .animated(Motion.reduced(Motion.glide) ?? .linear(duration: 0))
}

/// A card in a scroll view scaling up to full size and full opacity as it
/// reaches the middle, and back down at the far edge — the App-Store-shelf
/// feel `Motion.arrives()` already gives horizontal galleries, generalised
/// to any scroll axis. 0.96/0.85 at the edges are guesses, matched to the
/// existing `ArrivalTransition` in `Motion.swift`.
///
/// Wired to `Motion.glide` via `.animated`, not `.interactive`: `.interactive`
/// ties the scale directly to scroll offset with no animation curve at all,
/// which is right for a 1:1 drag-follow but not for "glide, no overshoot" —
/// that describes a curve, and only `.animated(_:)` takes one. Named
/// `.enterScale()` per the brief; flagging the `.interactive` → `.animated`
/// swap for the main session to eyeball on a device.
private struct EnterScaleModifier: ViewModifier {
    func body(content: Content) -> some View {
        // A single expression per branch of `Motion.isReduced`, not an
        // if/else returning `view` on one side and `view.scaleEffect(...)`
        // on the other: the transition closure isn't a result-builder
        // context, so two differently-typed returns would not type-check.
        content.scrollTransition(glideTransitionConfig) { view, phase in
            let isEdge = !phase.isIdentity && !Motion.isReduced
            return view
                .scaleEffect(isEdge ? 0.96 : 1)
                .opacity(isEdge ? 0.85 : 1)
        }
    }
}

extension View {
    /// Scales and fades this view in as it enters the viewport while
    /// scrolling. See `EnterScaleModifier`.
    func enterScale() -> some View {
        modifier(EnterScaleModifier())
    }
}

/// A few points of vertical drift against scroll — foreground content
/// moving very slightly faster or slower than its background reads as
/// depth. `amount` is a guess, capped at 6pt per the brief: past that it
/// stopped reading as depth and started reading as misregistration. Zero
/// under Reduce Motion.
private struct ParallaxModifier: ViewModifier {
    let amount: CGFloat

    func body(content: Content) -> some View {
        // One expression, not a guard returning `view` in one branch and
        // `view.offset(...)` in the other — see the comment on
        // `EnterScaleModifier`, same constraint applies here.
        content.scrollTransition(glideTransitionConfig) { view, phase in
            let raw = Motion.isReduced ? 0 : phase.value * amount
            let offset = max(-amount, min(amount, raw))
            return view.offset(y: offset)
        }
    }
}

extension View {
    /// Drifts this view up to `amount` points against scroll, for a sense of
    /// depth. Never pass more than 6pt — see `ParallaxModifier`.
    func parallax(_ amount: CGFloat = 6) -> some View {
        modifier(ParallaxModifier(amount: amount))
    }
}

/// A one-shot reward: scale 1 → 1.08 → back to 1 on `Motion.celebrate`, and
/// nothing under Reduce Motion — a reward is not information the reader
/// needs; skipping it costs nothing. Never loops, never fires twice for one
/// trigger change, and the whole thing must stay under 600ms so it never
/// blocks the reader's next gesture (rule 8). The 90ms hold below is a
/// guess, kept short because `Motion.celebrate` (response 0.55) already
/// takes a good fraction of the 600ms budget on its own for the up move
/// alone — the down move re-triggers the same spring afterward, so the
/// total is unverified against the 600ms ceiling without a device. Flagged
/// for the main session to time and shorten `celebrate` or this hold if it
/// runs long.
private struct CelebratesModifier<Trigger: Equatable>: ViewModifier {
    let trigger: Trigger
    @State private var isCelebrating = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(isCelebrating ? 1.08 : 1)
            .animation(Motion.reduced(Motion.celebrate), value: isCelebrating)
            .onChange(of: trigger) { _, _ in
                guard !Motion.isReduced else { return }
                isCelebrating = true
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(90))
                    isCelebrating = false
                }
            }
    }
}

extension View {
    /// Bounces this view once when `trigger` changes — a save, a completion.
    /// See `CelebratesModifier`.
    func celebrates(on trigger: some Equatable) -> some View {
        modifier(CelebratesModifier(trigger: trigger))
    }
}
