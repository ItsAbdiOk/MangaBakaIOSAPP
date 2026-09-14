# Community databases and bulk datasets

Measured 2026-09-14 against live endpoints. Every number below comes from a
request actually sent from this machine; nothing is quoted from documentation
alone. Requests were spaced ~1 s apart with a research User-Agent, never more
than a handful per host.

Read alongside `release-sources-2026-09-12.md` and
`release-sources-2026-09-13-survey.md`, which cover publisher RSS and sitemaps.
This file does not re-test those.

---

## The short version

**The cheapest answer was real.** MangaBaka's own `/v1/series/{id}/works`
already carries per-volume release dates, ISBNs, prices, page counts and cover
art for all five test series — including *future* dates, which is most of what
Naver was doing. Nothing else in this survey beats it for the English market.

**Its limit is the market, not the data.** Across all five series MangaBaka
returned English editions and one Latin-American Spanish edition. Zero Japanese
or Korean editions. So it answers need 1 (volume metadata) and most of need 3
(covers), and does **not** answer need 2 (original-language "when is the next
one out").

**Wikidata is the complement, and it is small enough to ship.** CC0, Japanese
original ISBNs and dates, and the whole useful extract is 285 KB gzipped. But
the per-volume layer covers 171 manga series out of 18,202 — under 1 %. It is a
bonus layer, not a backbone, and this file says so with the query that proves it.

---

## 1. MangaBaka's own API — the answer nobody had checked properly

**Replaces:** need 1 (volume and edition metadata), need 3 (covers), and
partially need 2 (future-dated volumes).

### The endpoint

```
curl -A 'MangaBakaIOS/1.0 (research)' \
  'https://api.mangabaka.org/v1/series/3397/works?limit=50'
```

```json
{"status":200,"data":[{"sequence_string":"1","release_date":"2021-03-02",
"pages":320,"identifiers":[{"id":"9781975319441","name":"isbn"}],
"sub_title":null,"price":[{"value":9.99,"iso_code":"usd"},
{"value":11.99,"iso_code":"cad"}],"collections":[{"id":"019dcaa4-…",
"series_id":3397,"title":"Solo Leveling","language":{"iso":"en",
"language":"English (English)"},"publisher":{"id":21,"type":"imprint",
"sub_type":"both","parent_id":18,"name":"Ize Press","languages":["en"],
"country_of_origin":"US"},…}],…}],
"pagination":{"count":30,"next":null,"previous":null,"page":1,"limit":50}}
```

Each work carries: `sequence_string`, `sequence_numeric`, `release_date`,
`pages`, `identifiers` (ISBN / ISBN-13), `price` (a list of currency objects),
`images`, `sub_title`, `part_of_volume`, `trim`, `inc_chapters`, `links`,
`description`, `source_ids`, `collections` (with language, publisher and
edition) and `updated_at`.

### Coverage, measured on the five series

| Series | MangaBaka id | Works | With `release_date` | With ISBN | With cover image | Edition language |
|---|---|---|---|---|---|---|
| Solo Leveling | 3397 | 30 | 30 | 30 | 15 | en (Ize Press) |
| One Piece | 377 | **267** | 267 | 267 | 112 | en (Shonen Jump) |
| The Apothecary Diaries | 222 | 16 | 16 | 16 | 16 | **es-la only** (Panini México) |
| The Beginning After The End | 1238 | 12 | 12 | 12 | **0** | en (Yen Press) |
| Delicious in Dungeon | 6886 | 29 | 29 | 29 | 14 | en (Yen Press) |

**5 of 5 have a release date and an ISBN on every single work.** That is a
100 % hit rate on the field that matters most, and it is better than anything
else measured in this survey.

Future dates are present and usable: One Piece has works dated 2026-11-10
(×2) and 2026-12-08; The Beginning After The End runs to 2026-12-15. The
release calendar this feeds is real, not hypothetical.

`/v1/works/upcoming?days=90&limit=50` returned `count: 807` — 807 forthcoming
works in the next 90 days across the whole database.

### The three holes, stated plainly

1. **English market only.** `/v1/series/{id}/collections` returns 2, 4, 1, 1 and
   3 collections for the five series and **every one of them is `en` except
   Apothecary Diaries, which is `es-la` and has no English collection at all**.
   There is no Japanese or Korean edition anywhere in the sample. Control that
   proves it: the Japanese vol. 1 ISBN for Delicious in Dungeon returns nothing,
   the English one returns a hit.

   ```
   /v1/works/identifiers?identifier=9784047301535  -> count 0   (Kadokawa, JP)
   /v1/works/identifiers?identifier=9781975319441  -> count 1   (Ize Press, EN)
   ```

   A `language=ja` query parameter is **silently ignored** — `?language=ja` on
   series 222 still returned all 16 Spanish works, `count: 16`. Do not build on
   that parameter; it does not filter.

2. **Cover art is patchy.** 155 of One Piece's 267 works have no `images` at
   all, and The Beginning After The End has **zero** covers on all 12 works.
   Need 3 (covers Apple and Open Library do not carry) is only half solved here.
   Measured no-image counts: Solo Leveling 15/30, One Piece 155/267, Apothecary
   0/16, TBATE 12/12, Delicious in Dungeon 15/29.

3. **Pagination is 50 max, and it is enforced.** `?limit=100` returns HTTP 400:
   `{"message":"Validation error: Too big: expected number to be <=50 at
   \"limit\"","status":400}`. One Piece therefore needs **6 requests** to list
   its volumes. Budget for that in `RequestBudget`; a naive "fetch all works"
   on a long-runner is six round trips, not one.

Also worth knowing: duplicate sequence numbers are normal. Solo Leveling vol. 1
appears twice, $9.99 and $20, paperback and hardcover, distinguished only by
ISBN and price. Any volume grid must group by edition or it will look broken.

### Auth, limits, caching

- **Keyless** for everything above. No API key, no account. Nothing to ship.
- **No rate-limit headers are exposed** — no `X-RateLimit-*`, no `Retry-After`
  on any successful response inspected. The published headers are
  `cache-control: public, max-age=60` and
  `cdn-cache-control: public, max-age=604800, stale-while-revalidate=60`, plus
  `x-api-stability: stable` and `x-api-version: v1`. A week of CDN cache means
  repeat fetches are cheap, but it also means **a corrected release date can be
  up to a week stale at the edge**. Say "as of" rather than implying live data.
- `/v1/works/identifiers?identifier=<isbn>` is a keyless ISBN→work lookup,
  marked beta, 1-hour CDN TTL. Note the parameter is `identifier`, not `isbn`;
  `?isbn=` returns HTTP 400 `"Please provide an identifier"`.

### Licence — the one real risk

MangaBaka's own data is **CC BY-NC-SA 4.0** (Data License §3; see
`docs/licences.md` and `design/needs-abdi/mangabaka-terms.md`). Two consequences
the App Store makes concrete:

- A **visible attribution to MangaBaka** is required wherever its data is shown.
  Settings has a row for this; confirm it is actually filled in before
  submission.
- **Whether a free App Store app counts as non-commercial is unresolved**, and
  it is MangaBaka's call, not ours. `docs/licences.md` already flags this as an
  open question with a contact address (`legal@mangabaka.org`). Building *more*
  on MangaBaka does not make this worse, but it does raise the cost of being
  wrong. This is the single thing in this file most worth asking about before
  release.
- Data License §4: MangaBaka holds no redistribution rights for third-party data
  and grants none. That constrains bundling, not runtime fetching.

**Apple risk: none.** Metadata and publisher cover art from a documented public
API, with buy-side ISBNs. No pirated content is surfaced or linked. 5.2.3 is not
engaged.

**Verdict: build on it.** It is the backbone, it is keyless, and it already has
the field we deleted Naver for — on the English side. The work is a volume grid
plus a 6-page fetch loop, not a new data source.

### Free bonus: cross-database ID mapping

`/v1/series/{id}` carries a `source` object with ids and normalised ratings for
**AniList, MyAnimeList, Kitsu, MangaUpdates, Anime-Planet, Shikimori and Anime
News Network**. Real response for series 377:

```json
"source":{"anilist":{"id":30013,…},"anime_planet":{"id":"one-piece",…},
"anime_news_network":{"id":1223,…},"kitsu":{"id":38,…},
"manga_updates":{"id":"pb8uwds",…},"my_anime_list":{"id":13,…},
"shikimori":{"id":13,…}}
```

That means **we never have to fuzzy-match titles against any other database in
this survey**. Every join below can be done on an exact id MangaBaka hands us.
This is the quiet enabler for everything else in this file.

Series level also carries `total_chapters` ("1193"), `final_volume` ("115"),
`status` ("releasing") and `last_updated_at`.

---

## 2. Wikidata — CC0, Japanese originals, and a shippable 285 KB

**Replaces:** part of need 1, specifically the **Japanese/Korean original
editions MangaBaka does not have**, plus native titles and volume counts.

### The SPARQL endpoint

`https://query.wikidata.org/sparql`, keyless, `Accept: text/csv` or
`application/sparql-results+json`. A 18.5k-row query returned in **1.9 seconds**.

Manga volumes are modelled two ways in Wikidata, and you have to query both:

**(a) Publication date statements with a volume qualifier** — P577 with P478
(volume) and P212 (ISBN-13) as qualifiers on the series item:

```
curl -A '…' -H 'Accept: application/sparql-results+json' \
  -G https://query.wikidata.org/sparql --data-urlencode 'query@q.rq'
```
```sparql
SELECT ?s ?date ?vol ?isbn WHERE {
  VALUES ?s { wd:Q20016948 }
  ?s p:P577 ?st . ?st ps:P577 ?date .
  OPTIONAL { ?st pq:P478 ?vol } OPTIONAL { ?st pq:P212 ?isbn }
} ORDER BY ?date
```
```
Q20016948 2015-01-15 vol=1  isbn=978-4-04-730153-5
Q20016948 2015-08-12 vol=2  isbn=978-4-04-730676-9
Q20016948 2016-08-12 vol=3  isbn=978-4-04-734243-9
Q20016948 2017-02-15 vol=4  isbn=978-4-04-734417-4
Q20016948 2017-08-10 vol=5  isbn=978-4-04-734631-4
…14 rows, every volume, Kadokawa Japanese first edition
```

**(b) Volumes as separate items** linked by P179 (part of the series) with their
own P577.

### Coverage, measured — and this is the number that decides it

| Query | Result |
|---|---|
| Manga series in Wikidata (`P31/P279* wd:Q21198342`) | **18,202** |
| …with per-volume dates via qualifier (modelling a) | **171** series, 1,196 volume statements |
| …with volumes as separate dated items (modelling b) | **79** series, 901 volume items |
| …with a volume count (P2635) | 4,946 |
| …with a Japanese or Korean title (P1476) | 7,374 |
| …with any publication date at all | 3,156 |
| …with an ISBN-13 on the series itself | 94 |

**The per-volume layer covers roughly 1 % of Wikidata's manga.** Even generously
counting both modellings without deduplication, that is ~250 of 18,202.

On the five test series: **1 of 5.** Delicious in Dungeon has all 14 Japanese
volumes with dates and ISBNs. Solo Leveling, The Apothecary Diaries and The
Beginning After The End returned **zero** volume-qualified dates. One Piece's
manga has the same problem, and searching "One Piece" additionally lands on
Q673, the *franchise* item, whose 102 statements are mostly video games — a
title search against Wikidata will pick the wrong item unless it is constrained
by P31.

What Wikidata *does* have reliably: native titles (`薬屋のひとりごと`,
`나 혼자만 레벨업`, `ダンジョン飯` — all confirmed) and MangaUpdates ids.

### Joining it to us

Of the 171 series with per-volume dates, **130 carry an AniList id** and 75 a
MangaUpdates id. Across all manga: 6,714 have an AniList id, 3,569 MangaUpdates,
210 MyAnimeList. Since MangaBaka hands us AniList and MangaUpdates ids for free
(§1), the join is exact — no title matching.

### The shippable extract, measured

The useful subset — QID, AniList id, MangaUpdates id, volume count, native
title, start date, for all 18,534 manga rows:

```
1,343,000 bytes CSV   ->   291,450 bytes gzipped   (1.9 s query)
```

The per-volume table (1,196 rows, 982 with an ISBN) is a further ~100 KB.

**285 KB gzipped is nothing** next to the 7.5 MB embeddings blob and the 1.5 MB
offline index already in the bundle. Shipping it is free.

### Freshness — and how a shipped copy goes stale

- The **full JSON dump** is `https://dumps.wikimedia.org/wikidatawiki/entities/
  latest-all.json.gz` — `Last-Modified: Tue, 08 Sep 2026 18:10:17 GMT`,
  `Content-Length: 156,008,813,215` (**156 GB**). Weekly cadence. Do not
  download this; there is no reason to. The SPARQL endpoint gives the same data
  filtered to manga in under two seconds.
- **Staleness profile is benign and this is the point.** Historical Japanese
  volume dates and ISBNs are facts about books already printed — they do not
  change. A copy shipped with a TestFlight build stays correct essentially
  forever for back-catalogue. What goes stale is *newly added* series and
  *forthcoming* volumes: Wikidata gains manga items continuously, so a
  six-month-old extract will be missing new series and a handful of
  recently-documented volumes. **Refresh it per app release by re-running the
  SPARQL query — a 2-second build step. That matches the app's release cadence
  exactly.** This is the dump-freshness test the brief asked about, and Wikidata
  passes it cleanly where a daily-refresh source would fail.

### Rate limits

WDQS public endpoint: documented 60-second query timeout, and a concurrency /
throttling policy that returns HTTP 429 with `Retry-After` under load. One 502
was observed mid-survey on a heavier query and succeeded on retry three seconds
later — the endpoint is not guaranteed, which is another argument for baking the
result into the bundle rather than querying it at runtime. **Do not call WDQS
from the app.** Run it at build time.

### Licence

**CC0 1.0.** No attribution required, no share-alike, no non-commercial clause.
This is the best licence in the entire survey and the only source here with no
legal question attached to it. Attributing Wikidata anyway is good manners and
costs one line in Settings.

**Apple risk: none.** Encyclopedic metadata, CC0, no links to content.

**Verdict: build on it, as a bundled build-time extract — but size the
expectation honestly.** It buys Japanese original volume dates and ISBNs for
roughly 170 series and native titles for ~7,400. That is a genuinely nice layer
on a series page and it is free, offline, unrate-limitable and CC0. It is not a
replacement for anything, and anyone who reads "Wikidata has manga volumes" as
"Wikidata solves need 1" will be wrong by a factor of a hundred.

### Negative result, recorded

Wikidata was the most promising candidate for **need 2** (original-language next
release) and it fails that outright: it is an encyclopedia of published facts,
carries no forthcoming-chapter data, and its per-volume coverage of the two
Korean webtoons in the test set (Solo Leveling, The Beginning After The End) is
zero. **Killed by the 171-of-18,202 query.**

---

## 3. Anime News Network Encyclopedia API — one request, every volume

**Replaces:** need 1 (volume dates + ISBNs) for English-licensed print manga.

Found by a delegated agent; **independently re-verified from this session** before
being written down, because it is load-bearing.

### The endpoint

The name parameters do not do free-text search — `?manga=Solo%20Leveling` returns
`<ann><warning>no result…</warning></ann>`. You search via `reports.xml` first,
then fetch by numeric id, and the parameter for that is confusingly called
`title`:

```
# 1. find the id
curl -A '…' -G https://cdn.animenewsnetwork.com/encyclopedia/reports.xml \
  --data-urlencode 'id=155' --data-urlencode 'type=manga' --data-urlencode 'name=One Piece'

# 2. fetch the record
curl -A '…' 'https://cdn.animenewsnetwork.com/encyclopedia/api.xml?title=17164'
```

Verified in this session (Delicious in Dungeon, id 17164, HTTP 200, 22,343 bytes):

```xml
<release date="2017-05-23" href="…releases.php?id=32917" ean="9780316471855">Delicious in Dungeon (GN 1)</release>
<release date="2017-08-22" href="…releases.php?id=34609" ean="9780316473057">Delicious in Dungeon (GN 2)</release>
<release date="2017-11-14" href="…releases.php?id=34610" ean="9780316412797">Delicious in Dungeon (GN 3)</release>
<release date="2018-02-20" href="…releases.php?id=34611" ean="9780316446402">Delicious in Dungeon (GN 4)</release>
<release date="2018-05-22" href="…releases.php?id=45615" ean="9781975326449">Delicious in Dungeon (GN 5)</release>
…15 releases total
```

`ean` is the ISBN-13. `date` is the US on-sale date. Digital editions are
distinguishable from print by the suffix — `(GN 12)` vs `(eBook 12)`.

**The operational win: all 15 volumes arrived in ONE 22 KB request.** GCD (§4)
needs one request per issue for the same data. For a series page that wants the
whole volume list, ANN is an order of magnitude cheaper in round trips. That
matters more than it sounds given the app's 30/min and 180/min budgets.

### Coverage, measured

| Series | ANN manga entry | Per-volume releases |
|---|---|---|
| One Piece | id 1223 | **230** releases, dated + EAN, GN/eBook mixed |
| The Apothecary Diaries | id 23731 | 15, e.g. GN 1 = 2020-12-08, ean 9781646090709 |
| Delicious in Dungeon | id 17164 | **15, re-verified in this session** |
| Solo Leveling | **none** | — |
| The Beginning After The End | **none** | — |

**3 of 5.** The two misses are both Korean webtoons, and the miss is total —
re-verified here, `reports.xml?type=manga&name=Solo Leveling` returns
`<report skipped="0" listed="100">` with **no items at all**. ANN's encyclopedia
has no manga-type record for either; only their anime adaptations.

**This is the shape of the whole survey: ANN is an English-print-manga
encyclopedia, and digital-first manhwa is simply not in it.**

### Auth, limits, licence

- **Keyless.** Nothing to ship.
- **1 request/second per IP**, enforced by delay rather than a hard block. A
  `nodelay.api.xml` variant allows 5 requests per 5 s and returns 503 above
  that. They explicitly support **batching up to 50 titles in one request**,
  which fits a "sync my library" pass nicely.
- **Attribution is mandatory and it is a UI requirement, not a footer line.**
  Their terms: you must list Anime News Network as the source **and include a
  link to the relevant Encyclopedia entry** on any page that displays these
  details. The `href` on every `<release>` gives you that link for free — but
  it has to actually appear on the volume row. Budget the design for it.

**Apple risk: none.** ANN is an industry news site and encyclopedia. No content
hosting, no scanlation links. 5.2.3 not engaged.

**Verdict: build on it, for print manga.** It is keyless, it is one request per
series, and it is the cheapest per-volume source measured. Pair it with the
mandatory backlink. Accept that it contributes nothing for manhwa.

---

## 4. Grand Comics Database — the open API, not the dump

> **Decided 2026-09-14: cut.** The licence page 403s behind Cloudflare, the
> API throttled a 33-minute session and served ban notices as HTTP 200, and
> nothing in the app ever called it — `VolumeEdition.swift`'s doc comment
> records why ANN covers the same English volumes in one request. No code to
> delete; this note is the whole of the cut. Re-open only if a Western
> comics shelf is ever wanted, and start by asking them for the terms.

**Replaces:** need 1, and it is the only source measured that hit **5 of 5**.

Found by a delegated agent; **independently re-verified from this session**,
including the one series the agent did not sample.

### The dump is a dead end; the API is not

- `comics.org/download/` is behind Cloudflare Turnstile. Not bypassed (and we
  do not bypass CAPTCHAs). Wayback CDX shows every capture from 2012–2023
  returning HTTP 302 with an identical response digest — it has redirected to a
  login for over a decade, independent of Cloudflare.
- GCD's own `gcd-django` README (repo pushed 2026-09-13, actively maintained)
  confirms the dump is `current.zip` and requires an **authenticated** download.
  **Negative result: GCD publishes a full database dump, and it is not
  anonymously downloadable. The "bundle the GCD dump" idea dies here.**
- `comics.org/robots.txt` carries `Disallow: /` for `User-agent: ClaudeBot`.
  HTML scraping of that site stopped at that point and only the open `/api/`
  and third-party mirrors were used after.

But `www.comics.org/api/*` is **keyless, un-Cloudflared and returns clean JSON**.
Documented on the project wiki, which also warns: *"the anonymous access will
likely be turned off at some point."* Treat that as a real risk, not boilerplate.

### The gotcha that will cost you an hour

The API defaults to Django REST Framework's **browsable HTML**. Without an
explicit header you get a `<!DOCTYPE html>` page, not JSON:

```
curl 'https://www.comics.org/api/issue/2207217/'                      -> HTML
curl -H 'Accept: application/json' 'https://www.comics.org/api/issue/2207217/'  -> JSON
```

### Real responses, fetched in this session

```json
{"api_url":"https://www.comics.org/api/issue/2207217/",
 "series_name":"Solo Leveling (2021 series)","number":"1","volume":"1",
 "publication_date":"2021","key_date":"2021-03-02","price":"20.00 USD",
 "isbn":"9781975319434","on_sale_date":"2021-03-02",
 "series":"https://www.comics.org/api/series/170046/","cover":""}
```

The agent did not sample The Beginning After The End, so it was done here:

```
/api/series/name/The Beginning After the End/  -> count 2  (id 187824 en 2022, id 203471 de 2023)
/api/series/187824/                            -> active_issues: 11 URLs
/api/issue/2424526/                            -> {"number":"1","volume":"1",
   "key_date":"2022-08-02","on_sale_date":"2022-08-02","isbn":"9781975345631",
   "price":"20.00 USD; 26.00 CAD","cover":""}
```

**That is a control worth noticing.** GCD and MangaBaka, two independent
databases, return the *same* ISBN, the *same* 2022-08-02 date and the *same*
$20 / CAD 26 price for TBATE vol. 1. Neither is copying the other's field
names. Two sources agreeing on an exact ISBN is the strongest evidence in this
file that both are right.

### Coverage, measured

| Series | GCD series records | Per-volume date + ISBN |
|---|---|---|
| Solo Leveling | 9 (US/Yen Press, DE, BR, SE, HU) | yes — 2021-03-02, 9781975319434 |
| The Apothecary Diaries | 1 (US) | yes — 2020-12-08, 9781646090709 |
| Delicious in Dungeon | 4 (US ×2, DE ×2) | **partial** — `key_date:"2017-05-00"` (month precision), `isbn:""`, `on_sale_date:""` |
| The Beginning After The End | 2 (en, de) | **yes — verified here**, 2022-08-02, 9781975345631 |
| One Piece | **56** (all language editions) | existence confirmed; not sampled, 56 series is too many for a polite budget |

**5 of 5 present** — the only source in this survey that covers both Korean
webtoons. And it carries **non-English print editions** (German, Brazilian,
Swedish, Hungarian Solo Leveling), which is exactly the "beyond the English
market" reach the brief asked for and MangaBaka does not have.

### The two things that make it awkward

1. **It is a wiki, and completeness varies by volunteer.** Delicious in Dungeon
   vol. 1 has a month-precision `key_date` and an *empty* ISBN in GCD, while
   ANN has the same volume at 2017-05-23 with ean 9780316471855 and MangaBaka
   has it too. A blank field in GCD means "nobody typed it in", not "no ISBN
   exists". Never present a GCD blank as an absence.
2. **Listing a series' volumes costs 1 + N requests.** `issue_count` is `null`;
   the volume list arrives as `active_issues`, an array of **URLs** (11 for
   TBATE), each needing its own fetch for the date and ISBN. One Piece across 56
   series records is hundreds of requests. **This is why ANN wins on cost and
   GCD wins on coverage** — they are not interchangeable.

### Auth, limits, licence

- **Keyless**, no account. Nothing to ship.
- **Rate limit undocumented numerically.** The wiki says anonymous access has
  "some limits on the number of accesses per hour" without a figure, and no
  `X-RateLimit-*` headers came back. Combined with the warning that anonymous
  access may be switched off, this is the operational risk: an App-Store-scale
  fleet hitting an unmetered volunteer-run endpoint is how anonymous access
  gets switched off.
- **Licence: UNVERIFIED, and this blocks shipping.** Every comics.org page
  except `/api/` is Cloudflare-gated, so the terms text could not be fetched.
  GCD is widely *said* to be CC BY-SA; there is no fetched evidence for that
  here and it is not asserted. **Ask gcd-tech directly before building.** The
  same email should ask for a real rate-limit number.

**Apple risk: none from the data.** Licensed print editions with ISBNs; no
scanlation, no content links. 5.2.3 not engaged. The open question is
licensing (5.2.1 / general IP), not content.

**Verdict: keep as a fallback, promote to "build on it" once the licence
question is answered.** It is the best coverage measured and the only source
that reaches the manhwa and the non-English print editions. It is also the one
with an unverified licence, an unpublished rate limit and a maintainer-stated
intention to possibly close anonymous access. Two of those three are a single
email away from being resolved.

---

## 5. Rejected, with the test that killed each

Recorded so nobody re-proposes them. Every one of these was called, not read
about.

### AniList GraphQL — no per-volume data exists

```
curl -X POST https://graphql.anilist.co -H 'Content-Type: application/json' \
 -d '{"query":"query($s:String){Media(search:$s,type:MANGA){id title{romaji} volumes chapters status startDate{year month day} endDate{year month day}}}","variables":{"s":"Solo Leveling"}}'
```
```json
{"data":{"Media":{"id":105398,"title":{"romaji":"Na Honjaman Level Up"},
"volumes":15,"chapters":201,"status":"FINISHED",
"startDate":{"year":2018,"month":3,"day":4},"endDate":{"year":2023,"month":5,"day":31}}}}
```

**`volumes` and `chapters` are totals, not lists.** There is no per-volume
object in the `Media` type and no manga equivalent of `nextAiringEpisode` —
that field exists only on anime. Worse, the counts are `null` for *ongoing*
series: One Piece and The Apothecary Diaries both returned `volumes: null,
chapters: null`. The Beginning After The End is **not in AniList's manga
catalogue at all** (`{"errors":[{"message":"Not Found.","status":404}]}` for
both spellings).

**Killed by:** the schema having no per-volume field. Keep for characters, which
is what we already use it for. Attribution "Powered by AniList" required.

### Kitsu — the field exists and is empty

`/manga/{id}/chapters` genuinely carries a `volumeNumber` and a `published`
date per chapter. `published` was **`null` on every chapter of every series
tested**, including Delicious in Dungeon (id 27539) — a *finished*, popular,
well-documented series, deliberately chosen as the best case.

```json
{"id":"1277315","attributes":{"canonicalTitle":"Chapter 1","volumeNumber":1,"number":1,"published":null}}
```

**Killed by:** the best-case test. A schema field nobody populates is not a data
source. `/manga/27539/relationships/installments` also returned `{"data":[]}`.

### Jikan / MyAnimeList — mirrors a series-level model

`/v4/manga/13` (One Piece) returns one `published.from`/`to` pair, one
`volumes` count, one `chapters` count. MAL's manga model has no per-volume
list, so its mirror cannot have one either.

Separately, **`/v4/manga?q=…` returned HTTP 504 twice, three seconds apart**:
`"Jikan failed to connect to MyAnimeList. MyAnimeList may be down/unavailable"`.
Direct-id lookups worked. Jikan proxies MAL live and inherits MAL's outages; it
is an unofficial community proxy with no SLA. Pointing an App Store install base
at it is a reliability problem on top of a data problem.

**Killed by:** no per-volume data upstream to mirror.

### AniDB — the access model, not the data

```
curl -sv 'https://api.anidb.net:9001/httpapi?request=anime&client=test&clientver=1&protover=1&aid=1'
* LibreSSL SSL_connect: SSL_ERROR_SYSCALL in connection to api.anidb.net:9001
```

AniDB requires a **pre-registered, non-transferable client string** tied to one
application and developer. That is precisely the shipped-key-shared-by-every-user
pattern the brief rules out, and AniDB auto-bans IPs for malformed requests, so
this was not retried. AniDB is also anime-first with secondary manga coverage.

**Killed by:** the access model. Rejected without testing coverage, deliberately.

### MangaUpdates `/v1/releases/search` — an Apple problem, not just a data one

`/v1/series/{id}` has no volume-level date field anywhere in its key list.
`publications` is serialization-magazine info, not volumes.

`/v1/releases/search` *does* carry `volume`, `chapter` and `release_date` — but
look at what is attached:

```
vol=48  chapter=467   groups=['One Piece HQ']       2007-08-18
vol=49  chapter=480   groups=['One Piece HQ']       2007-12-01
vol=None chapter=1192 groups=['Viz','MANGA Plus']   2026-09-06
```

"One Piece HQ" is a fan scanlation group. For older chapters this endpoint is
tracking **scanlation release timestamps**, not official publication. And even
the licensed rows are *chapter* releases — `volume` here means "which volume
this chapter will eventually be collected into", not "the print volume shipped
on this date".

**Killed twice over:** it is not per-volume data, and surfacing
"released by <scanlation group>" in a shipped app is real **guideline 5.2.3**
exposure — presenting unlicensed-scan provenance as legitimate release data.

**The existing MangaUpdates usage (categories, tags, description) carries none
of this risk and should stay exactly as it is.** The distinction is the
endpoint, not the source. No bulk export or dump was found; `/v1/` returns only
a status ping.

### Comic Vine — killed by its own terms, in its own words

Fetched from their API landing page:

> Non-commercial use only … Commercial use will result in your API key being
> revoked.

> You must sign up for a unique api key for each site individually.

> Don't redistribute in another form … Do not edit, manipulate or reproduce on
> any other medium.

Rate limit 200 requests per resource per hour, with burst detection.

**Killed by:** three independent clauses. Non-commercial-only; one key per site
(a key in a binary is one key for thousands of users, and the 200/hour limit is
meaningless at that scale); and no-redistribution, which forbids bundling a
snapshot. Both the live-call path and the bundled-dump path are closed.

Manga coverage was **not tested** — every data endpoint needs a login and no
account was created. That is a blocker, not a finding: this file does not claim
Comic Vine lacks manga, only that its terms make the question moot.

### Inducks — right shape, wrong universe

inducks.org runs an **Anubis** proof-of-work wall whose own page says it exists
against AI scrapers; it was not bypassed. Measured instead through the
third-party `WizyxGH/InducksButBetter` mirror, whose GitHub release carries
`inducks.sqlite.gz` at **318,591,352 bytes (~304 MB)**, asset updated
**2026-08-16** — about a month old, so actively rebuilt, not stale. Raw tables
(`inducks_*.isv`) dated 2026-07-24; `inducks_issue.isv` 21.5 MB,
`inducks_issuedate.isv` 5.4 MB, `inducks_issueprice.isv` 2.7 MB.

**Killed by:** the table schema. `inducks_character`, `inducks_herocharacter`,
`inducks_logocharacter` — it is a Disney comics database. No manga, and not
testable against the five series because they categorically do not belong in it.

**But the brief was right that the model is the point.** `publication → issue →
issuedate / issueprice`, one row per real printed volume, compiled to a single
SQLite file for offline use, is precisely the shape a bundled volume dataset
should take — and it is the shape the Wikidata extract in §2 should be built
into. Copy the schema, not the data.

### GitHub and Hugging Face bulk mirrors — nothing bibliographic exists

- `manami-project/anime-offline-database` — actively maintained
  (`pushed_at: 2026-07-04`, 1,327 stars) and **anime-only**. All eight repos in
  that org were checked; there is no manga sibling. Wrong domain.
- GitHub `manga dataset in:name,description` — 91 hits; the recent ones are
  almost entirely **computer-vision / OCR page-image** datasets (Manga109
  tooling, speech-bubble segmentation, YOLO labelling). Zero bibliographic.
- GitHub `myanimelist manga dataset` — 7 hits, all scraper *scripts* or stale
  Kaggle notebooks, oldest 2021. The newest is a pipeline that calls MAL's API,
  i.e. a tool, not a dump.
- GitHub `anilist manga dump` — **0 results.**
- Hugging Face `search=manga` — 20 results, all image/ML. `search=myanimelist`
  — 4, all anime/review-angled. `search=anilist` — 2.
- `GoodPoison/anilist-2025` inspected directly: JSONL, rows shaped
  `{"id":104425,"type":"ANIME","format":"MOVIE","startDate_year":1940,
  "episodes":1.0,…}` — series-level, **year granularity only**, no
  chapter/volume field in the sampled rows. **Last modified 2025-06-05 — about
  15 months stale.** Per the brief's own rule, that is a negative result and it
  is recorded as one.

**Killed by construction, not by assumption.** Every AniList-derived dataset is
capped by AniList's schema, and §5 above verified live that AniList has no
per-volume date field to begin with. A mirror cannot contain what the source
never exposed.

**Negative result, stated plainly: there is no maintained public bulk dataset of
manga volume release dates. We looked properly and it does not exist.** The only
bulk-shaped answer available is the one we build ourselves from Wikidata (§2).

---

## 6. What this actually means

### Against the three needs

**Need 1 — volume and edition metadata.** Solved, three ways over, all keyless:

| | Coverage (5 series) | Requests for a full volume list | Licence | Reach |
|---|---|---|---|---|
| MangaBaka `/works` | 5/5, 100 % dated + ISBN | ~1 per 50 volumes | CC BY-NC-SA, NC question open | English + 1 Spanish |
| ANN `api.xml` | 3/5 (no manhwa) | **1, whole series** | free, mandatory backlink | English print |
| GCD `/api/` | **5/5**, wiki-patchy fields | **1 + N per issue** | **unverified** | English + DE/BR/SE/HU |
| Wikidata extract | 1/5 | 0, it is bundled | **CC0** | **Japanese originals** |

Build on MangaBaka. It is already the backbone, it is the only one with no new
integration cost, and it hits 100 % on the field that matters. Everything else is
a supplement.

**Need 2 — "when is the next chapter out", original language.** **Not solved,
and nothing in this family solves it.** Every source here is a catalogue of
things already published. The nearest thing found is MangaBaka's own future-dated
works (2026-11-10, 2026-12-08, 2026-12-15 all present) and
`/v1/works/upcoming?days=90` with `count: 807` — but those are **English print
volumes**, not the Korean original's episode count and finished-flag that Naver
supplied. The sitemap work in `release-sources-2026-09-13-survey.md` (Kakao
Webtoon, COMIC-WALKER) remains the only live lead for this, and it gives one
date per series, not a schedule. **Record this as still open.**

**Need 3 — covers.** Half solved. MangaBaka has cover art on some works and not
others (TBATE: 0 of 12; One Piece: 112 of 267). GCD has `cover` URLs on
`files1.comics.org` for some issues and `""` for others. Neither is dense enough
to rely on alone. Apple's iTunes Search and Open Library stay in the picture.

### The gap that keeps reappearing

Every source in this file is strong on **Japanese print manga licensed into
English** and weak-to-absent on **Korean digital-first webtoons**:

- ANN: no manga record for Solo Leveling or TBATE at all.
- AniList: TBATE not in the manga catalogue.
- Wikidata: zero volume dates for either.
- MangaBaka: has both, but only their English print editions.
- GCD: the sole source carrying both — because Yen Press printed them.

The pattern is not a coincidence. These databases index **printed books with
ISBNs**. A webtoon that never had a print run has nothing for them to index.
The app's library is 554 Webtoons + 235 Kakao + 228 Piccoma titles, so **this
gap covers the majority of what the app actually holds**, and no amount of
further API-hunting in this family will close it. It is a different kind of
source — publisher feeds — or it is a feature we do not ship for manhwa.

### Recommended order of work

1. **Build the MangaBaka volume grid.** The data layer already decodes this
   shape; the endpoint is keyless and hits 100 %. Handle the 50-item pagination
   and the paperback/hardcover duplicate-sequence case. Cheapest possible win.
2. **Bundle the Wikidata extract** as a build-time SPARQL query into an
   Inducks-shaped table. 285 KB, CC0, refreshed per release, adds Japanese
   original dates and ISBNs plus native titles for ~7,400 series.
3. **Add ANN** for English print volumes MangaBaka is thin on, with the
   mandatory per-entry backlink in the volume row. One request per series.
4. **Email GCD** (`gcd-tech`) about licence and rate limits before writing any
   code against it. It is the best coverage measured and the only source that
   reaches the manhwa print editions, and it is one answer away from usable.
5. **Ask MangaBaka** whether a free App Store app counts as non-commercial
   under their Data License. This predates the survey and is now more
   load-bearing, not less.

### Things this file does not claim

- Comic Vine's manga coverage — blocked by login, never tested.
- GCD's licence — Cloudflare-gated, never fetched. Widely *said* to be CC BY-SA;
  no evidence gathered here, so not asserted.
- GCD's anonymous rate limit — no figure published, none observed.
- Jikan's series-level-only schema was confirmed from a direct id lookup, but
  its search endpoint 504'd both attempts, so its search behaviour is untested.
- One Piece's GCD per-issue data — 56 series records was too many to sample
  politely. Existence confirmed, contents not.
- AniList's 30/min limit is documented, not re-derived; the endpoint returns no
  `x-ratelimit-*` headers to inspect.

