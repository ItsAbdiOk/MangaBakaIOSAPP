# Implementation Spec — Brief 05: Lenses and the Tag Filter

Source: `design/Mockups/boards/brief-05-lenses.png` (1500×1916px, 4 phone frames — A, B, C, D — plus a "NOTES" panel, all on one board).

**Method note on measurements:** phone frames are drawn 393pt wide per the brief. Measuring the frame edge in board C gave ≈429px for that 393pt width, i.e. a board scale of **≈1.09 px/pt**. All pt figures below are pixel measurements on the board divided by 1.09 and rounded to a sane value (nearest 2–4pt) — treat them as **close estimates for engineering guidance, not pixel-exact specs**. Where I could not get a confident pixel reading, I wrote "not determinable from the board" rather than guess.

Colors read off the board (sampled pixel values): accent coral `#F87966` (sampled 248,121,102), selected-tag-chip fill a dark maroon (~#3A211D), unselected pill fill dark grey (~#1D1D1F on near-black page bg #000), card/row fill is a hair lighter than the pure-black frame background, muted body/secondary text mid-grey. Degraded-state amber is a warm orange/gold, distinct from and dimmer than the coral accent — exact hex not determinable from the board (no color chip given), but it reads roughly like iOS system orange, not coral.

---

## Board A — Filter sheet with save control

Half-height sheet presented over the (implied) Search/Mix results screen, rounded top corners, centered grab handle (~36pt wide bar) at the top.

**Header row:** "Filters" as a large bold title, left-aligned. "Reset" as a coral text link, right-aligned, same baseline as the title.

**TYPE section**
- Section label "TYPE": small, uppercase, grey, letter-spaced, sits above the row with a consistent ~16–20pt gap under the previous element.
- Three standalone pill buttons in a row (not a connected/joined segmented control): "Any", "Manhwa", "Manga". Each pill is independently rounded (full pill radius), roughly 8–10pt gap between them.
  - Unselected pill: dark grey fill, regular-weight light-grey text, no border.
  - Selected pill (Manhwa in the mock): solid coral fill (#F87966), bold near-black text. This is the same "solid coral fill + dark bold text" treatment used for every primary-selected control on this board.

**TAGS section**
- Label "TAGS" styled identically to "TYPE".
- Selected tags render as chips: dark maroon fill, coral text, coral "×" glyph immediately after the label, pill-shaped, chips read "Regression ×" and "Murim ×" in the mock.
- After the last chip, an "+ Add tags" chip: same pill shape, but **dashed** outline border, no fill, grey text with a leading "+". This is the affordance that opens Board D.
- Chips wrap left-to-right with small (~8pt) gaps; not determinable from the board whether they wrap to a second line when many tags are chosen — only 2 tags shown.

**MINIMUM RATING section**
- Label "MINIMUM RATING" styled identically to the above two.
- A single-thumb slider: coral filled track from the left edge to the thumb, plain grey track from the thumb to the right edge, white circular thumb (~18–20pt diameter). The numeric value ("8.0") sits as bold white text to the *right* of the track, outside it — not as a floating label above the thumb, not inside the thumb.

**Save-as-lens control (bookmark button)**
- Sits at the bottom of the sheet, to the **left** of the primary results button, same row, same height as that button — a square icon button, not a pill.
- Measured ≈49×54px on the board ⇒ **≈45–50pt square**, corner radius looks proportionally large relative to its size (roughly 12–14pt, "squircle"-ish, not fully round).
- **Active state (what the board shows, since a filter is set):** dark maroon/brown fill (same family as the selected-tag-chip fill), coral 1–1.5pt border, coral bookmark glyph (outline style, not filled solid) centered inside.
- **Inactive/greyed state (filters empty):** *not shown in the image* — the board only states in a caption below the row: "The bookmark saves this as a lens. Greyed until a filter is set." Treat this as a text-only spec: implement a visually greyed/disabled version of the same square control (e.g., reduced-opacity or neutral-grey fill/border/icon in place of the maroon/coral treatment) and gate it on "at least one filter is active" — but the exact grey values, opacity, and whether the icon changes shape are **not determinable from the board**.
- Caption text directly under the row (small, grey, centered under the whole button row, two lines in the mock): "The bookmark saves this as a lens. Greyed until a filter is set."

**"Show 148 results" button**
- Fills the remaining width to the right of the bookmark button (i.e., total width = sheet content width minus bookmark square minus a small gap).
- Solid coral fill (matches the selected-pill coral, `#F87966`), fully rounded pill/capsule shape, bold near-black label text, centered.
- Height ≈54px measured ⇒ **≈50pt**, matching the bookmark square's height so the two sit flush in one row.
- Label text is dynamic ("Show {n} results") — reflects the live count for the current filter combination.

---

## Board B — Naming sheet ("Save as a lens")

Smaller sheet (shorter than Board A's), same rounded-top-corner card style, no visible grab handle in this crop (not determinable whether one exists — likely present but out of frame/too faint to confirm).

**Layout top to bottom:**
1. Title "Save as a lens" — large bold, left-aligned.
2. Two-line explainer directly under the title, regular-weight grey text: "Lenses sit at the top of Search. This one reruns live — it stores the filters, not the results."
3. **Name field:** a rounded-rect text field, coral 1–1.5pt border (the only bordered/outlined field on this board — signals focus/active state). Pre-filled with the generated name "Manhwa · Regression · 8.0+".
   - **Selected-so-typing-replaces-it is shown visually**: the pre-filled text sits on a highlighted rectangle (dark maroon selection highlight, closely hugging the text bounds — the standard "select all" treatment) with a text caret drawn immediately after the last character. This is the only visual cue for "selected"; there is no separate label or icon for it.
4. One-line caption under the field, small grey text: "Generated from the filters. Selected, so typing replaces it."
5. **"WHAT IT STORES" card:** a distinct rounded card (subtly lighter fill than the sheet background, thin/no visible border), containing:
   - Small uppercase grey label "WHAT IT STORES".
   - Below it, lighter-grey body text summarizing the stored filter state: "Type manhwa · tags Regression, Murim · rating 8.0+ · sort trending". This is a plain-text summary line, not chips/tags.
6. **Button row at the bottom**, two buttons side by side:
   - "Cancel" — left, outlined pill (dark fill, thin grey border), white/light text.
   - "Save lens" — right, solid coral pill fill, bold near-black text.
   - Measured widths: Cancel ≈149px, Save lens ≈147px on the board — **essentially equal width (50/50 split)**, not weighted toward the primary action, with roughly a 10pt gap between them. Both appear to be the same height (not separately measured, but visually equal in the crop).

---

## Board C — Search idle screen (where lenses live)

This is a full-screen idle state (status bar "11:34" + a pill-shaped placeholder at top standing in for the dynamic island/notch — not part of the UI itself).

**Top to bottom:**

1. **"Search" title** — very large bold display-style title, left-aligned, below the status bar with generous top padding.
2. **Search field** directly under the title: full-width rounded rect, dark fill, leading magnifying-glass icon, greyed placeholder text "Title, tag, publisher, staff".
3. **"Your lenses" section**
   - Header row: bold section title "Your lenses" left-aligned, "Edit" as a coral text link right-aligned on the same baseline — same header pattern as "Filters"/"Reset" on Board A.
   - Each lens is a **full-width row/card** (not a chip), left-to-right anatomy:
     - Leading icon: coral bookmark glyph (outline style), vertically centered against the two lines of text.
     - Title line: bold white, the lens name (e.g., "Manhwa · Regression · 8.0+").
     - Subtitle line directly under the title: smaller grey text, the **live count** (e.g., "148 now", "1,902 now") — per the board's own NOTES panel, this count is a live query per lens, not a cached/stored result count.
     - Trailing: a light grey chevron ">" at the far right, vertically centered on the row — indicates the row is tappable/drills in.
   - Row height reads as roughly 72–80pt (two lines of text + top/bottom padding); rows are separated by a small gap (not divider lines — each row is its own rounded card, not a continuous divided list).
   - No visible border on a healthy row; the card fill is only a shade lighter than the screen background.

4. **Third lens row — "Webtoon originals" (degraded state).** This is the one board explicitly designed around a broken filter, and it differs from the healthy rows in every respect except position/size:
   - **Border:** the row gets a thin (~1pt) amber/warm-orange outline around its full rounded-rect card — the only lens row with a visible border.
   - **Leading icon:** the coral bookmark is replaced with an amber warning-triangle icon (⚠), same position/size as the bookmark it replaces.
   - **Title:** unchanged styling — still bold white "Webtoon originals", same weight/size as healthy rows.
   - **Subtitle:** the live-count line is replaced with two lines of amber-toned explanatory grey/amber body text: "One filter no longer exists. Runs without it — tap to fix." (no numeric count is shown at all for this row).
   - **Chevron:** absent. Unlike the two healthy rows, this row shows no trailing ">" chevron.
   - **Tappability:** per the copy itself ("tap to fix") and per the board's NOTES panel ("It does not silently return different results, and it does not refuse to run — a saved search that breaks on the API's schedule should degrade, not die"), the row **is still tappable** — tapping it should let the user fix/replace the missing filter, and the lens still runs (using its surviving filters) if invoked directly, it just can't silently pretend nothing changed.

5. **"Presets" section**
   - Header: bold "Presets" title, no trailing control (no "Edit" link — presets aren't user-editable).
   - Presets render as **wrapping pill chips**, not full-width rows: "Top rated manhwa", "Completed classics", "Short reads" — plain dark-grey pill fill, light grey text, sentence-case copy. Wraps to a second line when needed (3 chips shown across 2 lines in the mock).

6. **"Recent" section**
   - Header: bold "Recent" title, no trailing control.
   - Same exact chip styling as Presets (dark grey pill, grey text) — **no visual difference between a Presets chip and a Recent chip** other than content: Recent chips are raw lowercase search terms ("murim", "regression") rather than named, capitalized presets.

**Lens row vs. preset/recent chip, summarized:** lenses are the only entries rendered as full-width rows with icon + two-line text + chevron; everything else on this screen (presets, recent) is a compact pill chip. This is the visual signal that a lens is a "live, checkable thing" (it has a count, it can break, it's edited) versus a preset/recent term which is just a shortcut to fill the search field.

---

## Board D — Tag picker ("Add tags")

Full-screen sheet, status bar + placeholder pill at top (same convention as Board C).

**Nav bar:** "Add tags" as a large bold title, left-aligned; "Done" as a coral text link, right-aligned, same baseline — consistent with the Filters/Your lenses header pattern used elsewhere on this board set.

**Search field:** full-width rounded rect below the nav bar, dark fill, leading magnifying-glass icon, grey placeholder "Search 7,105 tags" (the live tag-count is baked into the placeholder copy itself).

**Selected-tag chips row:** below the search field, left-aligned, wrapping pill chips for each already-selected tag: "Regression ×", "Murim ×" — same dark-maroon-fill/coral-text/coral-"×" styling as the chips on Board A's TAGS section (this control is shared/consistent between the filter sheet and the tag picker).

**Match all / Match any control:** two standalone pills, same shape convention as Board A's TYPE row, but a **different selected-state treatment**: the selected pill ("Match all" in the mock) is a solid **dark grey** fill with bold white text — not coral. The unselected pill ("Match any") is outline/bordered, grey text. This reserves the coral "selected" treatment specifically for tag/type selections and uses a neutral (grey) selected state for this any/all mode toggle — worth flagging to the developer as an intentional inconsistency with Board A's TYPE control, not a mistake to "fix" by making it coral.

**Grouped browse list** (below "Match all/any"), groups shown: "Narrative tropes" (expanded), "Settings", "Themes", "Cast" (all three collapsed).

- **Group header row:** bold white group name, left-aligned; on the right, a count string, then a chevron.
  - **Count format:** `"{selected} · {total}"` when the group has at least one tag selected (e.g., "Narrative tropes" shows "2 · 38" = 2 selected of 38 tags in that group; "Settings" shows "1 · 22"). When nothing in the group is selected, it's just the bare total with no dot (e.g., "Themes" shows "41", "Cast" shows "17").
  - **Chevron:** caret, right of the count. Points **up (^)** when the group is expanded (Narrative tropes), points **down (v)** when collapsed (Settings, Themes, Cast). Groups are separated by thin horizontal divider lines (unlike Board C's lens rows, this list uses dividers, not individual cards).

- **Expanded group row anatomy** (seen under "Narrative tropes"): each tag is one row —
  - Tag name, left-aligned, regular weight, white/light-grey text.
  - **Weight bar**, positioned to the right of the tag name, before the checkbox, roughly mid-row horizontally, vertically centered on the row. Geometry (measured): a horizontal track ≈48pt wide (52px measured), ~2–3pt thick, fully rounded ends. It is **one continuous bar whose fill length and fill color intensity both encode the weight step** — not four discrete blocks/segments. Rest-of-track beyond the fill is a flat dark grey.
    - Measured fill ratios and colors across the four rows shown: "Regression" (selected) ~100% filled, full-brightness coral `#F87966`. "Weak to Strong" ~70% filled, dimmer coral (~#C16253). "Character Growth" ~45% filled, dimmer still (~#966450). "Revival" ~27% filled, dimmest/most muted brick tone (~#75423B).
    - The board's NOTES panel names the four underlying weight tiers explicitly: **Core, Defining, Recurrent, Incidental** (descending) — "a four-step bar carries the same ordering, sorts the list, and needs no legend." So: 4 fixed tiers, each with its own fill-length + fill-brightness combination, not a continuous/arbitrary percentage.
  - **Checkbox**, trailing, after the weight bar, ≈18–20pt rounded-square box, right-aligned in the row.
    - Selected: solid coral fill, white checkmark glyph.
    - Unselected: outline-only (grey border), transparent/no fill, no checkmark.
  - **"Show 34 more"** control: coral text link, left-aligned, sits as its own row at the bottom of the expanded group's tag list (after the visible tags), same coral as other primary text links (Reset, Edit, Done). It's a "load more within this group" affordance, not a navigation link — exact number is dynamic (group total − rows currently shown).

- **Collapsed group rows** (Settings, Themes, Cast): just the header row (name + count + down-chevron), no tag rows visible, consistent with standard disclosure-group collapse behavior.

---

## Cross-board notes (from the board's own "NOTES" panel — carried over verbatim because they constrain implementation)

- **Where saving happens:** one save control, living in the filter sheet (shared by Search and Mix). There is deliberately no second "save" entry point on a results screen.
- **A lens stores filters, not results:** the per-lens count is a live query, re-run each time it's shown — it is expected to change over time. This means Search's idle state needs to issue one count query per visible lens (see "Needs your call" below for the fallback).
- **Degrade, not die:** when one of a lens's filters no longer exists server-side, the lens keeps running with its surviving filters and visibly flags which one it dropped (the amber state on Board C) rather than silently changing results or refusing to run.
- **No per-search "blocked tags" toggle exists anywhere in these frames** — don't add one; it's called out as a possible future feature with its own state, not something to bolt onto this sheet.
- **Open API/cost question flagged by the board itself ("Needs your call"):** lens counts require a live count query per lens on Search's idle screen. If that's too many requests to fire on every idle-state load, the fallback specified is to drop the counts and show each lens row's filter summary in the subtitle position instead (i.e., subtitle becomes "Manhwa · Regression · 8.0+" both as the title *and* effectively the description, or some equivalent restated form — the board does not fully specify the fallback row's exact text, so **that fallback layout is not determinable from the board** beyond "counts come off, filter summary replaces them").

## Explicitly not determinable from the board

- Exact hex values for the amber/warning color, the dark-maroon chip fill, and the dark-grey unselected-pill fill (no swatches given; the values above are eyeballed approximations from pixel sampling, not a color spec).
- The visual appearance of the bookmark save control's *inactive/greyed* state (only described in a caption, never drawn).
- Whether Board B's naming sheet has a grab handle.
- Exact corner radii, padding, and line-height values beyond the approximate pt figures given (the board is not annotated with a redline/spec overlay).
- The exact fallback row layout for lens rows when live counts are dropped for cost reasons (see "Needs your call" above).
