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
| ~~Spotlight cover thumbnails~~ | Done: 941 entries in 84 ms off the main actor; cache only |
| Volumes for series with no English ebook | Mostly done: the Japanese store's edition (covers and count, no price). Rakuten/DMM parked — Abdi declined the signup 2026-09-11 |
| Volumes: Google Books as second filler | **Keyless is not dependable.** Two keyless requests on 2026-09-11 both got HTTP 429 "Queries per day" exhausted — for Google's shared anonymous project, not this IP, so every keyless reader shares one bucket. Needs a free API key (Google Cloud console → enable Books API → create key; ~5 min, but a signup). With a key: 1,000/day per key, enough at a request per series page cached a week. Parked until Abdi wants the signup; the Japanese-store fallback covers most of the gap |
| Preview beside a volume (item 5 original) | Apple Books' "Sample" is native on the store page the spine opens, so this may be done by default; confirm on the phone |
| Barcode scan | Abdi said leave it for now. Camera: cannot be verified on the simulator |
| Follow a publisher, with reminders | A design for "follow"; the page exists now |
| Anything read from Webtoons / Tapas pages | **Removed 2026-09-11 evening** (was `d54dcd7`, one afternoon). Abdi: no visible benefit — og:image is the cover MangaBaka already has — and the first App Store submission should be beyond reproach. Do not rebuild without a partner API from the platform |
| The hero's one unreproduced compact first-open | Reproduction; watch for it on the phone |

## Accessibility audit, 2026-09-11 evening

83 issues against 78 on the morning baseline. Diffed line by line: nearly
all of the change is content churn (a different series was open, so its
synopsis, title and labels appear and the old ones vanish). One issue from
today's work — "Free" on the read chips failed contrast — fixed. The rest
are the known classes: the stats strip's uppercase labels, the synopsis at
AX sizes, the hero title's Dynamic Type, the library search field's height.

## App Store readiness, checked 2026-09-11

Swept against the review guidelines (a Sonnet agent over the code, then
judgement calls by hand). Everything else was OK with evidence; these are
the things to do or say at submission:

- **Privacy questionnaire in App Store Connect** must match the manifest:
  *User ID* and *Other user content* (the reader's library, sent to their
  MangaBaka account), linked to the user, for app functionality, not used
  for tracking. Nothing else. No analytics, no ads, no IAP.
- **Age rating**: explicit content is reachable behind an opt-in toggle, so
  answer the questionnaire honestly (mature/suggestive themes present,
  off by default) rather than "none".
- **Reviewer note** to write: "Reader links on a series page come verbatim
  from MangaBaka's community-maintained dataset (CC BY-NC-SA 4.0); the app
  opens only http(s) links and does not curate them. Sign-in is a personal
  access token from mangabaka.org; the app creates no accounts, so there is
  no in-app account deletion — 'Remove token' de-links the device."
- **Hosts the app talks to**, for the reviewer if asked: api.mangabaka.org,
  api.mangaupdates.com, itunes.apple.com, graphql.anilist.co,
  shikimori.io (shikimori.one now redirects here, verified 2026-09-13).
  Nothing identifying goes to any but MangaBaka.
- Removed before submission: anything that read a platform's web page.

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
- ~~New from a publisher you follow.~~ Built as a page instead of a follow
  (Abdi, 2026-09-11): tap a publisher or studio on a series page → their
  page, everything MangaBaka attributes to them, most popular first, with
  the directory record where one exists. Studios (REDICE) are only in the
  series search, not the directory. A "follow" with reminders is still open.

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

---

## Done 2026-09-12

- **Cover galleries narrowed to readable languages** — `89033ae`. English plus
  the series' own language; novels exempt. Solo Leveling keeps 14 of 24 covers.
- **Tag pages no longer stop at 30** — `89033ae`. Not the tag route at all:
  `SeriesRepository.search` filters rows locally, and every pager inferred "more
  pages exist" from survivor count, so one filtered row killed pagination
  forever. `Pagination.next` had been modelled, decoded, and never read.
- **Apple + Google volume shelf** — `5ef96ac`, then `d0faf61` removed the Google
  API key in favour of the anonymous quota. Apple wins every collision; Google
  only fills numbers Apple lacks. Expect Google to return nothing most of the
  time: the shared quota was exhausted when measured.
- **Character profiles, with Shikimori when AniList is down** — `5ef96ac`,
  translated on-device before display.
- **Reading links held to an allowlist** — `633ef61`. 132 measured hosts;
  unrecognised hosts are hidden outright. Guideline 5.2.3.
- **`pornographic` removed, `erotica` gated** — `a3656dd`. See the amendment in
  `designs/app-feature-spec.md`.
- **Webtoons release feeds** — `d3adf24`, `f1ba553`, `4963d13`, `c31fce4`. The
  first source here that publishes real release dates. See
  `release-sources-2026-09-12.md`.
- **TestFlight build 64 crash fixed** — `3e603ca`. The Translation framework's
  download prompt was being raised from inside a sheet.

## Done 2026-09-13

- **Release section on the detail page** — Webtoons, Naver and the seven
  GigaViewer magazine feeds behind one `ReleaseFeedProvider`, merged by
  `ReleaseFeedService`, shown before the volumes shelf as "Releases · <source>".
  Tapas dropped: no episode endpoint (see `release-sources-2026-09-12.md`,
  2026-09-13 section). The Korean-vs-English gap compares title-parsed numbers
  within one season only — `totalCount` (653) against "[Season 3] Ep. 235" would
  have claimed Tower of God's original was 418 ahead. Proved by revert.
- **Language-pack download offered from Settings** — the crash fix left readers
  without ru→en silently getting no character text.
- **Dynamic Type leftovers** — only two real defects were left in the four
  audit classes (a 10pt chevron in the synopsis, a fixed 40pt search field);
  the stats strip and hero were already scaled by `459c926`. Muted labels
  measure 4.66:1, so no colour change. Residual project-wide: 63 fixed-point
  fonts and 44 fixed heights outside the detail page, listed by the agent, not
  fixed. **Not verified on a device at AX sizes.**

- **Deep review, data-shape focus, all 77 findings fixed** — `docs/reviews/SUMMARY.md`,
  commits `cfe6cb8`…`b55b222`. Seven Sonnet fixers by file ownership, one compile.
  Headline causes: matchers fitted to one publisher (12 sites), Codable fields typed
  without a captured payload (publisher `founded` was `Int?`, wire sends a date; the
  anime row read a v2-only key), UTC dates read locally, empty answers cached as
  long as good ones. 120 new tests, fixtures now real captures (French Webtoons
  feed, 72-item GigaViewer magazine, Kodansha/Seven Seas/VIZ titles). Honest gaps:
  the repository-filter drift test is a lock, not a proof (no live drift found);
  nested same-tag BBCode spoilers still split early; Google Books still mostly
  answers nothing (quota).
- **Apple Books: Square Enix numbering** — `df43edc`. The Apothecary Diaries
  showed six light novels instead of sixteen manga volumes.
- **Notifications cut to two conditions** — `NotificationPolicy` (new). Per
  Abdi: only a confirmed release out now, or a reading/paused series
  completing or ending a season. Cadence predictions, the monthly backlog
  nudge, the "back to it" nudge, and the publisher-follow notification are
  deleted, not gated off. `ReleaseReminders.reschedule` no longer rebuilds a
  calendar (`predicted`/`lastOpened`/`readingHour` are gone from its
  signature); it notifies once per event through the existing `notify()` path,
  capped at 3/day (a guess) with a 24h same-series cooldown. Feed-confirmed
  episodes, season-ended and Naver-finished are wired in `NotificationPolicy`
  but currently never fire in the app: `RootView+Session.refreshReminders`
  has no `[Int: ReleaseFeed]` cache to pass without adding a network call.

- **Failure audit, all 123 gaps fixed** — `docs/reviews/FAILURES-SUMMARY.md`,
  commits `9143277`, `67916a9`, `d4cd541`. Every request, decode, third party
  and trap now has a loading state, an honest failure (who failed, for how
  long, Retry), and an empty state only when the source answered. Shared kit:
  `APIError.party`, `.cancelled`, 20 s timeout (guess), pre-emptive 30/min
  search window, live countdown, `Fetched<T>`, `InlineFailure`,
  `ConfirmDestructive`, `Int(wholeOrClamped:)`. Characters are now AniList ∪
  Shikimori with a rough fuzzy match (Abdi's ask). 1,368 tests. **Not verified
  on a device**: onboarding push ordering; the corrupt-database reset toast.
- **Decisions taken as recommended** (flip if wrong): inline "Couldn't load ·
  Retry" per section; partial library renders with a bar; "Remove token" and
  "Deal another now" confirm; countdown auto-retries on Search only; library
  writes patch locally with a "Saved" toast.

## Next, in the order I would do it

1. **18+ age rating in App Store Connect**, and confirm which tier applies now
   that Apple has moved to 13+/16+/18+.
2. **App Store screenshots without real manga covers.** Nothing exists yet, so
   nothing is wrong yet; the constraint applies to the icon and promo text too.

## Explicitly not doing

- **Link unfurling / scraping Open Graph and JSON-LD** for metadata. Tested and
  it does not carry what it was claimed to — see `release-sources-2026-09-12.md`.
  It would also cost a dependency, a privacy story, and ongoing breakage to fetch
  data the app already has.
- **Blurring mature covers behind a toggle.** Those covers are filtered
  server-side and never downloaded unless the reader opts in, so a blur is
  redundant for the default reader and pointless for one who chose otherwise.
  Revisit only if a reviewer says otherwise.

