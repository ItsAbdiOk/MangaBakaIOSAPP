# The feel pass

Abdi, 2026-09-11: *"I want it to be a visuals treat. I want smooth transitions and
animations. I want haptics... I want this app to win design awards and I want it to be
addictive to use."*

This is the plan. Written before touching anything, because "add some animations" is how
an app ends up feeling busy rather than good.

## The principle

**Motion should explain, and haptics should confirm.** Every animation in this pass
answers a question the reader would otherwise have to work out: where did this come from,
where did it go, did that work, is there more. An animation that answers nothing is
decoration, and decoration is what makes an app feel cheap on the fiftieth launch rather
than the first.

The corollary, which matters more: **anything added here must survive Reduce Motion.**
The app now routes every animation through `Motion.reduced`. Nothing in this pass gets to
bypass it.

## What is already here

Worth knowing, because the gap is smaller than it looks:

- **Zoom navigation transition** — `RootView:260` uses `.navigationTransition(.zoom(...))`
  and Discover's covers are `.matchedTransitionSource`. Tapping a cover on Discover
  already grows it into the detail page.
- **Sensory feedback** in four places: the toast, a library state change, a library
  failure, and a stack commit.
- **A scroll transition** in the cover gallery.
- Animation timing is already correct and measured: everything is 0.20-0.28s with one
  spring at response 0.36 / damping 0.78, which is inside the 200-300ms window.

## 1 — Haptics: confirm every commitment

Cheapest win in the list and the one people feel first.

The rule: **a haptic marks a state change the reader caused.** Not a tap — a tap is its
own feedback. A *consequence*.

| Where | Feedback | Why |
|---|---|---|
| Tab switch | `.selection` | The one everybody expects and we do not have |
| Filter chip, sort, state chip | `.selection` | Confirms the list beneath changed |
| Add to library | `.success` | Already there via `LibraryControl` |
| Stack: throw commits | `.impact(.medium)` | Already there — check it fires on skip too |
| Stack: card lands back | `.impact(.soft)` | A cancelled swipe should feel cancelled |
| Rating: each star | `.selection` | A rating is set by feel, not by looking |
| Seed added / removed | `.selection` | |
| Pull to refresh completes | `.impact(.rigid)` | The list is new; say so without a toast |
| Reached the end of a feed | `.impact(.soft)` | Distinguishes "no more" from "still loading" |
| Copy (title, ISBN, artwork) | `.impact(.light)` | Already there, but imperative — unify |
| Toggle in Settings | `.selection` | |

**Unify on `.sensoryFeedback`.** Three sites still call
`UIImpactFeedbackGenerator(...).impactOccurred()` directly
(`DetailHero:120`, `AlternativeTitles:111`, `VolumesSection:174`). The declarative
modifier is the same haptic, but it is tied to a value change, so it cannot fire twice on
one event or fire during a body pass.

## 2 — Transitions: finish the zoom

The zoom transition is the single most expensive-feeling thing in the app and it is
wired on ONE screen.

- Search results, Mix results, Library rows, shelf rows, the Related row, the stack card
  and the volume spines all push a detail page with a plain slide.
- Each needs a `.matchedTransitionSource(id:in:)` and the namespace threaded to it. The
  id scheme already handles the hard case — the same series appearing in two rows at once
  — by keying on `row#seriesId`.

Also: **the cover gallery** should zoom from the tapped cover rather than cross-fading.

## 3 — Numbers should count, not cut

`.contentTransition(.numericText())` on every figure that changes:

- The Wrapped screen's headlines (142 series, 3,778 chapters, 148×)
- The community pulse's three figures
- The library's state-chip counts as a filter changes
- "N shown" on Search as results arrive
- The schedule's "N estimated of N in scope"

A number that morphs digit by digit reads as *the same number changing*. A number that
cuts reads as *a different screen*.

## 4 — Symbols should react

`.symbolEffect` is free and nobody is using it:

- The save/bookmark icon: `.bounce` on add
- The refresh icon: `.rotate` while loading
- The search magnifier: `.pulse` while a request is in flight
- The tab icons: `.replace` between filled and outline on selection
- The stack's skip/save circles: `.bounce` on commit

## 5 — Cards should arrive, not appear

`.scrollTransition` on the cover rows, as the gallery already does: a card entering from
the right comes up from ~0.94 scale and ~0.6 opacity. It costs nothing and it is most of
what makes a shelf feel like the App Store's.

Paired with `.scrollTargetBehavior(.viewAligned)` so a row settles on a card rather than
between two.

## 6 — Touch should answer

A button that does not move under a finger feels dead. A `ButtonStyle` that scales to
0.97 with a spring on `isPressed`, applied to every card and chip. One file, global
effect.

## 7 — Loading should be the shape of the answer

The app already decodes a BlurHash per cover, so a loading grid already has the right
colours. What it does not have is motion: a slow shimmer over the placeholder says
"working" where a static blur says "broken". `CoverSkeletonRow` was written for this and
deleted as dead code on 2026-09-11 — it is in git and worth bringing back, wired this
time.

## What this pass must NOT do

- **No animation on data arrival that implies the data is new.** A refetch that returns
  the same rows should not re-animate them; that is how an app feels jumpy.
- **No haptic on anything the reader did not cause.** A haptic for a background refresh
  is a phone buzzing in a pocket for no reason.
- **No spring so loose it bounces.** The measured window is 200-300ms and the existing
  spring is 0.36/0.78. Anything looser reads as a toy.
- **Nothing that bypasses `Motion.reduced`.**

## Order

1. Haptics (cheap, felt immediately, no layout risk)
2. Press feedback (one file)
3. Numeric transitions (mechanical)
4. Zoom transitions everywhere (the big one)
5. Scroll transitions and snapping
6. Symbol effects
7. Shimmer
