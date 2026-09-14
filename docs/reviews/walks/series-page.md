# Walk: Series page

Device: iPhone 16 Pro simulator, `dev.abdirahmanmohamed.mangabaka`, today's build.
Path: Library (empty, no MangaBaka token) → Search/Browse tab → typed "One Piece" → opened covers.
Screenshots: `docs/reviews/walks/../../../` — actual files live in the session scratchpad
(`walk-detail/*.png`), not committed; filenames referenced below match that folder.

Two series were opened: the flagship **ONE PIECE** (manga, 1193 ch / 115 vol) and, incidentally,
the spinoff **One Piece: Shokugeki no Sanji** and **One Piece: Law's Story** (novel), reached by
mis-taps and by swipe-paging. Comparing all three surfaced a real inconsistency (see Finding 3).

Budget used: ~62 of 70 tool calls.

## 1. Load sequence (observed)

For ONE PIECE, screenshots at t≈0s, 1s, 3s, 6s (`15-op-t0.png`, `16-op-t1.png`, `17-op-t3.png`,
`18-op-t6.png`) are **pixel-identical** — the whole hero block (cover stack, "Estimated next"
release estimate, title, author, chapter count, "Also known as", rating/ratings/chapters/
volumes/started stat row, description) was already fully rendered in the first screenshot taken
immediately after the tap. Nothing arrived late, nothing sat as an unresolved skeleton, in the
viewport at least. This is good — the hero section is fast, observed on a fresh (non-cached) tap.

For **Law's Story** (opened first, by mis-tap), the load surfaced an error banner instead of
content — see Finding 1.

I could not watch below-the-fold sections (Volumes, Readers-also-like, etc.) load in isolation
since scrolling itself triggers layout; what I can say is that by the time I scrolled to them
seconds later everything below was already populated except the "Similar by description" row
(Finding 2). Whether that row ever resolves given more time is untested — guessing, not observed.

## 2. Section order, scrolled top to bottom (ONE PIECE)

1. Hero: cover art (stacked-volumes visual), estimated-next-chapter badge, title, author, chapter
   count, "Also known as (22)".
2. "Use as seed" button.
3. Stat row: Rating / Ratings / Chapters / Volumes / Started.
4. Description with "View more" expander (not tapped).
5. Characters — 4 avatars shown (Luffy, Zoro, Nami, Usopp), see Finding 4.
6. Genres / Themes / Narrative Tropes / Settings — chip groups, several with an "N spoilers"
   pill that hides the tag text (good, deliberate spoiler protection) and a "+45" / "+83" style
   overflow count next to the group header, plus "15 more tag groups" to expand. Not expanded
   (budget).
7. Metadata table: Story & art, Publishers (truncated: "MANGA Plus, Shueisha, VIZ Media, Devir,
   P…" — no visible way to see the full list without tapping, not tested), Content rating, Anime
   adaptation.
8. **Volumes** — "113 of 115 on Apple Books", link to "Apple Books", horizontal cover shelf.
   Covers loaded (see item 3 below).
9. "Readers also like" — One-Punch Man, Demon Slayer, Hunter × Hunter, etc. Covers loaded fine.
10. **"Similar by description"** — three cards ("One Piece Party", "One Piece:", "Full Ahead!
    Coco") with **solid black placeholder rectangles**, no cover art, no "no cover" caption. See
    Finding 2.
11. "Scores elsewhere" — AniList 9.1, ANN 8.5, Anime-Planet 9.2, Kitsu 8.5, MangaUpdates 8.9-ish
    (cut off).
12. "What it's like · MangaUpdates" — tag chips with vote counts (Pirate·329, World Travel·306,
    …), "Show all 24" (not tapped).
13. Footer attribution: "Data from MangaBaka, and through it AniList, Kitsu, MangaUpdates,
    MyAnimeList and Anime-Planet. CC BY-NC-SA 4.0." — clear, good practice.

No section was empty-with-no-explanation except #10, and no section displayed a hard failure
banner on this series (unlike Law's Story, Finding 1).

## Findings

### Finding 1 — Throttling error shown with no retry, ever (observed)
On **One Piece: Law's Story**, the page loaded with a persistent banner: "Too many requests,
briefly — MangaBaka is throttling this connection. The limit is shared by everyone on your
network, so this may not be you at all." with a "Retry" button. Screenshots at t0/t1/t3/t6
(`07-load-t0.png` … `10-load-t6.png`) are identical — the app never auto-retried, and the error
never cleared on its own. The copy itself is a genuinely good moment ("this may not be you at
all" is honest and de-escalating), but the affected section simply sits broken until the user
manually taps Retry — nothing else on the page (Characters, stats, description) was blocked by
it, so the failure is scoped, just not self-healing. Not reproduced on ONE PIECE itself, so this
looks like a real, transient shared-rate-limit — worth checking whether *any* auto-retry-with-
backoff is wired up, since a first-time visitor landing on a throttled series with no obvious
cause for the failure could easily read it as broken.

### Finding 2 — "Similar by description" shows a row of covers with no covers, no explanation (observed)
Three of four visible cards in this section ("One Piece Party", "One Piece:", "Full Ahead!
Coco") render as flat black rectangles with no image, no placeholder icon, no "cover not
available" caption — nothing to tell the reader this is a missing-data state rather than a
loading or rendering failure (`21-scroll3.png`). This is exactly the "row of covers with no
covers" case the walk brief calls out. Compare with Finding 3's "No cover from the publisher"
style messaging used elsewhere in the app per the CLAUDE.md history — this section has no
equivalent messaging at all.

Also notable: the middle card's title renders as literally **"One Piece:"** — a truncated/
incomplete title with a trailing colon and nothing after it. Could be bad source data (a title
that really is just "One Piece:" in MangaBaka) or a truncation bug; I can't tell which from the
UI alone. Flagging as unsure rather than guessing.

### Finding 3 — The flagship series has no "read it" link; an obscure spinoff does (observed)
**One Piece: Shokugeki no Sanji** (a minor one-shot spinoff, 6 chapters) shows a **"Read in
English"** section right after "Use as seed", with a tappable **"MANGA Plus ↗"** pill
(`25-charscroll.png`). **ONE PIECE itself** — the single biggest, most-read series in the whole
catalog — has no such section anywhere on its page; scrolling from "Use as seed" goes straight
to the stat row, with nothing in between (`27-op-top-check.png`, confirmed by scrolling to the
exact same anchor twice). I did not follow either link (per instructions), so I can't confirm
whether MANGA Plus is even the right platform for ONE PIECE, but the *asymmetry* itself is the
finding: the series most likely to be tapped by a new user offers no way to read it, while a
niche spinoff does. This reads as a data-completeness gap rather than a UI bug, but it undercuts
the section's usefulness if it's this inconsistent.

### Finding 4 — Characters row shows only 4, no visible "Show all" (observed)
On ONE PIECE, "Characters" shows exactly four portraits (Luffy, Zoro, Nami, Usopp) — all crisp,
correctly cropped, no missing images. For a series with a cast in the hundreds there was no
"Show all" button, count badge, or chevron the way "Also known as (22)" and "What it's like ·
Show all 24" both have elsewhere on the same page. I tried a horizontal swipe directly over the
character row hoping for a scrollable strip; instead it triggered the page-level "swipe to next
series" gesture (see Finding 5) and navigated away entirely, which itself suggests the character
row is *not* independently horizontally-scrollable — it may just be capped at 4 with no way to
see more. Unsure: I could not distinguish "capped by design" from "the show-all control exists
somewhere I didn't find in my scroll pass."

### Finding 5 — Swipe-to-next-series works and correctly preserves scroll position (observed, good)
A horizontal swipe near the Characters row navigated to the next series in the originating list
(One Piece: Shokugeki no Sanji) — paging between series from a row is real and works. Swiping
back returned to ONE PIECE at the **exact same scroll offset** (Characters row still in view),
not reset to the top. This is exactly the behavior the walk brief was checking for, and it
worked cleanly both directions.

### Finding 6 — Floating tab bar overlaps page content with heavy, distracting blur (observed)
The bottom tab bar (Discover / Stack / Mix / Library pill + a separate circular search button)
floats over scrollable content rather than sitting on a solid background. Wherever a colorful
section (character portraits, volume covers) sits directly behind it, the translucency produces
a loud, smeared color bleed through the labels (zoomed crop in `crop_tabbar.png` — labels
"Discover"/"Stack"/"Mix"/"Library" sit on top of a messy pink/blue blur of the art behind them).
It's legible, so not a hard bug, but it's the opposite of the clean "frosted glass" effect this
pattern usually aims for — worth a look at the blur radius/opacity or adding a scrim.

Separately: because the tab bar is fixed to the screen (not the scroll view), a touch that
starts in its hit zone is captured by it even mid-swipe. Twice during this walk a scroll gesture
that started near y≈800pt (right where the tab bar sits) was swallowed and registered as a tap
on a tab instead of scrolling the page, once dropping me onto the unrelated "Mix" tab entirely
mid-review. Anyone scrolling a long series page with a swipe that starts low on screen risks
being bounced to a different tab without warning.

### Finding 7 — Discover's "Recently viewed" correctly tracks series page visits (observed, good)
Backing out to Discover showed ONE PIECE, Shokugeki no Sanji, and Law's Story all listed under
"Recently viewed" in the order visited. This is exactly the kind of persistence a reader would
want and expect — not a bug, noted as a good, correctly-scoped bit of state.

### Minor / unsure
- No large hero title that cross-fades into a compact nav title on scroll — the nav bar already
  shows the compact title ("ONE PIECE") from the very first frame, so item 5 of the brief
  (hero-to-nav crossfade) doesn't really apply to this screen's design; there's nothing to
  flicker because there's no separate hero title state. Noting this as a design observation, not
  a defect.
- Publishers field truncates ("MANGA Plus, Shueisha, VIZ Media, Devir, P…") with no visible way
  to see the rest — not tested whether tapping the row expands it.
- "15 more tag groups" and "Show all 24" (MangaUpdates tags) expanders were not tapped (budget).
- Did not test the actual tap-through on "MANGA Plus ↗" per instructions (must not follow
  external links) — can only confirm the label and platform name are present and look legitimate
  for a One Piece property.

## What's good
- Hero content loads fast and complete — no skeleton flicker, no progressive pop-in, in the one
  fresh-load case I could observe end-to-end.
- The throttling error copy is honest and low-anxiety ("this may not be you at all") rather than
  alarming or vague.
- CC-BY attribution footer is clear about where every number on the page comes from.
- Swipe-to-next-series paging works and correctly preserves the scroll position of the series you
  came from.
- "Recently viewed" on Discover accurately reflects exactly the pages visited, in order.
- Spoiler-gated tags ("N spoilers" pills that hide the actual tag text) are a thoughtful touch.

## What I could not test
- Whether "Show results" / "Show all" / "15 more tag groups" / Publishers-row expansion actually
  work (not tapped, to conserve budget).
- Whether the "Similar by description" black covers ever resolve given more time — only observed
  at one point in time, not re-checked minutes later.
- The actual reading destinations behind "MANGA Plus ↗" or "Apple Books" (must not follow
  external links per instructions).
- Whether the missing "Read it" section on ONE PIECE is a data gap specific to that series or
  something broader — only two series' presence/absence was compared.
