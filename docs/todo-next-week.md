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
| Siri / Shortcuts intents tried for real | Only the logic is tested; Siri is not on the simulator. Try "What's due this week in MangaBaka" on the phone |
| Spotlight cover thumbnails | A measurement: covers live in URLCache, 900 through it per launch is a cost to see first |
| Volumes for series with no English ebook | Rakuten Books / DMM Books as Japanese-edition fillers once Abdi's accounts exist and their terms are read. DMM: `floor=comic` only, never FANZA. Until then such series show MangaBaka's editions or nothing |
| Volumes: Google Books as second filler | **Keyless is not dependable.** Two keyless requests on 2026-09-11 both got HTTP 429 "Queries per day" exhausted — for Google's shared anonymous project, not this IP, so every keyless reader shares one bucket. Needs a free API key (Google Cloud console → enable Books API → create key; ~5 min, but a signup). With a key: 1,000/day per key, enough at a request per series page cached a week. Parked until Abdi wants the signup; the Japanese-store fallback covers most of the gap |
| Preview beside a volume (item 5 original) | Apple Books' "Sample" is native on the store page the spine opens, so this may be done by default; confirm on the phone |
| Barcode scan | Abdi said leave it for now. Camera: cannot be verified on the simulator |
| New from a followed publisher | A design for "follow" |
| Webtoon episode lists or thumbnails from the platforms | Declined: no public APIs, and scraping is the terms line. The page shows Season · Episodes from MangaBaka + the schedule, and the read chips carry "Free" / "Free to start" / "Subscription" where that is settled (Webtoons, Tapas, Manta; 2026-09-11) |
| The hero's one unreproduced compact first-open | Reproduction; watch for it on the phone |

## From Abdi, in build order

1. ~~Hero compression only when it has to.~~ Done, above.
   (3: gloss done; colour bleed done `d1e7554`.)

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

4. **All the volumes, with official covers and buy links.** Done 2026-09-11
   via the iTunes Search API (Apple Books shelf on the series page, official
   covers, price, buy link; strict title+volume match). Japanese-only series
   still wait on Rakuten/DMM. Original plan: MangaBaka's
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
- ~~Price.~~ Done with the Apple Books shelf (item 4 commit): the store's
  price under each spine.
- ~~iOS search finds your library.~~ Spotlight `0e9cbab`, App Intents
  `114a43b`. Thumbnails outstanding (see the table).
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

- **Decisions for Abdi** — ~~`ShelfDetailView` delete-or-rewire~~ (re-wired,
  2026-09-11); ~~L12 two rating scales~~ (the reader's own is stars, Wrapped
  now says so); L7 the A-Z jump index at
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
