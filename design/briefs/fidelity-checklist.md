# Fidelity checklist — what to fix when the mockups land

**Standing rule (Abdi, 2026-09-09):** match the mockups one-for-one. Deviate
only where following them would genuinely break the app, and then make the
smallest deviation that works and say so.

Do this pass **before** building new screens, not after.

---

## How this was found, so it can be found again

Design tokens that are defined and never used are the signal that a design was
*tokenised* rather than *implemented*. The audit is one command:

```sh
for t in $(grep -oE 'static let [a-zA-Z]+' MangaBaka/DesignSystem/Metrics.swift | awk '{print $3}'); do
  n=$(grep -rho "Metrics\.$t\b" MangaBaka --include='*.swift' | wc -l | tr -d ' ')
  [ "$n" -eq 0 ] && echo "Metrics.$t — defined, never used"
done
```

Run it for `Metrics`, `Palette` and `Typography`. Every hit is a piece of the
mockup that was measured and then not built.

---

## Known gaps, from the audit on 2026-09-09

### The whole glass layer is unbuilt

`MangaBaka/DesignSystem/Glass.swift` defines `floating` and `topBar`.
**Neither is used anywhere.** The app's headline material — Liquid Glass on
iOS 26 — exists as a file and is applied to nothing.

### The Stack screen is roughly a third of the mockup

The mockup's Stack carries eleven things. The app builds four.

| In the mockup | Built? |
|---|---|
| `BAKAMANGA` wordmark header | No — `typeWordmark()` has zero uses |
| "Cached 2m" status pill | No — `Metrics.gutterStatus` has zero uses |
| Overflow (`...`) menu | No |
| "The stack" screen title | No |
| "Drag the cover aside · tap it to open" instruction | No |
| "0 saved" counter | No |
| Card position badge ("1") | No |
| Neighbours peeking **left and right** | No — one card sits *behind and below* instead |
| Meta line: "Manhwa · 2022 · 7.8 from 6.4k" | No — only authors are shown |
| Tag chips (Revenge · Historical · Regression) | No |
| Three actions: skip chevron, "Details", coral `+` | No — drag only, plus VoiceOver actions |
| "Saved from the stack" strip → "Shelf ›" | No — `Metrics.coverSavedStripWidth` unused |

### Top spacing is wrong on every scrolling screen

`Metrics.scrollTopInset` is **106** and has zero uses. Five screens hardcode
`.padding(.top, 62)` instead. `Metrics.scrollBottomInset` (150) is likewise
unused.

### Other tokens defined and never built against

`Metrics.backButton` · `Metrics.ratingSegment` · `Metrics.toggle` ·
`Metrics.coverRowWidthCompact` · `Metrics.coverUpcomingThumb` ·
`typeTabLabel()` · `Palette.rowOpaque` · `Palette.surfaceInset` ·
`Palette.surfaceActive`

`coverUpcomingThumb` is worth noting: the mockup anticipated a release-calendar
thumbnail long before that feature was briefed.

### Information architecture may differ

The mockup's tab bar and the app's are not obviously the same shape — the app
ships Discover / Stack / Search / Mix / Shelf, and the mockup's Stack screen
shows a different arrangement with a floating search control. Resolve against
the new mockups rather than assuming either is right.

---

## Deviations to KEEP, with their reasons

These were changed against the mockup deliberately, each after a real failure
on hardware. Do not silently revert them to match a design.

1. **Covers are framed at a fixed 2:3.** The mockup sized each cover from its
   own reported dimensions. One 20-item API row returns 14 distinct aspect
   ratios spanning 0.63 to 0.88, which made rows visibly ragged with titles on
   different baselines.
2. **Tab bar clearance is 96pt, not 24.** 24pt cannot clear an 80pt floating
   bar, so the last row of every screen was unreachable.
3. **The peeking card shows no text.** Its title rendered at half opacity
   directly through the front card's title.
4. **Settings rows are a Button wrapping a drawn switch, not a live `Toggle`.**
   The real control only ever responded to a drag, never a tap, verified
   repeatedly on device. This one is a workaround for behaviour never fully
   explained, and is the weakest of the four — worth revisiting if a design
   calls for a standard toggle.

---

## Things in the app that were never designed at all

These are engineering constructions wearing the mockup's colours. They are in
`design/current-app/` screenshots, so a designer may mistake them for settled
design. They are not.

- Settings, entirely — Account, Content ratings, Formats, attribution
- The Shelf screen
- The failure / empty / stale state family
- Pagination affordances and their spinners
- The Stack's source caption and per-card reasons
- The drawn switch component


---

## Result of the pass (2026-09-09)

All nine screens in `NewBakaManga.html` are built: home, stack, search, mix,
library, dropped, schedule, tags, plus the floating chrome.

`Glass.swift` went from **zero uses to six**. The unused-token count went from
**13 to 6**, and three of the six that remain are deliberate.

### Still unused, deliberately

| Token | Why |
|---|---|
| `Metrics.gutterStatus` | The mockup draws a fake iOS status bar. The real one is drawn by iOS. |
| `Metrics.backButton` | The mockup has a custom 38pt circular back button. The system navigation bar's own control is used instead: it handles the edge-swipe gesture and VoiceOver for free, and the custom top bar now hides on pushed screens so it is visible. |
| `Palette.rowOpaque` | No surface currently needs an opaque row. |

### Ruled out, with the reason (2026-09-09)

**The density setting is not a feature.** `coverRowWidthCompact` (100pt) sat on
this list for weeks as an unbuilt setting. It is a prop in the mockup's own
editor panel — `density: { editor: 'enum', options: ['Comfortable', 'Compact'] }`
— sitting next to `accent` and `glassBlur`. Those are knobs for the designer to
preview with, not controls the app was meant to ship. The token is deleted and
`coverRowWidth` carries the reason, so it does not get re-proposed.

The check that distinguishes the two: search the mockup for the token's name.
A real feature appears in the rendered markup. A design knob appears only in
`this.props`.

**The filter sheet's "Blocked tags" switch is deliberately not built.** The
mockup puts an on/off switch for the whole blocked-tag list inside the search
filter sheet. The list itself lives in Settings and is global. Adding a second
control for it would need a new "blocking is currently off" state that nothing
else in the app has, and two places to change one thing is how they drift. If a
design wants per-search blocking, that is a feature to spec, not a token to use
up.

### Deviations added 2026-09-10, with reasons

**The tab bar is the system's, not a drawing of the mockup's.** The mockup draws
a floating capsule of four tabs plus a detached search circle. On iOS 26 the
system tab bar *is* a floating glass capsule, and `TabRole.search` is what
detaches search from it — so the mockup's arrangement is what the system already
produces. The hand-drawn version cost the selection indicator that sizes to its
label and slides under a dragging finger, the scroll-away behaviour, and real
Liquid Glass's specular response. `AppTabBar` is deleted.

**The mockup's "In collections" row could never have worked.** It draws other
series' covers. `/v1/series/{id}/collections` returns *editions of the series
you asked about* — every row carries the same `series_id`, checked live on
2026-09-10. The mockup's row was populated from a hardcoded list of unrelated
series, so it was placeholder content shaped like a feature. Built instead as
**Editions**: publisher, language, volume count, format, and whether the release
is licensed — which answers a question nothing else in the app answers.

**Tags are grouped rather than listed.** The mockup draws three tag chips; a
real series carries 146. Grouped by `tags_v2`'s own taxonomy, weighted by how
central each tag is to the series, spoilers held back per group. Four groups
show by default and the other thirteen sit behind one control, because grouping
all seventeen fixed the wall and rebuilt it taller.

### Not built from the mockup

- Mix's **Tags** and **Blocked tags** filter sections. The API supports both and
  `SearchQuery` carries tags; only the UI is missing.
- Mix's **"Save as a lens"** button. Lenses ship as presets; writing your own
  needs a design.
- A **library search** field on the Library screen.

### Deviations added during the pass

- Tag chips on the stack card left-align where the mockup centres, because
  `FlowLayout` caps an over-wide item and a long tag used to hang off the edge.
- The stack's left-hand neighbour is absent until the first card is dealt with,
  because there genuinely is no previous card yet.
- Discover's "Open the stack" shortcut says what it does rather than "N left in
  today's stack", which Discover cannot know without duplicating the stack.
- The accent moved to `#F87966`, the sRGB of the mockup's `oklch(0.72 0.16 30)`.
