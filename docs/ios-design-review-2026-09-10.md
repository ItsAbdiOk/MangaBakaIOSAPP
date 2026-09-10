# MangaBaka — iOS design review, 2026-09-10

Run on a real iPhone 16 Pro (mirrored), plus a static audit of the design
system. Report only; nothing was changed.

Scores are 0-10 against the gstack iOS rubric. Where a number could be
measured from source rather than eyeballed from a screenshot, it was.

---

## Part 1 — measured from source

These hold everywhere in the app, so they are reported once rather than per
screen.

### Colour contrast — the biggest finding

The ground is `#08080B`. Text colours are `#EBEBF5` at varying alpha. Ratios
computed against the ground (WCAG AA needs 4.5:1 for body, 3:1 for large):

| token | alpha | ratio | verdict |
|---|---|---|---|
| textPrimary | .96 | 18.37 | pass |
| textBody | .75 | 9.53 | pass |
| textSecondary | .60 | 6.32 | pass |
| textMuted | .50 | 4.66 | pass |
| textTertiary | .45 | 3.96 | large text only |
| textFaint | .40 | 3.34 | large text only |
| **textQuaternary** | **.32** | **2.52** | **fails, even for large text** |
| accent #F87966 | — | 7.54 | pass |

**76 places** in the app pair small type (10.5-12.5pt) with a colour below the
AA body threshold. **26 of those** use `textQuaternary`, which fails even the
large-text threshold, at 10.5-12.5pt — the worst combination in the app.

To clear 4.5:1 on this ground, a text colour needs alpha >= 0.49. Raising
tertiary/faint/quaternary to .49 would collapse four tiers into one, so the
real fix is a decision, not a find-and-replace: keep the faint tiers for
genuinely decorative marks and move informational text (provenance lines,
counts, captions) up to `textMuted` or higher.

Worst offenders, all 11pt on 2.52:1:
`ScheduleRow:82` (where a release estimate came from), `DetailStatsStrip:86`,
`DetailCredits:85,98`, `LibraryList:144,213,215`, `MixFilterStrip:44`,
`BlendDNAView:45,120`, `FilterSheet:102`, `TasteView:72,168,193`,
`BrowseView:54,153,191`, `SeriesDetailView:177`, `DetailEditions:64`,
`ReadingInsightsView:207`, plus three Settings sections.

### Touch targets

`Metrics.headerPill` is **30pt**, and it is used as a fixed or minimum height
for filter chips, tag rows, settings rows and search presets — 14pt short of
Apple's 44pt minimum. Confirmed at `MixFilterStrip:120,180`,
`TagPickerSheet:111,140`, `SettingsRow:162`, `SearchIdleView:174`,
`BlockedTagsSection:62,83`, `SeriesDetailView:355`.

Two controls are worse:
- `MixView:121` — the "x" that removes a mix seed is the glyph alone, roughly
  17pt square.
- `MixView:134` — the empty seed slot is 82 x 41pt; 3pt short.

### VoiceOver

Two icon-only controls carry no label, so VoiceOver announces the symbol name
or nothing: the seed remove "x" (`MixView:121`) and the empty seed "+"
(`MixView:134`). Every other icon-only control checked either has an
`accessibilityLabel` or sits beside its own visible text — 66 explicit labels
across the app, which is good coverage.

### Reduce Motion

15 files animate. **One** respects `accessibilityReduceMotion` — the swipe
stack. The cover gallery's glide, the tag-group expand, the toast, the library
shape change and the settings disclosures all animate regardless of the
setting.

### Animation timing — no finding

Every duration is 0.20-0.28s with one spring at response 0.36 / damping 0.78.
That is inside the rubric's 200-300ms window and correctly damped. Nothing to
fix.

### Spacing rhythm

Values are 7, 10, 11, 12, 13, 14, 16, 18, 22, 24, 26, 28, 30, 34 — not a 4 or
8pt grid. This is a deliberate deviation, not drift: they are the mockup's own
numbers, and the standing instruction is to match the mockup one-for-one.
Recorded so a future reader does not "fix" it.

### Dead tokens

`Metrics.gutterStatus` and `Metrics.backButton` have zero uses.

---

## Part 2 — on the device

Driven through iPhone Mirroring on the real phone, against the real 939-series
library. Two halves: Discover/Search/Filters/Tag picker/Mix/Seed picker/Stack,
and Library/Insights/Schedule/Series detail.

### The worst finding: nothing has a scroll edge

**Content scrolls under the status bar, the Dynamic Island and the navigation
bar with no blur and no scrim anywhere in the app.**

Three independent sightings, all on the phone:

1. **Library, scrolled.** The row title "Breaking A Romantic Fantasy Villain"
   is cut in half by the Dynamic Island, with the clock printed on top of the
   words. The row is simply illegible.
2. **Your reading, scrolled.** A list row shows through behind the "Your
   reading" navigation title.
3. **Series detail, scrolled.** The large title "Mushoku Tensei: Jobless
   Reincarnation" slides up behind the inline navigation title, which reads
   "Mushoku Tensei: Jobless Reincar..." — two copies of the same words on top
   of each other, with cover artwork bleeding through both.

Root cause, confirmed in source: the four tab roots (`DiscoverView:76`,
`SearchView:57`, `MixView:56`, `LibraryView:93`) draw their own title inside
the `ScrollView` with a flat `.padding(.top, Metrics.scrollTopInset)` and no
navigation bar at all, so iOS's automatic scroll-edge effect never applies.
The pushed screens do have navigation bars but no `toolbarBackground`.

This is the single highest-leverage fix in the review: it is one modifier per
screen, and it is the difference between the app looking finished and looking
like a prototype the moment anyone scrolls.

### "Waiting for you" is counting series you have never opened

On the device, five of the eight visible rows read `ch 0`:

- The Devil Butler — Reading, ch 0 of 889 — **889 behind**
- Lady Baby — Paused, ch 0 of 240 — **240 behind**
- Second Life Ranker — Reading, ch 0 of 232 — **232 behind**
- Chainsaw Man — Reading, ch 0 of 232 — **232 behind**
- The Advanced Player of the Tu... — Paused, ch 0 of 223

The section's own subtitle says "Chapters published since you stopped". You
cannot have stopped something you never started. `ReadingInsights.waiting`
(`ReadingInsights.swift:36`) takes `read = entry.progressChapter ?? 0` and
never requires `read > 0`, so the list is dominated by the biggest series in
the library that have never been opened, ranked by total length.

The feature is answering the wrong question — "what is the longest thing I own"
rather than "where did I leave off".

### The schedule's first run is a dead screen

"Next chapters" on first open shows "Not measured yet", a **Measure** button,
and a panel reading **"0 ESTIMATED OF 0 IN SCOPE"**. Below that, roughly 60%
of the screen is empty black.

"0 of 0" is not a number a reader can act on, and nothing says what Measure
will do or that it takes minutes (MangaUpdates is rate-limited to one request
every three seconds). The screen should say what it is about to do, roughly
how long, and why nothing is there yet.

### Smaller findings, device

- **Series detail** shows the inline navigation title AND the large title
  simultaneously before any scrolling, which is one title too many.
- **Library rows** end in a dim em dash for an unrated series. At
  `textQuaternary` it is nearly invisible and means nothing on its own.
- **Mix, Blend button.** The disabled state is `.opacity(0.4)` over the same
  accent fill (`MixView:194`) — a faded version of the live button rather than
  a disabled colour.
- **Mix seed picker.** The per-row "+" is roughly 28pt.
- **Filters sheet.** "Clear all" wipes every filter with no undo and no
  confirmation. (The earlier claim that it is styled as an inert chip was
  wrong — it is a normal secondary button.)
- **Tag picker.** Each row carries a 44 x 3pt orange bar that is the tag's
  breadth. There is no legend anywhere in the sheet, and a reviewer looking
  straight at it concluded it was a leftover slider control. VoiceOver is
  told what it means ("Broad, 9,000 series"); a sighted reader is not.
- **Search idle.** "Browse", "Surprise me" and "Clear" are three
  same-weight accent links with no hierarchy between them.

### Checked and NOT a finding

- The orphaned card at the end of the search results grid is ordinary
  `LazyVGrid` behaviour with three flexible columns, not a layout bug.
- Animation timing is correct throughout (0.20-0.28s, one spring at
  0.36/0.78).
- The tab bar minimising on scroll is `.tabBarMinimizeBehavior(.onScrollDown)`
  behaving as Apple intends. It did not visibly restore on scroll-up under
  mouse-wheel scrolling, but that is likely a mirroring artefact rather than a
  defect — it needs a finger to confirm, so it is recorded as unverified.

### Not audited

Shelf detail, the Library inline search with results, the cover gallery on
device, Settings on device, the blocked-tags screen on device, and a
mid-drag Stack card. The first attempt at the Library half was lost to a
tooling failure and the phone time was spent on the screens above instead.

---

## Fix list, in the order worth doing

1. Give every scrolling screen a scroll edge (blur behind the status bar and
   navigation bar). One modifier per screen; fixes the worst-looking defect in
   the app.
2. `ReadingInsights.waiting` — require `read > 0`, with a test.
3. Raise informational text off `textQuaternary` (2.52:1). Decide the tier
   split rather than bumping every token to .49.
4. Chips and rows to a 44pt minimum height; mix seed "+" and "x" to 44pt with
   VoiceOver labels.
5. The schedule's first-run state: say what Measure does and how long it takes.
6. Reduce Motion on the 14 animating surfaces that ignore it.
7. A real disabled colour for the Blend CTA.
8. A legend for the tag-breadth bar, or remove it.
9. Delete `Metrics.gutterStatus` and `Metrics.backButton`.

---

## Part 3 — Apple's own accessibility audit

`XCUIApplication.performAccessibilityAudit` run over Discover, Stack, Mix,
Library, a series page and Settings. This is mechanical rather than
impressionistic: it walks the real view hierarchy and measures. 86 issues.
Raw output: `docs/accessibility-audit-2026-09-10.tsv`.

Added as its own target and scheme, kept out of the pre-push run for the same
reason as the performance tests:

    xcodebuild test -scheme MangaBakaAccessibility -destination '<a simulator>'

### It confirms the contrast finding, with the elements named

47 contrast issues, "failed" or "nearly passed", on every screen. Notable ones
the manual pass did not catch:

- **Series titles themselves fail** — "ONE PIECE", "Solo Leveling",
  "Omniscient Reader" on Discover; "RUNAWAY FAMILY" and "Breaking A Romantic
  Fantasy Villain" in the Library. These are `textPrimary`, which measures
  18:1 against the ground, so the audit is measuring them against what is
  actually behind them, not against the token. Worth reproducing before fixing.
- **"SAVE" and "SKIP" on the swipe stack**, which are drawn over arbitrary
  cover art — contrast there cannot be guaranteed by a colour choice alone.
- **The "Blend" button**, which is the disabled-state finding arriving a
  second time: 0.4 opacity over the accent fails outright.
- **The count halves of the Library state chips** — "71", "171", "1", "939".
- **The em dash** used for an unrated series.

### Hit areas — Apple names the same controls

9 issues, and they are precisely the ones measured in the static audit:

- "Reading, 71 series", "Rereading, 1 series", "Paused, 171 series",
  "Completed, 134 series", "Plan to read, 133 series", "Dropped, 429 series"
  — the Library state chips, all 30pt.
- "Sort by Recently updated".
- The state legend as a whole.
- The token field in Settings.

### Two categories the manual pass missed entirely

- **Text clipped** (4, Discover): the meta line under a cover card —
  "Manga · 7.0", "Manhwa · 8.7", "Manga · 8.9" — is being clipped at its
  current size, not merely at large Dynamic Type.
- **Dynamic Type partially unsupported** (15, across Discover, Library, Mix,
  Stack, Settings): "ch 120", "ch 138", "Manga · 7.0" and friends. These use
  `typeGridMeta`, which is declared `relativeTo: .caption2`, so the reason it
  is only "partially" supported needs checking rather than assuming.

Both are worth a look before the contrast work, because they are small and
they are certain, where some of the contrast hits need reproducing first.
