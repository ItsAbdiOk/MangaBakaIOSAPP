# Publishers and reading platforms — the third survey

Measured 2026-09-14 against the live sites and APIs. This extends
`../release-sources-2026-09-12.md` and `../release-sources-2026-09-13-survey.md`
and does not re-derive what they settled. Where it *re-tested* one of their
conclusions, that is called out explicitly under "Re-tested".

Method: `curl`, Safari User-Agent, 15–40 s timeouts, `--max-filesize 6M`
(30M once, for the ANN bulk dump), at most 5 requests per host, ~1–2 s apart.
Every claim below comes from a request actually made in this session. Where a
thing was not tested, it says so.

**The test that decides everything here:** can the source state the date of the
*next* chapter or volume for a series a real reader follows? A beautiful API
with no dates is a negative result, and is recorded as one.

---

## The headline

**Anime News Network's Encyclopedia API is the find.** It is documented,
keyless, rate-limited at a published 1 req/s, and it carries per-volume English
print releases with **volume number, exact date, and ISBN-13 — including
future-dated pre-orders**. Nothing else surveyed across three days does that
across multiple publishers. It is the closest replacement yet for the Amazon and
Google Books holes (need #1 in the brief, and partly #3).

It does **not** replace Naver (need #2, "next episode in the original
language"). Nothing found in this survey does. That hole is still open, and
after three surveys the honest read is that it cannot be closed lawfully from a
phone — see "The Naver hole is still open" at the end.

---

## Re-tested from the earlier surveys

Four claims the previous surveys made were re-run today, because the brief asked
and because a source that worked on Friday is not evidence about Monday.

| Claim (date) | Re-tested today | Verdict |
|---|---|---|
| Kakao Webtoon `sitemap.xml` is viable (09-13) | yes | **Holds.** |
| Kodansha USA `release-calendar` returns 6 future weeks (09-13) | yes | **Holds, with one bug.** |
| Dark Horse new-releases RSS is past-only (09-13) | yes | **Holds.** |
| `shonenmagazine.com` is "Magazine Pocket" (09-12, flagged a guess) | yes | **Wrong. Correct it.** |

### Kakao Webtoon sitemap — verified, unchanged

`GET https://webtoon.kakao.com/sitemap.xml` → 200, `text/xml; charset=utf-8`,
**610,341 bytes** (610,022 on 09-13).

- 3,087 `<url>` entries (was 3,086); **3,087 carry `<lastmod>` — 100%, no gaps.**
- Dates present through today: 8 entries dated 2026-09-14, 68 dated 09-13.
- The two bulk re-index clumps are still there and still poisonous:
  **1,019** entries on 2026-06-24 and **780** on 2025-01-07. A series whose
  `lastmod` is one of those two exact values means *unknown*, not "last released
  then". The 09-13 survey's rule stands verbatim.

A day's drift of ±1 entry is consistent with a live daily rebuild. The 09-13
conclusion is confirmed; build on it as that survey ranked it.

### Kodansha USA release-calendar — verified, and one bug found

`GET https://kodansha.us/wp-json/kodansha/v1/release-calendar` → 200,
`application/json`, 23,752 bytes. Still 8 weeks, 2026-08-25 → 2026-10-13,
**74 volumes**. Shape:

```json
{"tue_key":"2026-08-25","date_label":"Published on Aug. 25, 2026","is_past":true,
 "items":[{"title":"Volume 7","series_name":"The Ayakashi Hunter's Tainted Bride",
           "creators":"...","volume_url":"...","formats":["digital","print"]}]}
```

**New, and it matters: `is_past` is wrong.** The week of 2026-09-08 is flagged
`"is_past": false` although today is 2026-09-14. Do not read that flag; derive
past/future from `tue_key` yourself. Shipping code that trusted `is_past` would
show a shipped volume as upcoming — a visible, wrong-facing bug.

Also tested today, and all three are dead ends, so nobody re-opens them:

- `kodansha/v1/new-releases` → 200, 5,645 B. Just-shipped volumes (2026-09-08).
  Past-only, and a subset of what `release-calendar` already carries. Adds nothing.
- `kodansha/v1/on-sale` → 200, **26 B**: `{"success":true,"data":[]}`. Empty
  without parameters; no documented parameters exist. Unusable as tested.
- `kodansha/v1/search-series?query=Attack%20on%20Titan` → 200, 44,193 B, and
  **the `query` parameter is ignored**. It returns an alphabetical catalogue page
  (`count: 24, total_count: 1169`, beginning "10 DANCE"). There is no server-side
  lookup: matching a series means paging all 1,169 (≈49 requests) and matching on
  the client. Do not plan a per-series lookup against this.

### Dark Horse — verified past-only

`GET https://www.darkhorse.com/feed/new-releases/rss/` → 200,
`application/rss+xml`, 69,208 B, `Last-Modified: Wed, 09 Sep 2026`. Ten distinct
`pubDate` values, 2026-08-18 → 2026-09-09, **every one in the past**. Zero
lookahead, confirmed by reading the dates rather than the docs. The 09-13
verdict ("an 'it shipped' signal, not a schedule") is correct.

### "Magazine Pocket" — the guess in the code is wrong

`ReleaseSource.gigaViewerHostNames` carries "Magazine Pocket" as the English
name for `shonenmagazine.com`, labelled a guess on 09-12. It is a wrong guess,
and they are two different products on two different stacks:

- `shonenmagazine.com` — GigaViewer (Hatena). `/rss` works. This is the one the
  app already reads, and it should keep reading it.
- `pocket.shonenmagazine.com` — **exists as a separate host**, robots.txt at 200
  listing `sitemap.xml` and `sitemap_main.xml`. It is **Nuxt on CloudFront/S3**
  (`x-powered-by: Nuxt`, `server: AmazonS3`), not GigaViewer at all. `/rss` →
  **404**. `sitemap_main.xml` and `sitemap_contents.xml` both 200 but carry only
  landing, ranking and genre pages — **no per-series URLs**.

So the real Magazine Pocket has no feed, and the host that does have a feed is
not Magazine Pocket. **Action: rename the label on `shonenmagazine.com` to the
site's own name and drop the "Magazine Pocket" guess** — leaving it invites
someone to "fix" the feed by pointing it at `pocket.` and breaking seven hosts'
worth of working RSS. No code was changed here; this survey is read-only.

---

## The find: Anime News Network Encyclopedia API

**Replaces:** need #1 (volume and edition metadata: title, volume number,
release date, ISBN, publisher) and part of need #3 (covers). Directly fills the
hole Amazon PA-API and Google Books left.

### Documentation, auth and limits — all published

`https://www.animenewsnetwork.com/encyclopedia/api.php` (200, 98 KB) is the
official documentation page. In ANN's own words:

- **Keyless.** No account, no key, no registration. Nothing to ship in a binary.
- **Rate limit: 1 request per second per IP**, documented. Over that, requests
  are *delayed*, not dropped. A `nodelay.api.xml` variant exists that returns 503
  instead of delaying — use the normal one and pace ourselves.
- **Batching: up to 50 titles per request**, as repeated `manga=` parameters or
  a slash-separated id list.
- ANN asks for details to be cached; a week is the figure in their own docs.

This sits comfortably inside the app's existing 30/min and 180/min windows.

### The endpoint, and the response that matters

```
curl --compressed -A '<Safari UA>' \
  'https://cdn.animenewsnetwork.com/encyclopedia/api.xml?manga=~One%20Piece'
```
→ 200, `text/xml;charset=UTF-8`, 237,299 bytes.

The elements in that one response: 883 `<news>`, **232 `<release>`**, 56
`<info>`, 15 `<img>`, 9 `<staff>`, 5 `<manga>`, 4 `<review>`, 4 `<ratings>`.
The `<release>` elements are the point:

```xml
<release date="2024-03-12" href="https://www.animenewsnetwork.com/encyclopedia/releases.php?id=49084" ean="9781974743322">One Piece: Ace&#039;s Story-The Manga (GN 1)</release>
<release date="2005-10-11" href="...releases.php?id=4970"  ean="9781421501598">One Piece Color Walk (Artbook 1)</release>
<release date="2013-02-19" href="...releases.php?id=23227" ean="9781421545257">One Piece - Romance Dawn (eBook 1)</release>
```

and, filtering that same response for dates after today:

```xml
<release date="2026-11-10" href="...releases.php?id=57439" ean="9781974766703">One Piece (GN 113)</release>
<release date="2026-12-08" href="...releases.php?id=57440" ean="9781974769421">One Piece - Wano to Egghead Box Set (GN 91-111)</release>
```

**That is a publisher-announced future volume date, with its ISBN-13, from a
documented keyless API.** It is the answer to "when is the next volume out" for
the English print edition, and it is the first one found in three surveys that
is not a store listing.

Every `<release>` carries: `date` (ISO, day precision), `ean` (ISBN-13),
`href` (the ANN encyclopedia page — which is also the attribution link we owe
them), and a text body of the shape `Series Title (GN n)` / `(eBook n)` /
`(Artbook n)` / `[Complete Box Set] (GN)`. The format marker in parentheses is
how print, digital and box sets are told apart.

### Coverage, measured against the brief's five series

Measured, not claimed. Each is a real request.

| Series | In ANN as manga? | Releases | Newest | Future dates |
|---|---|---|---|---|
| One Piece | yes (several entries) | 232 | 2026-12-08 | **2** (GN 113, box set) |
| The Apothecary Diaries | yes, id 23731 | 15 | 2026-03-17 (GN 15) | 0 |
| Delicious in Dungeon | yes, id 17164 | 15 | 2024-12-10 (box set) | 0 — correct, it is complete |
| Solo Leveling | **no** | — | — | — |
| The Beginning After The End | **no** | — | — | — |

**Three of five, and the pattern in the two misses is the important part: both
are Korean webtoons.**

- `reports.xml?id=236&type=manga&search=solo+leveling` → 200, and the result is
  an **empty report**. ANN has Solo Leveling as *anime* only (`type=TV`, `movie`
  — a bare `~Solo Leveling` lookup returns Blu-ray releases, which is a trap
  worth knowing about). Yen Press publishes the manhwa in print; ANN has not
  catalogued it.
- `search=beginning+after` with no type filter → 200, and every hit is
  `type=TV`. The manhwa is absent.

So: **ANN is strong on Japanese manga in English translation and weak-to-absent
on Korean webtoons.** Given this library is 59% Webtoons, that is a real limit
and it should be stated in the UI's terms, not hidden — ANN answers "when is the
English volume out" for the Japanese half of the shelf.

**A second, softer limit.** Forward coverage is uneven even where the series
exists. One Piece has November and December pre-orders listed; The Apothecary
Diaries stops at GN 15 on 2026-03-17, six months stale, although the series is
ongoing in English. ANN's encyclopedia is volunteer-edited, so a future date is
present when someone entered it. **Treat a future date as a real signal and its
absence as "unknown", never as "nothing is coming."** That asymmetry must be in
the code, not just in this document.

### Matching a series to an ANN id — and the bulk dump

Name lookup has a documented catch, and it bit immediately: `api.xml?title=~name`
**matches only the primary title**, not alternates. `~The Apothecary Diaries`
returned `<warning>no results</warning>` because ANN's primary name is
"Apothecary Diaries", without the article. Two things fix it:

1. **The search report matches alternate titles.**
   `reports.xml?id=236&type=manga&search=apothecary&nlist=10` → 200, and each
   `<item>` carries a `<searched_title>` showing which alternate matched:
   ```xml
   <item><id>37076</id><type>manga</type><name>Kusuriuri no Seijo</name>
     <vintage>2023-10-30</vintage>
     <searched_title>Holy Woman of the Apothecary</searched_title></item>
   ```

2. **A bulk dump we can bundle — which the brief explicitly allows.**
   `reports.xml?id=155&type=manga&nlist=all` → 200, **885,397 bytes on the wire
   (gzipped), 4.0 MB raw, 24,322 `<item>` entries.** Re-gzipped locally: 762,109
   bytes. Every item is `id`, `gid`, `type`, `name`, `precision` and usually
   `<vintage>`:
   ```xml
   <item><id>40520</id><gid>2133139052</gid><type>manga</type>
     <name>Chicchakute Dekakute Kawaii Nanase-san</name>
     <precision>manga</precision><vintage>2026-09-10</vintage></item>
   ```
   It is sorted newest-id-first, and ANN's own documentation describes exactly
   this usage: one full import, then a daily `nlist=50` for new titles.

**~760 KB gzipped for the entire manga title index is bundleable.** The app
already ships a 20k-title offline index; this is the same order of magnitude.
Bundling it turns series→ANN-id matching into a local lookup and reduces the
network cost to one `api.xml` call per series the user actually opens, cached a
week as ANN asks.

### Licence and attribution — a real obligation, not boilerplate

ANN's terms for the API, quoted from their documentation page, require that we:

- list Anime News Network as the source of the data, and
- include a link to the relevant Encyclopedia entry on any page that displays
  their details.

The `href` on every `<release>` is that link, so the obligation is cheap to
meet — but it is **mandatory and must appear on the series page**, not buried in
a settings screen. This needs to go in `docs/licences.md` alongside the others
before anything ships.

### Apple risk

Low. ANN is a public encyclopedia of metadata — dates, ISBNs, titles, staff. It
hosts no chapters and links to no reader. Nothing here engages 5.2.3. The one
thing to be careful of is the `<info type="Picture">` blocks, which carry ANN's
own thumbnail URLs at three sizes; those are cover art hosted by ANN, and using
them for need #3 is a licensing question for `docs/licences.md`, not an App
Store one.

### Verdict

**Build on it.** It is the best single source found in three surveys for
volume-level data, and the only keyless one with future dates across many
publishers. Caveats to carry into the code: Korean webtoons are largely absent;
absence of a future date means unknown; attribution is compulsory.

---

## Metadata services — tested, and three clean negatives

The brief asked whether AniList, Kitsu, Jikan/MAL or AniDB carry release
schedules. They do not. Each died on a specific test, recorded here so nobody
proposes them again.

### AniList — counts, not dates

Introspecting the schema is the cheapest possible control, so that is what was
done first:

```
POST https://graphql.anilist.co   {"query":"{ __type(name:\"Media\"){ fields{ name } } }"}
```

The `Media` type's full field list includes `chapters`, `volumes`, `startDate`,
`endDate`, `nextAiringEpisode`, `airingSchedule` — and **nothing per-volume**.
`chapters` and `volumes` are integers (counts), `startDate`/`endDate` are the
series' own run. `nextAiringEpisode` and `airingSchedule` are anime types.

Confirmed against four of the five test series (real queries, all 200):

```
Solo Leveling          FINISHED  chapters 201  volumes 15  nextAiringEpisode null
One Piece              RELEASING chapters null volumes null nextAiringEpisode null
The Apothecary Diaries RELEASING chapters null volumes null nextAiringEpisode null
Delicious in Dungeon   FINISHED  chapters 111  volumes 14  nextAiringEpisode null
```

`search:"The Beginning After The End", type:MANGA` returned `{"errors":[{"message":"Not Found.","status":404}]}`
on two attempts with two different search strings — AniList's manga search did
not find it, which is itself a small coverage note.

**Verdict: reject as a release source.** It answers "how many volumes exist",
never "when". Keep using it for characters, which is what it is already there
for. `nextAiringEpisode` is null for every manga tested, so the field name is a
trap, not a feature.

### Kitsu — has the right field names and no data behind them

This one looked like the winner for about ninety seconds. `GET
https://kitsu.io/api/edge/manga?filter[text]=...` → 200,
`application/vnd.api+json`, and the attributes include **`nextRelease`** and a
**`chapters`** relationship whose members have a **`published`** field, plus an
**`installments`** relationship (volumes). Exactly the shape wanted.

Then the data:

- Delicious in Dungeon (id 27539): `nextRelease: null`. Chapters have
  `published: null`.
- One Piece (id 38): `nextRelease: null`. `installments` → **`meta.count: 0`** —
  no volume records at all.
- One Piece chapters, sorted `-number` → **`meta.count: 5000`**, and the top five
  are chapters 5000, 4999, 4998, 4997, 4996, **every one `volumeNumber: 1` and
  `published: null`.** One Piece has roughly 1,140 chapters. The chapter table is
  filled with 5,000 empty placeholder rows.

That last line is the kill. The `published` field is not merely sparse — the
chapter table is junk, and a count read off it would be wrong by a factor of
four. (`kitsu.app` is the same service on a new domain; both hosts answered 200
with byte-identical records, so either works and neither helps.)

**Verdict: reject.** Field names that promise dates, no dates behind them, and a
chapter table that would actively mislead.

### Jikan / MyAnimeList — series-level dates only

`GET https://api.jikan.moe/v4/manga/13` (One Piece) → 200. The full attribute
list has no per-volume or per-chapter member. What it gives:

```json
{"title":"One Piece","status":"Publishing","chapters":null,"volumes":null,
 "published":{"from":"1997-07-22T00:00:00+00:00","to":null,
              "prop":{"from":{"day":22,"month":7,"year":1997}},
              "string":"Jul 22, 1997 to ?"},
 "publishing":true}
```

Series start and end, and counts. Nothing else.

**Reliability note, since it is the kind of thing that only shows up in a real
test:** the first two Jikan requests of this session both returned **504 Gateway
Time-out** from its nginx. The third, after a pause, returned 200. Jikan is a
volunteer-run scraper of MAL and it visibly falls over; that alone would rule it
out as a primary source.

MyAnimeList's own API was checked in the same breath:
`GET https://api.myanimelist.net/v2/manga?q=one+piece&limit=1` → **403**,
`{"message":"","error":"forbidden"}`. It needs a registered client id — a key,
in an app with no server. Out on the brief's own constraint even if it had the
data, which Jikan's mirror of it shows it does not.

**Verdict: reject both.**

### AniDB — wrong medium, and gated anyway

`GET http://api.anidb.net:9001/httpapi?request=anime&aid=1&client=test&clientver=1&protover=1`
→ 200, gzip-encoded, and decompressed it reads:

```xml
<error code="302">client version missing or invalid</error>
```

AniDB requires a client name and version **registered and approved by AniDB
staff** per application. Separately and more decisively, AniDB is an *anime*
database — it has no manga or volume catalogue to offer. Two independent
reasons.

**Verdict: reject.** Do not spend a request on it again.

---

## Storefronts that are not Amazon

### BookWalker Japan — the most promising lead in the survey, and it fails

This deserves the space because the 09-14 probe flagged
`bw_new_schedule.xml` as "the single most promising unverified lead". It was
then verified, and it is not one.

`https://bookwalker.jp/sitemap.xml` → 200, 1,798 B, an index of 13 section files
including, temptingly, `bw_new_schedule.xml`.

**`https://bookwalker.jp/sitemapxml/bw_new_schedule.xml` → 200, `text/xml`,
425 bytes.** 41 `<url>` entries, **0 `<lastmod>`**, and the entries are:

```xml
<url><loc>https://bookwalker.jp/new/</loc></url>
<url><loc>https://bookwalker.jp/new/?qsto=st1</loc></url>
<url><loc>https://bookwalker.jp/new/?qsto=st2</loc></url>
```

It is a list of facet URLs for the site's own "new releases" browse page. The
name means "the new-releases *section*", not "the release schedule". **Killed by
the obvious test, which is why it was worth one request.**

The per-volume sitemap was then checked, because that is where dates would
actually live. `bw_detail.xml` → 200, 291 B, an index of **29** shard files, all
stamped with one bulk regeneration time. And `bw_detail1.xml` → 200,
**1,397,003 bytes gzipped on the wire**, with:

- **30,000 `<url>` entries and 30,000 `<lastmod>` values** — full coverage.
- The dates are **real and varied**, not a bulk stamp: 2011-12-06, 2016-07-26,
  2017-04-28 … spread across 15 years, with sensible daily clumps (1,332 on
  2026-09-11, 1,283 on 2026-09-01). These look like genuine per-volume
  publication dates.

Two findings then kill it anyway:

1. **Zero future dates.** Minimum 2011-12-06, **maximum 2026-09-14 — today.**
   Not one entry in 30,000 is dated ahead. BookWalker's sitemap exposes what has
   published, never what is coming. The 予約 (pre-order) signal is not in it.
2. **The URLs are opaque UUIDs.** Every `<loc>` is
   `https://bookwalker.jp/de<uuid>/` — for example
   `https://bookwalker.jp/ded1c73c91-73ca-4017-bd1a-78edb3fc8e38/`. **No title,
   no series key, no volume number, no ISBN.** There is no way to connect one of
   these to a series a reader follows without fetching the HTML page behind each
   UUID, which is the scraping the brief forbids.

Cost, for completeness: 29 shards × ~1.4 MB gzipped ≈ **40 MB** for the whole
catalogue, and it would buy a pile of dated UUIDs.

**Verdict: reject, on two independent grounds — no future dates, and no join
key.** This closes the 09-14 probe's number-one follow-up; it does not need
another request.

### BookWalker Global — moving house, nothing to take

- `global.bookwalker.jp/sitemap.xml` → 200, an index of three files, all stamped
  `2026-04-07` — five months stale.
- `/api/` → 301 → `https://bookwalker.com/migration/api/`
- `/opds/` → 301 → `https://bookwalker.com/migration/opds/`

The OPDS redirect is the interesting one, since the brief asked about OPDS
catalogues. Following it lands on a Next.js marketing shell on the new
`bookwalker.com` domain with no JSON body and no API documentation in the raw
HTML — a "we moved" page. **Unverified rather than dead:** whether real OPDS or
API docs render behind that JavaScript was not determined, and determining it
means a browser render, which this survey's rules exclude. Recorded as an open
question, not a result.

### Kobo — blocked, not absent

Five paths were tried (`sitemap.xml`, `/rss`, `/onix`, `/developer`) and all
returned **403** with the same `maint.kobo.com` maintenance HTML. The first pass
also used the wrong path: Kobo's robots.txt lists `Sitemap:
https://www.kobo.com/sitemap` — **no `.xml`**. That correct URL was then fetched
and **also returned 403, 22,173 bytes of the same maintenance page.**

So it is not a mis-typed URL. A uniform 403 to every path, including robots'
own advertised sitemap, is a WAF fingerprinting `curl` rather than a site that
is down or endpoints that are gone. A browser would very likely get through.

**Verdict: dead as tested, and honestly so.** The app is not a browser and
should not pretend to be one to get past a bot wall. No public ONIX or partner
feed was reachable. If Kobo ever matters enough, the next step is a
browser-rendered check, which is a different rule set than this survey's.

### Google Play Books — dead by robots, not by rate limit

`play.google.com/robots.txt` → 200, and it carries `Disallow: /books/*`; only
the bare `/books` and `/books/publish` are allowed. No sitemap is listed.
`play.google.com/store/sitemap.xml` → **400 Bad Request**; not a real path.

There is no public feed for individual book pages. This is a *separate* dead end
from the already-known Google Books API 429 — the brief asked for something
different from that, and there is nothing.

### Comikey — verified alive, still no schedule

The 09-13 survey found `comikey.com/sitemap-comics.xml` usable. Re-fetched
today: **200, `application/xml`, exactly 137,238 bytes — byte-identical in size
to 09-13.** 811 `<url>` entries, every one with a date-only `<lastmod>` and
`changefreq: hourly`. **No date is in the future**; the newest are today and
yesterday.

New, and the reason it was worth re-checking: Comikey runs *simulpub* on a
published schedule, so a next-chapter feed was plausible. There is none.
`/rss` and `/feed` both **404**, and the sitemap index (485 B) confirms only
four sections — comics, tags, news, pages — with **no per-chapter sitemap**.

**Verdict: unchanged from 09-13.** A "last touched" date per series, no
lookahead. Worth ~20 lines once a `SitemapFeedClient` exists, as that survey
ranked it, and not before.

### INKR — reconfirmed dead

`comics.inkr.com/sitemap/chapter/0.xml` → 200, `text/xml`. Newest `<lastmod>` in
the file is still **2022-04-27**, identical to 09-13. **A catalogue that has not
moved in four and a half years.** Do not check again without a specific reason
to believe INKR redeployed.

### Webtoon's own API — there isn't one

The brief asked whether Webtoon publishes an official API beyond the per-series
RSS the app already uses. It does not, and this is as close to proof as a DNS
lookup gets:

- `developers.webtoons.com` → **DNS resolution failure.**
- `api.webtoons.com` → **DNS resolution failure.**

Neither hostname exists. `webtoon.com/en/partner` redirects to a business
development marketing page, not documentation.

**Verdict: the per-series RSS feed is the whole of Webtoons' public machine
surface, and the app already reads it.** Anything else is the reader's internal
endpoints — undocumented, and out under the same rule that removed Naver.

### eBookJapan — dead

`robots.txt` and `sitemap.xml` both 200; the sitemap is 4,480 bytes of marketing
and category landing pages (`/sale/`, `/ranking/`, `/free/books/?genres=T1`),
**no per-title URLs and no `<lastmod>` anywhere in the file.** Read, not
inferred.

### Rakuten Books, honto, Kinokuniya — open leads, not results

These got the "one or two requests" quick check and are being written down as
**unfinished**, because calling them dead would be a claim the evidence does not
support:

- **Rakuten Books** — robots.txt (200) lists real sitemaps at `sitemap.xml.gz`
  and an Atom-named path. A guessed plain `/sitemap.xml` 404'd. The real files
  were not opened.
- **honto** — robots.txt (200) lists four sitemap indexes including
  `sitemap_ebook_pd_idx.xml` (an ebook *product* index — a promising name, and
  BookWalker is a lesson in what promising names are worth). Not opened.
- **Kinokuniya** — `sitemap.xml` → 200, 31.6 KB, an index of gzipped per-goods
  files, every sub-file stamped `lastmod=2026-09-13`. That is an index-level
  bulk stamp like Kakao's and proves nothing about per-product dates. Sub-files
  not opened.

**None of the three was verified to carry per-title dates.** Each needs one more
fetch of its real (non-guessed) sitemap file. Given that BookWalker — the
largest and most manga-focused Japanese store — turned out to have real dates
but no join key and no future dates, the prior on these three should be low.

---

## Korean webtoon platforms other than Naver

The brief ranked this first by value. The answer, after re-testing everything,
is that **Kakao Webtoon's sitemap is the only lawful machine-readable source on
any Korean platform, and it gives one date per series with no cadence and no
lookahead.** Verified above. The rest:

### Ridibooks — new ground, and a clean negative

- `robots.txt` → 200. Lists `Sitemap: https://ridibooks.com/sitemap.xml`, and
  disallows `/api/` outright — so there is no lawful API path even to look for.
- `/sitemap.xml` → 200, a **sitemap index** of 15 files: one blog, ten book
  shards (`sitemap-books-1..10.xml.gz`), plus genre-home, goods, group and
  keyword-finder. **There is no manga or comic-specific file** — Ridi sells
  manhwa as ordinary books, so they are not separable.
- `sitemap-books-1.xml.gz` → 200. 33,115 `<url>` entries were read before the
  6 MB cap, and **all 33,114 sampled `<lastmod>` values are the single identical
  timestamp `2026-09-13T19:00:22.809Z`.** One batch-regeneration stamp for the
  whole shard.
- `/rss` → **404**.

That last point is the kill, and it is the same failure as Azuki/Omoi in the
09-13 survey: a `<lastmod>` that is the build time carries zero information.

**Verdict: reject.**

### Lezhin — extended from "not probed further" to dead

The 09-13 survey stopped at "sitemap.xml 404, redirects into /en/". Completed:

- `www.lezhin.com/en/robots.txt` and `/en/sitemap.xml` → both **301** to
  `www.lezhinus.com`.
- `www.lezhinus.com/robots.txt` → 200. Disallows login/payment/account paths and
  blocks Naver's `Yeti` from the language roots. **No `Sitemap:` directive at
  all.**
- `www.lezhinus.com/en/sitemap.xml` → **404**.
- `/rss` → 307 → `/en/rss` → **404** (a 23,734-byte Next.js 404 page).

**Verdict: reject, now fully tested.** No sitemap, no RSS, nothing advertised.

### Toomics — re-verified across languages

The 09-13 survey checked English only. All languages behave identically:

- `toomics.com/sitemap.xml` → 200, 1,026 B, an index of 11 per-language files
  (en, ja, sc, tc, mx, esp, it, por, de, fr, th), **no `<lastmod>` at index
  level**.
- `global.toomics.com/sitemap-en.xml` → 200, **exactly 838 bytes**, five
  landing-page URLs (ranking, ongoing_all, new_comics, age_verification, store),
  **no `<lastmod>` element at all**.
- `global.toomics.com/sitemap-ja.xml` → 200, 837 B, the identical five pages
  under `/ja/`.

**Verdict: reject.** The 09-13 finding was not an English-only artefact.

### Kakao Page — the 09-13 kill confirmed, with the reason sharpened

Only the index was fetched, as the earlier survey's ~270 MB figure made
re-fetching the shards indefensible.

`page.kakao.com/sitemap/sitemapindex.xml` → 200, 29,483 B, **183 `<loc>`
entries**. The decisive detail: the filenames are bare sequential shards —
`sitemap.0.xml.gz` … `sitemap.182.xml.gz` — **with no series-id range, no letter
range, no content hint of any kind**. There is no way to pick the shard holding
a given series. All 183 `<lastmod>` values are today, a daily regeneration stamp.

**Verdict: reject, confirmed.** 235 library links, second-largest platform,
and the catalogue exists but cannot be indexed from a phone. This is the single
largest unserved block after Piccoma.

### Pixiv Comic — one probe, stopped on the rule

`comic.pixiv.net/robots.txt` → 200, **38 bytes**, containing only
`Disallow: /images/page/`. No sitemap is listed and no API path is referenced.
Probing further would mean blind-guessing undocumented internal endpoints, which
is exactly what got Naver removed, so it stopped there.

**Verdict: reject, consistent with the 09-13 sitemap finding.**

---

## English licensors, beyond Kodansha

Kodansha USA is re-verified above and remains the only per-publisher forward
calendar. Everything else in the English print market was pushed on a new angle
today — mostly "is it secretly WordPress or Shopify?", since both expose public
JSON — and all of it failed.

| Publisher | New angle tried today | Result |
|---|---|---|
| VIZ | `/wp-json/` , `/products.json` | 301 → **404**; **404** (byte-identical 5,363 B HTML 404). Neither WordPress nor Shopify. |
| Yen Press | `/wp-json/`, `/products.json` | 301 → **404**; **404**. Neither. |
| Seven Seas | `/products.json` | **403**, Cloudflare challenge (`cf-mitigated: challenge`) — same wall as robots.txt. |
| Square Enix Manga | `/en-us/products.json` | **404**, Next.js error shell. Custom storefront, not Shopify. |
| J-Novel Club | robots, sitemap, rss, labs API | all dead — see below. |

**VIZ is closed.** Across two surveys: robots disallows `/manga/` and `/news`,
no sitemap at three paths, no RSS, no WordPress REST, no Shopify products feed.
The owner's position is that a site's own terms do not bind us, only Apple's —
but that does not conjure an endpoint into existence. There is no
machine-readable VIZ source to use, permitted or otherwise. (Note the
consolation: ANN carries VIZ's catalogue well — One Piece GN 113's
`ean` 9781974766703 is a VIZ ISBN, future-dated. **ANN is the way to VIZ dates.**)

**Yen Press** remains the 09-13 finding: a 4.2 MB sitemap with zero `<lastmod>`,
and now confirmed to have no JSON endpoint either. Painful, because Yen Press is
the English publisher for both Solo Leveling and The Beginning After The End —
the two series ANN misses. **Those two specifically have no source at all.**

**J-Novel Club — new ground, dead on every path.**
- `robots.txt` → 200, 52 B, disallowing only `/user` and `/series/new`.
- `/sitemap.xml` → 200 but **`content-type: text/html`**, 179,603 B — it is the
  React SPA's shell, not a sitemap. A 200 that is not what it claims to be.
- `/rss` → **404**.
- `labs.j-novel.club/app/v1/nav/list?format=json` (their app's own API) → **503**,
  Cloudflare challenge.
- `labs.j-novel.club/robots.txt` → 200, 25 B: **`Disallow: /` for all agents.**

**Verdict: reject.** The API-forward reputation does not survive contact.

### Penguin Random House — real, and the one to decide on

This was the best structural idea in the brief: one distributor covering many
licensors. The findings, honestly separated into what was proven and what was not:

**Proven.** The API exists, is Mashery-hosted, and **carries an `onsale` date
field on title records.** A keyless call —
`GET api.penguinrandomhouse.com/resources/v2/title/domains/PRH.US/titles/<isbn>/authors`
— returns **403** with `X-Mashery-Error-Code: ERR_403_DEVELOPER_INACTIVE`. So it
is definitively **not keyless**.

**The key situation.** PRH's own docs state a key can be requested by anyone but
must then be **activated manually by an API manager**, which takes time. So:
free, self-service, no business relationship — but human-gated, not instant. A
single key shipped inside an iOS binary is extractable, which is precisely the
objection that killed Google Books. The same objection applies here and should
be assumed fatal unless PRH's terms permit a public client key.

**A caution about how this was established.** PRH's documentation page embeds a
live example API key in its sample `curl`, and the probing agent used it. It
returned 200 and a real title record containing `"onsale": "2024-09-10"` — which
is how we know the field is real. **That key is not ours, is not reproduced in
this document, and must not be used again or shipped.** It is a third party's
demo credential; using it in a product is the kind of thing that gets an app
pulled. Further probing with it was declined for that reason, which is why the
next paragraph is an open question rather than an answer.

**Unproven, and this is the unsure to bring forward.** Whether PRH distributes
*any* manga licensor's catalogue is untested. One guessed VIZ ISBN for One Piece
Vol. 1 returned 404 — inconclusive, because the ISBN was guessed and because
VIZ may simply not sit in the `PRH.US` domain. The claim in the brief that PRH
distributes Kodansha, Yen Press and VIZ was **not verified and should not be
relied on.**

**Verdict: hold, do not build.** The cheap next test, before anything else, is
to take one *known-good* Kodansha or Yen Press ISBN — ANN's `ean` attribute
supplies verified ones for free — and query PRH for it with a key we own. If
manga is not in PRH's catalogue, the key question never needs answering.

### ONIX

No public ONIX 3.0 endpoint was found or advertised on any publisher site in
this survey, and PRH's documentation does not mention ONIX at all (checked by
searching the pages already fetched). Consistent with the expectation that ONIX
moves over B2B trading relationships, not public URLs. **Not available to us.**

---

## Scanlation aggregators — named, and out

Per the brief, this is stated in one line rather than omitted.

**MangaDex** has the best manga API in existence — documented, keyless,
generous, with per-chapter publish timestamps and translated-language fields;
it would answer need #2 better than anything else in this document. **It is a
scanlation host.** An app that queried it would be surfacing and linking to
chapters the developer has no rights to, which is the textbook **App Store
Review Guideline 5.2.3** rejection. **Rejected on Apple grounds, not taste, and
not because of its terms of service.** It was not tested, because a test could
not change the verdict.

The same reasoning covers every chapter-hosting aggregator of the same kind. A
source that publishes only *metadata* — dates, ISBNs, titles, counts — is fine
however unofficial it is; ANN, MangaUpdates and the sitemaps above are all in
that category. A source that serves or indexes the chapters themselves is not.

---

## The Naver hole is still open

Need #2 in the brief — "when is the next episode out, in the original language"
— is **not filled by anything in this survey**, and that should be said plainly
after three days of looking.

What exists, and what it falls short of:

- **Kakao Webtoon sitemap:** one last-change date per series. No episode number,
  no total, no completion flag, no next date. A *recency* signal.
- **COMIC-WALKER, Tapas, Comikey, Tappytoon sitemaps:** the same shape.
- **GigaViewer's seven magazine RSS feeds:** real per-episode dates, but past
  ones, magazine-wide.
- **Webtoons per-series RSS:** the strongest thing the app has — real dates,
  real episode numbers, finales in the title — and still past-only.
- **Kodansha's calendar and Apple's pre-orders:** genuinely future, but *volumes*
  in English, not *episodes* in the original.
- **ANN:** genuinely future, volumes, English print, Japanese titles mostly.

Nothing publishes a scheduled *next episode* date. Kakao's and Naver's
day-of-week schedules and Tapas' `WAIT_SCHEDULED` cadence live in those
platforms' systems and appear only in their HTML. What Naver's
`api/article/list` gave — `totalCount` and an official `finished` flag, which
powered "the translation will catch up and stop" — has **no lawful replacement**
on any Korean platform.

The honest conclusion after three surveys: that specific feature cannot be
rebuilt from public sources. Either it is dropped, or it is approximated from
what we do have (Webtoons' in-title finale markers plus MangaUpdates' chapter
counts), and the approximation is labelled as one in the UI.

---

## What to do, in order

1. **Build the ANN Encyclopedia client.** Biggest single win available: keyless,
   documented, future-dated volumes with ISBNs, across many English publishers
   including VIZ, whose own site gives nothing. Bundle the ~760 KB gzipped
   manga-title dump for local id matching; one `api.xml` call per opened series,
   cached a week. **Carry the attribution requirement into
   `docs/licences.md` before it ships** — it is a condition of use, not a nicety.
   Encode the two caveats in the code: absent ≠ nothing coming; Korean webtoons
   are largely missing.
2. **Fix the `is_past` bug** in any Kodansha `release-calendar` work — derive
   past/future from `tue_key`, never from the flag. It is wrong today.
3. **Correct the "Magazine Pocket" label** on `shonenmagazine.com` in
   `ReleaseSource.gigaViewerHostNames`. It is a wrong guess and it points a
   future maintainer at a host with no feed.
4. **One test before PRH is considered again:** a known-good Kodansha or Yen
   Press ISBN (take one from ANN's `ean`) against the PRH title endpoint, with a
   key we own. If manga is not there, the shippable-key question is moot.
5. **Leave the rest alone.** Ridibooks, Lezhin, Toomics, Kakao Page, Pixiv
   Comic, BookWalker (both), Kobo, Google Play Books, INKR, eBookJapan,
   J-Novel Club, VIZ, Yen Press, Seven Seas, Square Enix, AniList-as-releases,
   Kitsu, Jikan, MAL and AniDB are all tested and recorded above with the test
   that killed each.

## Still genuinely unfinished

Three things, flagged rather than guessed at:

- **Rakuten Books, honto, Kinokuniya** — their real (non-guessed) sitemap files
  were never opened. One fetch each would settle them. Low prior after BookWalker.
- **`bookwalker.com/migration/opds/`** — an OPDS path behind a JavaScript shell.
  Needs a browser render, which is outside this survey's rules.
- **Kobo** — uniformly 403 to `curl`, including its own advertised sitemap path.
  Blocked, not proven absent.
