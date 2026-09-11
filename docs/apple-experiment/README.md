# What Apple's version of MangaBaka would look like

Branch: `apple-idiomatic`. Nothing here is merged and nothing on `main`
changed. Built 2026-09-11, overnight.

Your reasoning, in your words: *when iOS 26 first came out, people who were
using Apple's navbar automatically got the liquid glass version. It's like
those sorts of future upgrades that Apple does with whatever their UI is. You
just get it naturally if you're using Apple's technology.*

That is exactly right, and this branch is an attempt to show you how much of
it you are currently paying for by hand.

## How to run it

```bash
git checkout apple-idiomatic
```

Then build and run as usual. `MangaBakaApp.swift` points at `AppleRootView`;
the shipping root is still in the file underneath, so swapping two lines
switches back. The screens live in `MangaBaka/Apple/` and use the same models,
the same repository, the same cache and the same live data — only the
presentation differs.

## The screenshots

| | |
|---|---|
| `01-discover-light.png` | Discover, at rest, real large title |
| `02-discover-scrolled.png` | **The whole argument in one frame** |
| `03-library.png` | Library as a `List` with `.searchable` |
| `04-library-swipe.png` | Swipe actions, which cost nothing |
| `05-settings-light.png` | Settings as a `Form` |
| `06-settings-dark.png` | The same code in dark |
| `07-discover-dark.png` | The same code in dark |
| `08-detail-dark.png` | A series page |

**Look at `02-discover-scrolled.png` first.** The large title has collapsed to
an inline one and the covers passing underneath it are blurred and lightened —
that is Apple's iOS 26 scroll edge effect, and the code that asks for it is
`.navigationTitle("Discover")`. Compare with what we spent an hour building on
`main` tonight: a `ScrollEdgeScrim`, a window-inset measurement, a weighted
gradient, a scroll-geometry observer and a unit test, to approximate a worse
version of it.

## What the system gives, that we currently write

Everything in this list is already built by hand on `main`, or is missing:

- **Scroll edge effect.** Built tonight as `ScrollEdge.swift`. Free here.
- **A title that collapses as you scroll**, and comes back. Not on `main` at
  all; the four tab roots print a static 34pt title inside the scroll view.
- **Tap the status bar to scroll to top.** Not on `main`. A `List` or a
  `ScrollView` under a navigation bar gets it.
- **The inline title fading in as the large one leaves.** Built tonight as
  `DetailBarTitle.swift`, 55 lines with its own scroll observer.
- **Swipe actions** on library rows. Not on `main` — changing a series' state
  needs a tap into an edit sheet.
- **A search field that lives in the navigation bar**, collapses on scroll,
  and brings its own Cancel and clear buttons. On `main` the clear button had
  to be reported missing by you and then built (`SearchClearButton.swift`).
- **Section headers, footers, separators, insets and the A–Z index.** `main`
  has a hand-written `JumpIndex` for the last one.
- **44pt rows by default.** We spent a commit tonight adding `.tapTarget()` to
  nine controls; a `Form` row is already there.
- **Light mode.** `06` and `07` are the same code as `05` and `01`. `main`
  hard-codes `#08080B` and `#EBEBF5` at fixed alphas and calls
  `.preferredColorScheme(.dark)`, so there is no light mode and there cannot
  be one without redoing the palette.
- **Increase Contrast, Reduce Transparency, Smart Invert.** Semantic colours
  respond to all three. Fixed hex values respond to none.
- **Dynamic Type across the whole range.** We measured tonight that
  `.caption2` does not move across the four smallest sizes, and moved nine
  styles onto `.subheadline` to fix it. `.font(.caption)` would have been
  correct the whole time.

## What gets worse

This is not a recommendation, and the losses are real.

- **It is not your design.** The mockup's floating capsule tab bar, the
  detached search circle, the swipe stack, the dark ground with accent
  `#F87966`, the specific type ramp — all of it goes. What is left looks
  competent and looks like everybody else's app. Discover in particular reads
  as a generic shelf screen rather than as yours.
- **The stack could not survive this.** A card you throw sideways is not an
  Apple pattern; there is nothing to inherit. It would stay hand-built either
  way.
- **Density.** `insetGrouped` is roomy. The library shows fewer series per
  screen than `main` does, and with 939 of them that matters.
- **The blend, the mix DNA, the tag breadth bars, the library shape bar.**
  None of these has a system equivalent. They would be hand-built inside an
  Apple shell, which is a slightly awkward place to put them.

## The honest middle

The interesting answer is not "Apple's version" or "yours". It is that the
free upgrades come from the **containers** — navigation bars, `List`, `Form`,
`.searchable` — and almost none of them come from the **colours and type**.
You could take a real navigation bar on each tab root and keep every other
thing about the design. That would have made four of tonight's fixes
unnecessary and would cost you a title that moves when you scroll, which the
mockup does not draw either way.

If you want one thing from this branch on `main`, take that: real navigation
bars on the four tab roots, custom everything else.

## What is not built here

This is a sketch, not a port. Mix, the swipe stack, Search, the schedule,
insights, the cover gallery and the blocked-tags screen are all absent. So is
every write path — the buttons in `AppleLibraryView` and
`AppleSeriesDetailView` are wired to nothing on purpose, because the point was
to look at it rather than to ship it.
