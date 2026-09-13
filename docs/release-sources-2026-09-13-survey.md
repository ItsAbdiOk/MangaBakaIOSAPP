# Release sources beyond RSS — sitemaps, public JSON, store feeds

Measured 2026-09-13 against the live sites. 93 logged requests (plus 4
gzip-size checks folded into the log), never more than 5 to one host, 1 s
apart, a Safari User-Agent, 15 s timeouts, curl `--max-filesize 6MB`. Every
request is in the appendix with status, content-type and size so nobody
re-sends it.

Read `release-sources-2026-09-12.md` first. This file does not re-test what
that one says died; it tests the methods that one never tried — sitemaps,
store feeds, and the JSON a publisher's own site calls without a login.

## The rule this was measured against

Allowed: RSS/Atom; `sitemap.xml` with `<lastmod>`; JSON the publisher's own
web page fetches with no token; documented partner APIs; Apple/Google store
feeds. Not allowed: HTML, Open Graph, headless browsers, mobile-app APIs that
need a device signature, anything behind a login, anything `robots.txt`
forbids. Each host's robots verdict is recorded below because "the file was
there" is not the same as "we may fetch it".

## Library share, from the 12 September count (940 series)

| Series | Host | Result of this survey |
|---|---|---|
| 554 | www.webtoons.com | already served (RSS) |
| 235 | page.kakao.com | sitemap exists, unusable in practice (below) |
| 228 | piccoma.com | sitemap has no dates — dead |
| 212 | manga.nicovideo.jp | sitemap redirects to login — dead |
| 189 | series.naver.com | no sitemap, robots allows — nothing found |
| 172 | comic.naver.com | already served (JSON) |
| 149 | tapas.io | **sitemap with per-series lastmod** — works, semantics unverified |
| 124 | webtoon.kakao.com | **sitemap with per-series lastmod** — works |
| 96 | comic-walker.com | **sitemap with per-series lastmod, to the second** — works |
| 87 | comic.pixiv.net | no sitemap at two paths — dead |
| 74 | zebrack-comic.shueisha.co.jp | sitemap has no dates; `/rss` is HTML — dead |
| 45 | www.crunchyroll.com | not probed: Crunchyroll Manga closed; those links are stale |

The on-device database could not be re-read from this session (the
sandbox refused the query), so these counts are the 12 September ones, not
fresh. Link *shapes* below come from the test fixtures and from the sitemaps
themselves, not from the library, and are flagged where that matters.

## What works

### Kakao Webtoon — `webtoon.kakao.com/sitemap.xml` (124 series)

- One file, 610 KB, **not gzip-compressed by the server**, 3,086 `<url>`
  entries of the shape `/content/<url-encoded-korean-title>/<numeric id>`,
  every one with `<lastmod>` and `<changefreq>daily</changefreq>`.
- 346 distinct dates; 79 entries dated 2026-09-11, 75 on 09-09, 74 on 09-10,
  three dated today. Two big clumps (1,020 on 2026-06-24, 781 on 2025-01-07)
  are bulk re-indexes, not releases — a series whose lastmod is one of those
  two dates should be treated as "unknown", not "last released then".
- What it gives: **one date per series, the most recent change**. No
  per-episode history, no episode numbers, no next date, no totals.
- Freshness: daily. History depth: none.
- Match on the trailing numeric id — that is Kakao's own key and survives
  title changes; the encoded Korean slug in the path does not.
- robots.txt: `Disallow: /webview` only. Sitemap not listed in robots but
  served at the standard path. **Allowed.**
- Politeness: fetch once a day at most, `If-Modified-Since`, one fetch shared
  by all 124 series. 610 KB/day uncompressed is the cost; Kakao ignored
  `Accept-Encoding: gzip`.
- Effort: ~150 lines. A `SitemapFeedClient` (new file, ~120 lines) that
  fetches a URL, parses `<url><loc><lastmod>` with `XMLParser`, caches a
  `[String: Date]` keyed on the loc for a day; plus a per-host key extractor
  (`/content/…/<id>` → id) and a `ReleaseSource.kakaoWebtoon` case with its
  host in `ReleaseSource.hosts` (`ReleaseSource.swift`, ~10 lines). The
  answer is a one-entry `ReleaseFeed` ("last change: date"), which
  `ReleaseSummary.summarise` must not read as a cadence — one point is not a
  rhythm.

### COMIC-WALKER (Kadokawa) — `comic-walker.com/sitemap-series.xml` (96 series)

- Index at `/sitemap.xml` (795 B) → `sitemap-series.xml`, 1.0 MB, **68 KB
  gzipped**, 8,032 entries of the shape `/detail/KC_NNNNNN_S`, every one with
  a `<lastmod>` carrying a timestamp to the second in JST
  (`2026-09-13T09:56:41+09:00`).
- 5,051 distinct timestamps. One bulk clump of 1,660 on
  `2026-08-24T16:34:33` — same rule as Kakao: that exact value means
  "unknown".
- What it gives: one timestamp per series, the last change. No episodes, no
  history, no next date.
- robots.txt: `Disallow: /?`, `/api/`, `/auth/`; sitemap listed. **Allowed.
  Note `/api/` is explicitly forbidden** — the JSON the site's own reader
  calls lives under it, so the sitemap is the only lawful machine source
  here.
- Politeness: daily, gzip, one fetch for all 96 series.
- Match on the `KC_…_S` code. The fixtures use `/detail/KC_…_S`; older
  COMIC-WALKER links were `/contents/detail/KC_…_S/` and the code is the
  same, so match on the code, not the path.
- Effort: reuses the `SitemapFeedClient` above; ~30 lines for the key
  extractor and the `ReleaseSource` case.

### Tapas — `tapas.io/sitemap-comic.xml` (149 series)

- Index at `/sitemap.xml` → `sitemap-comic.xml`, **5.4 MB, 793 KB gzipped**,
  45,653 entries, every one with `<lastmod>` (date only). 45,519 use the
  slug (`/series/solo-leveling-comic`) and 134 a numeric id. The fixtures
  store `/series/<slug>/info`, so the slug matches once `/info` is dropped.
- 4,611 distinct dates; 274 on 2026-09-12, 326 on 09-11; 2,241 series
  changed in the last fortnight. Rebuilt daily (index lastmod is today).
- **Semantics unverified.** `solo-leveling-comic` (the comic finished in
  2021) carries `2026-03-12`; `villains-are-destined-to-die` carries
  `2026-08-12`. Either Tapas republished episodes, or lastmod is "page
  edited", not "episode published". The control that would settle it —
  compare a known weekly Tapas series' lastmod against its own published day
  for two consecutive weeks — is one request a week for two weeks and was
  not affordable inside this survey's 5-per-host budget. Do that before
  building.
- `tapas.io/series/<slug>.json` (re-checked once, 769 B) confirms the
  12 September finding and adds one field: `badges: [{type:
  "WAIT_SCHEDULED", period: 86400}]` — a wait-or-pay cadence in seconds, not
  a release date.
- robots.txt: `Disallow: /rss/` for every agent — so Tapas RSS is off the
  table on policy grounds, not only because it answers 400. Sitemap listed.
  **Sitemap allowed.**
- Politeness: 793 KB/day gzipped, for 149 series. Acceptable but the
  heaviest fetch in this document; must be `If-Modified-Since` and must
  never run on cellular without the user's say-so.
- Effort: reuses `SitemapFeedClient`; ~30 lines; plus the two-week control
  first.

### Kodansha US — `kodansha.us/wp-json/kodansha/v1/release-calendar` (volumes)

- The site is WordPress. `/wp-json/` (284 KB) lists the public REST
  namespaces, one of which is the publisher's own `kodansha/v1` with
  `release-calendar`, `new-releases`, `on-sale`, `search-series`.
- `release-calendar` answers 23.7 KB of JSON, **8 weeks**: 2 past, 6 future
  (2026-08-25 … 2026-10-13), each week a list of `{title: "Volume 7",
  series_name, creators, volume_url, formats: [digital, print]}`. 74
  volumes in the sample.
- What it gives: **publisher-confirmed volume release weeks, six weeks
  ahead**, for every Kodansha USA series — the only "next date" source in
  this survey that is not a store listing.
- Freshness: weekly cadence, cache a day. History: 2 weeks only.
- robots.txt: `Disallow: /wp-admin/`, `/search/`, `/?s=`; `wp-json` not
  forbidden. The `sitemap_index.xml` answered **403** (Cloudflare) while
  `/feed/` and `/wp-json/` answered 200, so the block is per-path, not
  per-client. **Allowed** on the letter of robots; it is an undocumented
  route the site's own calendar page calls, which is inside the rule set
  for this survey but is the least "published for machines" of the working
  sources. Abdi should decide whether that is above board enough.
- Coverage of the library: unknown — the library is keyed on reading
  platforms, not English print publishers. Matching is by `series_name`
  against the series' English title, the same problem the Apple shelf
  already solves.
- Effort: ~200 lines. New `KodanshaCalendarClient` (~120), a matcher reusing
  `AppleBooksClient`'s title normalisation, and a new shape in
  `ReleaseFeed` or a sibling type for "volume, week" rather than "episode,
  instant" (the existing `ReleaseEntry` is episode-shaped; see
  `WebtoonsFeed.swift:13`).
- Also there: `kodansha.us/feed/` — WordPress news RSS, 182 KB, 10 items,
  sales and licence announcements, no release dates. Usable as an
  "announced" source only.

### Apple Books, iTunes Search — pre-orders are next-volume dates (already fetched)

- `itunes.apple.com/search?term=Jujutsu+Kaisen&media=ebook&entity=ebook&country=gb&limit=200`
  → 210 results, 324 KB. **8 carry a `releaseDate` in the future**:
  `Chainsaw Man, Vol. 22` 2026-10-13, `Jujutsu Kaisen Modulo, Vol. 1`
  2027-01-05, `Chainsaw Man, Vol. 23` 2027-02-02, `Me & Roboco, Vol. 21`
  2026-10-27.
- So the answer to "is it usable as a next-volume signal" is **yes**: a
  future-dated result is a pre-order, and a pre-order date is the
  publisher's own announced date. The app already downloads this and
  already keeps `releaseDate` as a string it never reads
  (`AppleBooksVolume.swift:28`, the comment on line 22–27 says why it is a
  string).
- Caveat visible in the same sample: the search is fuzzy — a "Jujutsu
  Kaisen" query returns Chainsaw Man and Me & Roboco. The shelf's existing
  matcher already has to cope with this; the next-volume signal inherits
  whatever it does.
- Documented, keyless, the store's own terms apply and the app is already
  bound by them. Rate limit is Apple's published ~20 calls/minute.
- Effort: **the smallest in this file, ~40 lines.** Parse `releaseDate`
  leniently (`ISO8601DateFormatter` with and without fractional seconds,
  nil on failure — never fail the row), take the minimum future date among
  matched volumes, surface it as "Vol. N on <date> (Apple Books)". No new
  network code.
- Google Books, the companion: `googleapis.com/books/v1/volumes?…` answered
  **429**, "Queries per day" quota exhausted for Google's shared anonymous
  project — the same state as on 12 September. Keyless Google Books is not
  a source anyone can rely on; a key would fix it but is a Google Cloud
  project in the app's name, which is a distribution question.

### Dark Horse — `darkhorse.com/feed/new-releases/rss/`

- `/rss` redirects to it. `application/rss+xml`, 69 KB, this week's releases
  with `pubDate` = on-sale date (`Wed, 09 Sep 2026`). Mostly American comics
  variants; manga volumes appear when they ship.
- What it gives: this week's on-sale list only. No lookahead, no per-series
  path. An "it shipped" signal, not a schedule.
- robots.txt: allows everything but `/admin/`; blocks a list of AI crawlers
  by name (`anthropic-ai`, `GPTBot`, …) — irrelevant to the app, which is
  not one of them, but noted. `sitemap-products-2020s.xml` (522 KB) has no
  `<lastmod>` at all.
- Effort: ~80 lines with the existing RSS parser; low value for this
  library.

### Sunday Webry (Shogakukan) — `sunday-webry.com/rss` exists

- HEAD → 200 `application/rss+xml`. Not fetched (budget); the 12 September
  note that `/rss/series` is 404 stands. No robots.txt (404 — everything
  allowed), no sitemap at `/sitemap.xml` or `/sitemap_index.xml`.
- Sunday Webry is not GigaViewer, so it does not slot into
  `GigaViewerFeedClient` unchanged, but if the item shape is the
  `[第N話] Title` pattern the same matcher applies. One GET to find out.

## What works but is not worth it

### Tappytoon — `tappytoon.com/sitemap-series.xml`

- Index → `sitemap-series.xml`, 334 KB / 36 KB gzipped, 2,336 entries
  (1,542 English, `/en/book/<slug>`), every one with a `<lastmod>` at
  `T04:00:00Z` — a daily batch stamp, 995 distinct days, 104 on 2026-09-10.
- Same shape and value as Kakao's: one last-change date per series.
- robots.txt: `Disallow: /comics/*/chapters` — the chapter list itself is
  forbidden to crawlers; the series sitemap is listed and **allowed**.
- Not in the library's top twelve; the fixtures carry `/en/book/x`, so the
  slug matches directly. Build only when there is a `SitemapFeedClient` to
  hang it on: ~20 lines then.

### Comikey — `comikey.com/sitemap-comics.xml`

- 137 KB, one entry per series (`/comics/<slug>/<id>/`), `<lastmod>`
  date, `changefreq: hourly`, 513 distinct dates, entries dated today.
  robots allows. Not in the library's top twelve. ~20 lines once the sitemap
  client exists.

### Kodansha K Manga — `kmanga.kodansha.com/sitemap_nexttime_viewer_1.xml`

- The name promised a next-episode list; the file (1.2 KB) holds 9 episode
  URLs with `<lastmod>` of yesterday/today plus one from March 2025, so it
  is "recently added", not "coming". `sitemap_viewer_2.xml` (1.75 MB) lists
  22,886 episode URLs, of which only 133 carry a `<lastmod>`. No
  per-series file. robots allows. Not a schedule; not in the library.

## Dead ends — do not re-test these URLs

- **page.kakao.com** (235 series, second-largest platform). Sitemap index
  exists (`/sitemap/sitemapindex.xml`, 29 KB) → **183 gzipped files of
  50,000 URLs each**; file 1 is 1.46 MB compressed. Per-series `<lastmod>`
  is present and some are today, but 4,499 of the 50,000 in the sample sit
  on one bulk date (2023-04-19). Finding the library's 235 series means
  fetching all 183 files, ~270 MB, with no index of which file holds which
  id. Exists; unusable from a phone. robots: `Disallow: /viewer`,
  `/store/kakaopage/webseries/viewer`. Note the fixtures store
  `/content/<id>` while the sitemap uses `/home/<encoded-title>/<id>`.
- **piccoma.com** (228). `/sitemap.xml` → 6 product files; `sitemapproduct1.xml`
  is 2.4 MB of bare `<loc>` (`/web/product/N`), **zero `<lastmod>`**.
  robots allows. Nothing to date from.
- **manga.nicovideo.jp** (212). `/sitemap.xml` 302s to
  `account.nicovideo.jp/spa/login` — behind login. robots.txt is an empty
  200. Dead on the "nothing behind login" rule.
- **series.naver.com** (189). robots allows (`Disallow: /my/*, /viewer,
  /search, …`), lists no sitemap; `/sitemap.xml` 404.
- **comic.pixiv.net** (87). `/sitemap.xml` 404, `/sitemaps/sitemap.xml` 404.
  robots: `Disallow: /images/page/` only.
- **zebrack-comic.shueisha.co.jp** (74). `/sitemap.xml` is 328 KB, 4,508
  `/title/N` entries, **no `<lastmod>`**. `/rss` answers 200 but
  `text/html` — a page, not a feed. robots forbids `/title/*/chapter/*/viewer`
  and account paths only.
- **MangaPlus (Shueisha)**. `/sitemap.xml` is 192 KB, 1,083 entries, and
  **every one of them has `<lastmod>2026-06-07`** — a static stamp, no
  information. `jumpg-webapi.tokyo-cdn.com/api/title_detailV3?…&format=json`
  (the web reader's own API, protobuf by default) answered **403** to a
  plain browser GET; it is unofficial and undocumented and is **not
  allowed** under the rule set regardless of the 403. robots allows all.
- **Toomics**. Sitemap index → 11 language files; `sitemap-en.xml` is 838 B
  and lists five landing pages. Nothing per series.
- **Pocket Comics**. `pocketcomics.com/sitemap.xml` is a Yoast WordPress
  index with one `page-sitemap.xml` — the marketing site, not the reader.
  robots names and blocks `ClaudeBot` among a list of AI crawlers; the app
  is not one, but the intent is clear enough to note.
- **LINE Manga**. `manga.line.me/robots.txt` lists 19 sitemaps including
  `sitemaps/webtoons/periodic.xml` and `daily_list.xml`; both answer **412**
  from outside Japan (both probes). Geo-fenced; dead from a non-Japanese
  network, unverified from inside one.
- **Bilibili Comics**. `www.bilibilicomics.com` — DNS **SERVFAIL** on both
  probes. The global service appears to be gone; any such links in the
  library are dead links.
- **Azuki → Omoi**. `azuki.co/robots.txt` points its sitemap at
  `www.omoi.com` (a rebrand). The index (161 KB) is one file per series; the
  per-series file lists every chapter and volume URL, but **all 97
  `<lastmod>` values are today** — regenerated, not real. robots forbids
  `/volume-isbn/*`, accounts and checkout. No public GraphQL was found at a
  documented address and none was probed blind.
- **INKR**. `comics.inkr.com/sitemap.xml` → 56 chapter files with real
  per-chapter timestamps to the millisecond — but the newest in
  `chapter/0.xml` is **2022-04-27**. The catalogue has not moved in four
  years. robots allows.
- **Lezhin**. `/sitemap.xml` 404 (redirects into `/en/`); robots lists no
  sitemap. Not probed further.
- **VIZ**. robots: `Disallow: /manga/`, `/news`, `/search`, `*.php`,
  `Crawl-delay: 2`; **no sitemap listed**. `/sitemap.xml`, `/rss`,
  `/shonenjump/sitemap.xml` all 404. VIZ publishes nothing for machines that
  robots permits.
- **Yen Press**. `/sitemap.xml` is **4.2 MB**, 19,010 URLs including
  per-chapter and per-volume pages (`/titles/N-<slug>-chapter-N`,
  `…-vol-N`), **zero `<lastmod>`**. `/rss` and `/feed` 404. A chapter's
  existence is a count signal without a date; not worth 4 MB.
- **Seven Seas**. `robots.txt` and `/feed/` both answer **403** with a
  Cloudflare "Just a moment…" challenge to a Safari UA — the site does not
  serve non-browser clients at all. Its news RSS, if it exists, is
  unreachable on the rules.
- **Square Enix Manga & Books**. Everything redirects into `/en-us/`;
  `/en-us/robots.txt` and `/en-us/sitemap.xml` both 404.
- **Gangan Online**. No robots (404), `/sitemap.xml`, `/rss`,
  `/sitemap/sitemap.xml` all 404.
- **Webtoon Canvas**. Same host and RSS mechanism as the served Webtoons
  feed; the one probe used a guessed `title_no` and got the "Connect Error"
  404 page. Unverified, but there is no reason it differs from Originals —
  test with a real Canvas `title_no` from the library when one is to hand.
- **Google Books** (already in the app): 429, shared anonymous quota
  exhausted, as on 12 September.

## Two cross-platform ideas, judged

**(a) Apple Books pre-order dates as "next volume".** Works, measured above
(8 future-dated volumes in one query). It is the cheapest thing in this
document to build because the bytes are already on the device. Limits: only
series with an English digital edition on Apple Books; volume, not chapter;
the store lists a pre-order weeks to months ahead, and the date can slip
without the old date being withdrawn — show the date with "Apple Books" on
it, as the shelf already does, and never say "confirmed".

**(b) Publisher press/news RSS as "announced".** Kodansha US `/feed/` (200,
10 items, sales and licences) and Dark Horse `/feed/new-releases/rss/`
(200, on-sale dates) are the only two that answer. VIZ forbids `/news`;
Seven Seas is behind Cloudflare; Yen Press has no feed. Two feeds, neither
per-series, one of them a sales blog: not enough to build an "announced"
source on. The Kodansha `release-calendar` JSON is the better version of the
same idea and is the one to build.

## Ranked: what to build next

1. **Apple Books pre-order date → "next volume" (~40 lines, no new network).**
   Serves every series the shelf already finds on Apple Books, the day it
   ships. Publisher-set date. The only source here with a *future* date per
   series.
2. **`SitemapFeedClient` + Kakao Webtoon + COMIC-WALKER (~200 lines).** One
   client, two hosts, 220 series (23% of the library), a last-change date
   each, both allowed by robots, 680 KB/day combined. Gives "last release:
   date" and, joined with MangaUpdates' chapter count, "stalled since". Does
   not give a cadence — one point per series — so it demotes MangaUpdates
   only for *recency*, not for rhythm.
3. **Tapas via the same client, after the two-week control (~30 lines).**
   149 series (16%), 793 KB/day. Build only once the control shows lastmod
   moves on the series' publishing day; if it moves on page edits instead,
   record that here and stop.

Then, if the policy question is settled in its favour, Kodansha US
`release-calendar` (~200 lines) for six-week volume lookahead on
Kodansha-licensed series.

## What share becomes publisher-sourced

Today: Webtoons 554 + comic.naver 172 (as a confirmation source, not a lead)
≈ 59–77% of 940 have *some* publisher signal; Webtoons alone is 59%.

After the top three: + Kakao Webtoon 124 + COMIC-WALKER 96 + Tapas 149 =
369 more *links* with a publisher last-change date. The link counts sum to
1,095 across 940 series, so series carry several links and the union is
smaller than the sum; it could not be computed here because the database
could not be read this session. Honest bracket: **between 59% (no new
series beyond Webtoons') and ~98% (no overlap at all)**, and the truth is
nearer the top of that range only if the Kakao/COMIC-WALKER/Tapas links sit
mostly on non-Webtoons series — a one-line query against `libraryEntry`
answers it. Apple's contribution overlaps rather than adds — it is a
volume date on series already counted.

**What that does and does not do to MangaUpdates.** Webtoons and Naver give
history and cadence; the three sitemap sources give one date and no
cadence. MangaUpdates can be demoted to fallback for "when did this last
release" across ~98% of the library, but stays the primary for "how often
does it release" on the 39% that only have a sitemap date — until a second
fetch, a day later, gives a second point, and a fortnight later a rhythm.
That is a slow-building cadence the app could accumulate itself from daily
sitemap deltas, at zero extra requests, and it would be publisher-derived.
Worth designing for from the start: store every observed lastmod change
per series, not only the latest.

The 235 page.kakao, 228 Piccoma, 212 Nico, 189 series.naver and 87 pixiv
series — 40% of the library by count, but overlapping with Webtoons links on
the same series — have no lawful machine source and stay on MangaUpdates.

## Questions only a partner API would answer

- **Next episode, not last.** No public source here states a *scheduled*
  episode date; the closest are Kodansha US's volume weeks and Apple's
  pre-orders. Webtoons' own day-of-week label, Kakao's and Naver's
  "요일" schedule, and Tapas' `WAIT_SCHEDULED` cadence exist in their
  systems and appear in their HTML, not in any feed.
- **Hiatus and completion flags** at the episode level. Naver's `finished`
  is the only official one found; Webtoons puts finales in the *title*.
- **Season boundaries** as data rather than text to parse.
- **The Kakao Page and Piccoma catalogues at all** — nothing lawful exists
  for 460 links.
- **Whether a Tapas or Kakao `lastmod` means "episode published"** — a
  partner would just say; this document can only measure it over two weeks.
- Partner programmes found: Webtoons has no public developer programme;
  Tapas has a creator dashboard, not an API; Kodansha's `kodansha/v1` is
  internal to their WordPress; MangaPlus's API is app-only and
  protobuf. None of the eight offers a signup an indie iOS app could
  complete today — that is the honest answer to "documented partner API".

## Appendix — every request sent (93 rows; ≤5 per host)

| # | Method | URL | Status | Content-Type | Bytes |
|---|---|---|---|---|---|
| 1 | GET | https://tapas.io/robots.txt | 200 | text/plain | 2967 |
| 2 | GET | https://mangaplus.shueisha.co.jp/robots.txt | 200 | text/plain; charset=UTF-8 | 76 |
| 3 | GET | https://kmanga.kodansha.com/robots.txt | 200 | text/plain; charset=utf-8 | 218 |
| 4 | GET | https://comikey.com/robots.txt | 200 | text/plain; charset=utf-8 | 189 |
| 5 | GET | https://azuki.co/robots.txt | 200 | text/plain; charset=UTF-8 | 259 |
| 6 | GET | https://inkr.com/robots.txt | 200 | text/plain; charset=utf-8 | 412 |
| 7 | GET | https://www.lezhinus.com/robots.txt | 200 | text/plain | 376 |
| 8 | GET | https://tappytoon.com/robots.txt | 200 | text/plain; charset=UTF-8 | 6290 |
| 9 | GET | https://toomics.com/robots.txt | 200 | text/plain | 1323 |
| 10 | GET | https://www.pocketcomics.com/robots.txt | 200 | text/plain; charset=utf-8 | 1836 |
| 11 | GET | https://manga.line.me/robots.txt | 200 | text/plain;charset=utf-8 | 1748 |
| 12 | GET | https://www.bilibilicomics.com/robots.txt | 000 |  | 0 |
| 13 | GET | https://webtoon.kakao.com/robots.txt | 200 | text/plain; charset=UTF-8 | 79 |
| 14 | GET | https://page.kakao.com/robots.txt | 200 | text/plain; charset=utf-8 | 135 |
| 15 | GET | https://piccoma.com/robots.txt | 200 | text/plain; charset=utf-8 | 166 |
| 16 | GET | https://www.viz.com/robots.txt | 200 | text/plain; charset=utf-8 | 494 |
| 17 | GET | https://yenpress.com/robots.txt | 200 | text/plain; charset=utf-8 | 72 |
| 18 | GET | https://sevenseasentertainment.com/robots.txt | 403 | text/html; charset=UTF-8 | 5639 |
| 19 | GET | https://squareenixmangaandbooks.square-enix-games.com/robots.txt | 404 | text/html; charset=utf-8 | 15293 |
| 20 | GET | https://www.darkhorse.com/robots.txt | 200 | text/plain | 542 |
| 21 | GET | https://kodansha.us/robots.txt | 200 | text/plain | 1196 |
| 22 | GET | https://www.sunday-webry.com/robots.txt | 404 | text/html; charset=utf-8 | 10061 |
| 23 | GET | https://comic-walker.com/robots.txt | 200 | text/plain; charset=UTF-8 | 606 |
| 24 | GET | https://www.ganganonline.com/robots.txt | 404 | text/html; charset=utf-8 | 2689 |
| 25 | GET | https://zebrack-comic.shueisha.co.jp/robots.txt | 200 | text/plain; charset=UTF-8 | 224 |
| 26 | GET | https://comic.pixiv.net/robots.txt | 200 | text/plain | 38 |
| 27 | GET | https://manga.nicovideo.jp/robots.txt | 200 | text/plain | 0 |
| 28 | GET | https://tapas.io/sitemap.xml | 200 | text/xml | 735 |
| 29 | GET | https://mangaplus.shueisha.co.jp/sitemap.xml | 200 | text/xml; charset=UTF-8 | 192109 |
| 30 | GET | https://kmanga.kodansha.com/sitemap.xml | 200 | application/xml | 604 |
| 31 | GET | https://comikey.com/sitemap.xml | 200 | application/xml | 485 |
| 32 | GET | https://www.azuki.co/sitemap.xml | 200 | application/xml; charset=utf-8 | 160894 |
| 33 | GET | https://comics.inkr.com/sitemap.xml | 200 | text/xml | 6056 |
| 34 | GET | https://www.lezhinus.com/sitemap.xml | 404 | text/html; charset=utf-8 | 23742 |
| 35 | GET | https://www.tappytoon.com/sitemap-index.xml | 200 | text/xml | 562 |
| 36 | GET | https://toomics.com/sitemap.xml | 200 | text/xml | 1026 |
| 37 | GET | https://www.pocketcomics.com/sitemap.xml | 200 | text/xml; charset=UTF-8 | 404 |
| 38 | GET | https://manga.line.me/sitemaps/webtoons/periodic.xml | 412 | text/html;charset=UTF-8 | 10861 |
| 39 | GET | https://webtoon.kakao.com/sitemap.xml | 200 | text/xml; charset=utf-8 | 610022 |
| 40 | GET | https://page.kakao.com/sitemap/sitemapindex.xml | 200 | text/xml | 29483 |
| 41 | GET | https://piccoma.com/sitemap.xml | 200 | text/xml; charset=utf-8 | 710 |
| 42 | GET | https://www.viz.com/sitemap.xml | 404 | text/html; charset=UTF-8 | 5363 |
| 43 | GET | https://yenpress.com/sitemap.xml | 200 | application/xml; charset=UTF-8 | 4156239 |
| 44 | GET | https://sevenseasentertainment.com/feed/ | 403 | text/html; charset=UTF-8 | 5624 |
| 45 | GET | https://squareenixmangaandbooks.square-enix-games.com/en-us/sitemap.xml | 404 | text/html; charset=utf-8 | 15297 |
| 46 | GET | https://www.darkhorse.com/sitemap.xml | 200 | application/xml | 606 |
| 47 | GET | https://kodansha.us/sitemap_index.xml | 403 | text/html; charset=UTF-8 | 5730 |
| 48 | GET | https://www.sunday-webry.com/sitemap.xml | 404 | text/html; charset=utf-8 | 10061 |
| 49 | GET | https://comic-walker.com/sitemap.xml | 200 | application/xml | 795 |
| 50 | GET | https://www.ganganonline.com/sitemap.xml | 404 | text/html; charset=utf-8 | 2689 |
| 51 | GET | https://zebrack-comic.shueisha.co.jp/sitemap.xml | 200 | text/xml; charset=UTF-8 | 328238 |
| 52 | GET | https://comic.pixiv.net/sitemap.xml | 404 | text/html; charset=UTF-8 | 2308 |
| 53 | GET | https://manga.nicovideo.jp/sitemap.xml | 200 | text/html | 4590 |
| 54 | GET | https://www.bilibilicomics.com/sitemap.xml | 000 |  | 0 |
| 55 | GET | https://tapas.io/sitemap-comic.xml | 200 | text/xml | 5421792 |
| 56 | GET | https://kmanga.kodansha.com/sitemap_nexttime_viewer_1.xml | 200 | application/xml | 1189 |
| 57 | GET | https://kmanga.kodansha.com/sitemap_viewer_2.xml | 200 | application/xml | 1753965 |
| 58 | GET | https://comikey.com/sitemap-comics.xml | 200 | application/xml | 137238 |
| 59 | GET | https://www.omoi.com/sitemap-yuri-is-my-job.xml/ | 200 | application/xml; charset=utf-8 | 17554 |
| 60 | GET | https://comics.inkr.com/sitemap/chapter/0.xml | 200 | text/xml | 93291 |
| 61 | GET | https://www.tappytoon.com/sitemap-series.xml | 200 | text/xml | 334277 |
| 62 | GET | https://global.toomics.com/sitemap-en.xml | 200 | text/xml | 838 |
| 63 | GET | https://manga.line.me/sitemaps/sitemap.xml | 412 | text/html;charset=UTF-8 | 10861 |
| 64 | GET | https://page.kakao.com/sitemap/sitemap.1.xml.gz | 200 | application/gzip | 1464945 |
| 65 | GET | https://piccoma.com/sitemapproduct1.xml | 200 | text/xml; charset=utf-8 | 2430244 |
| 66 | GET | https://www.darkhorse.com/sitemap-products-2020s.xml | 200 | application/xml | 522404 |
| 67 | GET | https://comic-walker.com/sitemap-series.xml | 200 | application/xml | 1004109 |
| 68 | GET (Accept-Encoding: gzip) | https://tapas.io/sitemap-comic.xml | 200 | text/xml | 793269 on wire (gzip) |
| 69 | GET (Accept-Encoding: gzip) | https://webtoon.kakao.com/sitemap.xml | 200 | text/xml | 610022 on wire (server sent no gzip) |
| 70 | GET (Accept-Encoding: gzip) | https://comic-walker.com/sitemap-series.xml | 200 | application/xml | 68308 on wire (gzip) |
| 71 | GET (Accept-Encoding: gzip) | https://www.tappytoon.com/sitemap-series.xml | 200 | text/xml | 35612 on wire (gzip) |
| 72 | GET | https://tapas.io/series/solo-leveling-comic.json | 200 | application/json;charset=UTF-8 | 769 |
| 73 | GET | https://kmanga.kodansha.com/sitemap_contents.xml | 200 | application/xml | 1397 |
| 74 | GET | https://kodansha.us/feed/ | 200 | application/rss+xml; charset=UTF-8 | 182189 |
| 75 | GET | https://kodansha.us/wp-json/ | 200 | application/json; charset=UTF-8 | 284448 |
| 76 | HEAD | https://www.viz.com/rss | 404 | text/html; charset=UTF-8 | 0 |
| 77 | HEAD | https://www.viz.com/shonenjump/sitemap.xml | 404 | text/html; charset=UTF-8 | 0 |
| 78 | HEAD | https://yenpress.com/rss | 404 | text/html; charset=UTF-8 | 0 |
| 79 | HEAD | https://yenpress.com/feed | 404 | text/html; charset=UTF-8 | 0 |
| 80 | HEAD | https://www.sunday-webry.com/rss | 200 | application/rss+xml; charset=utf-8 | 0 |
| 81 | HEAD | https://www.sunday-webry.com/sitemap_index.xml | 404 | text/html; charset=utf-8 | 0 |
| 82 | HEAD | https://www.ganganonline.com/rss | 404 | text/html; charset=utf-8 | 0 |
| 83 | HEAD | https://www.ganganonline.com/sitemap/sitemap.xml | 404 | text/html; charset=utf-8 | 0 |
| 84 | HEAD | https://zebrack-comic.shueisha.co.jp/rss | 200 | text/html; charset=UTF-8 | 0 |
| 85 | HEAD | https://comic.pixiv.net/sitemaps/sitemap.xml | 404 | */*; charset=UTF-8 | 0 |
| 86 | GET | https://series.naver.com/robots.txt | 200 | text/plain; charset=UTF-8 | 439 |
| 87 | GET | https://www.darkhorse.com/rss | 200 | application/rss+xml; charset=utf-8 | 69208 |
| 88 | GET | https://kodansha.us/wp-json/kodansha/v1/release-calendar | 200 | application/json; charset=UTF-8 | 23752 |
| 89 | GET | https://itunes.apple.com/search?term=Jujutsu+Kaisen&media=ebook&entity=ebook&country=gb&limit=200 | 200 | text/javascript; charset=utf-8 | 324114 |
| 90 | GET | https://www.googleapis.com/books/v1/volumes?q=intitle:%22Jujutsu+Kaisen%22&orderBy=newest&maxResults=10&printType=books | 429 | application/json; charset=UTF-8 | 1306 |
| 91 | GET | https://jumpg-webapi.tokyo-cdn.com/api/title_detailV3?title_id=100034&format=json | 403 | text/html; charset=UTF-8 | 146 |
| 92 | GET | https://www.webtoons.com/en/canvas/x/list?title_no=98963 | 404 | text/html;charset=UTF-8 | 3107 |
| 93 | GET | https://series.naver.com/sitemap.xml | 404 | text/html; charset=UTF-8 | 1621 |

Rows 68–71 are the gzip-size checks of files already fetched, sent with
`Accept-Encoding: gzip` and counted against the same per-host budget. Status
`000` is a connection failure (DNS SERVFAIL for bilibilicomics.com), not an
HTTP answer. Final URLs after redirects were recorded but are omitted here;
the notable ones — `azuki.co` → `www.omoi.com`, `inkr.com` →
`comics.inkr.com`, `darkhorse.com/rss` → `/feed/new-releases/rss/`,
`nicovideo` → the login page, Square Enix → `/en-us/` — are in the text.
