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
