# Detail-page request budget vs. the walk's 429s

> **Update 2026-09-15.** Two changes since the count below: the `/links` leg is
> gone (the full record's `links_v2` carries the same rows — checked on series
> 2060, same 21 ids, every field `SeriesLink` reads), and the two feeds
> (`similar`, `readersAlsoLike`) are `.background`, joining news, relationships
> and collections. A cold open is now **8 requests, 3 of them foreground**
> (`full`, `works`, `images`), so the guaranteed floor under Discover prefetch
> is **60 / 3 = 20 cold opens a minute**, from 6.6. The five background legs
> wait at the gate instead of throwing. Not re-walked on a device; the count is
> from the code and `LinksInlineTests`.
>
> **Later the same day, from poking the API rather than the code:**
> - `/images` pages at 24 and caps `limit` at 50; the app took page one.
>   Series 2060 holds 75 covers (the fan showed 16), ONE PIECE 931. Repeated
>   `language=` filters server-side (a comma list is rejected); `content_rating`
>   is accepted and ignored (75 of 75). Now sent: `limit=50&language=en&language=ko`
>   (`SeriesRepository.imagesQuery`). Rows can be `volume_back` and `season`,
>   which the caption used to call "Vol. N" — fixed in `SeriesImage.caption`.
>   The response also carries `available_languages` / `available_types`;
>   unused, noted for a future "other languages" toggle on the gallery.
> - `/works` pages ascending at 25 by default, ignores `sort`/`order`, caps at
>   50. ONE PIECE (377): 267 printings, page one grouped to "Volumes 7", and
>   volume 113 (2026-11-10) on page 6 — never fetched, so the Next-volume
>   widget could not see it. Now first + last page (`fetchWorks`), one extra
>   `.background` request only when `count > 50`; the shelf badge reads the
>   highest volume number and says it is showing first and latest.
> - Each work carries its `collections` inline, identical in shape to
>   `/collections`. Across six series every collection appeared via works, but
>   a collection with no catalogued works would not, so the `/collections` leg
>   stays. Sample too small to cut it: 0 misses of 9 collections.
> - `/v1/series/mix` already returns the full 36-field series; `schema=full` is
>   rejected there and was never needed (`open-items-2026-09-15.md`).

## 1. Every MangaBaka request on open

Cold open (series never cached), all default to `.userInitiated` (`APIClient.swift:61,574`; nothing overrides it):

| Call | Endpoint | Cache | Priority |
|---|---|---|---|
| `similar` feed | `SeriesDetailView.swift:565` → `SeriesRepository.feed` | 24h TTL (`SeriesRepository.swift:353-359`) | `.userInitiated` (default, `SeriesRepository.swift:500-501`) |
| `alsoLike` feed | `SeriesDetailView.swift:566` | 24h TTL | `.userInitiated` |
| `extras` → `links` | `SeriesRepository.swift:857-860` | 6h, one bundle (`SeriesRepository.swift:779-786`) | `.userInitiated` |
| `extras` → `news` | `:861-867` | 6h | `.userInitiated` |
| `extras` → `relationships` | `:868-871` | 6h | `.userInitiated` |
| `extras` → `full` (`/v1/series/{id}`) | `:873-876` | 6h | `.userInitiated` |
| `extras` → `editions` (collections) | `:877-880` | 6h | `.userInitiated` |
| `extras` → `works` | `:885-888` | 6h | `.userInitiated` |
| `images` | `SeriesRepository.swift:767-768` | in-memory `BoundedCache`, indefinite until relaunch | `.userInitiated` |

**Cold-open total: 9 MangaBaka requests**, matching the doc comment (`SeriesDetailView+Editions.swift:11-12`). **Warm-open (same series inside 6h/24h caches): 0.** `loadTaste` (`SeriesDetailView.swift:663`) adds a 10th, but only on the *first* detail page opened per launch (session-cached).

The 7–9 "third-party" requests in the same comment (ANN, Open Library editions, NDL, Apple/Google Books, MangaUpdates cadence/categories, release feeds) are a separate pool — different hosts, different `RequestSpacing` gates, no shared budget with MangaBaka's own gate.

## 2. The gate's math

`RateLimitGate.swift:53`: general family = 180/min, search = 30/min (only `/series/search`, `RateLimitGate.swift:87-91` — nothing on the detail page hits it).

All 9 detail-page requests are `.userInitiated`, which is checked against the **full** 180 with no reserve deduction (`RateLimitGate.swift:198-213`). Theoretical ceiling: **180 / 9 = 20 cold opens/minute** if nothing else is running.

Discover/Stack prefetching uses `.background` (`DiscoverModel.swift:296`), which shares the *same* general window but is capped at `limit − reserve = 120` (`RateLimitGate.swift:70-75`), leaving `.userInitiated` a guaranteed floor of `reserve = 60` slots. So under contention with background feed traffic, the guaranteed floor drops to **60 / 9 ≈ 6.6 cold opens/minute**.

At the limit the gate does not queue `.userInitiated` requests — it throws `.rateLimited` immediately once the window is full (`RateLimitGate.swift:208-212`), which is what the reader sees as the card. `.background` requests instead wait (`waitForBackgroundSlot`, `:289-315`).

## 3. Where the card comes from, and what section it's really on

"Too many requests, briefly / MangaBaka is throttling this connection…" is `APIError.rateLimited(_, party: .mangaBaka)`'s rendering (`APIError.swift:279`, `:341`). It fires only when `party == .mangaBaka`, i.e. the *local gate itself* refused (or the server sent a real 429 and `recordRateLimit` remembered it, `RateLimitGate.swift:334-343`) on a MangaBaka-family request — not a third-party one.

**Correction to the premise:** the walk doc does not actually attribute the three rate-limit cards to the "Releases" section. `docs/reviews/walks/editions.md:95-96` separately reports a *different*, non-throttle error ("The request didn't complete") specifically on Releases for Solo Leveling. The three 429 cards (`editions.md:97-103`) are reported as standalone, one each on Pick Me Up, Solo Leveling, and Surviving the Apocalypse, with no section named. Given §3's `party` gating, they are far more likely to be one of the 9 `.userInitiated` MangaBaka legs above (most plausibly `extras`, which is 6 of the 9 and gates the whole page's "readable" state) than the Releases section, which calls a third-party `ReleaseFeedService` (`SeriesDetailView+Releases.swift:15-19`) whose errors carry a non-`.mangaBaka` party.

This is a real 429, not a client-side pre-refusal wrongly worded: "Retrying in 4s" in the walk's copy matches a short `Retry-After`-driven countdown (`RateLimitGate.swift:333-343`), which only exists once a request has actually reached the server and been refused.

## 4. Existing measurement

No debug screen or test renders "requests per detail open." `NetworkLedger.swift` records per-host counts, but `docs/reviews/SUMMARY-2026-09-11.md:245` notes it's blind to writes, and nothing surfaces a per-page-open total from it.

An older count exists: `docs/reviews/full/wire.md:81` says "the series page fires **seven** general requests per open… plus `/images`" (= 8) — stale relative to today's 9, consistent with a source added since (the doc comment citing "nine" is dated 2026-09-14, today).

## 5. Conclusion

**(a)** 9 MangaBaka requests per cold detail-page open (0 warm, within 6h/24h caches) — confirmed directly in `SeriesRepository.swift:857-888` + `:565-566,767-768`, matching the doc comment.

**(b)** 20 cold opens/minute before hitting the general 180/min limit if nothing else is running; **as low as ~6.6/minute** if Discover/Stack background prefetch (`DiscoverModel.swift:296`) is saturating its 120-slot cap at the same time — they share one budget (`RateLimitGate.swift:70-75`).

**(c)** Yes, plausibly exceeded: ~6 series visited in a fast walk is up to 54 general requests: comfortably under the 180/20-opens ceiling alone, but easily over the ~60-slot floor if Discover/Stack background traffic was concurrently active (which the Discover/Stack screens the walk passed through before the detail walk would have started). Can't fully separate "page asks too much" from "walker went too fast" from the evidence on hand — no NetworkLedger dump or timestamp log was captured during the walk. Leaning toward walker pace + concurrent background load, not the per-open request count itself, since 9 requests/open is a documented, deliberate design (`SeriesDetailView+Editions.swift`, `SeriesRepository.swift:779-786`), not a leak.

**(d)** Cheapest lever: drop 4–5 of the 9 `.userInitiated` legs to `.background` priority — `news`, `relationships`, `editions`, `works` (`SeriesRepository.swift:861-888`) render below the fold or in a sidebar (`news` in `SeriesDetailView.swift:483`), so losing the race to a real foreground request and queuing briefly costs nothing visible, while raising the guaranteed floor for the legs the reader is actually staring at (`full`, `links`, `images`, similar/alsoLike) toward the full 180. Mechanical: change one `priority:` argument per call site plus a parameter thread-through on `SeriesRepository.fetchExtras` — **effort: small, a few hours** including a `RateLimitGate` contention test. No caching change needed; the 6h/24h TTLs already make warm opens free. No request found that is fetched and discarded, or fetched for a section not on screen — `news` is rendered, `images` feeds the cover fan, all 6 `extras` legs are consumed.
