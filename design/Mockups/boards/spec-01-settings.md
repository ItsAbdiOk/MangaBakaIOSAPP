# Settings — Implementation Spec

Source: `brief-01-settings.png` (1500×3218px board, read via PIL crops — see method note at bottom).
Board contains a two-column layout: **Frame A** (left column) is the full resting-state Settings
page, unrolled top to bottom. The right column holds smaller frames: **B** (four account states),
**C** (blocked tags, empty), **D** (one row at largest accessibility size), **E** (recently viewed,
nothing to clear), followed by a "Notes" panel with four annotations.

**Frame width:** measured left/right rounded-frame edges = **393pt** (matches iPhone 14/15/16
logical width, 1:1 — this board is NOT rendered at 3x, so pixel values below can be read directly
as points; no /3 conversion needed). All measurements below are given in points, with a
`(x/393)` fraction where useful for responsive translation.

---

## 1. Section order and structure

Top to bottom, Frame A:

1. **ACCOUNT**
2. **FORMATS**
3. **CONTENT**
4. **BLOCKED TAGS**
5. **RECENTLY VIEWED**
6. **DATA AND CREDIT**

Nav bar above all sections: time readout top-left ("11:34" status-bar mock, ignore), then a row
with a circular back-chevron button and bold "Settings" title, left-aligned, roughly 34pt tall
title text. Reached via the gear icon in the Library header — confirmed no tab bar entry, but
**96pt is reserved at the foot of the page for the tab bar** per the board's own note (i.e. the
page's bottom safe area/scroll inset should be 96pt even though Settings itself isn't a tab).

**Section header style** (e.g. "ACCOUNT", "FORMATS"):
- All caps
- Small — approximately 13pt
- Colour: mid grey, sampled ≈ `rgb(141,141,147)` / `#8D8D93` (standard iOS secondary-label grey)
- Letter-spaced (tracking visibly wider than body text; exact tracking value not determinable
  from the board — looks like a typical +0.5–1pt iOS "sectionHeader" tracking)
- Directly below the header: a one-to-two line grey caption/description in a slightly lighter
  body grey (not measured precisely — reads as standard secondary body text, ~15pt)

**Section-to-section rhythm**, measured at the Formats section boundary:
- Previous card's bottom edge → next section header: **~40pt**
- Section header → its caption text: **~28pt**
- Caption text → next card's top edge: **~27pt**
- So roughly **95pt** total from one card's bottom to the next card's top, occupied entirely by
  header + caption, no extra card chrome between sections.

**Card geometry** (Formats card, applies to all row-cards): corner radius reads as **~20pt**
(not pixel-precise — could not isolate the arc to sub-point accuracy, treat as approximate).
Card background ≈ `rgb(17,17,20)` / `#111114`, sitting on a near-black page background
≈ `rgb(0,0,0)`–`rgb(10,10,10)`.

---

## 2. Account card — four states (Frame B)

One card, one region, four different occupants (the board literally swaps card contents per
state — it is not four different card shapes). **Status dot + its accompanying line of text
carry all the state signalling; the field/description block below is described by the board as
staying fixed in position so nothing jumps as a check completes** — i.e. don't let the card's
overall height or button block position shift due to variable-length copy if avoidable; the dot
+ title row height and the card's start position should be the same across all four states.

### State: Unverified
- Header row: small grey dot (`rgb(90,90,96)` / `#5A5A60`, plain neutral grey — not accent, not
  red) + bold title **"Not checked yet"**
- Body: two-line grey description ("Saved on this phone but never used. It is checked the first
  time something needs it.")
- Button: **"Check now"** — filled grey pill, bg noticeably lighter than card bg (a raised
  "secondary" button fill, ~`rgb(45,45,48)`–ish, sampled area was partly text so treat as
  approximate), white bold label, not full width — sized to text + padding.

### State: Checking
- Header row: dot in a dim, desaturated accent tone ≈ `rgb(90,49,45)` (a muted/dark version of
  the accent red, not the full-strength accent) + bold title **"Checking…"**
- Below the title: a **thin horizontal progress bar**, full card width, accent-coloured
  (`#F87966`) on the left portion fading/transitioning to dark grey (`rgb(38,38,41)`) on the
  right — reads as an indeterminate/partial progress indicator, not a spinner.
- Body: two-line grey description ("The field and buttons stay put and stay usable — this is not
  a modal wait.")
- **No buttons in this state** — this is the direct evidence for "the field below never moves":
  the board's own caption states the field and buttons stay in place and stay interactive during
  this state, i.e. whatever field/button layout is present in Unverified/Valid should not be
  removed or re-laid-out just because a check is in progress. (The visual example shown simply
  doesn't render a button row here — treat the position where Unverified's button/Valid's field
  sits as reserved space, not collapsed.)

### State: Valid ("Connected", shown twice — once in Frame B, once at full detail in Frame A)
- Header row: **green dot** (`rgb(88,184,94)` / `#58B85E`) + bold title **"Connected"**, with
  the account handle **"@kaito"** right-aligned on the same row, dimmed grey, regular weight.
- Thin full-width divider line below the header row (`rgb(33,33,36)`).
- Below divider: a masked token field — a rounded rect, slightly lighter than card bg, containing
  a row of bullet/dot characters (••••••••••••, password-masked), with a **"Replace"** button to
  its right (filled grey pill, same style as "Check now", not full width, sits inline to the
  right of the field on the same row).
- Below that: **"Remove token"** as a plain text link, left-aligned, accent-coloured
  (`#F87966`/`rgb(246,124,105)` sampled), no button chrome — a destructive text link.
- (Frame B's shorter "Connected" excerpt shows just the description line "Library sync,
  recommendations and your taste profile are on." instead of the field/Replace/Remove block —
  this is Frame B truncating the frame for space, not a second visual treatment; Frame A's fuller
  version with the field is the one to build from.)

### State: Invalid
- Card gets a **full outline border** around the whole card in the accent colour at reduced
  opacity — border ≈ `rgb(71,35,29)`, card background tinted dark red ≈ `rgb(22,11,9)` (this is
  the *card* getting the tinted-callout treatment, distinct from the plain card bg used in the
  other three states).
- Header row: **full-strength accent dot** (`#F87966`) + bold title **"Token rejected"**.
- Body: three-line grey description.
- Two buttons side by side:
  - **"Paste a new one"** — filled accent pill (`#F87966` bg), dark/near-black bold text, this is
    the primary action.
  - **"Get a token ↗"** — outline pill (border only, transparent/card-colour fill), white bold
    text, external-link arrow glyph after the label.

---

## 3. Rows with switches (Formats, Content)

- Rows sit together on one card with rounded corners (**~20pt radius**), each row separated by a
  **1pt hairline divider**, colour ≈ `rgb(33,33,36)` / `#212124`, inset to match row padding (not
  full bleed to card edges — matches standard iOS grouped-list dividers).
- **Row height: 63pt exactly** (measured across all four Formats rows — Manga/Manhwa/Manhua/
  Novels each exactly 63pt tall, divider-to-divider).
- Row content: bold title (e.g. "Manga") top-left, grey caption directly below it (e.g. "Japanese,
  right to left") — title+caption stacked vertically, left-aligned, vertically centered as a pair
  within the 63pt row.
- Switch sits right-aligned, vertically centered in the row.
- **Switch size confirmed: 51×31pt track, 27pt knob** — matches the board's stated constraint,
  matches system `UISwitch`/`Toggle` metrics, visually indistinguishable from a real toggle.
  - **On** track colour: accent `#F87966` (sampled `rgb(248,121,102)`), knob white.
  - **Off** track colour: dark grey ≈ `rgb(44,44,46)` / `#2C2C2E`, knob white.

Content section rows follow the identical card/row/divider/switch treatment (Safe/Suggestive/
Erotica/Explicit), 63pt-tall rows on their own card, same dividers, same switch metrics — except
the Safe row per point 4 below.

---

## 4. The locked "Safe" row

- **No switch at all** — not a disabled/dimmed switch, the switch control is entirely absent for
  this row, replaced by a **lock pill**.
- Lock pill: small rounded-rect pill, right-aligned where the switch would sit. Dark grey fill
  (slightly lighter than card bg, close to `rgb(45,45,48)`-ish, matches the other filled-grey
  buttons like "Check now"), subtle 1pt border a touch lighter than the fill. Contains a small
  **lock glyph icon** (closed padlock, outline style) followed by the label **"Always on"**, both
  in a medium-contrast grey (not full white, not dimmed-to-invisible — legible secondary tone).
  Pill is sized to content + padding, not full width, not the same width/height as the switch
  track it replaces.
- **Row title stays at full contrast** — "Safe" renders in the same bright white bold as every
  other row title (confirmed both at normal size and in the Frame D large-accessibility-size
  example, where "Safe" is rendered at large scale in the same bright white as "Suggestive").
  Only the caption below it ("The baseline everyone sees") is the normal dimmed grey, same as
  every other row's caption — i.e. **do not dim the whole row** to signal "locked"; the notes
  panel explicitly calls out today's implementation (fully dimmed row) as the thing to fix: a
  greyed switch or dimmed row reads as broken/unavailable, the lock pill is what should carry the
  "this is a rule, not a bug" meaning.

---

## 5. The two warning treatments

### Content ratings — tinted callout
Appears below the Erotica/Explicit rows, above the next section header. Full width of the page
content column (not full-bleed to the card, indented to match card/row padding).
- Background: dark red tint ≈ `rgb(22,11,9)` / `#160B09`
- Border: 1pt, muted red-brown ≈ `rgb(71,35,29)` / `#47231D`
- Corner radius: reads similar to the row cards, moderately rounded (not pixel-measured, treat
  as roughly matching card radius, ~14–16pt — smaller than the 20pt card radius, this is a
  smaller/tighter component)
- Padding: comfortable card-style padding on all sides (icon + text sit inset from the border,
  not flush)
- **Icon: yes** — a small circular-arrow "refetch" glyph (⟳-style icon), accent-coloured
  (`#F87966`, sampled `rgb(248,121,102)` on the glyph strokes), top-left, aligned with the first
  line of text
- Text colour: dimmed grey body text (not accent, not white) — three lines: "Changing this
  refetches your feeds. Cached copies were fetched under the old filter, so they are discarded."
- Per the board's own notes panel: this gets the heavier tinted treatment because "the discard is
  immediate and total."

### Formats — plain grey line
Appears below the Novels row, above the "CONTENT" section header.
- **No box** — no background fill, no border, no corner radius, no padding beyond normal text
  margins. Confirmed by direct pixel sampling: the region around this text is identical to the
  page background.
- **No icon.**
- Text colour: same dimmed secondary grey as any other caption/body text (not accent, not white).
- Two lines: "Changing this clears downloaded feeds, because they were fetched under the previous
  setting."
- Per the board's notes: "same mechanism, smaller blast radius" — Formats' consequence is
  considered less severe than Content's, hence no card treatment at all, just a plain text line
  sitting directly on the page background at the same left inset as everything else.

---

## 6. Blocked tags — populated and empty

**Populated** (shown in Frame A, under "BLOCKED TAGS" header, caption "Hidden everywhere,
whatever a series is rated. Unblock from the tag list in Browse."):
- Chips flow left-to-right, inline, with a trailing "+ Block a tag" control after the last chip.
- **Chip**: pill/fully-rounded rect, dark grey fill (~matches card bg, slightly lighter, similar
  tone to other filled-grey secondary controls), white/bright text label (e.g. "Cooking"),
  comfortable horizontal padding (~12–14pt each side, not pixel-measured precisely).
- **× treatment**: the × sits inside its own small circular badge at the trailing edge of the
  chip, background a step lighter grey than the chip itself (visibly distinct roundel), × glyph
  in white/light grey. Not a bare × character floating in the chip — it has its own circular hit
  target.
- **"+ Block a tag" control**: pill shape, **dashed border** (confirmed — clearly a dashed not
  solid stroke), transparent/page-coloured fill (no solid background), accent-coloured **+** icon
  followed by white "Block a tag" label.

**Empty** (Frame C, "BLOCKED TAGS" header, caption "Nothing is blocked. Add a tag here and it is
hidden everywhere, whatever a series is rated."):
- Only the dashed "+ Block a tag" pill is shown, identical styling to the populated state's
  trailing control (same dashed border, same accent + icon, same label) — confirming it's one
  reusable control, not two different components for empty vs. populated.
- Per the board's note: **no icon, no empty-state illustration** — this is deliberate; an empty
  list is treated as the normal/invitational state, not an error/empty state requiring extra
  visual weight.

---

## 7. Recently viewed — populated and empty

Both states use the same component: a **full-width, filled dark card/button** (not an outline
button), rounded corners matching the row-card radius, centered content (icon + label centered
horizontally within the button, not left-aligned).

- **Populated** ("Clear 2 series" — Frame A): history/clock-arrow icon + bold label, both in the
  accent colour (`#F87966`-family, sampled reddish-orange on both icon and text). Card fill is
  the same dark grey as other cards; no visible border. This is an active, tappable destructive
  action.
- **Empty** ("Nothing to clear" — Frame E): same button shape/size/position, but icon + label are
  rendered in a **dimmed neutral grey** instead of accent — visually inert/disabled-looking
  though per the board's note it should read as "went inert rather than disappearing," i.e. it
  stays in the DOM/layout and is presumably non-interactive (tap does nothing / no series to
  clear) rather than being hidden. Per the board: "a control that vanishes makes the section look
  like it lost a feature" — so **do not conditionally remove this button when the list is empty**,
  keep it present and swap it to the dimmed/inert visual state with a "0" reflected as "Nothing to
  clear" copy rather than "Clear 0 series."

---

## 8. Data and credit

Single card under "DATA AND CREDIT" header:
- Body paragraph, standard dimmed grey text: "Series data comes from MangaBaka, and through it
  from AniList, Kitsu, MangaUpdates, MyAnimeList and Anime-Planet."
- **"mangabaka.org ↗"** — rendered as its own line/paragraph below the body text, bold,
  **accent-coloured (`#F87966`), ~16px per the board's own note** ("a 16px accent link in its own
  section, not body text") — i.e. visually distinct from the paragraph above it, not an inline
  link within the sentence. Trailing external-link arrow glyph.
- Thin full-width divider (same hairline colour as row dividers, `rgb(33,33,36)`) below the link.
- Licence line below the divider, in the **dimmed secondary grey** (smaller/lower visual weight
  than the accent link, same weight/colour as ordinary body/caption text elsewhere on the page):
  "Licensed CC BY-NC-SA 4.0 — free for personal, non-commercial use with attribution. This app is
  free and carries no ads or purchases."
- Per the board's own notes panel: a **second attribution obligation** (third-party data credit)
  belongs on the series detail screen's tracker row, **not on this screen** — explicitly called
  out as a change not yet made, out of scope for this spec.

---

## 9. The accessibility-size frame (Frame D)

Board's own description: "Above roughly 1.6× [Dynamic Type], the row stops being a horizontal
thing. Title, caption and switch stack; nothing has a fixed height; the switch keeps its 51×31
hit target."

Observed in the example row (shown at large scale, "Suggestive"):
- **Title** ("Suggestive") — large bold text, full width, top of the stack.
- **Caption** ("Fan service, innuendo") — directly below the title, full width, dimmed grey,
  same relative position as at normal size (title-then-caption), just now on its own line rather
  than sharing a row with the switch.
- **Switch** — moved below the caption, own line, **left-aligned** (not right-aligned as it is at
  normal/default text size) — this is a deliberate re-alignment, not just a wrap. Switch itself
  is unchanged: still 51×31 with the 27pt knob, same on/off colours as section 3.
- Row height is **not fixed** — the board explicitly says "nothing has a fixed height," i.e. the
  63pt fixed row height from section 3 applies only below the ~1.6× Dynamic Type threshold; above
  it, row height must be intrinsic/auto-sizing to fit the stacked, wrapped text.
- The "Safe" row's large-scale rendering (shown adjacent) confirms the lock-pill row follows the
  same restacking rule and the same full-contrast title rule at large sizes — title stays bright
  white, lock pill likely also drops to its own line below the caption at this size (not
  independently confirmed for the pill's exact position at this scale — the board shows the "Safe"
  title+caption stacked but the pill itself was cropped out of the visible large-scale example;
  **not determinable from the board** exactly where the lock pill sits relative to the caption at
  the accessibility size — safest bet is to mirror the switch's placement, i.e. own line below the
  caption, but this is an inference, not something directly shown).

---

## Notes / things the board itself flags as open or deliberate

- The board's own "Notes" panel (right column, bottom) restates several of the above points
  verbatim as rationale — cited inline above where relevant.
- Switch metrics (51×31, 27pt knob) are stated by the board as matching "system metrics," and the
  board explicitly says it is not asking for a real interactive `Toggle` — these are drawn/static
  for the mockup, but should be built as functioning switches with these exact metrics.
- Not determinable from the board: exact card corner radius to sub-point precision, exact chip
  padding values, exact button padding values, exact section-header letter-spacing value, and the
  lock pill's exact position at accessibility text sizes (see section 9).

---

## Method note

Read via `PIL.Image` crops from `/Users/abdi/Code/MangaBakaIOSAPP/design/Mockups/boards/brief-01-settings.png`
(1500×3218px), segmented top-to-bottom and re-cropped/zoomed 2× around specific components for
pixel colour sampling (`im.getpixel`). All colour values above are sampled RGB, converted to hex
where a clean value was legible; treat sampled values as approximate (anti-aliasing/text-glyph
contamination affects some samples, noted inline where relevant).
