# Roadmap — "help people find the work faster"

Abdi, 2026-09-11: nothing here reproduces copyrighted material. Every item
links to the official product, the official reader, or a first-party store,
and only where the source says the thing exists in the reader's language.
Weekly limit reset before any of it is built.

## Done 2026-09-11 (easiest first, on the £8 of extra credits)

- **1. Hero compression only when it has to** — `5be4a35`. Measured, not
  `ViewThatFits` (unbounded height in a ScrollView); full column shown when
  ≤ the cover's 225pt. One unreproduced first-open compact on ONE PIECE.
- **2 + "Where to read, in your language"** — `f4de983`. One surface: a
  "Read in English" chip row under the actions, one chip per platform in the
  reader's language, opening the title's own link through the system.
  **Still to check on the phone:** that Webtoons/Tapas open in-app.
- **iOS search finds your library** — `0e9cbab`, Spotlight half. Verified on
  the simulator. App Intents half still to do (below).
- **mangabaka.org links** — `99135b7`, our side. Share button live; opening
  is dormant until the association file exists. **Ask for MangaBaka** (not
  sent — draft):
  > Could mangabaka.org host `/.well-known/apple-app-site-association`
  > (served as `application/json`, no redirect) with
  > `{"applinks":{"details":[{"appIDs":["<TEAMID>.dev.abdirahmanmohamed.mangabaka"],"components":[{"/":"/*/*/*"},{"/":"/*/*"}]}]}}`?
  > Then series links open in the iOS app when it is installed.
  Our side after that: the Associated Domains entitlement
  (`applinks:mangabaka.org`) — a provisioning change, do it on a day with a
  TestFlight build to check.
- **Four small review findings** — `de7b802`: D-A4 (double search), D-B2
  (torn row on refresh — the review's suggested guard was wrong, the test
  caught it), L10, W16. P-F12 was already settled by `2f78286`.

## Not done yet, and what is holding each one back

Kept current so nothing is forgotten. Abdi, 2026-09-11.

| Item | Blocked on |
|---|---|
| Webtoons / Tapas opening in-app from the "Read in English" chips | Abdi's phone with Webtoons installed; the simulator has no such app, so it opens Safari there |
| mangabaka.org links opening in the app | MangaBaka hosting `/.well-known/apple-app-site-association` (draft ask above); then our Associated Domains entitlement, on a TestFlight day |
| App Intents ("What's due this week", "Open <series>") | Nothing — next cheapest, ~half a day |
| Spotlight cover thumbnails | A measurement: covers live in URLCache, 900 through it per launch is a cost to see first |
| Colour bleed behind rows (item 3, second half) | Nothing hard: BlurHash gives the colour; a per-row ambient tint is a gradient too. The gloss itself shipped (`glossy covers` commit) |
| All the volumes (item 4) | 2–3 days; first request is One Piece `/v1/series/377/images` to count volume covers. Data-source accounts: **Rakuten Books API** (App ID, free, no sales quota — Japanese covers, volume numbers, ISBNs, dates) and **DMM Books affiliate API** (account; `floor=comic`) — Abdi is making both accounts. Both are data sources like Google Books, not buy destinations for iOS readers; DMM's FANZA side is adult and must never be queried. Terms of each to be read before a request is written |
| Preview beside a volume (item 5) | Item 4 |
| Apple Books price line | Item 4's iTunes lookup |
| Barcode scan | Camera: cannot be verified on the simulator. Needs Google Books ISBN resolve + VisionKit, ~1 day, then a phone check |
| New from a followed publisher | A design for "follow" |
| The hero's one unreproduced compact first-open | Reproduction; watch for it on the phone |
| Volume covers unavailable for series with no English ebook | Rakuten/DMM above may close this gap for Japanese editions |

## From Abdi, in build order

1. ~~Hero compression only when it has to.~~ Done, above.

2. ~~"Read" opens the exact title in the official app.~~ Done as the chip
   row, above; phone check outstanding.

3. **Glass covers everywhere, cover colour bleeding into the ground.** The
   gloss is done 2026-09-11 — Abdi clarified it is a shiny pane, not the
   3D material, so it is two gradients and a rim, free on sixty cards, no
   device measurement needed. The colour bleed remains. Original note: BlurHash
   already gives a dominant colour per card for free; a per-row ambient tint is
   an average of the visible cards'. Glass over ~60 cards is GPU work: build it
   behind a flag and measure scroll frame time on the 16 Pro with the
   performance target *before* it defaults on. If it drops frames, detail page
   only. 1–2 days.

4. **All the volumes, with official covers and buy links.** MangaBaka's
   `/works` is editions for sale and is sparse (One Piece: 8 of 113). The
   order of sources, cheapest first — Amazon is not on it, for covers or
   anything else:
   - **Count**: MangaBaka `final_volume`; Wikidata for the big series.
   - **Covers**: MangaBaka `/v1/series/{id}/images` first — already decoded,
     rows carry `type: volume`, `index`, `language`, and may hold far more
     than `/works`. *First thing: one request for One Piece to see.*
   - **Fill**: iTunes Search API (`media=ebook`, `country=` — 600px art, Apple
     Books link, one result per volume sold), then Google Books as the ISBN
     resolver and cover gap-filler only. **Google is data, not a destination**:
     these are iOS readers, so buy links go to Apple Books, never Play Books
     (Abdi, 2026-09-11).
   - Strict match: title and volume number must both appear, else "couldn't
     verify" rather than a wrong cover. Lazy per visible spine, cached on disk.
   - Series with no English ebook and no MangaBaka images get "N volumes,
     covers unavailable", not a fake. 2–3 days.

5. **"Preview" beside a volume, only where a preview exists.** Apple: the Books
   app link, where "Sample" is native. Google's web reader only where Apple
   has no sample and Google reports `viewability == PARTIAL` — a preview is
   worth a web page, a purchase is not. No page images pulled directly —
   undocumented, watermarked, against terms. Expect the button to be absent on most licensed
   manga; that is correct. Webtoons' free first episodes are the real preview
   and item 2 lands on them. 1 day on top of item 4.

## Same theme — accepted by Abdi 2026-09-11, part of the roadmap

- **Scan the barcode in a shop.** VisionKit's on-device scanner reads the ISBN
  off a physical volume → Google Books resolves the title → MangaBaka search
  → the series page, with your library state on it ("you're on chapter 53").
  No terms issue; nothing leaves the phone but a title. The single most
  "find it faster" thing on this list. ~1 day.
- **Price.** Apple Books' price beside MangaBaka's own listed price on the
  volume sheet, from the same lookup as item 4. No Play Books price: nobody
  here can buy there. Half a day once 4 exists.
- **iOS search finds your library.** Spotlight half done (`0e9cbab`; no cover
  thumbnails yet — covers are in URLCache, measure before pulling 900 through
  it per launch). Still to do: App Intents for "What's due this week" and
  "Open <series>". Half a day.
- **mangabaka.org links open in the app.** Our side done (`99135b7`); waiting
  on MangaBaka for the association file, then the entitlement.
- ~~"Where to read, in your language."~~ Done (`f4de983`).
- **New from a publisher you follow.** `/v1/publishers/{id}/collections`
  exists; a "coming from Seven Seas" row or a reminder when a followed
  publisher lists a volume. 1 day; needs a design for "follow".

Declined, with the reason: Amazon links without an Associates account; pulling
preview pages as images; a generic "open Webtoons" button that lands anywhere
but the title; Crunchyroll for the anime (no per-title link in the data).

## Review findings deliberately left, with reasons

From the 2026-09-11 deep review (`docs/reviews/SUMMARY.md` has the ids).

- **Decisions for Abdi** — `ShelfDetailView` delete-or-rewire; L12 two rating
  scales (out of 5 in Library, out of 10 in Wrapped); L7 the A-Z jump index at
  20×13pt (a redesign); L11/S-F21 the hand-drawn switch (contested in the
  review itself); S-F12 `AppServices`' nineteen values.
- **Judgement calls** — R24 series titles on the lock screen; D-A3 tag chips
  re-blend and type chips do not; P-F10 a client backstop for `tag_not`.
- **Would need a measurement first** — S-F17 the gallery's two 1000pt blurs;
  S-F5 `heroTitleTravel` at AX sizes; S-F14 leading vs Dynamic Type; S-F19
  Bold Text; S-F6 `Motion` and view invalidation; S-F4 the key-window inset.
- **Tied to the shelf decision** — L3 `shelves` derived for a screen nothing
  presents.
- ~~Small and unglamorous~~ — all settled 2026-09-11 (`de7b802`; P-F12 by
  `2f78286`).
