# Reader slice — what it says about the reader, and when things come out

Read-only review, 2026-09-13. Focus: data-shape assumptions that fail on real
inputs, following this morning's `totalCount` fix. Nothing was built, run or
edited; six live GETs were spent and are listed at the end.

## Scope

Reviewed in full (every line read): `Core/Schedule/` — `WebtoonsEpisode`,
`ReleaseFeedService`, `WebtoonsFeed`, `WebtoonsFeedClient`, `NaverFeedClient`,
`GigaViewerFeedClient` (incl. `MagazineFeedParser`), `TranslationGap`,
`ReleaseSummary`, `ReleaseSource`, `ReleaseFeedProvider`, `Cadence`,
`SeasonReading`, `ReleaseSchedule`, `ReleaseCalendar`, `UpcomingWork`,
`MangaUpdatesClient`, `MangaUpdatesID`. `Core/Library/` — `ReadingInsights`,
`ReadingTime`, `ReadingWrapped`, `ReadingWrappedYear`, `TasteLedger`,
`TasteProfile`, `TasteRanker`, `Continuations`, `LibraryEntry`,
`LibrarySnapshot`.

Skimmed only: `LibraryService` (the `try?` sites and paging), `SpotlightIndex`
(function list). Read outside the slice only to state impact:
`Features/Detail/ReleaseSection.swift`, `Features/Schedule/ScheduleRow.swift`
(`cadenceLine`), `Core/Networking/APIClient.swift:29-45`,
`docs/schemas/mangabaka_openapi.json:29915-29927`, and the test suites for the
feeds.

Already established elsewhere and not re-derived: R1–R25 in
`SUMMARY-2026-09-11.md` (R6, R7, R10, R11, R15, R17 are visibly fixed in the
code read here; R5, R9, R12, R14, R16, R18–R25 not re-checked). The
`LibrarySnapshot.readCache` `compactMap { try? decode }` at
`LibrarySnapshot.swift:149-151` is the P-F9 pattern (one undecodable row
silently shortens the library until the six-hour expiry) — one line, cited,
moving on.

## Findings, ordered by value

### 1. The Webtoons feed is not always "the twenty most recent" — for some series it is the *first* few, and the app then reports Episode 7 of a finished 200-episode series with a weekly rhythm

- **What** — `ReleaseFeed`/`ReleaseSummary` assume the feed's entries are the
  newest; for at least some series (Daily Pass / completed ones, by the look
  of it) Webtoons returns the oldest handful instead, and nothing checks.
- **Where** — assumption stated at `WebtoonsFeed.swift:7-8` ("the twenty most
  recent entries"); consumed at `WebtoonsFeed.swift:58` (`latestEpisodeNumber`
  = max number in feed) and `ReleaseSummary.swift:65-70` (rhythm from those
  dates). Printed with no year at `Features/Detail/ReleaseSection.swift:118`
  (`shortDate`), so 2018 reads as this year.
- **Why it matters** — live GET, True Beauty (`title_no=1436`, completed,
  ~230 episodes): the feed carries **8 entries, "Episode 0"–"Episode 7", all
  August–September 2018**. Through this code that is
  `.rhythm(7 days, very evenly)`, `latest = Episode 7`, and the section prints
  "About every 7 days, very evenly · Ep. 7 · 19 Sep" — a confident, wrong
  schedule for a series that ended years ago, dated as if last week. The
  French Estate Developer feed (`title_no=5188`) is the same shape: Ep. 1–7,
  2023. `docs/release-sources-2026-09-12.md:82-83` recorded Lore Olympus as
  "9 entries from 2018 — an anomaly with no explanation" and said "do not
  trust a thin feed blindly"; the code trusts it. With Naver also answering,
  `translated = 7` makes the gap line "The Korean original is 600+ episodes
  ahead". Webtoons is 59% of the library, and completed/Daily Pass series are
  a large share of what a reader has finished.
- **Effort** — a function. Two cheap checks are available without a request:
  `series.totalChapters` (the feed test at `WebtoonsFeedTests.swift:48-52`
  already uses it as a control) and the reader's own `progressChapter`. A feed
  whose highest number is far below either is the oldest-first shape and
  should summarise to `.none`, not `.rhythm`. Which series get this shape is
  an open question below.
- **Confidence** — certain (two live feeds plus the doc's third).

### 2. Non-English editions localise `pubDate`; every entry is dropped, and the empty feed is cached for a week

- **What** — the redirect that recovers the 84% of placeholder links lands in
  whatever language Webtoons has (`/fr/`, `/id/`, …); those feeds print dates
  in that language; the POSIX RFC-822 formatter returns nil for all of them;
  the feed parses "successfully" with zero entries.
- **Where** — `WebtoonsFeed.swift:180-188` (formatter, `en_US_POSIX`),
  `:234` (`guard … let date = … else { return }` — the entry is silently
  dropped), `:161-162` (a feed with a channel title and no entries is still a
  feed); `WebtoonsFeedClient.swift:68-71` caches it, `:14` for seven days;
  `:132-137` sends the redirect that chooses the language. The doc knew:
  `docs/release-sources-2026-09-12.md:85-86` says "take schedules from the
  English feed", and the code does not.
- **Why it matters** — live GET,
  `/fr/fantasy/estatedeveloper/rss?title_no=5188`: `ven., 24 mars 2023
  15:01:24 GMT` for every entry. Verified in a scratch script that the app's
  exact formatter returns nil for it (and parses `+0000`, `GMT`, `+0900` and a
  one-digit day fine). Titles in that feed are plain `Ep. 7`, so the title
  reader would have worked. Result: no section, no error, for a week — and
  because an answered-but-empty Webtoons feed is still `primary`
  (`ReleaseFeedService.swift:55-62`), the Korean-only Naver fallback is skipped
  too. The doc's own example of the redirect is a series that lands on `/fr/`.
- **Effort** — a function: after the redirect, rewrite the language segment
  to `en` and try that feed first (the doc's rule), falling back to the landed
  language; or don't cache a feed that parsed to zero entries.
- **Confidence** — certain.

### 3. Naver's `totalCount` counts articles and paid-ahead episodes, not free episodes — the sibling of this morning's bug, in the branch the fix left alone

- **What** — for series with no seasons on either side, the gap uses
  `naver.totalCount` as "the original's episode number". It is the article
  count: it includes the pay-to-read-early episodes and every non-episode
  article, so it runs 6–11 past the number a Korean reader would give.
- **Where** — `ReleaseFeedService.swift:87-91` (`case (nil, nil): originalNumber
  = naver.totalCount ?? naver.latestEpisodeNumber`, with the comment "the
  official figure"). The test at `ReleaseFeedServiceTests.swift:133-156` pins
  this with a fixture built from the belief (listed max 104, `totalCount`
  140) rather than from a response — charter pattern 2.
- **Why it matters** — live GET, 화산귀환 (`titleId=769209`, no seasons):
  `totalCount: 185`; newest free episode is `174화` (`no: 180`); the five
  paid-ahead in `chargeFolderArticleList` run to `179화` (`no: 185`). So the
  count is 6 non-episode articles plus 5 paid episodes above the free one.
  Lookism (`641253`): `totalCount 624`, newest free `617화`, seven paid-ahead.
  Every no-season Webtoons series with a Naver link ("Episode N" titles are
  the common Webtoons shape) will say "The Korean original is N episodes
  ahead" with N overstated by roughly 6–11, and on a fully caught-up
  translation it will claim a lead that does not exist. The comment's
  justification — paywalled series list only three so the listed max
  understates — is not what the payload does: the list is `sort: DESC`, so
  the listed max is the newest free episode whatever the length of the list.
- **Effort** — a line: prefer `naver.latestEpisodeNumber`; use `totalCount`
  only when no title parsed at all. Plus fixing the test's fixture to the
  live numbers above (which will fail it, as it should).
- **Confidence** — certain.

### 4. GigaViewer titles come in shapes the reader rejects — `[106話]`, `[第１２２話]`, `[4375回]`, `[#96]` — and a rejected shape makes the section vanish

- **What** — `readJapanese` matches only `第[0-9]+話` with ASCII digits. Real
  magazine feeds omit `第`, use full-width digits, use `回`, or use `#`. An
  unmatched title has `number == nil`, is not an "episode", and a series whose
  entries are all of that shape summarises to `.none`.
- **Where** — `WebtoonsEpisode.swift:81` (the regex), `:19` (`isEpisode`),
  `ReleaseSummary.swift:52`. The fixture at `GigaViewerFeedTests.swift:17-33`
  has `[第33話] カテナチオ` — with a space after `]` and `GMT` dates; the live
  feed has no space and `+0000`. The date difference is harmless (checked:
  the formatter parses `+0000`); the title difference is the bug, and the
  fixture is hand-shaped rather than captured (charter pattern 2).
- **Why it matters** — live GET, `shonenjumpplus.com/rss`, 108 items. Of the
  first 40 titles, these do not parse: `[第１２２話]ふつうの軽音部`
  (full-width), `[106話]クソ女に幸あれ`, `[69話]英雄機関`, `[32話]おかえり水平線`,
  `[21話]夫婦と16歳`, `[17話]どろん`, `[17話]サナギの心臓`, `[27話]天傍台閣`,
  `[4375回]猫田びより`, `[#96]ゴーストフィクサーズ`, `[第1画目]…`, `[第14歩目]…`,
  `[おまけ15]…`. Roughly a third. The series-title match
  (`GigaViewerFeedClient.swift:49`) succeeds for those, so the feed *is*
  found — and then says nothing. `normalise` folds width for the series
  title but `read` gets the raw title, so the full-width case is a
  half-applied fix.
- **Effort** — a line: `第?[0-9０-９]+(話|回)` after folding width (or fold in
  `read` first), and `#N`. `画目`/`歩目`/`おまけ` are a judgement call.
- **Confidence** — certain.

### 5. `finished` is decoded, documented as the reason Naver is read, and never consulted — a completed original is described as stalled

- **What** — charter pattern 3. `ReleaseFeed.finished` exists so the app can
  tell "the original has stopped" from "the original is done"; nothing reads
  it.
- **Where** — decoded `NaverFeedClient.swift:88`, carried
  `WebtoonsFeed.swift:23-24`, promised in `NaverFeedClient.swift:6-10`; the
  only consumer of the Naver feed, `ReleaseFeedService.gap` (`:73-105`), and
  `TranslationGap.between` (`:50-66`) never mention it. A grep for
  `.finished` outside these two files finds only comments.
- **Why it matters** — a finished Korean original that the English is still
  translating (the ordinary case for every completed webtoon) is silent past
  three median gaps, so it reads as `.originalPaused` and the section prints
  "The Korean original hasn't released since 2 Feb 2025 — the translation will
  catch up and stop" (`ReleaseSection.swift:104-106`). The second half is
  true; the first half describes a hiatus that is a completion. The reader is
  told to worry about the wrong thing.
- **Effort** — a line in `gap` plus a case (`originalComplete`) and one
  sentence in the view.
- **Confidence** — certain that it is unread; likely for the wording impact.

### 6. Finish dates are UTC-midnight calendar days, and Wrapped reads their year, month and day in the device's calendar

- **What** — the API's own schema says `finish_date` responses are
  `YYYY-MM-DDT00:00:00.000Z` for "a calendar date". Every reader west of UTC
  sees that instant as the previous local day.
- **Where** — `ReadingWrappedYear.swift:47` (`calendar.component(.year …)`,
  `calendar: .current`), `:70` (`.month`, `busiestMonth`), `:140`
  (`dateComponents([.day])`, `fastestFinish`). Schema:
  `docs/schemas/mangabaka_openapi.json:29915-29927`. The same trap is
  documented and handled for release dates at `UpcomingWork.swift:110-126`
  (`localDay`), so the project already knows it.
- **Why it matters** — a series finished on 1 January is counted in the
  previous year's Wrapped; a finish on the 1st of any month moves the
  "busiest month"; a two-day sprint spanning a month boundary is unaffected
  (both ends shift). Small share of entries, but a Wrapped that says "you
  finished 11 series in 2025" and is off by the New Year's Day one is exactly
  the kind of claim a reader can check.
- **Effort** — a line: a UTC `Calendar` for these three, or a date-only
  parse as `UpcomingWork.localDay` does.
- **Confidence** — certain by the schema text; not measured on a device in a
  western zone.

### 7. (Cross-slice, flagged not owned) API v2 will return bare `YYYY-MM-DD`, and the decoder only accepts date-time

- **What** — the schema says "API v2 will accept and return `YYYY-MM-DD`
  only". `APIClient`'s custom date strategy tries internet date-time with and
  without fractions and throws otherwise.
- **Where** — `APIClient.swift:35-45`; schema
  `mangabaka_openapi.json:29923`; the swallow that turns it into "no library"
  is `LibraryService.swift:161`.
- **Why it matters** — the day the library endpoint moves to v2, every page
  throws on its first `start_date`, and the charter's "swipe stack silently
  fell back to a random queue for a reader with 937 tracked series" happens
  again. Not live yet.
- **Effort** — a line (a third fallback parse).
- **Confidence** — worth checking (depends on the v2 timeline).

### 8. Two per-chapter reading rates, opposite in direction, on one screen

- **What** — `ReadingInsights.minutesPerChapter` says a manhwa chapter is 6
  minutes and a manga chapter 11; `ReadingTime.secondsPerChapter`, calibrated
  on 152 series, says manhwa 214 s (3.6 min) and manga 170 s (2.8 min). The
  same screen shows both.
- **Where** — `ReadingInsights.swift:120-128` vs `ReadingTime.swift:21-28`;
  rendered together in `Features/Library/ReadingInsightsView.swift:77`
  (`hoursRead`) and `:181` (`ReadingTime.label`). `ReadingTime` landed
  2026-09-12 (`e6c0cd3`) beside the older constant rather than replacing it.
- **Why it matters** — 100 manga chapters read: "about 18 hours" in one card;
  100 manga chapters waiting: "≈ 5 h" in the next. A reader will notice a
  four-fold disagreement about their own time. The two constants also
  interact with a third: the binge guard at `ReadingWrappedYear.swift:151-157`
  uses the 11-minute rate against an 8-hour ceiling, admitting a 44-chapter
  same-day manga; on the measured 2.8-minute rate the same ceiling admits
  170, which is well past the "stamped 80-chapter import" the guard was
  written to reject (`:101-105`). Fixing the duplication without re-deriving
  the ceiling reopens R14.
- **Effort** — a file: one rate table, both call sites, and the ceiling
  restated in chapters or re-derived against the new rate.
- **Confidence** — certain.

### 9. A series removed from the library keeps its weight in the taste ledger forever

- **What** — `absorb` adds and re-weights; nothing subtracts a series that is
  no longer in the library. The `prune` comment claims removal removes
  influence; no code path does that.
- **Where** — `TasteLedger.swift:73-100` (`absorb(_ entries:)`), `:216-217`
  (the claim), `:180-185` (`clear`, sign-out only). `TasteProfile.buildIDs`
  (`:104-106`) re-absorbs the fresh snapshot after a removal and never diffs
  it against `TasteSource`.
- **Why it matters** — a reader who prunes fifty dropped series still gets
  recommendations ranked (`TasteRanker`) and tags highlighted by them until
  they sign out. The "what you read" claim quietly includes what they chose
  to un-read.
- **Effort** — a function: after absorb, subtract every `TasteSource` row not
  in the snapshot's ids at its stored state's weight, then delete the row.
- **Confidence** — certain.

### 10. The detail page's cadence never gets its season; the settled row then blocks the build from adding it

- **What** — two code paths measure a cadence; only one sets `season`.
- **Where** — `ReleaseSchedule.swift:306-310` (`run`, sets
  `cadence?.season`), `:354-357` (`cadence(for:)`, does not); `:287-289`
  skips settled rows, so a series first opened from its detail page is
  settled without a season and the schedule build leaves it that way.
- **Why it matters** — `ScheduleRow.cadenceLine` (`ScheduleRow.swift:107-108`)
  prints "Season 3 · about every 7 days" only when `season` is set; for Tower
  of God opened from Search before the Schedule tab, it prints "chapter 235"
  — the exact "means nothing without the season" case the comment names.
- **Effort** — a line (set it in `cadence(for:)` too, or one shared helper).
- **Confidence** — certain.

### 11. `marksFinale` matches "the end" and "finale" anywhere in a title

- **What** — an ordinary episode whose title contains those words ends the
  season.
- **Where** — `WebtoonsEpisode.swift:110` (`"(?i)finale|final episode|(?i)the
  end"` as an unanchored search); consumed at `WebtoonsFeed.swift:77-82` and
  `ReleaseSummary.swift:56-58`, which outranks the rhythm.
- **Why it matters** — "Ep. 45 - The End of Summer", "Episode 30: Until the
  end", "Ep. 12 (Season 2 Finale next week)" produce `.seasonEnded(season:
  nil)` → "The season ended on 5 Sep" for a week, until a newer episode
  arrives and `finale.published >= latest` fails. Self-healing, but a wrong
  claim for a week is the class of thing this feature exists to avoid.
- **Effort** — a line: require the marker inside parentheses or at the end,
  and drop the bare "the end".
- **Confidence** — likely (no live example found in six GETs; the titles
  above are plausible, not observed).

### 12. Two one-line guards missing in the Naver decoder

- **What** — (a) `2000 + parts[0]` with no range check; a four-digit year
  yields 4025. (b) `Article.no: Int` is required by the type, never read
  (`:82-86` says so), and one null `no` fails the whole feed.
- **Where** — `NaverFeedClient.swift:127`; `:93`.
- **Why it matters** — (a) is untriggered on the four series fetched (all
  `YY.MM.DD`), so it is a fence, not a fix; (b) is charter pattern 1 in its
  purest form — a required field with zero readers.
- **Effort** — a line each (`guard parts[0] < 100`; `let no: Int?` or delete).
- **Confidence** — worth checking for (a); certain for (b) being unread,
  worth checking for whether Naver ever omits it.

### 13. (Cross-slice) `.recent` rows are identified by timestamp, and real feeds share timestamps

- **What** — `ForEach(entries.prefix(5), id: \.published)`.
- **Where** — `Features/Detail/ReleaseSection.swift:62`.
- **Why it matters** — True Beauty's Episode 0, 1 and 2 share
  `04:26:13 GMT`; Estate Developer's Ep. 1–3 share `15:01:29`. Duplicate
  SwiftUI ids: rows collapse or mis-render, and a debug-build warning. Any
  feed whose first three episodes launched together and which falls below
  `Cadence.minimumDates` hits it.
- **Effort** — a line (`id: \.title` or an index).
- **Confidence** — likely (behaviour of duplicate ids is undefined, the
  duplicates themselves are observed).

### Minor, one line each

- `ReleaseScheduleService.staleAfter = 14 days` (`ReleaseSchedule.swift:87-89`)
  has a rationale and no `guess` label; every other threshold in this slice
  now has one.
- `GigaViewerFeedClient.swift:59` `?? "Shonen Jump+"` is unreachable
  (`matchingHost` only returns keys of the same dictionary) and would
  mis-attribute if it ever ran.
- `ReleaseSource.swift:31` `.gigaViewer.displayName` is "Shonen Jump+" for a
  source that is seven publishers; only reached if `sourceName` is nil, which
  `GigaViewerFeedClient` never leaves nil. Same dead fallback, two places.

## What this slice does well

- `ReleaseFeedService.swift:76-84` records this morning's measurement with
  the numbers (653 vs 235, 418), the date, and what was ruled out — the
  reason finding 3 was findable in an hour.
- `WebtoonsEpisode.swift:25-34` keeps both rejected title rules with the
  exact input that killed each ("Afterword 3" → episode 3; "Episode <n>" →
  loses Tower of God). Negative results where the code is.
- `WebtoonsFeed.swift:117-131` states the 16%/84% split with its sample size
  (118 series) and says it "changes what this feature is worth".
- `NaverFeedClient.swift:82-86` refuses `no` as the episode number and gives
  the number that proved it (654 vs 235); `:114-119` labels noon a guess and
  says why it is the least wrong one.
- `ReleaseSummary.swift:66-69` takes the latest episode by date rather than
  by position because "nothing guarantees feed order survived parsing" — the
  right instinct, and it is what keeps finding 1 from being worse.
- `Cadence.swift:117-121` names the two series it was measured on and the
  before/after numbers; `:126-132` records the "every 1 day, exactly"
  pathology and why the fallback was narrowed (R16, fixed).
- `TranslationGap.swift:34-38` labels the pause threshold a guess and says
  what deriving it would need (a corpus of known hiatuses).
- `ReleaseCalendar.swift:17-23` and `:65-69` are R11 and R10 fixed, each with
  the arithmetic that was wrong written down.
- `ReleaseSchedule.swift:386-392` turns an undecodable cached cadence into a
  retryable failure rather than a settled "too few releases" (R7, fixed).
- `ReadingTime.swift:6-15` gives the calibration's provenance, its p25/p75,
  and says "measured for exactly one reader, a GUESS for anyone else".
- `MangaUpdatesID.swift:8-17` documents the silent failure mode of the
  base-36 id with the series that exposed it.
- `WebtoonsFeed.swift:205-210` drops non-UTF-8 CDATA rather than substituting,
  so a mangled title is never parsed as sound.
- `MangaBakaTests/Fixtures/knight-only-lives-today.rss` is a captured
  response, not a hand-built one; the suite's control at
  `WebtoonsFeedTests.swift:48-52` checks the feed against MangaBaka's chapter
  count — the very check finding 1 needs promoted into production.

## Open questions

- **Which Webtoons series return the oldest-first feed?** Hypothesis: Daily
  Pass / completed titles (True Beauty, Lore Olympus, Estate Developer FR all
  fit). A survey of ~20 feeds across ongoing/completed/Daily Pass would settle
  the rule and tell whether `series.status == "completed"` alone predicts it.
- **Naver `dailyPass` thin lists: newest three or oldest three?** The doc
  says "~3 episodes listed publicly"; Tower of God turned out not to be
  `dailyPass` (payload says `false`, 20 listed), so the claim in
  `ReleaseFeedService.swift:88-90` is unverified either way. If oldest,
  `latestEpisodeNumber` understates and `lastEpisodeAt` is years old —
  `.originalPaused(since: 2019)` for a running series. One GET on a known
  `dailyPass` title answers it.
- **Non-English Webtoons titles.** French uses `Ep. 7` (parses). Indonesian,
  Spanish, German, Thai and zh-hant are unverified; zh-hant is likely
  `第N話` and would parse via the Japanese branch — once its dates parse.
- **Does Naver ever send a four-digit year in `serviceDateDescription`?** Not
  in 60 articles across three series.
- **`readSeason` on incidental "Season N" text** — "Episode 50 (Season 2
  preview)" would set `season = 2` on a season-1 episode and push
  `latestSeason` up. Plausible, not observed.

## Live requests spent (6 of 6)

1. `GET https://www.webtoons.com/fr/fantasy/estatedeveloper/rss?title_no=5188`
   — 200, `application/rss+xml`; 7 entries `Ep. 1`–`Ep. 7`, dates `ven., 24
   mars 2023 15:01:24 GMT` (findings 1, 2, 13).
2. `GET https://www.webtoons.com/en/romance/truebeauty/rss?title_no=1436` —
   200; 8 entries `Episode 0`–`Episode 7`, Aug–Sep 2018, `Wed, 19 Sep 2018
   04:00:24 GMT` (finding 1, 13).
3. `GET https://comic.naver.com/api/article/list?titleId=641253&page=1`
   (Lookism) — 200; `totalCount 624`, `totalRows 617`, newest free `617화
   김갑룡 [08]` `26.09.10`, seven `chargeFolderArticleList` items with
   `serviceDateDescription: "46일 후 무료"` (finding 3, 12).
4. `GET https://comic.naver.com/api/article/list?titleId=769209&page=1`
   (화산귀환) — 200; `totalCount 185`, newest free `174화` (`no 180`), paid
   to `179화` (`no 185`), `finished: false`, `dailyPass: false` (finding 3).
5. `GET https://shonenjumpplus.com/rss` — 200, `application/rss+xml`, 108
   items, `pubDate` `Sat, 12 Sep 2026 15:00:00 +0000`, title shapes as listed
   in finding 4.
6. `GET https://comic.naver.com/api/article/list?titleId=183559&page=1`
   (Tower of God) — 200; `totalCount 653`, `dailyPass: false`, 20 listed,
   newest `3부 235화` `25.02.02`, `no 654` (open question 2; confirms the
   morning's numbers).

One scratch script (`swift tz.swift`, ~5 s, one core) checked the app's
RFC-822 formatter against the five date strings above; it is not a build of
the project.
