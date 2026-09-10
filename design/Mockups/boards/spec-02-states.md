# Brief 02 — Empty / Error / Stale / Loading — Implementation Spec

Source board: `brief-02-states.png`, 1500×3028px. Phone frame content width measured at 393px (x=44 to x=437 in board pixels), which matches a standard 393pt-wide iPhone (14/15/16 non-Plus/Pro-Max) at 1:1 — **board pixels convert 1:1 to points** throughout this spec. All values below are measured directly off the board unless marked "not determinable."

Colors sampled directly from board pixels:
- Accent: `#F87966` (rgb 248,121,102) — confirmed against brief.
- Amber (stale bar only, NOT the accent): `#EFA831` (rgb 239,168,49).
- Board/screen background: near-black, ~`#090909`–`#000000` depending on layer (pure `#000000` for phone screen content, `rgb(9,9,11)` for the board canvas behind the phone frames — negligible difference, treat both as near-black `#000`).
- Neutral secondary button fill: `rgb(38,38,41)` ≈ `#262629`.
- Card/list-row fill used for icon "mark" boxes on the compact cards: `rgb(15,15,15)`–`rgb(17,17,20)`, i.e. barely lighter than pure black.

---

## 1. The shared error skeleton

The board states explicitly: **"mark, headline, one line of cause, one action"** — four elements, always in that order, top to bottom.

Two different renderings appear on the board and they are NOT the same layout — see the inconsistency flagged at the end of this section.

### 1a. Full-screen rendering (the "offline" example — shown as the hero, full phone frame)

This is the canonical, spelled-out version. Measured off the offline card:

- **Layout**: single column, everything **horizontally centered** on screen. Not pinned to top or bottom edge — the block sits with the mark starting well below the nav/status bar and the button ending well above the tab bar, reading as vertically centered in the available content area (roughly upper-middle: mark top sits ~190pt below the screen's top edge).
- **Mark**: not a plain glyph — an SF-Symbol-style icon (here, a wifi-slash "no connection" glyph) inside a rounded-square container box, ~55×55pt (measured 55×55px), fill `rgb(15,15,15)` (barely lighter than the pure-black screen behind it), corner radius approximately 14–16pt (soft squircle, not a full circle — visually a rounded square, not a circle badge). Glyph color: light grey/white, centered in the box, roughly 20–22pt symbol size.
- **Spacing mark → headline**: ~20pt gap (mark bottom to headline top).
- **Headline**: bold, ~20pt size (single line measured 18px cap-height band), centered, white/near-white.
- **Spacing headline → cause line**: ~25pt gap.
- **Cause line**: regular weight, dimmer grey, centered, wraps to **two lines** in this example (max observed line width ~274pt). Line-height gap between the two wrapped lines ≈ 9pt.
- **Spacing cause → button**: ~23pt gap.
- **Action button**: pill shape, height 45pt, width sized to label (measured 110pt for "Try again"), fully rounded corners (radius ≈ height/2, i.e. a true pill).
- **Max text width**: ~275–280pt (both headline and cause line wrap/center within this width inside the 393pt-wide screen — effective side margins ≈ 59pt each, well past the standard 16–24pt screen padding, meaning the text block is deliberately narrower than the screen, not edge-to-edge).
- **Text alignment**: center, for both headline and cause line.

### 1b. Compact "list card" rendering (the other five causes, as drawn on the board)

On the board, the five other causes are stacked as separate rounded-rect cards in a vertical list for side-by-side comparison — **not** as five separate full phone screens. Each compact card uses a **different, left-aligned, horizontal** arrangement:

- Mark: smaller icon box, ~40×40pt, dark neutral fill, **top-left** of the card (not centered).
- Headline: bold, sits to the right of the mark on the same row (not below it, not centered).
- Cause line: regular weight grey, full card width, left-aligned, below the headline row.
- Button(s): pill, neutral grey fill by default, left-aligned, below the cause text.
- Card container: rounded rectangle, subtle 1px border, inset padding ~16–20pt, stacked with ~16pt gaps between cards.

**⚠️ Flag for you before building**: the brief's own caption says the five causes are "the same block" as the full-frame offline example, implying they should reuse the section 1a centered skeleton at full-screen size. But the board actually draws them as compact left-aligned horizontal cards for comparison purposes. This is very likely just a board/review-layout convenience (stacking six full phone screens side by side would be impractical to review), not a second, real in-app layout — but it is genuinely ambiguous from the image alone. **Recommend building every one of the six causes as a full-screen centered layout per section 1a**, and treat the compact cards as the board's shorthand rather than a literal second component. Confirm with the designer if inline (non-full-screen) error cards are actually needed somewhere in the app.

---

## 2. Per-cause differences

| Cause | Mark (SF Symbol-style glyph) | Button(s) | Notes |
|---|---|---|---|
| Offline | Wifi-slash icon | **One** pill button, "Try again" | Rendered as the accent-filled example in the hero — see inconsistency note below |
| Rate limited ("Too many requests, briefly") | Hourglass icon | **One** pill button, "Retry now", neutral grey fill `rgb(38,38,41)` | Countdown text sits **inline as the last (bold) sentence of the cause copy**, directly above the button — not a separate element, not attached to the button itself. On the board: "...this may not be you at all. **Retrying in 38s.**" then the button below. |
| Server error ("MangaBaka had a problem") | Triangle-exclamation icon | **One** pill button, "Try again", neutral grey fill | |
| Needs an account ("This part needs an account") | Person-with-plus icon | **One** pill button, "Open Settings", **filled accent** (`#F87966`) | Confirmed by pixel sample: this button is the only one in the compact-card list sampled at true accent color. Card also reads with a subtly warmer/reddish border stroke vs. the neutral grey border on the other cards — exact color not determinable from the board, but it's visibly distinct, not the same neutral grey as the other five. |
| Decode failure ("Something went wrong") | Question-mark-in-circle icon | **Two** pill buttons side by side, "Try again" + "Check for an update", both neutral grey fill | Shares literal copy/headline with transport failure by design — see board's own callout in section D notes. |
| Transport failure ("Something went wrong") | Question-mark-in-circle icon (same glyph as decode failure) | **One** pill button, "Try again", neutral grey fill | Same headline/body wording as decode failure on purpose (board note: "a reader cannot act on the difference, and both drop what was cached") |

**Confirmed**: "Needs an account" is the only card in the five-item comparison list with a filled accent button; the other four/five there use the neutral grey pill (`rgb(38,38,41)` fill, same grey as the button chrome elsewhere in the app).

**Inconsistency to flag**: the standalone "offline" hero screen's "Try again" button samples as true accent `#F87966`, not the neutral grey used by "Try again" everywhere else in the compact list (including "MangaBaka had a problem," which is also styled "Try again" but rendered neutral grey). Per the board's own stated rule ("needs an account is the only card with a filled accent button, because it's the only one where tapping fixes something"), the offline hero's button should logically also be neutral grey — reconnecting isn't something the app can fix by itself either. Build "Try again" (offline, server error, transport failure, decode failure) and "Retry now" (rate limited) as **neutral grey**, and treat the hero's accent-colored render as a one-off inconsistency in the mockup, not spec.

---

## 3. The stale bar (most important piece)

Exact measurements from the "Discover" screen example:

- **Position**: NOT a full-width top banner and NOT floating — it sits inline in the content flow, directly under the screen's title + subtitle ("Discover" / "Thursday · 268 series cached"), above the first content section ("Rising this week"). Per the board's own caption: "It sits under the title, scrolls away with the content, and returns on the next failed refresh" — i.e. it is part of the scrollable content, not pinned/sticky.
- **Width**: **inset**, not full-bleed. Card left/right edges sit inset from the screen edges by the same margin as the screen's normal content padding (matches the "Discover" title's left margin).
- **Height**: measured ~78–80pt tall (accommodates a 2-line text stack plus padding).
- **Background**: a distinct card fill, slightly lighter than pure black screen background (dark neutral grey card, not colored) — **the amber (`#EFA831`) is used ONLY as a small status dot, not as the bar's background.** Do not fill the bar amber.
- **Corner radius**: fully rounded rect, generous radius, visually ~16pt (matches the other card radii on this board).
- **Icon**: not a symbol/glyph — a small solid amber **dot** (circular bullet, ~8pt diameter), positioned at the left, vertically centered against the second text line (the detail line), not the headline.
- **Text arrangement**: two lines, left-aligned, stacked, positioned to the right of the amber dot:
  - Line 1 (bold, white): "Showing yesterday's" — states the fact plainly.
  - Line 2 (regular, dimmer grey): "Last updated 19 hours ago · refresh failed" — detail/cause, can wrap to two lines if long (it does here).
- **Retry control**: a small pill button, "Retry", neutral grey fill, positioned at the **far right**, vertically centered against the whole bar (not just one line).
- **No large mark/icon box** — unlike the error skeleton, this uses only the small amber dot, confirming the board's point that stale-but-showing "is not an error screen at all."

---

## 4. The four empty states

Board's mapping rule: **"an invitation gets a filled button; a dead end gets a way out; a finished thing gets neither."**

| State | Elements present | Elements absent | Button treatment | Category |
|---|---|---|---|---|
| **Library, nothing saved** ("Nothing saved yet") | Eyebrow label, headline, one line of cause/explanation, one button | No mark/icon (board note: "same skeleton as the errors, **no mark**") | Filled accent pill, "Open the stack" — confirmed accent-filled by pixel sample | Invitation |
| **Stack exhausted** ("That's today's stack") | Eyebrow label, headline, one line of stats ("18 seen, 5 saved. A new one is dealt tomorrow morning."), one button | No mark/icon | **Outline/ghost button, no fill** — "See what you saved" samples as background-matched with only a border stroke, no accent, no grey fill | Finished thing → gets neither (no filled button) |
| **Search, no results** ("Nothing for 'vinlnad saga'") | Eyebrow label, headline (echoes the mistyped query), one line of cause, **two actions** | No mark/icon | Primary: filled **neutral grey** pill, "Search 'vinland saga' instead" (a spelling-corrected retry — the "way out"). Secondary: plain text/ghost button below it, "Clear filters" — no visible fill, sits directly under the primary button | Dead end → gets a way out (two escape routes, neither one is accent-filled) |
| **Search, idle** | See section 5 below — structurally different, no headline at all | Mark, headline, cause line all absent | No single action button — see section 5 | N/A — this is not an empty state in the error-skeleton sense |

Note: none of the four empty states use the mark/icon box from the error skeleton — confirmed by the board's own caption ("Same skeleton as the errors, **no mark**"). They keep only: eyebrow label (small caps grey, e.g. "LIBRARY, NOTHING SAVED" — this reads as a board annotation/category label; confirm with designer whether it is meant to render as real in-screen UI chrome or is just the board's own captioning convention), headline, one line of body copy, and 0–2 buttons.

---

## 5. Search, idle — layout in detail

This is explicitly NOT an empty-state treatment. Board quote: **"No headline at all — an idle field is not an empty state. Recent searches and saved lenses fill the space instead."**

Structure observed:
- No mark, no headline, no centered block at all.
- Content is a set of **tappable pill/chip rows**, wrapped left-to-right, left-aligned (chip-flow layout, like a tag cloud), not a vertical list of full-width rows.
- Three chips visible: "murim", "Completed manhwa 8+", "regression" — wrapped onto two rows (two chips on row 1, one on row 2).
- Chips are pill-shaped, neutral grey outline/fill (same visual weight as the secondary buttons elsewhere), sized to their text content.
- **Not determinable from the board**: whether "recent searches" and "saved lenses" (mentioned in the caption) are visually grouped under separate section headers — no section labels/headers are visible above the chips in this crop; they appear to render as one undifferentiated chip group. If the two categories need distinct headers or visual separation, that's a decision for you, not something the board specifies.

---

## 6. Loading

### 6a. First load of a screen (skeleton grid)

- Skeleton shapes: solid rounded-rect blocks standing in for cover thumbnails, arranged in the **same 3-column grid** the real content grid uses (matches the "Rising this week" cover grid dimensions elsewhere on the board) — confirms the board's caption: "Skeletons in the real grid, not a spinner — the layout does not jump when covers arrive."
- Each skeleton cell: one tall rounded-rect (the cover placeholder, ~2:3 aspect ratio, corner radius ~12pt) plus **two short bar placeholders below it** (title line + subtitle line), left-aligned under each cover, varying slightly in width to avoid a too-uniform look.
- Cover placeholder fill: dark neutral grey, slightly lighter than pure background (matches other skeleton/placeholder fills on this board, ~`rgb(28,28,30)` range — exact value not sampled, treat as a standard "skeleton grey").
- **Animation**: the board is a static image, so shimmer motion itself is not directly observable. However, the caption explicitly says **"BlurHash takes over per cover"** once a real cover image is available — meaning the flow is: static/skeleton block → BlurHash placeholder (blurred color preview) → real image, per cell, independently, as each cover finishes loading (not as one synchronized grid-wide transition). Whether the skeleton phase itself uses a shimmer animation is **not determinable from the board** — build a standard shimmer if your design system already has one, since the board doesn't rule it out, but there's no direct evidence for it either.

### 6b. Pagination footer row ("Loading 500 more")

- **Position**: an inline footer row at the bottom of existing content — explicitly NOT a full-screen state. Board quote: "A footer row, never a full-screen state — there is already content above it."
- **Height**: a single pill-shaped row, measured similar height to the other buttons/bars on the board, ~45pt.
- **Width**: full content width (spans the same inset margins as the surrounding list/grid), rounded-rect container, neutral dark fill.
- **Spinner**: yes — a small circular progress indicator, accent-tinted (partial ring, consistent with a standard iOS `ProgressView` spinner styled in the accent color), positioned to the **left** of the label text, both centered together within the row.
- **Text**: regular weight, white/light grey, reads "Loading 500 more" — the board explicitly calls out that the count is meaningful copy, not filler: "It names the page size, because at 1,200 entries a reader deserves to know this takes three rounds." Build this as a template string (e.g. "Loading {pageSize} more"), not a hardcoded string.

---

## Open items not determinable from the board

- Exact corner radius values (given as visual approximations, ~14–16pt for cards/icon boxes, ~12pt for cover thumbnails) — no ruler/grid overlay on the board to confirm precisely.
- Exact skeleton fill color and whether it shimmers.
- Whether "recent searches" vs "saved lenses" get separate headers in Search Idle.
- Whether the eyebrow labels on the empty-state cards ("LIBRARY, NOTHING SAVED" etc.) are real in-app UI text or board-only captions.
- Schedule's empty state — explicitly not drawn on this board; the board's own note says it needs its own copy pass first.
- Needs-account card border color — visibly distinct/warmer than the other five, exact value not sampled.
