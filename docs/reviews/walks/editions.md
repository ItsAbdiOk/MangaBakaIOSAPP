# Walk: Volumes & new "Other editions" data sources

Date: 2026-09-14. Device: iPhone 16 Pro simulator, fresh install, today's build.
Screenshots: `/private/tmp/claude-501/-Users-abdi-Code-MangaBakaIOSAPP/0e51fbb2-e05c-42ef-ae08-5c1768d90a47/scratchpad/walk-editions/`

Series walked: **ONE PIECE** (long-running Japanese manga), **Omniscient Reader** and **Solo Leveling**
(Korean manhwa/webtoon). Could not reach **The Apothecary Diaries** — ran out of tool-call budget
before finding a working path to search (see "Not tested" below).

## 1. Is there a new section, and where does it sit?

Observed (01-onepiece-top.png → 03-onepiece-scrollup.png, 26/27-sololeveling-scroll.png). Page order
on a series detail screen, top to bottom, is:

1. Header / synopsis
2. **Releases** (existing — next-chapter ETA; on Solo Leveling this showed an error, see §6)
3. **Volumes** *N* — "Apple Books" (existing "buy it" shelf — horizontally scrolling covers with prices)
4. **Other editions** ← the new section, immediately below Volumes
5. **Editions** (existing, older section — e.g. "EN · Shonen Jump — 113 volumes · digital · Official")
6. Related / Similar / Readers also like / Scores elsewhere

So "Other editions" sits directly between the two existing sections, not beside or instead of either.
It does **not duplicate** the Apple Books Volumes shelf — Volumes shows purchasable numbered covers with
GBP prices; Other editions shows dated text rows per printing/format (GN vs eBook vs omnibus) sourced
from ANN/Open Library, which Volumes doesn't have. It sits oddly close in *name* to the pre-existing
"Editions" section a few hundred points below it, though — two sections called "Editions" and "Other
editions" back to back, with different data shapes and no visual distinction beyond the header text, is
the kind of thing a reader would call confusing on a first look. **Guessing** on user confusion; **observed**
the naming collision itself.

## 2. What does each group say? Does it name its source? Is ANN tappable?

Screenshot: 03-onepiece-scrollup.png (top of "Other editions" for ONE PIECE).

The section is internally grouped into sub-blocks, each with its own byline:

- **"Vol. 113 announced for 10 November 2026 · Anime News Network"** — one-line forecast row, sourced.
- **"Open Library"** header, then **"The request didn't complete."** — labelled, and honestly empty.
- **"English · One Piece"** subheader with **"Volume data from Anime News Network"** directly under it,
  then a long flat list of rows: `One Piece (GN 10)` / `One Piece - Tears (eBook 9)` / `One Piece -
  [Omnibus] 32 - Wano (GN 94-96)`, each with a date and a small red arrow (↗) icon on the right.

So yes — every group that has data names its source (ANN or Open Library), and the ANN block carries one
shared "Volume data from Anime News Network" attribution above the whole list rather than repeating it
per row. **The rows do look tappable**: consistent right-aligned arrow-out icon, same affordance as a
normal link row elsewhere in the app. I did not tap through (told not to follow links out of the app), so
I can't confirm the destination is each row's *own* ANN entry as opposed to a shared search page —
**guessing** on where the link actually goes, **observed** that the visual affordance is present and the
section is clearly attributed to ANN by name.

For Solo Leveling (Korean manhwa, 27-sololeveling-top.png) the same section renders as two short error
lines instead of a list — see §6.

## 3. Languages: only English + original language?

Scrolled the full ONE PIECE "Other editions" list (screenshots 02–08, ~230 rows: GN, eBook, and Omnibus
English printings). Every row I saw was English. I did not see a German, French, Spanish, or Portuguese
row anywhere in the list, and did not see a Japanese/NDL sub-block either (see §5). **Observed**, but
with a caveat: the list is long enough (100+ rows) that I sampled it via repeated scroll+screenshot
rather than reading literally every row — a single stray non-English/non-Japanese row in a gap I
scrolled past is possible but I found none in ~6 full screens of it.

## 4. Forthcoming volumes / wrong ended-status claims?

Yes: ONE PIECE's "Other editions" top line reads **"Vol. 113 announced for 10 November 2026 · Anime News
Network"** — a future-dated, clearly-labelled-as-announced volume, correctly separate from the released-
volumes list below it. I did not see any copy claiming a series "has ended" or "nothing is coming" — on
the contrary, ONE PIECE's header area already says "Manga · Releasing" and "LIKELY · Due in 5 days" for
the next chapter (01-onepiece-top.png), consistent with the forecast. **Observed**, good behavior: the
forthcoming-volume line reads as a forecast, not a promise.

## 5. Per-series coverage differences

- **ONE PIECE** (long-running Japanese manga): full ANN English list (GN + eBook + Omnibus, ~1997–2023),
  plus the Vol. 113 forecast. Open Library errored ("The request didn't complete"). **No Japanese/NDL
  entries found** anywhere in the section despite scrolling the entire list — for a series this is
  explicitly supposed to source Japanese volumes from NDL, that's a gap worth flagging, though I can't
  rule out I scrolled past a short NDL block given the list's length. **Guessing** on whether NDL simply
  returned nothing for this title vs. is broken; **observed** that no such block was visible in my pass.
- **Solo Leveling** (Korean webtoon, "expect little"): confirmed — "Other editions" has no volume list at
  all, just two short error/empty lines (§6). Matches expectation.
- **The Apothecary Diaries** (manga + light novel): **not tested.** I could not find a reliable way to
  reach search — see "Not tested" below.

## 6. Failure and empty states

This is where the new work looks most deliberate. Every failure I hit had explanatory copy, never a bare
spinner or a silent blank:

- **Open Library**, on both ONE PIECE and Solo Leveling: "Open Library" label + "The request didn't
  complete." — plain, honest, no fake "no editions found."
- **ANN forecast on Solo Leveling**: "Announced volumes couldn't be checked just now." — this is the good
  line: it explicitly reads as "we don't know" rather than "there is nothing," which is exactly the
  distinction the brief asked me to check for.
- **"Releases" section** (existing, unrelated to the three new sources but hit repeatedly): "The request
  didn't complete." with a **Retry** button, on Solo Leveling.
- **Rate limiting**, hit three separate times across different series (Pick Me Up, Solo Leveling,
  Surviving the Apocalypse — screenshots 20, 25, 28): an actual in-app card, not a toast — **"Too many
  requests, briefly / MangaBaka is throttling this connection. The limit is shared by everyone on your
  network, so this may not be you at all. / Retrying in 4s"** with a Retry button. This is the best copy
  I saw in the whole walk: it pre-empts the user's likely wrong conclusion ("it's just me") and says
  exactly what's happening and that it's already retrying. Worth calling out as the standout moment,
  same as the brief said a good empty-state line is worth flagging.

No group sat empty with zero explanation, and no spinner ran indefinitely in front of me — though I can't
rule out a spinner that resolves slower than my scroll-and-screenshot cadence caught.

## 7. Timing

Not rigorously measurable through screenshots, but the ONE PIECE detail page settled its header content
before I could scroll to it, and the "Other editions" section had already finished (showing ANN rows, not
a placeholder) by the time I scrolled to it a few swipes in — I didn't observe content shoving other
content around after it had already rendered. The three rate-limit cards above are the one place timing
is visibly bad: a **retry-in-N-seconds loop that is user-visible**, meaning on a throttled network this
section can sit retrying for a while with the rest of the page usable around it. That's a real, observed
timing issue, just not the "sections arrive late and shove layout" variant the brief was watching for.

## Not tested

- **The Apothecary Diaries** (manga vs light novel shelf separation) — never reached. The bottom tab bar /
  search button is visually present in the very first Discover screenshot but became unreachable after
  the first navigation: repeated taps on its location landed on nothing, and a translucent
  circular overlay (a recording-indicator-style icon plus a magnifying glass) sits fixed over part of
  that same screen region and appears to intercept taps in later screens. I could not find a search entry
  point in the time budget; I reached Solo Leveling and Omniscient Reader only by following "Readers also
  like" / "Similar" carousels from ONE PIECE. This means point 5's manga/light-novel shelf-separation
  check, and the "German/French/Spanish/Portuguese" check on a series with heavier European licensing,
  are both unverified.
- I did not attempt to tap into any individual ANN row (instructed not to follow links out of the app), so
  I can't directly confirm each row deep-links to its *own* ANN entry rather than a shared/search page —
  only that the tappable affordance (red arrow icon) is present and consistent.
- Did not confirm whether NDL (Japanese volumes) is wired up at all for any series I could reach — ONE
  PIECE would have been the best candidate and showed no Japanese block, but I can't distinguish "NDL
  returned nothing for this title" from "NDL is broken" from just the UI.

## Summary of what's good

- Every error state names what failed and says "couldn't check" / "didn't complete" rather than implying
  emptiness — this is exactly the honesty bar the brief asked about, and the app clears it everywhere I
  looked.
- The rate-limit card is genuinely well-written: explains the shared-network caveat, gives a concrete
  retry countdown, offers a manual Retry.
- ANN is named as the source both at the per-row-group level and implicitly through the section it's
  attributed to; the forthcoming-volume line is clearly framed as a forecast, not a claim.
- Section placement doesn't duplicate the existing Apple Books shelf.

## Summary of what's concerning / missing

- No Japanese/NDL volumes visible on ONE PIECE despite scrolling the entire "Other editions" list —
  worth a direct check against the NDL integration, since this was one of the three sources the task said
  was "wired in an hour ago."
- Two sections both titled around "Editions" ("Other editions" and "Editions") sit a few hundred points
  apart with different data shapes and no visual distinction — likely to read as redundant/confusing.
- Couldn't verify the light-novel/manga shelf separation (Apothecary Diaries) at all.
- Search/navigation itself was the biggest practical obstacle in this walk: an overlay in the lower-right
  of the screen appears to block taps intended for the app's own search button in some screens.
