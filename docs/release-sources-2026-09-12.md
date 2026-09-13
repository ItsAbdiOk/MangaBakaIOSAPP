# Release data from the publishers — what each one actually gives up

Measured 2026-09-12 against the live sites, and against Abdi's real library (940
series, read out of the on-device database rather than guessed at). Negative
results are recorded with their reason, per CLAUDE.md: the point of this file is
that nobody re-proposes an idea that already died, or re-tests a host that
already answered.

## Why this exists

`Cadence` says in its own documentation that no source publishes real manga
release schedules, and every date it produces is inferred from when scanlations
appeared. That is true of MangaUpdates, which is where the estimates come from.
It is **not** true of the publishers themselves, some of whom publish exact
timestamps and have all along.

## What his library is actually made of

Top reading platforms across all 940 series:

| Series | Host |
|---|---|
| 554 | www.webtoons.com |
| 235 | page.kakao.com |
| 228 | piccoma.com |
| 212 | manga.nicovideo.jp |
| 189 | series.naver.com |
| 172 | comic.naver.com |
| 149 | tapas.io |
| 124 | webtoon.kakao.com |
| 96 | comic-walker.com |
| 87 | comic.pixiv.net |
| 74 | zebrack-comic.shueisha.co.jp |
| 45 | www.crunchyroll.com |

Webtoons is 59% of the library. Anything that works there matters more than
everything else combined.

## Webtoons — official RSS, and the placeholder trap

`https://www.webtoons.com/<lang>/<genre>/<slug>/rss?title_no=<id>` returns
`application/rss+xml`, ~7–20KB, the twenty most recent entries with exact
`pubDate` timestamps, plus the official title, synopsis and a cover.

**The trap, and the most important number here: only 16% of the Webtoons links
MangaBaka stores carry a real slug.** In a 118-series sample of the library, 84%
are stored literally as `/-/-/-/list?title_no=N`. The genre and slug are not
optional — a wrong path answers **500**, not a redirect-to-canonical 404.

**The recovery.** Webtoons keys the page on `title_no` alone and redirects a
wrong path to the canonical one, *correcting the language segment too*:

- `title_no=5188` sent to `/en/x/y/` → `/fr/fantasy/estatedeveloper/`
- `title_no=7620` → `/id/drama/on-the-way-to-meet-mom/`
- `title_no=6408` → `/en/action/why-i-quit-being-the-demon-king/`

So one redirect recovers any placeholder, in the edition Webtoons actually has.
This is the difference between the feature reaching one series in six and
reaching effectively all of them.

**Entries are not all episodes.** "The Knight Only Lives Today" (MangaBaka 1263)
ends season one at episode 112, and the feed's three *newest* entries are
`Afterword 1/2/3`, published the same Friday as the finale. Two rules were tried
and both are wrong:

- "trust any title with a number in it" → reads `Afterword 3` as episode 3, so
  the newest entry of a 112-episode series reports as **3**.
- "require `Episode <n>` exactly" → discards every entry of Tower of God, whose
  titles read `[Season 3] Ep. 235`.

What works is an allowlist of the *episode word*: `Afterword 3` and `Episode 3`
are the same shape and only the word differs.

**Finales are in the title** — `Episode 112 (Season 1 Finale)` — which is the
only way to tell a finished season from a stalled one. "Season 1 ended on 28
August" and "overdue since August" are opposite claims that a median gap cannot
distinguish.

**Freshness, four series.** unOrdinary current to within two weeks. Omniscient
Reader to June 2026. Tower of God frozen at Feb 2025, which matches its actual
hiatus and is therefore correct rather than stale. Lore Olympus returned only 9
entries from 2018 — an anomaly with no explanation, so do not trust a thin feed
blindly.

**Non-English.** `zh-hant` works and localises its dates (`週二, 08 9月 2026`),
which breaks an RFC-822 parser. Take schedules from the English feed.

## Naver (the Korean original) — no RSS, but a richer JSON endpoint

`comic.naver.com/webtoon/rss?titleId=` is **404**; that RSS is gone.

`https://comic.naver.com/api/article/list?titleId=<id>&page=1` returns JSON with
more than the English side has:

- `totalCount` — the official episode count (Tower of God: 653)
- `finished` — an official completion flag
- 20 recent episodes, newest first, with `serviceDateDescription` (`YY.MM.DD`),
  `starScore` and `volumeNo`
- titles carrying the season: `3부 235화` = season 3, episode 235

**Limit:** for `dailyPass` (paywalled) series only ~3 episodes are listed
publicly, so date history is thin. `totalCount` and `finished` still hold.

**What it is for.** Comparing the original against a translation that lags. Tower
of God's Korean stops 2 Feb 2025 and its English 24 Feb 2025 — both at the season
3 finale, so that one is a *confirmation* case, not a lead case. The valuable
case is the original stopping while the translation is still shipping: the
English will catch up and halt, and no English-side signal reveals it.

## Japanese publishers — one engine, enabled per publisher

**GigaViewer** (built by Hatena) powers a large share of Japanese publisher
sites. Append `.json` to an episode URL:

```
publishedAt: 2012-06-13T15:00:00Z     ISO 8601
number: 1
title: [第1話] ワンパンマン
series: { id, title, thumbnailUri }
prevReadableProductUri / nextReadableProductUri
```

One adapter would serve all of them — **but it is switched off per publisher.**
`tonarinoyj.jp` serves it. `shonenjumpplus.com` and `comic-days.com`, the same
engine, answer `{"error":{"message":"wrong feature"}}`. Adding XHR headers and a
browser UA did not help.

**Magazine-wide RSS** exists at `<host>/rss` on shonenjumpplus.com,
comic-days.com, magcomi.com, shonenmagazine.com, comic-gardo.com,
comic-earthstar.com and tonarinoyj.jp — all `application/rss+xml`. These are
magazine feeds, not per-series, so they need different handling.

**Tapas** answers JSON when `.json` is appended to a series URL. Its `/rss/`
path is 400, and its Open Graph and JSON-LD are worthless: `og:title` is `"Read
Solo Leveling | Tapas Web Comics"` and the single JSON-LD block is Tapas Media
Inc's postal address and founder.

## Dead ends — do not re-test these

- **Kakao** (page.kakao.com, webtoon.kakao.com), **Piccoma**, **Nico**
  (manga.nicovideo.jp), **comic.pixiv.net** — nothing on any of five probe
  patterns, and between them that is ~800 links.
- `shonenjumpplus.com/rss/series`, `tonarinoyj.jp/rss/series`,
  `comic-days.com/rss/series`, `sunday-webry.com/rss/series` — all 404. The
  site-wide `/rss` is the one that works.
- **Link unfurling via Open Graph / JSON-LD**, suggested as a general solution:
  Webtoons has **no** JSON-LD at all, and Tapas' is the company's mailing
  address. The claim that these carry genre, creators, episode counts and
  schedules did not survive testing on either site.
- `web.archive.org` appeared once as a `webplatform` link and is deliberately
  excluded from `ReadingPlatforms`: an archived reader page is the unauthorised
  copy whoever made it.

## One trap in the Webtoons feed to never touch

Each `<item>`'s `description` is not text — it contains the first two panels of
the episode as `<img>` tags pointing at Webtoons' CDN. Rendering those
republishes the comic. Parse `pubDate`, `title` and `author`; drop `description`.

## 2026-09-13 — building the three adapters

**Tapas: negative result, do not retest.** `tapas.io/series/<slug>.json`
answers 200 but carries no episode list at all — just the series' own blurb
and metadata. Every episode-list URL shape tried against it answered either
400 or 302: `/episodes`, `/episode-list`, an RSS-style `/rss/<slug>`, and a
paginated `?page=1` variant. Tapas is not built into `ReleaseFeedProvider`;
see the comment on the protocol itself.

**GigaViewer per-episode JSON: tried, rejected.** `<episode url>.json` answers
real data — `publishedAt`, `number`, `title`, the series block — but reading a
series' *history* that way costs one request per episode, and the payload
carries the page image URLs alongside it. Those must never be rendered
(the same rule that already governs Webtoons' `<description>`), and one
request per chapter is a request budget no other adapter here pays.

**Magazine-wide RSS chosen instead.** `<host>/rss` costs one request for an
entire magazine's current lineup and carries no page images at all — titles,
links and dates only. The cost is that it is a magazine feed, not a series
feed: it turns over daily rather than weekly, so `GigaViewerFeedClient` caches
it a day, not a week, and every series read off the same host shares that one
cached fetch rather than paying for its own.

**The seven hosts, re-verified.** All seven still answer
`application/rss+xml` at `/rss`: tonarinoyj.jp, shonenjumpplus.com,
comic-days.com, magcomi.com, shonenmagazine.com (a 301 to follow, not a
failure), comic-gardo.com, comic-earthstar.com. Item titles are the shape
`[第33話] カテナチオ` — the episode marker in its own brackets ahead of the
series' own title, unlike Webtoons' `[Season 3] Ep. 235` where the bracket is
a prefix to a following episode word. Splitting at the first `]` and matching
the remainder against a series' own titles (case/width-folded) is how one
provider serves all seven without per-publisher special-casing.

"Magazine Pocket" for shonenmagazine.com is carried as a guess in
`ReleaseSource.gigaViewerHostNames` — it is the site's own English branding as
best determined, not independently confirmed the way the other six were.

## Method note, because it nearly went wrong

A subagent probing 87 platforms reported Webtoons as having no endpoint. It had
picked a placeholder URL as its example, so all five of its probes 500'd. Its
own results carried the disproof: `dongmanmanhua.cn`, the same platform's Chinese
arm, passed the identical `/list` → `/rss` probe because MangaBaka happens to
store a real slug for it. The conclusion would have written off 59% of the
library on a sampling artefact.

## 2026-09-13 review

Two more measured facts about the Webtoons feed, both live GETs, recorded here
because they change what a bare "20 entries" answer is worth.

**Not every feed is the twenty most recent — some are the oldest.** True
Beauty (`title_no=1436`, completed, ~230 episodes) answers with 8 entries,
"Episode 0"–"Episode 7", all dated August–September 2018 — the *start* of the
series, not its end. The French Estate Developer feed (`title_no=5188`) is the
same shape: `Ep. 1`–`Ep. 7`, 2023. Nothing in the feed itself flags this; the
only tell is comparing the feed's highest number against the series' own known
chapter count. `ReleaseSummary.summarise` now takes that count and reports
`.none` rather than a confident rhythm when the feed sits far below it.

**A non-English edition localises `pubDate`, and the parser used to drop every
entry.** The redirect that recovers a placeholder link's real path also
corrects the language segment — `title_no=5188` lands on `/fr/`, not `/en/`
— and that edition's RSS writes French weekday/month names: `ven., 24 mars
2023 15:01:24 GMT`. The `en_US_POSIX` RFC-822 formatter returns nil for that
string, so every entry silently failed to parse and the feed cached itself
empty for a week. The client now tries the English edition first (rewriting
the landed URL's language segment) and falls back to the landed language only
if that fails; the parser also accepts the French weekday/month forms as a
second line of defence. Other localised editions (Indonesian, Spanish, German,
Thai, zh-Hant) are not yet verified either way.
