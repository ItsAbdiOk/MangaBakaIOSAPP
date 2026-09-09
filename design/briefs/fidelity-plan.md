# Fidelity pass — the plan, ready to start cold

Written 2026-09-09 before starting, so a fresh session can pick this up without
re-deriving anything. Read `fidelity-checklist.md` alongside it: that one holds
the *gaps*, this one holds the *order*.

**Standing rule:** match `design/Mockups/NewBakaManga.html` one-for-one.
Deviate only where following it would genuinely break the app, and then make
the smallest deviation that works and record it here with the reason.

---

## What the new mockup contains

`design/Mockups/NewBakaManga.html` (~1.01 MB, distinct from the original
`BakaManga.html`). Eight screens, found via `screen === '<name>'`:

`home` · `stack` · `search` · `mix` · `library` · `schedule` · `tags` · `dropped`

**It changes the information architecture.** Two nav groups appear in the
source: `Discover, Mix, Tags, Library, Dropped` and `Discover, Stack, Mix,
Library`. The second reads as the tab bar — **four tabs plus a floating search
control**, against the five the app ships (Discover, Search, Stack, Mix,
Shelf). Shelf appears to be absorbed into Library and Dropped.

`dropped` having its own surface matches the recommendation made from the
measurement that 46% of the library is dropped.

---

## Order of work

1. **Stack.** Named specifically by Abdi as the screen he liked and we never
   built. The app builds 4 of the mockup's 11 elements — see the table in
   `fidelity-checklist.md`. Highest value, self-contained.
2. **The glass layer.** `MangaBaka/DesignSystem/Glass.swift` defines `floating`
   and `topBar` and neither is used anywhere. Applying it touches every screen,
   so it lands before the screens are individually matched, not after.
3. **Tab bar restructure** to four tabs plus floating search. Touches
   `RootView`, every navigation path binding, and the tab-bar clearance metric.
   Do this before matching individual screens, since it changes their frames.
4. **Existing screens** — Discover against `home`, plus `search` and `mix`.
   Also fix the top inset: `Metrics.scrollTopInset` is 106 and unused while five
   screens hardcode `.padding(.top, 62)`.
5. **New screens** — Library, Dropped, Schedule, Tags. Schedule can be wired
   immediately; its data layer is already built and tested (`Cadence`,
   `MangaUpdatesClient`, `ReleaseScheduleService`, 239 tests green). Library
   needs the entry-editing sheet, which is briefed but not designed.

---

## What the design did not cover

Abdi's instruction: fill these in myself, following the mockup's design
language rather than inventing a second one. Do not treat them as licence to
freestyle — lift spacing, type roles and colour usage from the nearest designed
screen and say which one was used as the reference.

- Onboarding / first run
- Sign-in (token today, OAuth when a `client_id` exists)
- Settings — Account, Content, Formats, attribution
- The failure / empty / stale state family (five error kinds)
- Rating control (five steps: 20/40/60/80/100) and progress control (+1 chapter)
- Publishers, taste profile
- App icon — an App Store blocker, and the current one is a placeholder
- Launch screen — currently the blank system default

---

## Deviations to preserve

Each was a fix for a real failure on hardware. Do not silently revert them to
match a design; if a design contradicts one, raise it rather than choosing.

1. Covers framed at a fixed 2:3 (API returns 14 distinct ratios in one row).
2. Tab bar clearance 96pt (24 cannot clear an 80pt floating bar).
3. The peeking card shows no text (it ghosted through the front card's title).
4. Settings rows are a Button around a drawn switch, not a live `Toggle` (the
   real control only answered a drag). Weakest of the four — revisit if a
   design calls for a standard toggle.

---

## State at the point of writing

- `main` pushed at `9d5db49`. Xcode Cloud is building it.
- That push carried the design brief, the fidelity checklist, the
  release-schedule data layer and `PRIVACY.md`.
- 239 tests green, lint clean, warnings are errors.
- TestFlight build 19 is `VALID` — that is the one to install; it predates the
  schedule layer.
- Not yet done: external TestFlight group for Abdi's brother (steps given, age
  rating needs answering honestly at 17+ because of the content opt-in).

### How to verify a fidelity pass actually landed

A design token defined and never used means a piece of the mockup was measured
and not built. This is the check that would have caught the original gap:

```sh
for t in $(grep -oE 'static let [a-zA-Z]+' MangaBaka/DesignSystem/Metrics.swift | awk '{print $3}'); do
  n=$(grep -rho "Metrics\.$t\b" MangaBaka --include='*.swift' | wc -l | tr -d ' ')
  [ "$n" -eq 0 ] && echo "Metrics.$t — defined, never used"
done
```

Run it for `Metrics`, `Palette` and `Typography`, and for `Glass.swift`'s
`floating` and `topBar`. Thirteen tokens were unused when this plan was
written; that number should fall, not hold.
