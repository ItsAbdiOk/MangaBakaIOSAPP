# MangaBaka — design brief for Claude Design

Six screens to design. Everything below is measured against the live API and
the running app on 2026-09-09, not imagined. Where a number appears, it is a
real number from Abdi's own account (937 series).

Read `design/current-app/` alongside this — those are screenshots of the app as
it exists today, so new work extends the vocabulary rather than replacing it.

---

## Part 1 — The existing design system

These are lifted from `MangaBaka/DesignSystem/`. New screens should use them.
Do not introduce a second palette or a second type ramp.

### Colour

Dark only. The app pins `.preferredColorScheme(.dark)`; there is no light mode
and none is planned.

| Token | Value | Used for |
|---|---|---|
| `ground` | `#08080B` | Screen background |
| `imagePlaceholder` | `#131318` | Cover placeholder before load |
| `rowOpaque` | `#0F0F14` | Opaque row backgrounds |
| `surfaceInset` | white 3.5% | Recessed surfaces |
| `surface` | white 4.5% | Cards, grouped rows |
| `surfaceChip` | white 6% | Chips, secondary buttons |
| `surfaceField` | white 9% | Text fields |
| `surfaceActive` | white 13% | Pressed / selected |
| `textEmphasis` | white 98% | Hero titles |
| `textPrimary` | white 96% | Titles, primary labels |
| `textBody` | `#EBEBF5` 75% | Body copy |
| `textSecondary` | `#EBEBF5` 60% | Subtitles |
| `textTertiary` | `#EBEBF5` 45% | Meta, captions |
| `textQuaternary` | `#EBEBF5` 32% | Footnotes, disabled |
| `accent` | `#FF7F63` | The one accent. Warm coral |
| `onAccent` | `#180B06` | Text on accent fill only |
| `positive` | `#4FC98A` | Success / signed-in dot |
| `hairline` | white 8% | Row dividers |
| `border` | white 10% | Card borders |
| `glassEdge` | white 13% | Glass edge highlight |

`onAccent` is a near-black brown that only works **on** the coral fill. It has
already caused one bug by being used on a grey disabled background, where it
rendered black-on-black.

### Type ramp

System font throughout, no custom faces. Named roles rather than sizes, because
every one of them scales with Dynamic Type:

`typeScreenTitle` · `typeStackTitle` · `typeDetailHeroTitle` · `typeSheetTitle` ·
`typeSectionHeader` · `typeDetailSectionHeader` · `typeSubsectionHeader` ·
`typeCTA` · `typeBody` · `typeRowTitle` · `typeSubtitle` · `typeChip` ·
`typeCardTitle` · `typeWordmark` · `typeSmallMeta` · `typeEyebrow` ·
`typeFootnote` · `typeGridMeta` · `typeTabLabel`

### Spacing, radii, sizes

| Token | Value |
|---|---|
| `gutter` | 18 |
| `sectionGap` | 26 |
| `detailRowGap` | 28 |
| `gapChips` / `gapStrip` / `gapCovers` / `gapHero` | 7 / 10 / 12 / 16 |
| `radiusSheet` / `radiusStackCard` / `radiusCard` | 26 / 20 / 16 |
| `radiusCoverRow` / `radiusCoverGrid` | 13 / 12 |
| `ctaPrimary` / `ctaDetail` / `ctaSecondary` | 52 / 48 / 46 |
| `field` / `headerPill` | 40 / 30 |
| `coverRowWidth` / `coverDetailHeroWidth` | 118 / 126 |
| `coverAspect` | 2:3, always |
| `tabBarClearance` | **96** |

### Four rules that are not negotiable

1. **Covers are always 2:3.** The API reports per-scan dimensions that vary
   wildly — one 20-item row came back with 14 distinct ratios from 0.63 to
   0.88. Framing each at its own ratio made rows visibly ragged. Art is cropped
   to fill a fixed 2:3 frame.
2. **Every scrolling screen reserves 96pt at the bottom.** The tab bar floats
   over content. Passing *under* it is intended; being unable to scroll clear
   of it is a bug, and was one on all six screens.
3. **No fixed heights around text.** Dynamic Type has produced four separate
   clipping bugs here, three of them the same mistake. Use `minHeight`.
4. **Glass on the tab bar only.** Live blur under a moving cover feed is
   expensive on GPU and battery. The spec limits it deliberately.

### One known visual problem, worth solving in this round

The floating tab bar's translucency lets cover art bleed through hard enough to
hurt legibility — visible in `04-search-results.png` and `08-detail.png`. A
treatment that keeps the glass but restores contrast would be welcome.

---

## Part 2 — The screens

Priority order. 1 and 2 are the ones worth doing first.

---

### 1. Library — the biggest gap in the app

**The problem.** Abdi has **937 series** tracked on MangaBaka. The app can read
every one of them and shows none. This is the largest gap between what the app
knows and what it displays.

**The fact that should shape the design.** The obvious layout leads with
"Reading". That would bury 92% of the library. The real distribution:

| State | Count | Share |
|---|---:|---:|
| Dropped | 429 | 46% |
| Paused | 171 | 18% |
| Completed | 134 | 14% |
| Plan to read | 131 | 14% |
| Reading | **71** | **8%** |
| Rereading | 1 | 0% |

Nearly half is **dropped**. A design that treats dropped as an afterthought is
designing for a library he does not have. Dropped is also the most interesting
state nobody builds for: it is a record of what he gave up on and why.

Also true: **75%** have chapter progress, **45%** carry his own rating.

**Data available per entry** (`/v1/my/library`, real field names):
`state`, `progress_chapter`, `progress_volume`, `rating` (0-100), `note`,
`start_date`, `finish_date`, `number_of_rereads`, `priority`, `is_private`,
`read_link`, plus the full nested `Series` (cover, titles, authors, status,
type, total_chapters).

Progress is directly expressible: `progress_chapter` against
`Series.total_chapters` gives a real completion figure for 75% of the library.

**What to design**
- The default view. Which state leads, and how the other six are reached.
- A library row or cell: cover, title, progress, his rating, state.
- How 937 items are made navigable — search within, sort, filter, or jump.
- Empty state for a reader with no MangaBaka account (most users).

**States needed:** loading, loaded, empty (no account), empty (account, no
library), error.

---

### 2. Mix DNA — make the recommender legible

**The opportunity.** A blend returns a `dna` field: ten tags with weights,
explaining what the blend actually *is*. This turns the recommender from "trust
me" into something a reader can see and steer. It has been sitting unused
because `/v1/series/mix` never successfully decoded until yesterday.

**Real response** (seeded from one series):

```
seed_count: 1
dna: Kuudere 0.161 · Kuudere Characters 0.138 · Unaging Female Lead 0.118
     Twins 0.112 · Eye Powers 0.109 · Split Personality 0.082
     Super Powers 0.081 · Vampires 0.068 · Special Ability 0.067
     Urban Fantasy 0.065
```

Weights are floats that sum to roughly 1. Ten of them. The top weight here is
0.16 and the tenth is 0.065, so the spread is shallow — a visualisation that
relies on dramatic differences in magnitude will look flat on real data.

**Per-result data:** `score`, `cosine`, `shared_tags`, `shared_tags_total`,
`matched_author` (bool), `matched_related` (bool), `matched_seed_ids`.

**What to design**
- How the DNA of a blend is shown. It is the identity of the mix, not a footnote.
- Ideally: whether a reader can *push* it — damp a tag, boost another.
- How an individual result says why it matched (shared tags, same author).

**Existing screen:** `05-mix.png`. Today Mix is three empty seed slots and a
Blend button; the DNA has nowhere to live.

---

### 3. Taste profile

**Data:** `/v1/my/series/discover/top-genres` returns `tag_id`, `tag_name`,
`affinity_score`. Real sample from his account:

```
Time Travel                 83.7
Transmigrated into a Game   52.0
Age Regression              37.5
```

**Flag, unresolved:** the endpoint returned only **3 rows** for a 937-series
library. Either that is the whole answer or it needs a parameter I have not
found. Design for a handful of strong affinities rather than a long list, and I
will confirm the ceiling before build.

Scores are unbounded-looking (83.7 is not a percentage of anything stated). Do
not present them as percentages.

---

### 4. Tag browsing

**Data:** `/v1/tags` — **7,105 tags**, and they are a *tree*, not a list.
Fields: `id`, `name`, `name_path` ("Activities > Acrobatics"), `parent_id`,
`level`, `series_count`, `is_genre`, `is_spoiler`, `content_rating`,
`merged_with`.

Real rows:

| Tag | Path | Level | Series |
|---|---|---:|---:|
| Activities | Activities | 1 | 0 |
| Acrobatics | Activities > Acrobatics | 2 | 19 |
| Apprenticeship | Activities > Apprenticeship | 2 | 96 |

Three things worth designing around:
- **`series_count` varies enormously.** A tag on 19 series should not get the
  same weight as one on 9,000.
- **`is_spoiler`** exists. Some tags give away plot and should be hidden or
  revealed deliberately.
- **`merged_with`** points at a survivor. Merged tags must never be shown; they
  lead nowhere.

There are also **46 flat genres** (`/v1/genres`) — Action, Adventure, Comedy,
Boys Love, Doujinshi — which are a much smaller, friendlier entry point than
7,105 tags.

---

### 5. Release calendar

Upcoming volumes with real publication dates, prices and ISBNs. Documented in
`docs/designs/api-opportunities.md`. The one genuinely time-shaped surface in
the app — everything else is a catalogue.

---

### 6. Publishers

`/v1/publishers` reports **500** publishers. The field list could not be read
in this pass — the endpoint returned a database error — so treat the shape as
unconfirmed and design conservatively until I verify it.

---

## Part 3 — What exists today

`design/current-app/`:

| File | Screen |
|---|---|
| `01-discover.png` | Discover — three horizontal cover rows |
| `02-stack.png` | Stack — swipe card, with per-card reason and source caption |
| `03-search-idle.png` | Search, idle, with "Surprise me" |
| `04-search-results.png` | Search, 3-column results grid |
| `05-mix.png` | Mix — empty seed slots, filters, Blend |
| `06-shelf.png` | Shelf — near-empty, only a collapsed "Skipped (28)" |
| `07-settings.png` | Settings — Account, Formats |
| `08-detail.png` | Series detail — hero, chips, synopsis |

Also available: `design/covers/` holds 14 real cover images, and
`design/Mockups/BakaManga.html` is the original mockup this app was built from.

**Two screenshots show real problems** rather than finished work: `06-shelf.png`
is nearly empty because the shelf genuinely is, and both `04` and `08` show the
tab-bar bleed described above.

---

## Part 4 — Constraints

- **iOS 26, SwiftUI, dark only.** Liquid Glass is available and used sparingly.
- **Everything scales.** Dynamic Type up to the largest accessibility sizes.
  Cover cards already widen by 1.5x at accessibility sizes rather than wrapping
  titles into oblivion.
- **VoiceOver.** The Stack is a drag surface and VoiceOver cannot drag, so it
  exposes explicit actions. Any new gesture-driven design needs the same.
- **Reduce Motion** is honoured; the card-throw animation is skipped under it.
- **Content filtering is real.** Safe and suggestive by default, anything
  stronger behind a deliberate opt-in, and there is a separate format filter
  (manga / manhwa / manhua / novel / oel / other). Both are server-side.
- **Attribution is required.** CC BY-NC-SA 4.0 — MangaBaka and its upstream
  sources must be credited. No ads, no purchases.
- **Rate limits are shared per IP**, so partial failure is ordinary. Every
  screen needs a sensible state when one endpoint fails and others do not.

## Part 5 — What I need back

Per screen: the layout, the states (loading / empty / error / loaded), and the
components. If a screen needs a component the app does not have yet, name it
and specify it rather than assuming one exists.

The two worth your best effort are **Library** and **Mix DNA**. Library because
937 series are invisible today; Mix DNA because it is the only thing here that
would make the recommendations arguable rather than magic.
