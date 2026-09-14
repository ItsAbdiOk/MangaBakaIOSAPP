# Korean webtoon episodes — is there a lawful "next / latest episode" source?

Measured 2026-09-14 with `curl`, ≤5 requests per host, on three test titles:
**Solo Leveling** (Kakao/Tapas, complete), **Tower of God** (Naver/Webtoons,
ongoing), **Lore Olympus** (Webtoons Originals, English-first, complete).
Extends `publishers.md`, `datasets.md`, `bibliographic.md` and the two
`release-sources-*` surveys; nothing they killed is re-derived here. Every
number below comes from a request made today; "not tested" is written where
it applies.

Constraints, as set: no scraping, no HTML parsing, no private or undocumented
APIs, keyless, App Store-safe.

## Recommendation

**None — no lawful source publishes a scheduled next episode for a Korean
webtoon. Twelve candidates, 0 of 12.** That answer is now four surveys deep
and should be treated as settled.

**What to do instead: parse a field the app already downloads.** MangaUpdates
`GET /v1/series/{id}` — keyless, documented, metadata-only, already fetched
and cached a week by `MangaUpdatesClient.series(number:)`, already decoded
into `MangaUpdatesSeries.status` — carries the original-language chapter
count and an Ongoing/Complete flag as free text:

```
Tower of God   status: "652 Chapters (Ongoing)  \n18 Volumes (Ongoing)\n\nS1: 78 Chapters + Prologue  \nS2: 337 Chapters + Prologue  \nS3: 235 Chapters  \n"   last_updated 2026-08-07
Solo Leveling  status: "200 Chapters + Prologue (Complete)  \n15 Volumes (Complete)  \n..."   completed: true   last_updated 2026-09-12
Lore Olympus   not on MangaUpdates (search "Lore Olympus" → 0 matching rows; MangaBaka carries no MU id for it)
```

That is exactly the pair Naver's `api/article/list` used to give — `totalCount`
and `finished` — for **2 of 3** titles, and the miss is an English-original
Webtoons title where the Webtoons RSS is already the native feed. It is a
recency-of-edit signal, not a schedule: ToG's text was last touched 2026-08-07.
Label it as such in the UI ("~652 episodes in Korean, per MangaUpdates").

**The measurement that decided it:** across all twelve candidates, the number
of future-dated episode rows returned for the three titles was **0**. The
only things that returned *any* per-episode data were past-only (Webtoons
RSS, MangaUpdates releases, MangaDex external links).

## Every candidate, measured

| # | Source | Official / documented | Keyless | Episode no. + date, Korean webtoons | Result on the 3 titles | Verdict |
|---|---|---|---|---|---|---|
| 1 | Webtoons per-title RSS `/{lang}/{genre}/{slug}/rss?title_no=N` | Official feed, undocumented but linked from the site; `robots.txt` does not disallow `/rss` | yes | English edition only; episode no. in title, exact `pubDate`; **past only** | ToG: 200, 20 items, newest "[Season 3] Ep. 235 (Season 3 Finale)" 2025-02-24. **Lore Olympus: 200, 9 items, all Episodes 1–9 from 2018**, `lastBuildDate` 2024-06-23 — the feed of a completed Daily Pass title shows the *first* nine episodes, not the last. SL: not on webtoons.com. | Already built. Keep. **New bug: Daily Pass feeds are oldest-first — see follow-up.** |
| 2 | Tapas RSS `/rss/…` | `robots.txt` says `Disallow: /rss/` for every named agent (re-read today, 2,967 B) | — | — | Not re-fetched; 09-12 survey measured 400 | Reject, policy and 400 (unchanged) |
| 3 | Sitemaps (Naver, Kakao, Tapas, Webtoons) | Declared in `robots.txt` — Naver: `Sitemap: https://comic.naver.com/sitemap.xml`; Webtoons and Kakao Webtoon declare none | yes | `lastmod` only, never an episode number | **Naver sitemap: 200, 546 B, three `<loc>`s** (`/webtoon`, `/bestChallenge`, `/challenge`), **0 `<lastmod>`** — landing pages, nothing per title. Kakao: per-series `lastmod` only (publishers.md, holds). Tapas: same shape (09-13). | Recency signal at best; no episodes. Sitemap argument below. |
| 4 | MangaUpdates `POST /v1/releases/search` (`search_type: series`) | Documented OpenAPI; spec marks it bearer-auth but it answers **200 without a token** | yes (measured) | English releases only, past only; `chapter`, `volume`, `release_date`, `groups[]` | SL: 380 hits, newest c.200 2023-05-31 by **LeviatanScans / FLAME-SCANS / Asura** (scanlators). ToG: 838 hits, newest v.3 c.235 2025-02-24 by **"LINE Webtoon"** (official). LO: absent from MU. | Official rows exist for 1 of 3; scanlation provenance on another. Datasets.md's 5.2 concern stands. Not for the UI. |
| 5 | MangaUpdates `GET /v1/series/{id}/rss` | Documented, `security: none` | yes | Same rows as #4, titles only, **no dates in the items** | ToG: 200, `application/xml`, 3,231 B, "Tower of God v.3 c.235 / LINE Webtoon" | Strictly less than #4. Reject. |
| 6 | MangaUpdates `GET /v1/series/{id}` `status` text + `completed` | Documented, keyless, already in the app | yes | Original-language **count** + Ongoing/Complete, human-edited free text; no dates | SL: "200 Chapters + Prologue (Complete)", completed=true. ToG: "652 Chapters (Ongoing)", completed=false. LO: not on MU. **2 of 3.** | **Use. The recommendation.** |
| 7 | MangaDex `GET /manga/{id}/feed` with `externalUrl` | Documented, keyless, 5 req/s/IP, mandatory real User-Agent (api.mangadex.org/docs/2-limitations) | yes | Official-publisher chapters appear as `externalUrl` rows (pocketcomics.com, tappytoon.com, webnovel.com) | SL (`ko`, completed): 24 chapters in en+ko, **24/24 external**, newest external row is ch. 3 dated 2024-02-18 — a stub, not a list. ToG (`c0ee660b…`, hiatus): **0** chapters en/ko. LO: **0** en/ko, 16 in other languages. **0 of 3 usable.** | Reject on data alone; the 5.2 argument in publishers.md never had to be reached. |
| 8 | AniList `Media.nextAiringEpisode` / `airingSchedule` | Documented, keyless | yes | Anime-only types; manga returns null/empty | SL: chapters 201, `nextAiringEpisode: null`, `airingSchedule.nodes: []`. ToG: chapters null, null, []. LO: `Page.media(search:"Lore Olympus", type:MANGA)` → `[]`. **0 of 3.** | Reject. Confirms publishers.md. |
| 9 | Kitsu `manga/{id}` + `/chapters` | Documented, keyless | yes | `chapterCount` only; `/chapters` rows are numbered placeholders | SL 201, ToG **null**, LO 280. ToG `/chapters?sort=-number` → **5,000 rows, `number` 5000…4998, `published: null`, titles null** — synthetic padding. | Reject. |
| 10 | Comick | Undocumented aggregator, hosts scans | — | — | `api.comick.fun` → **DNS failure**; `api.comick.io` → 301 → `comick.dev` → **404** HTML shell. | Reject twice (dead, and a chapter host). |
| 11 | Wikidata (`P1113` episodes, `P5760` chapters, `P582` end) | Documented SPARQL, keyless | yes | Per-series counts only, when someone entered them; never per-episode | Q106588507 SL: no count. Q487202 ToG: no count. Q96219608 LO: only `end: 2024-01-01`. **0 of 3.** | Reject. |
| 12 | Webtoon app deep links / AASA | `www.webtoons.com/.well-known/apple-app-site-association` → **404**; `/apple-app-site-association` → 200 but the 244 KB HTML homepage | — | Not a data source by construction | Not applicable | Only ever a "Open in WEBTOON" button; carries no episode data. Untested beyond the two fetches. |
| 13 | MangaBaka `/v1/series/{id}/works`, `/v1/works/upcoming` | MangaBaka's own API, keyless | yes | **Print volumes**, `release_date`, `count_type ∈ main/extra/other`; no episodes | SL: 25 works, all dated, newest 2025-08-19, seq 13. ToG: **0**. LO: **0**. Upcoming: 580 works in 60 days, none are episodes. | Already built (`UpcomingWork.swift`). Not an episode source. |
| 14 | Webtoon / Naver developer programmes | `developers.webtoons.com`, `api.webtoons.com` → DNS failure (publishers.md). `developers.naver.com` answered 200 today but as a 5 KB JS shell — product list **not read**. Naver's platform is Client-ID/Secret by design. | no | — | Not tested further | Keyed → out under the keyless rule regardless of coverage. |

Kakao Page, Lezhin, Toomics, Ridibooks: tested and dead in publishers.md; not re-run.

## Request shapes for the recommendation

Already issued by the app; shown so nobody adds a second call.

```
GET https://api.mangaupdates.com/v1/series/{numeric id}        # numeric = Int(base36, radix: 36); MangaBaka hands the base-36 id in source.manga_updates.id
User-Agent: <app UA>                                             # MU asks for spacing + caching; client already spaces 3 s and caches 7 d
→ { "status": "652 Chapters (Ongoing)  \n18 Volumes (Ongoing)\n\nS1: …", "completed": false, "latest_chapter": 235, "last_updated": { "as_rfc3339": "2026-08-07T18:28:36-07:00" } }
```

Parse rule, from the two measured strings: first line matches
`^(\d+) Chapters(?: \+ Prologue)?[^()]*\((Ongoing|Complete)\)`. Anything
else → `nil`, shown as nothing. `latest_chapter` (235) is the *English*
release row — do not confuse it with the 652 in `status`.

Attribution: MU's Acceptable Use Policy (bundled `mangaupdates_openapi.json`
info block) — "You will credit MangaUpdates when using data provided by this
API." `docs/licences.md` has no MangaUpdates entry today; add one.

## Apple, in two paragraphs

The guideline number in the brief is off, and it matters. Fetched today from
developer.apple.com: **5.2.3 is "Audio/Video Downloading"** — apps must not
save, convert or download media from third-party sources without
authorization. Nothing here streams or downloads anything, so 5.2.3 does not
engage. The rule that does is **5.2.2 "Third-Party Sites/Services"**: "If your
app uses, accesses, monetizes access to, or displays content from a
third-party service, ensure that you are specifically permitted to do so under
the service's terms of use. Authorization must be provided upon request." The
practical impact: *Apple's rule imports the publisher's terms.* "I care about
Apple, not the ToS" is not a split Apple offers; a reviewer who asks for
authorization is asking for the ToS position. The line that keeps 5.2.2
comfortable is the one publishers.md already drew: metadata a service
publishes for machines (MangaUpdates' API with its own AUP, Webtoons' RSS,
ANN's encyclopedia) versus chapter content or its index. The recommendation
sits entirely on the first side — a chapter *count* from a metadata API that
asks only for credit.

Sitemaps, argued both ways from the `robots.txt` text. *For*: Naver's file
says `Allow: /` and `Sitemap: https://comic.naver.com/sitemap.xml` — a sitemap
is a file the site publishes *for* automated readers, under a public
standard, and reading it is the use it invites; Kakao Webtoon disallows only
`/webview`. *Against*: robots.txt is addressed to crawlers, and Naver's own
file `Disallow`s `/webtoon/detail` and `/webtoon/list?…&page=` for `*` while
allowing them only for `facebookexternalhit` and `Twitterbot` — a site that
carves out social previews is signalling that the general public is not an
intended machine reader of episode pages. Today the argument is moot: Naver's
sitemap holds three landing pages and no `<lastmod>`, so there is nothing to
read. Reading a declared sitemap is not scraping under the owner's own rule
(no HTML, a documented format, an advertised URL), but it also carries no
episode data on any Korean platform measured across four surveys.

## What a follow-up implementation would need

1. `MangaUpdatesSeries.status` → a small `OriginalRun` value (`chapters: Int`,
   `ongoing: Bool`, `editedAt: Date`) via the regex above. ~30 lines plus
   tests on the two strings recorded here, and one deliberately malformed one.
   Prove the test fails without the parser.
2. Surface it in `ReleaseSummary` as a labelled approximation: "≈652 in
   Korean · ongoing · MangaUpdates, edited 7 Aug" — never as a next date. The
   two caveats from publishers.md hold: absent ≠ nothing coming; the count is
   only as fresh as its last human edit.
3. `docs/licences.md`: add the MangaUpdates credit line, and the Webtoons RSS
   entry while there (neither is listed).
4. **Fix the Daily Pass RSS bug first.** Lore Olympus' feed returns episodes
   1–9 (2018) with `lastBuildDate` 2024. `ReleaseFeed.latestEpisodeNumber`
   takes `max`, so it will report 9 of 280, and `Cadence` will estimate a
   weekly rhythm from 2018. Detect "newest item is episode ≤ 20 and older than
   a year" → treat as `.answered(nil)`. One fixture, one test.
5. Do not build: MangaDex (0 of 3, and a chapter host), Kitsu chapters
   (padding), Wikidata (empty), Comick (dead), any sitemap for episodes.

## Requests made today (per host)

api.mangabaka.org 7 · www.webtoons.com 5 · comic.naver.com 2 · tapas.io 1 ·
webtoon.kakao.com 1 · api.mangaupdates.com 6 · api.mangadex.org 6 ·
graphql.anilist.co 2 · kitsu.io 4 · api.comick.fun/io 2 · query.wikidata.org 2 ·
www.wikidata.org 3 · developers.naver.com 2 · developer.apple.com 1 (WebFetch).
