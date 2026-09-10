# Library screen — implementation spec

Source: `design/Mockups/boards/brief-04-library.png` (1500×2140px, read via cropped PIL sections; phone frames drawn at 393pt wide = 1:1 px:pt, so pixel measurements below can be read directly as points).

Board A = "The list, loaded" (main scroll state). Board B = "Mid-edit" (edit sheet). Board C = "Empty, and still loading" (empty state + partial-load state).

Colours sampled by pixel-picking the PNG (not from a design token file — treat as close approximations, not hex-exact):
- Accent (coral): `#F87966` (rgb 248,121,102) — used for the selected filter pill, the "Reading" band, star ratings, CTA buttons, active sort/jump-index label.
- Screen background (Board A): pure black `#000000`.
- Sheet/card background (Board B/C): `#16161C` (rgb 22,22,28) — a very dark blue-black, distinct from pure black.
- Search field / unselected pill fill: `#141414`–`#1A1A1A` range (rgb ~20,20,20), barely lighter than the black page background.

---

## 1. Header block

- **Title** "Library": large bold, top-left, white. A circular icon button (theme/appearance toggle, sun glyph) sits top-right at the same vertical centre as the title, ~40×40pt, dark-gray filled circle.
- **Count line** "1,204 series · 512 rated": directly under the title, small, medium-gray, single line.
- **Search field**: rounded rectangle, fill `#141414`-ish (slightly lighter than pure-black page bg), measured height **~42pt**, width = full content width (margins ~20pt each side, i.e. ~353pt on a 393pt frame). Corner radius reads as fully/near-fully rounded (stadium-ish but not a perfect capsule — roughly 14–16pt radius, not half-height). Leading magnifying-glass icon, gray, followed by placeholder text "Find in your library" in medium-gray, regular weight. No visible border/stroke.
- **Pinned vs scrolling**: per the board's own caption ("Search and the state filter are pinned; the bar under them is the shape of the library"), the search field and the state-filter pill row are pinned to the top and stay fixed while the list scrolls. The shape bar, "Pick back up" row, and "All series" list all scroll underneath them.

## 2. State filter row

- Horizontal row of capsule pills: "All 1,204", "Reading 86", "Paused 41", "Compl…" (cut off — scrolls horizontally, confirming the row is wider than the screen).
- Pill height: **~32pt** (measured 220–251px in the source). Fully rounded capsule (radius = half height).
- Selected pill ("All 1,204"): solid accent-coral fill (`#F87966`), bold near-black text.
- Unselected pills: dark-gray fill (close to `#3C3C3C`/`#2C2C2E` range, distinctly lighter than the page background but darker than the pill fill would suggest at a glance — sample it against your own gray-100 token rather than trust an exact hex here), light-gray/white regular-weight text.
- Horizontal gap between pills: ~8–10pt.
- Confirmed horizontally scrollable (last pill "Completed" is truncated at the frame edge).

## 3. Shape bar

- Sits directly under the filter row, **not pinned** (scrolls with the list, per the board caption "the bar under them is the shape of the library").
- Bar height: **~6–7pt** — a thin proportional track, not a chunky bar.
- Segments, left to right, touching but separated by a hairline **~2px gap** (at this resolution that reads as a deliberate small gap between segments, not full antialiasing — treat as "segments do not blend into each other," build with a small gap of 1–2pt rather than 0):
  1. **Reading** — coral `#F87966` (matches accent exactly)
  2. **Paused** — orange, ≈ `#E38D3D` (rgb 227,141,61)
  3. **Completed** — green, ≈ `#67B36A` (rgb 103,179,106)
  4. **Planning** — mid gray, ≈ `#525252` (rgb 82,82,82)
  5. **Dropped** — near-black gray, ≈ `#242424` (rgb 36,36,36)
- Segment widths in the mockup (out of a ~357pt track) are roughly proportional to counts: Reading ~24pt, Paused ~13pt, Completed ~118pt (widest), Planning ~126pt, Dropped ~68pt. This is illustrative of "proportional width," not a spec to hit exact px on.
- Legend row directly below the bar: small square swatches + labels ("Reading", "Paused", "Completed", "Planning", "Dropped") in a single horizontal line, gray text, colored square dots matching the segment colors.
- **Currently-filtered segment indication**: not determinable from the board — the mockup shows the "All" pill selected and no segment visually highlighted/outlined differently from the others in that state. The brief's caption says the bar "doubles as the filter a reader actually wants" and is tappable, but no selected-segment visual treatment (outline, brightening, label enlargement) is shown on this board. Do not guess a selected-state style; confirm before building it.

## 4. List rows ("All series")

- Section header row: "All series" (bold white) left, "Recently updated ⌄" (coral text + small chevron, no button/pill background — plain text control) right-aligned, same baseline.
- **Row height: ~78pt** (measured consecutive cover tops 78px apart).
- **Cover thumbnail**: portrait rectangle, **~38×58pt** (≈2:3 aspect, matches manga cover ratio), vertically centered in the row with ~10pt padding top/bottom. Small corner radius (not measurable precisely at this scale — looks like ~4–6pt, a soft rounded rect, not sharp corners and not a large radius).
- **Row content to the right of the cover**, top to bottom: title (bold white, single line, truncates), then a horizontal line with the **state chip** followed by progress text (e.g. "Ch 112 / 179" or "Vol 84 / 110") in medium gray, small size.
- **Rating**: right-aligned within the row, a single star glyph + numeral (e.g. "★ 5"), white/light gray. Not a 5-star row — just one star icon and the number. Rows with no rating show an em-dash "—" in the same position instead.
- **State chip**: small pill, all-caps text (e.g. "READING", "PLANNING"), tightly padded. Fill is a **dark, low-opacity tint of the state's colour**, not the solid state colour — sampled "READING" chip fill ≈ `#281310` (rgb 40,19,16), a dark maroon tint of the coral accent. Text is the full-saturation state colour (coral for Reading). "PLANNING" chip reads as a dark neutral-gray tint with gray text. Build this as accentColor.opacity(~0.15–0.2) fill + solid accentColor text, per state.
- **Dividers**: none observed. Rows are separated by whitespace only (pure black background between them, no hairline rule).

## 5. Jump index

- A vertical strip of single-character labels pinned to the right edge of the list: **A D G K O S W #** (7 entries).
- Sits to the right of the "Recently updated" sort control at the top, running down the right margin alongside the list.
- Small caps, tight vertical spacing (letters stacked with very little gap — roughly line-height-only spacing, no visible padding between them).
- Colour: unselected letters are dim gray; on this board, "O" is rendered in the accent coral, i.e. **the letter matching the current scroll position is highlighted in accent colour** while the rest stay gray.
- Width of the strip itself: narrow, roughly 15–20pt, sitting flush against the right edge with a small margin (~10pt) from the frame edge.
- **Important behavioural note from the board's own annotation** (not visual, but load-bearing for implementation): *"The jump index. Only when sorted by title, only above ~200 entries."* The index is conditional — only shown when the list is sorted by Title AND has enough entries (~200+) to be worth it. It is not always-on.

## 6. Sort control

- "Recently updated ⌄" sits top-right of the "All series" section header, at the same row as that header (not in the pinned top header — it scrolls away with the list, since it's part of the "All series" section, not the pinned search/filter block).
- Styled as plain text in accent coral with a small down-chevron beside it — no button background, no border. Reads as a menu/picker trigger (tap to open a sort-option list), not a segmented control.
- Board caption confirms available options: "Recently updated" (default), title, rating, date added — all "behind header control," i.e. a single tap-to-reveal menu, not visible inline options.

## 7. Edit sheet (Board B — "Mid-edit")

- Presented as a bottom sheet over the list (the list is dimmed/visible behind it at ~reduced brightness at the top of the board). Sheet top corner radius is visibly rounded (a standard iOS sheet radius, ~20pt+ — not precisely measurable beyond "clearly rounded, matches system sheet style").
- **Grabber**: small horizontal capsule, centered, ~36pt wide × ~4pt tall, light gray, sitting just below the sheet's rounded top edge.
- **Header row**: cover thumbnail (portrait, **~56×84pt**, larger than the list-row thumbnail, same ~2:3 aspect) + title ("Solo Leveling", bold white) + subtitle ("Manhwa · 179 chapters", gray) to its right.
- **STATE section**:
  - Label "STATE", small caps, gray, left-aligned.
  - Two rows of pill buttons: row 1 = Reading / Rereading / Paused; row 2 = Completed / Planning / Dropped. (6 options total, wrapping at 3 per row.)
  - Pill height ≈ **32–35pt**, generously rounded capsule shape, matching the filter-row pill style.
  - **Selected state ("Reading")**: solid accent-coral fill, bold dark/black text.
  - **Unselected states**: dark neutral-gray fill (distinctly different from the coral, roughly matching the unselected filter-pill gray), white/light-gray regular-weight text. No border/outline distinguishing them — fill colour and text weight are the only differentiators.
- **RATING section** (left column, paired with CHAPTER on the right in the same row of labels):
  - Label "RATING", small caps gray.
  - 5 star glyphs in a row, left-aligned, each **~20×20pt**, tight horizontal spacing (~8pt gaps).
  - Partial selection reads as: filled stars solid accent-coral, unfilled/remaining stars rendered as the same star glyph in a muted gray outline/fill (not a half-star, not a different remaining-star size) — e.g. a 4-star rating shows 4 coral stars + 1 gray star, all same size.
- **CHAPTER section** (right column, same row as RATING label):
  - Label "CHAPTER", small caps gray.
  - Stepper: a minus button, a bold numeral in the middle, a plus button — three separate elements, not a single connected segmented track.
  - Minus/plus buttons: dark-gray rounded-square, **~33×33pt** each, softly rounded corners (not fully circular, not sharp — roughly 8–10pt radius square).
  - Numeral ("112"): bold white, sits in open space between the two buttons (no background/pill behind the number itself), roughly centered with ~40pt of horizontal space allotted to it.
- **Save button**: full-width minus the sheet's side margins, **width ≈356pt** on the 393pt frame (≈20pt margins each side), **height ≈49pt**. Solid accent-coral fill, bold black/near-black centered label "Save", clearly rounded corners (reads as ~14–16pt radius, a standard prominent-CTA rounding, not a full capsule).
- **Sheet presentation height**: not determinable from the board — the board crops the sheet's top edge against the dimmed list behind it, but there's no way to read an exact sheet height or detent (e.g. medium vs large sheet) from the image. Build as a fitted-content sheet (`.presentationDetents([.height(...)])` sized to content, or `.medium`) and confirm against the real content height once built.

## 8. Lower states (Board C)

Both states are shown as cards stacked vertically (not two separate phone frames — this board shows two card-style panels).

### Empty library
- Card container: dark card background `#16161C`-ish, rounded corners, sits on the plain near-black page background.
- Content, top to bottom, left-aligned: eyebrow label "EMPTY LIBRARY" (small caps, gray), headline "Nothing saved yet" (bold, white, large), body paragraph in gray ("Swipe through the stack and anything you keep lands here, with a reading state and a rating. No search field, no filter, no shape bar — they arrive with the first entry."), then a CTA button "Open the stack" — solid accent-coral fill, bold black text, rounded rect (same style family as the Save button, i.e. ~14pt radius, not a full pill), left-aligned (not full width — it's sized to its label plus padding, sitting under the paragraph rather than spanning the card).
- Confirms explicitly in copy: no search field, no state filter, no shape bar are shown in the empty state — those three chrome elements only appear once there's at least one entry.

### Partial-load state ("PAGE 1 OF 3 LOADED")
- Separate card below the empty-state card (in this board they're stacked for comparison; in the real app this is presumably a state of the same screen the empty card represents an earlier state of, not simultaneous).
- Eyebrow label "PAGE 1 OF 3 LOADED" (small caps, gray) at the top of the card, outside/above the nested sub-card.
- A nested, slightly lighter sub-card inside it containing: a small circular spinner/progress-ring icon (accent-coral partial ring) on the left, and on the right a bold line "500 of 1,204 loaded" with a gray description line below it: "Counts and search cover what has arrived so far."
- Below that sub-card: skeleton/placeholder list rows — a small gray square (cover placeholder) + two horizontal gray bars of varying width (title-line and subtitle-line placeholders), repeated per row, matching the real row's cover+title+subtitle layout but in loading-skeleton form.
- Where it sits on screen: per the eyebrow label's own wording and the accompanying design note, this banner sits at the **top of the "All series" list** (above the loaded rows, below the shape bar), not as a full-screen overlay — it's a compact status card, not a modal or toast.

---

## Notable inconsistencies / open questions found while reading the board

- **Jump index contradiction**: the board's own caption says the jump index appears "only when sorted by title, only above ~200 entries," but Board A's screenshot shows the jump index (A D G K O S W #) visible while the sort control reads "Recently updated" — the default sort, not Title. Either the screenshot is illustrative-only (showing the index for reference regardless of the stated rule), or the rule needs re-checking before building. Flag before implementing the conditional.
- **Partial-load count never grows**: the board's own critique text says so directly — "The count says 'of 1,204' from the first page, so the number never grows in front of the reader" — and separately notes nothing offers "Add to library" for a series that may be on page three. Both are acknowledged gaps in the brief itself, not something this spec is inventing; flag to product before/while building the partial-load UI so it isn't built as if that's fine.
- **Shape bar's "selected segment" indicator** is described in prose (the bar "doubles as the filter") but has no visible selected-state treatment on the board — see §3. Needs a design answer before implementation, not a guess.
- **Dropped state's default visibility**: the brief notes "Dropped. In the filter, last, and never in the default list." This affects whether "All series" / "All 1,204" actually includes Dropped titles or not — worth confirming the exact filtering behaviour of "All" before wiring it up, since the board doesn't visually resolve this.
