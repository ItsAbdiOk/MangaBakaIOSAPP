# Deep review — synthesis

2026-09-13. Six read-only slice reviews, 87 raw findings, 77 after de-duplication.
Focus of the run: data-shape assumptions that fail on real inputs — parsers, matchers,
regexes, date and number readers, "first result wins", and fixtures that are one happy
example — prompted by the two bugs found this morning (`df43edc`: Square Enix's
"Title 01 (Manga)" rejected by the Apple Books matcher; `434af07`: a cumulative Naver
count compared against a per-season episode number). This pass read all six reports,
the charter, and `SUMMARY-2026-09-11.md`. Nothing was built, run, or edited beyond this
file. Every line two reports both cite was read in the source before being merged.

Ids used throughout, because three reports numbered their findings 1–n:

| prefix | slice | file | raw | merged away |
|---|---|---|---|---|
| `W` | wire — `Core/Networking`, `Core/Model`, `Core/Auth` | `wire.md` | 12 | — |
| `T` | third parties — `Core/Volumes`, `Core/Characters`, `Core/Persistence`, `Core/Images`, `Core/History`, `Core/Notifications` | `third-parties.md` | 14 | T3+F15, T6+F16, T8+F5 |
| `R` | reader — `Core/Schedule`, `Core/Library` | `reader.md` | 16 | R2+F9, R3+F8, R11+F10, R13+S5 |
| `L` | library / discovery UI — `Features/{Library,Schedule,Discovery,Search,Mix,Stack,Browse,Shelf,Onboarding}` | `library-discovery-ui.md` | 11 | — |
| `S` | surface — `Features/Detail`, `Shared`, `DesignSystem`, `App` | `surface.md` | 15 | S4+W11, S7+W3 |
| `F` | tests — `MangaBakaTests`, `MangaBakaUITests` | `tests.md` | 19 | (see above) |

Nine merges: same file:line, same defect, found from two sides. Reader's two dead
"Shonen Jump+" fallbacks (`GigaViewerFeedClient.swift:59`, `ReleaseSource.swift:31`) are
one finding (R15). Nothing was dropped.

**A process note before the findings.** Two of the six briefs named
`api.mangabaka.dev`. That host is dead — it answers HTTP 500 `"deprecated … switch to
https://api.mangabaka.org"` — and wire and surface each burned a third of their request
budget on it. The app already uses `.org` (`Configs/Base.xcconfig:7`). Fix the brief
template before the next run.

---

# 1. The three highest-value changes

Value is readers affected × how wrong the screen is; effort is what the reports say.
All three are certain from live requests made today, not from reading alone.

## 1. The Webtoons feed is trusted whatever shape it arrives in — R1 + R2 (+ R5)

**Two functions.** Webtoons is 59% of the library, and 84% of its links go through the
redirect that lands on a non-English edition (`WebtoonsFeed.swift:117-131`).

- **R1** — for completed and Daily Pass series the feed is the *oldest* handful, not the
  newest twenty. True Beauty (`title_no=1436`, ~230 episodes) answers Episode 0–7, all
  2018. Through `WebtoonsFeed.swift:58` (`latestEpisodeNumber` = max in feed) and
  `ReleaseSummary.swift:65-70` that prints "About every 7 days, very evenly · Ep. 7 · 19
  Sep" with no year (`ReleaseSection.swift:111-113`) — a confident schedule for a series
  that ended years ago, dated as if last week. With Naver answering, the gap line then
  says "600+ episodes ahead". `docs/release-sources-2026-09-12.md:82-83` recorded Lore
  Olympus as exactly this shape and said "do not trust a thin feed blindly".
- **R2** — the redirect lands on `/fr/`, `/id/` …; those feeds localise `pubDate`
  (`ven., 24 mars 2023`); the `en_US_POSIX` RFC-822 formatter (`WebtoonsFeed.swift:180-188`)
  returns nil; `:234` drops every entry; `:161-162` still calls it a feed;
  `WebtoonsFeedClient.swift:68-71` caches the empty feed for seven days; and because an
  answered-but-empty Webtoons feed is still `primary` (`ReleaseFeedService.swift:55-62`)
  the Naver fallback is skipped too. No section, no error, for a week. The doc knew
  (`release-sources-2026-09-12.md:85-86`: "take schedules from the English feed").
- **R5** rides along: `finished` is decoded (`NaverFeedClient.swift:88`), promised
  (`:6-10`), and read by nothing, so a completed Korean original reads as `.originalPaused`
  — "hasn't released since 2 Feb 2025", a hiatus that is a completion.

**Why first:** largest reach in the review, both defects produce a *claim* rather than a
blank, and the guard for R1 already exists as a test control
(`WebtoonsFeedTests.swift:48-52` checks the feed's max against `series.totalChapters`).
Promote it: a feed whose highest number is far below `totalChapters` or the reader's
`progressChapter` is the oldest-first shape and summarises to `.none`. For R2: rewrite
the language segment to `en` after the redirect and never cache a feed that parsed to
zero entries.

## 2. `founded`/`closed` are typed from two publishers that happen to have neither — W1

**Four lines plus two fixtures.** `PublisherRecord.founded: Int?`, `closed: Bool?`
(`Catalogue.swift:59-61`) and `PublisherDetail` the same (`PublisherDetail.swift:31-32`).
The spec types both `string|null, format: date`; the live search for "Kodansha"
returns `"founded": "2008-07-01"` on Kodansha USA. Both fixtures agree with the model
(`PublisherPageTests.swift:31` `"founded": 1997, "closed": true`;
`CatalogueTests.swift:121` `"founded":2005`).

**Effect:** `[PublisherRecord]` is one array under `try?` (`CatalogueService.swift:130`),
so any search whose results include a founded publisher returns nil and the browser says
"could not search" (`PublisherBrowser.swift:112`). The detail is under `try?` at `:126`,
so Kodansha USA's page opens with no record and no error. `PublisherDetail.swift:56-57`
("Since …", "Closed") have never rendered for anyone. Verified on Ize Press and Yen Press
only — both `founded: null` — which is exactly charter §1's tell.

**Why second:** it is the charter's founding pattern reproduced on an endpoint added
after the last review, the whole publisher feature is broken for every major publisher,
and the fix is `String?` twice and a year derived for `summary`.

## 3. "Anime adaptation: None listed" for a series with two seasons — S1

**One line (stopgap) or one decoded field.** `DetailCredits.swift:77-78` reads
`anime.exists == true ? "Yes" : "None listed"`. On `/v1/series/3397/full` today, `anime`
is `{start: "Chap 0 (S1) / Chap 46 (S2)", end: …}` with **no `exists` key**; the fact is
the sibling `has_anime: true`, which `Series.AnimeAdaptation` (`Series.swift:71-76`) does
not model. The page's fill is `/v1/series/{id}` (`SeriesRepository.swift:683`), and
`filling(gapsFrom:)` takes `anime ?? other.anime` (`Series.swift:214`), so every series
whose front copy lacks `anime` — every library entry, per `NonsenseGuardTests.swift:38-40`
— gets the v1 object and the wrong answer. `NonsenseGuardTests.swift:30` fixtures
`{"exists": true}`, the model's shape.

**Why third:** the most-visited screen, a false negative stated as fact under a comment
that forbids exactly that, and the comment beside it (`:71-76`) says it was verified on
2026-09-10 against a shape the v1 endpoint does not send — the open question in §6 is
which endpoint it *was* verified on.

**Three that nearly made it, each a line and each certain from a live request:** R3
(Naver `totalCount` counts articles and paid-ahead episodes — 화산귀환 `185` vs newest free
`174화` — so every no-season gap line overstates by 6–11; `ReleaseFeedService.swift:87-91`,
the branch this morning's fix left alone), T1 (the Japanese-store fallback's regex
requires whitespace before the number; Kodansha writes `進撃の巨人 (1)` — 0 of 34 match,
Shueisha 30 of 30; `AppleBooksVolume.swift:191`), and R4 (GigaViewer titles `[106話]`,
`[第１２２話]`, `[4375回]`, `[#96]` are rejected by `第[0-9]+話`; roughly a third of
`shonenjumpplus.com/rss`; `WebtoonsEpisode.swift:81`).

---

# 2. Cross-cutting findings

Each candidate was tested against all six reports. Instances are named with file:line;
a candidate with fewer than three instances across two slices is reported as not holding.

## X1. Matchers built from one publisher's shape — HOLDS, and it is the run's headline

Eleven findings in four slices are one defect: a title or number rule derived from the
first source it was written against, then run against sources that spell things
differently. The morning's Square Enix bug is the twelfth.

| rule | shape it was fitted to | shape that fails |
|---|---|---|
| `AppleBooksVolume.swift:191` JP bare pattern (**T1**) | Shueisha `呪術廻戦 30` (fixture `AppleBooksTests.swift:117-121`, ONE PIECE only) | Kodansha `進撃の巨人 (1)`, `進撃の巨人(34)` — 0/34 live |
| `AppleBooksVolume.swift:198` EN pattern (**F3**) | Yen Press, Square Enix, J-Novel Club | Seven Seas `… (Manga) Vol. 1` (bracket before marker); VIZ `Naruto, Vol. 1: Uzumaki Naruto` (text after number) |
| `AppleBooksVolume.swift:118-119` title equality (**F4**) | exact title | `Berserk Deluxe Volume 12` — the test proves `split`, not the shelf |
| `AppleBooksVolume.swift:121,127` untagged accepted (**T4**) | tagged editions | J-Novel Club tags only from vol. 7; untagged novels 1–6 fill any comic gap |
| `AppleBooksVolume.swift:147`, `GoogleBooksVolume.swift:87` `contains("novel")` (**T8/F5**) | `(Light Novel)` | `(Graphic Novel)` |
| `GoogleBooksVolume.swift:83-88` (**T3/F15**) | "mirrors AppleBooksMatch" | has neither of this morning's Apple fixes; `language` decoded, never filtered |
| `WebtoonsEpisode.swift:81` `第[0-9]+話` (**R4**) | `[第33話] カテナチオ` (hand-shaped fixture, `GigaViewerFeedTests.swift:17-33`) | `[106話]`, `[第１２２話]`, `[4375回]`, `[#96]` — ~⅓ of the live feed |
| `WebtoonsEpisode.swift:72-75` `[0-9]+화` anywhere (**F6**) | `3부 235화` | `외전 3화` (side story) → episode 3 — the Afterword bug (`:25-30`) re-made in Korean |
| `WebtoonsEpisode.swift:110` `marksFinale` unanchored (**R11/F10**) | `(Season 1 Finale)` | `Episode 30: The End of Summer` → "season ended" |
| `MangaUpdatesClient.swift:56-59` `firstNumber` (**F17**) | `c.12 (end)` | `Extra 3` → chapter 3 → the season rule fires |
| `DisplayTitle.swift:67` first `-Latn` (**W2**) | one romanisation per series | series 638 has two `ko-Latn`; the untagged one wins over the `native` one the setting quotes |
| `LanguageFlag.swift:22-23` two letters = region (**W10**) | `pt-br` | `es-la` → "Spanish (Laos)", `ko-ro` → "Korean (Romania)" |

**The cause is the same in every row:** the fixture is the example that motivated the
rule (`AppleBooksTests.swift:20-38` "reduced" the live 60-row answer to the shapes the
model handles; `GigaViewerFeedTests.swift:12-37` is hand-written and undated), so the
test cannot fail on a shape the author did not think of. The three verbatim captures in
the repo (`knight-only-lives-today.rss`, `rising.json`, `library.json`) are the ones
nobody found a bug against. **Fix direction:** store the raw store/feed answer as the
fixture (tests F3, F11), and put the ranking once — extract `AppleBooksMatch.volumes`'s
rank-then-match so Google runs the same rule (T3). This is the previous review's X1
("a rule applied n−1 times") in its most expensive form, because each store adds a
new n.

## X2. Codable fields typed without a recorded payload — HOLDS, seven instances

| field | typed as | wire sends | evidence |
|---|---|---|---|
| `Catalogue.swift:59-61`, `PublisherDetail.swift:31-32` `founded`/`closed` (**W1**) | `Int?`/`Bool?` | `"2008-07-01"` | live today; spec `format: date` |
| `Series.swift:71-76` `AnimeAdaptation.exists` (**S1**) | the only fact field | v1 sends `has_anime` beside an `anime` with no `exists` | live 3397 today |
| `MangaUpdatesClient.swift:76-78` `Row.record` (**F1**) | non-optional wrapper | every stub in the suite is `{"results":[]}` — no row has ever been decoded in a test | schema agrees; untested |
| `NaverFeedClient.swift:93` `Article.no: Int` (**R12b**) | required | `:82-86` says it is never read; one null fails the feed | 60 articles, all present |
| `SeriesWork.swift:78-81` `release_date` (**W9**) | `yyyy-MM-dd` only | spec gives no `format`; one sample | open |
| `AppleBooksClient.swift:106-108` `.iso8601` on `releaseDate` (**T9**) | strict, for a field nothing reads | 53/53 end in `Z` today | open |
| `UpcomingWork.swift:71-75` no `count_type` (**F14**) | every work is "Vol." | schema has `main|extra|other` | untested |

Wire's evidence table (`wire.md` §Evidence) is the map: every type with a dated payload
is series-shaped; `PublisherRecord`, `Genre`, `Profile` have none. **The amplifier is
unchanged from 2026-09-11 (X2 half B):** W12 counts 6 in-slice `try? client.get` sites
and 19 app-wide; `genres()`/`tags()` (`CatalogueService.swift:47,78`) and the bundled
`TagTaxonomy.swift:42,46` still return `[]` on failure; `HistoryStore.swift:72` and
`LibrarySnapshot.swift:149-151` drop rows with `try?`. W1 and S1 were invisible for the
same reason the charter's four were.

## X3. "First match wins" over ambiguous lists — HOLDS, nine instances

- `DisplayTitle.swift:67` — first `-Latn` title (**W2**); two on series 638.
- `Series.swift:241` — first `native` title, script ignored (**W3/S7**); 3397 has four
  (`ko`, `ko-Latn`, `ja-Latn`, `ja`). If `ko-Latn` ever comes first, `coverLanguages`
  (`:281-282`) becomes `["en","ko-latn"]`, `SeriesDetailView+Covers.swift:73`'s
  `hasPrefix` drops every Korean cover, and `DetailHero.swift:301-306` bylines the
  romanisation. Works today by order; the order has already changed once since 09-10.
  The `-Latn` exclusion the comment at `DisplayTitle.swift:73-74` promises is applied to
  the second branch (`:76`) only.
- `CatalogueService.swift:119-123` — exact name else `hits.first` (**W11/S4**).
  `q=Ize Press (Yen Press)` → `[]` (Yen Press exists); `q=Kodansha` → Kodansha USA first,
  Kodansha third. Masked today by W1.
- `GoogleBooksVolume.swift:83-88` — first by number (**T3**).
- `AppleBooksVolume.swift:127` — first by number, untagged accepted (**T4**).
- `WebtoonsFeed.swift:58` — max number in whatever the feed sent (**R1**).
- `StackModel.swift:333,357-360` — `reacted.sorted().suffix(60)`: the sixty *highest
  ids*, not the sixty most recent (**L4**).
- `TrackerScores.swift:43-44` — highest/lowest from a `Dictionary`; ties by hash order
  (**S10b**).
- `StackSections.swift:68-70` — first three tags in wire order while `tagsV2` carries
  weights (**L11**).

**Cause:** none of these lists is documented as ordered, and the code already knows it —
`ReleaseSummary.swift:66-69` takes the latest episode by date "because nothing guarantees
feed order survived parsing", and `DisplayTitle.swift:88-93` records the English branch
needing a trait preference. The rule exists; it was applied to one branch.

## X4. Test decoders and fixtures that are not the production decoder or a live response — HOLDS, and it is why X1–X3 were green

- **The decoder** (**F2**): `Fixture.decoder()` (`FixtureLoading.swift:27-31`),
  `LibraryDecodingTests.swift:20-21`, `APIShapeContractTests.swift:25-29` build their own
  `JSONDecoder` with `.iso8601`; production is `APIClient.swift:12` (`private`) with a
  custom closure at `:32-46`. 42 + 10 call sites measure a different parser.
  "A real library response decodes" is true of a decoder the app never runs.
- **Fixtures built from the model:** `PublisherPageTests.swift:31`,
  `CatalogueTests.swift:121` (W1); `NonsenseGuardTests.swift:30` (S1);
  `ReleaseFeedServiceTests.swift:133-156` `totalCount: 140` as truth (R3/F8);
  `DisplayTitleTests.swift:18-23` "the real payload" — four titles of 34, omitting the
  one that fails (W2); `GigaViewerFeedTests.swift:12-37` hand-shaped, and `:50-58` asserts
  `!items.isEmpty` (F11); `CatalogueTests.swift:183-184` retry fixture with keys the
  endpoint does not send (F13); `AppleBooksTests.swift:20-38` reduced (F3);
  `CharacterSourceTests.swift:126,144` assert the fallback and never that the outage
  memory stayed clear (T2).
- **Fixtures with one state:** `Fixtures/library.json` — both entries `reading`, no
  rating, no finish (F12); every MangaUpdates stub `{"results":[]}` (F1); every Google
  item `language: "en"` (F15).

**Fix direction:** one function — `APIClient.makeDecoder()` static, called by
`Fixture.decoder()` — plus captured payloads with dates for the eight sites above. The
model to copy is `WebtoonsFeedTests.swift:7-11, 46-51, 65-73`: verbatim feed, dated, with
an independent control.

## X5. UTC/local date handling — HOLDS, four instances, one already solved in the model

- `ReadingWrappedYear.swift:47,70,140` — `finish_date` is `T00:00:00.000Z` by the schema
  (`mangabaka_openapi.json:29915-29927`); read through `Calendar.current` (**R6**). A
  1 January finish lands in the previous year west of UTC.
- `VolumesSection.swift:75,90,151` — `SeriesWork.date` parses UTC midnight and provides
  `utcYear(of:)` for this reason (`SeriesWork.swift:89-106`); the view reads
  `Calendar.current` (**S2**). Every volume a day early in the Americas.
- `APIClient.swift:35-45` — accepts date-time only; the schema says v2 will send
  `YYYY-MM-DD` (**R7**). Latent until the library moves.
- `WebtoonsFeed.swift:180-188` — the sibling: a locale, not a zone, but the same class
  (**R2**).

`UpcomingWork.swift:110-126` (`localDay`) and `SeriesWork.swift:156,166` already solve
it. Apply the same helper at the three view sites; this is the 2026-09-11 X1 pattern
again (the rule lives in a model comment and the view did not read it).

## X6. An empty answer cached as long as a good one — HOLDS, three instances (was nine on 09-11)

- `WebtoonsFeedClient.swift:68-71` — a feed that parsed to zero entries is cached for
  seven days (`:14`) (**R2**).
- `ReleaseFeedService.swift:55-62` — an empty Webtoons feed is still `primary`, so Naver
  is not asked (**R2**).
- `CharacterService.swift:79-81` — every `APIError.server` sets `aniListDownUntil` for
  15 minutes, and `AniListClient.swift:150-162` throws `.server` for "no cast" and
  "unknown id" (**T2**). One stale id blacks out AniList for every series page.

The previous instances (W9, R10, D-B3) are fixed and `CatalogueService.swift:43-45,
94-95` now declines to cache a failure. What is left is the same shape one layer up:
the *client* distinguishes failure from empty; the *service* above it collapses them.

## X7 (not a candidate; found here). A count used as an ordinal — four instances, the morning's bug generalised

- `ReleaseFeedService.swift:87-91` — `totalCount` (articles + paid) as the episode
  number (**R3**).
- `AppleVolumesRow.swift:77-82` — `expected > volumes.count` decides "N of M" without
  looking at which numbers the shelf holds (**S12**).
- `StackModel.swift:333` — series id as a proxy for recency (**L4**).
- `NaverFeedClient.swift:82-86` got it right (`no` is a position, not a number) and says
  so with the 654-vs-235 evidence — which is why R3 was findable.

## X8 (not a candidate). `Int(Double)` reachable from real input — three sites, the force-unwrap rule in another spelling

`Series.swift:121-122` via `lenientDouble` (`:344-345` accepts `"inf"`, `"nan"`,
`"1e400"` as strings, which `JSONDecoder` does not reject because they are strings —
**W4**); `APIError.swift:33,36` on an uncapped `Retry-After` (**W4/W8**);
`LibraryEditSheet.swift:120,233-235` on twenty typed digits or a pasted "inf" (**L2**);
and `APIClient.swift:269`, where `JSONSerialization` raises an ObjC exception for a
non-finite body that `try?` cannot catch (**W5**). Library-UI cleared its view sites on
the belief that the decoder rejects non-finite numbers; wire's point is that the string
path bypasses the decoder. Both are right; the string path is the one to close. The
four-agent "no force-unwraps" verification of 2026-09-11 does not cover this class.

**Recurrences of the 09-11 cross-cuts, in one line each:** X1 (rule applied n−1 times)
— S2, W3, R4 (`normalise` folds width for the series title, not the episode), R10
(`season` set in `run`, not `cadence(for:)`), T3, L7 (`chapterText` in the editor, not
the four lists). X3 (computed, read by nobody) — R5 `finished`, T3 `language`, T9
`price`/`releaseDate`, R12b `Article.no`. Duplicated constants — L8, S10, R8 (two
per-chapter rates, 4× apart, on one screen, and the binge ceiling depends on one of
them). Comment drift — W6, T3 ("mirrors" is stale), T11 ("200" is 40).

---

# 3. Everything, ranked by value to effort

77 findings. Effort in the reports' vocabulary: *line* / *lines* / *function* / *file* /
*fixture* / *decision*. Within a band, certain sits above likely above worth checking.
Read the bands, not the ranks.

**A (1–19): certain, broad, ≤ a function.** **B (20–37): certain or likely, narrower
reach.** **C (38–52): settled by one measurement or capture first.** **D (53–66):
real, needs a decision or a product answer.** **E (67–77): small, cosmetic, drift.**

| # | id | finding | file:line | conf | effort | slice |
|---|---|---|---|---|---|---|
| 1 | R1 | Oldest-first Webtoons feed summarised as a live weekly rhythm | `WebtoonsFeed.swift:58`; `ReleaseSummary.swift:65-70` | certain | function | reader |
| 2 | R2/F9 | Localised `pubDate` empties feed; cached 7 days; Naver skipped | `WebtoonsFeed.swift:180-188,234`; `WebtoonsFeedClient.swift:68-71`; `ReleaseFeedService.swift:55-62` | certain | function | reader/tests |
| 3 | W1 | `founded`/`closed` typed `Int?`/`Bool?`; wire sends date strings | `Catalogue.swift:59-61`; `PublisherDetail.swift:31-32` | certain | lines | wire |
| 4 | S1 | "None listed" anime on v1 shape; `has_anime` unmodelled | `DetailCredits.swift:77-78`; `Series.swift:71-76` | certain | line | surface |
| 5 | R3/F8 | Naver `totalCount` counts articles + paid; gap overstated 6–11 | `ReleaseFeedService.swift:87-91` | certain | line | reader/tests |
| 6 | T1 | JP-store pattern rejects Kodansha's bracketed numbers, 0/34 | `AppleBooksVolume.swift:191` | certain | line | third |
| 7 | R4 | GigaViewer titles without `第`, full-width, `回`, `#` rejected | `WebtoonsEpisode.swift:81` | certain | line | reader |
| 8 | T2 | One empty AniList cast blacks out AniList 15 min | `CharacterService.swift:79-81`; `AniListClient.swift:133-162` | certain | function | third |
| 9 | W2 | Romanised picks first `-Latn`; 638 has two | `DisplayTitle.swift:67` | certain | line | wire |
| 10 | S3 | "Story & art" credits the author with the art | `DetailCredits.swift:54-59` | certain | line | surface |
| 11 | S2 | Volume dates parsed UTC, shown in device zone | `VolumesSection.swift:75,90,151` | certain | lines | surface |
| 12 | R6 | Wrapped reads UTC-midnight finish dates in local calendar | `ReadingWrappedYear.swift:47,70,140` | certain | line | reader |
| 13 | R5 | `finished` decoded, never read; completion reads as hiatus | `ReleaseFeedService.swift:73-105`; `NaverFeedClient.swift:88` | certain | line + case | reader |
| 14 | T3/F15 | Google matcher lacks the Apple fixes; `language` never filtered | `GoogleBooksVolume.swift:83-88`; `GoogleBooksClient.swift:50-54` | certain | function | third/tests |
| 15 | L2 | "+1" traps on twenty digits or "inf" | `LibraryEditSheet.swift:120,233-235` | certain | line | lib-ui |
| 16 | W5 | Non-finite body raises ObjC exception under `try?` | `APIClient.swift:269` | certain | line | wire |
| 17 | W4 | `Int(Double)` on wire values; `lenientDouble` accepts "inf" | `Series.swift:121-122,344-345`; `APIError.swift:33,36` | certain | line each | wire |
| 18 | L3 | Unparseable chapter text silently clears progress | `LibraryEditSheet.swift:242-244` | certain | function | lib-ui |
| 19 | F2 | Contract tests use a decoder the app never runs | `FixtureLoading.swift:27-31`; `APIClient.swift:12` | certain | function | tests |
| 20 | R8 | Two per-chapter rates, 4× apart, one screen; binge ceiling tied | `ReadingInsights.swift:120-128`; `ReadingTime.swift:21-28` | certain | file | reader |
| 21 | R9 | Removed series keeps taste weight until sign-out | `TasteLedger.swift:73-100,216-217` | certain | function | reader |
| 22 | R10 | Detail-page cadence never gets its season; settled row blocks it | `ReleaseSchedule.swift:354-357,287-289` | certain | line | reader |
| 23 | L1 | A–Z rail emits duplicate letters (Ō) → duplicate `ForEach` id | `LibrarySort.swift:82-85`; `LibraryModel.swift:155-161` | certain | line | lib-ui |
| 24 | L5 | Wrapped critic caveat names the wrong series | `WrappedView.swift:177-178` | certain | function | lib-ui |
| 25 | W11/S4 | `findPublisher`: composite names miss; else first hit | `CatalogueService.swift:119-123` | certain/likely | function | wire/surface |
| 26 | T5 | `shikimori.one` 301s to `.io` through a DDoS guard | `SeriesCharacter.swift:125,92,298` | certain | line | third |
| 27 | S8 | `ReadingPlatforms` hides Piccoma; admits portal roots | `ReadingPlatforms.swift:38-42,64-95` | certain / w.c. | line + function | surface |
| 28 | F1 | No test decodes a MangaUpdates list with a row in it | `MangaUpdatesClient.swift:76-78` | certain | fixture | tests |
| 29 | F12 | `library.json` is one state: reading, unrated, unfinished | `Fixtures/library.json` | certain | fixture | tests |
| 30 | F11 | GigaViewer fixture hand-shaped; `descriptionDropped` cannot fail | `GigaViewerFeedTests.swift:12-37,50-58` | certain | fixture | tests |
| 31 | F4 | "Berserk Deluxe" test proves `split`, not the shelf | `AppleBooksTests.swift:147`; `AppleBooksVolume.swift:118-119` | certain | line + decision | tests |
| 32 | R13/S5 | Release rows keyed by timestamp; launch batches collide | `ReleaseSection.swift:62` | likely | line | reader/surface |
| 33 | T4 | Untagged novels fill the comic's missing numbers | `AppleBooksVolume.swift:121,127` | likely | lines | third |
| 34 | F3 | Apple fixture one publisher per rule; Seven Seas/VIZ rejected | `AppleBooksTests.swift:20-38`; `AppleBooksVolume.swift:198` | likely | lines | tests |
| 35 | L6 | Continuations walk restarts on every library page | `LibraryView.swift:138-140`; `Continuations.swift:107-129` | likely | line | lib-ui |
| 36 | L4 | Exclusions send the 60 highest ids, not most recent | `StackModel.swift:333,357-360`; `ShelfStore.swift:64-68` | likely | function | lib-ui |
| 37 | W3/S7 | `nativeLanguage` accepts `-Latn`; cover fan empties by order | `Series.swift:241,281-282`; `DisplayTitle.swift:75` | likely | line | wire/surface |
| 38 | R11/F10 | `marksFinale` matches "the end" anywhere | `WebtoonsEpisode.swift:110` | likely | line | reader/tests |
| 39 | F6 | Naver `readKorean` accepts side stories as episodes | `WebtoonsEpisode.swift:72-75` | likely | line + decision | tests |
| 40 | F17 | MangaUpdates "Extra 3" is chapter 3 | `MangaUpdatesClient.swift:56-59` | likely | line | tests |
| 41 | F7 | `(season?, nil)` pairing untested; goes `.none` | `ReleaseFeedService.swift:86-96` | certain untested | tests | tests |
| 42 | S6 | No year on release dates; no completed-series guard | `ReleaseSection.swift:111-113`; `ReleaseSummary.swift:49-74` | likely | line + function | surface |
| 43 | W10 | `LanguageFlag.name` turns `es-la`/`ko-ro` into countries | `LanguageFlag.swift:22-23` | certain | line | wire |
| 44 | W7 | `+` in a query reaches the server as a space | `SearchQuery.swift:76,89,92`; `APIClient.swift:374` | w.c. | line | wire |
| 45 | W8 | `Retry-After` honoured uncapped; HTTP-date form ignored | `APIClient.swift:183`; `RateLimitGate.swift:35-43` | w.c. | line | wire |
| 46 | W9 | `release_date` parsed as `yyyy-MM-dd` only | `SeriesWork.swift:78-81,92-98` | w.c. | line | wire |
| 47 | R7 | v2 will send `YYYY-MM-DD`; decoder throws | `APIClient.swift:35-45` | w.c. | line | reader |
| 48 | T9 | One bad `releaseDate` sinks 200 rows for a field nothing reads | `AppleBooksClient.swift:106-108`; `AppleBooksVolume.swift:20,23` | w.c. | line | third |
| 49 | T6/F16 | Shikimori nested/unlisted BBCode reaches screen and translator | `ShikimoriDescriptionParser.swift:26,34-40` | w.c. | function | third/tests |
| 50 | T7 | AniList dialect wider than three markers | `CharacterProfile.swift:120,126` | w.c. | function | third |
| 51 | T8/F5 | "(Graphic Novel)" read as a novel | `AppleBooksVolume.swift:147`; `GoogleBooksVolume.swift:87` | w.c. | line | third/tests |
| 52 | S15 | Lowercased script code handed to ICU | `LanguageFlag.swift:17,24` | w.c. | line | surface |
| 53 | T10 | Three filters assembled by hand in four places | `SeriesRepository.swift:601-605,441-449`; `+Paging.swift:44-56`; `+Count.swift:25-33` | certain | function | third |
| 54 | W12 | `genres()`/`tags()`/`TagTaxonomy` return `[]` on failure | `CatalogueService.swift:47,78`; `TagTaxonomy.swift:42,46` | certain | function | wire |
| 55 | R12 | Naver: no year guard; `no` required and unread | `NaverFeedClient.swift:127,93` | w.c. / certain | line each | reader |
| 56 | T13 | Reminder constants unlabelled; `nudgeDates` outlive the account | `ReleaseReminders.swift:182,196,199,231-233` | certain / likely | line each | third |
| 57 | T12 | History filters by rating only; drops rows silently | `HistoryStore.swift:58-64,72,74-78` | certain | lines + decision | third |
| 58 | L7 | Chapter progress truncated in four lists, kept in editor | `LibraryList.swift:142`; `PickBackUp.swift:95`; `ReadingInsightsView.swift:174`; `ShelfDetailView.swift:229,237` | certain | line each | lib-ui |
| 59 | L9 | Volume progress hides chapter progress in the row | `LibraryList.swift:134-142` | w.c. | line | lib-ui |
| 60 | L10 | Mix filter chips fire a blend per tap (D-A3 on record) | `MixFilterStrip.swift:156,161,168` | certain | function | lib-ui |
| 61 | L11 | Stack caption shows first three tags in wire order | `StackSections.swift:68-70` | w.c. | function | lib-ui |
| 62 | S12 | `countLine` compares a count with a number | `AppleVolumesRow.swift:77-82` | w.c. | line | surface |
| 63 | S9 | Publisher names sent and titled untrimmed | `DetailCredits.swift:134,169`; `RootView.swift:302` | w.c. | line | surface |
| 64 | T11 | Google asks 40, comment says 200, never pages | `GoogleBooksClient.swift:75-78` | certain / w.c. | line or function | third |
| 65 | F18 | Two 429 back-off paths untested; `dailyPass` shape untested | `NaverFeedClient.swift:48-51`; `GigaViewerFeedClient.swift:105-108` | certain | tests | tests |
| 66 | F19 | 113 source-text assertions; three worth moving to values | `DetailFidelityTests.swift:313-322,165-168`; `AppleBooksTests.swift:253-267` | certain | hour | tests |
| 67 | L8 | "three seconds apart" is a copy of `minimumInterval` | `ScheduleModel.swift:140-141` | certain | line | lib-ui |
| 68 | S10 | "within 5 points" stale copy; dictionary tie by hash | `TrackerScores.swift:118,43-44` | certain / w.c. | line | surface |
| 69 | S11 | "Oel" for OEL | `DetailHero.swift:278`; `DiscoverView.swift:262` | certain | line | surface |
| 70 | W6 | `SeriesEdition` comments name enums the spec lacks; raw `status` | `SeriesEdition.swift:34-37,63` | certain | lines | wire |
| 71 | F13 | Retry fixture uses keys the tag endpoint does not send | `CatalogueTests.swift:183-184` | certain | line | tests |
| 72 | F14 | Upcoming works never carry `count_type`; art books are "Vol." | `ReleaseCalendarTests.swift:8-22`; `UpcomingWork.swift:71-75` | w.c. | line | tests |
| 73 | S14 | Publisher sheet keyed by name | `DetailCredits.swift:168` | w.c. | line | surface |
| 74 | S13 | `compact` prints "1000.0k" | `DetailStatsStrip.swift:132-133` | certain | line | surface |
| 75 | T14 | Birthday hand-formatted from `monthSymbols` | `AniListClient.swift:418-425` | certain | line | third |
| 76 | R14 | `staleAfter = 14 days` has no guess label | `ReleaseSchedule.swift:87-89` | certain | line | reader |
| 77 | R15 | Dead "Shonen Jump+" fallback, two places | `GigaViewerFeedClient.swift:59`; `ReleaseSource.swift:31` | certain | line | reader |

---

# 4. Verdict per slice

Default is fix in place. Every agent again reported findings it could only make because
of a dated comment (`ReleaseFeedService.swift:76-84`, `NaverFeedClient.swift:82-86`,
`PublisherDetail.swift:4-8`, `SeriesWork.swift:89-106`, `WebtoonsEpisode.swift:25-34`).
A rewrite deletes that evidence, and nothing in this run argues for one.

## wire — fix in place

Twelve findings, all lines, none structural. W1 is four lines and two fixtures. W2, W3,
W4, W5, W10 are a line each. The slice's evidence table is the best artefact in the
review and should become the standard for the other five. The one thing to *add* rather
than fix: `APIClient.makeDecoder()` exposed (F2) — it belongs here even though the
finding is in tests.

## third parties — fix in place, with one extraction that is not optional

Fourteen findings; T1, T5, T8, T9, T14 are lines. **The extraction: T3.** Google's
matcher is a stale copy of Apple's, missing two fixes already, and "mirrors
AppleBooksMatch deliberately" (`GoogleBooksVolume.swift:68-70`) is the duplicated-constant
hazard in code form. Pull rank-then-match out of `AppleBooksMatch.volumes` into one
function both stores call, then T1/T4/T8/F3/F4 are fixed once. Bump both cache keys in
the same commit, as `df43edc` did. T2 is a function and changes the error taxonomy in
`AniListClient` (refused vs answered-nothing) — do it before adding any third source.

## reader — fix in place. Explicitly do not rewrite.

Sixteen findings, the highest count again, and the best comments again.
`ReleaseFeedService.swift:76-84` records this morning's measurement with the numbers
and what was ruled out; that is why R3 took an hour. **One function, not a rewrite, for
R1:** promote the `WebtoonsFeedTests.swift:48-52` control into `ReleaseSummary` — a feed
whose max is far below `totalChapters` or `progressChapter` is oldest-first. **One
function for R2** in `WebtoonsFeedClient` (rewrite the language to `en`; never cache
zero entries). **One file for R8:** a single rate table, both call sites, and the binge
ceiling restated in chapters — fixing the duplication without re-deriving the ceiling
reopens the 09-11 R14. Everything else is a line.

## library / discovery UI — fix in place

Eleven findings; L1, L2, L6, L7, L8 are lines. L3 (an invalid chapter string is a
"clear") is a function and the only one that changes behaviour a reader can see; it
needs the locale question in §6 answered first. L4 needs `ShelfStore` to expose a
timestamped or rowid-ordered query — one function. The two "not findings" the report
cleared (`name_path` split, rating scales) are recorded so nobody re-raises them.

## surface — fix in place

Fifteen findings; S1, S2, S3, S11, S13 are lines. The charter-6 audit found nothing to
replace: `ScrollEdge` is already on record (S-F4/S-F20, 09-11) and the detail page
correctly uses `.scrollEdgeEffectStyle(.hard)`; `DetailBarTitle`, `TapTarget`, `Motion`,
`FlowLayout` are justified with reasons written in the files. `EdgeSwipeToDismiss` and
`InlineSearchField` are the cost of choosing sheets over pushes — a design decision, not
a defect.

## tests — fix in place, plus five captures

Nineteen findings and one structural change: F2, which is one function in `APIClient`
and zero changes at 52 call sites. The rest is capture work: a verbatim iTunes answer for
Solo Leveling GB (F3), `tonarinoyj.jp/rss` (F11), a `/fr/` Webtoons feed (R2/F9), a
MangaUpdates list with rows (F1), two more `library.json` entries (F12 — it closes the
evidence gap under the 09-11 R13/R19/L8 at once). F19's three rows are an hour. Do not
convert the whole-tree scans or the absence assertions — the report is right that a
value test cannot do what they do.

---

# 5. What recurred from 2026-09-11, and what is new

**Fixed since, confirmed in the code by the slice that owns it:** W1, W3, W5, W7, W8,
W9, W11, W12, W14, W16 (wire, with W15 withdrawn in code); R6, R7, R10, R11, R15, R17
(reader); S-F1 (surface); D-A4, D-B2, L10 (todo, `de7b802`); P-F12 (`2f78286`); W13
(`APIShapeContractTests.swift:95-121` now derives its list from source);
`ShelfDetailView` re-wired (`LibraryView.swift:106`); the UI audit navigation bug
(`AccessibilityAuditTests.swift:143-157`).

**Recurred as a pattern, in new instances:**

- **X1 "rule applied n−1 times"** — six new instances (§2, closing paragraph). It is
  still the characteristic defect. The extraction in T3 and the helper in S2/R6 are the
  two places to move a rule out of a comment and into a call every site is forced
  through.
- **X2 half A "typed without a payload"** — W1 and S1 are the charter's founding bug on
  two endpoints added after the last sweep. The evidence-table discipline in `wire.md`
  is the guard; extend it to the satellite APIs (Naver, GigaViewer, MangaUpdates, iTunes).
- **X2 half B "failure = empty"** — count is down (19 `try? client.*` app-wide, 2 in-slice
  indistinguishable) but the shape moved up a layer: R2's empty-feed-is-primary and T2's
  no-cast-is-outage.
- **X3 "computed, read by nobody"** — R5 `finished`, T3 `language`, T9 `price`/
  `releaseDate`, R12b `Article.no`. All four are fields, which is new: on 09-11 they were
  properties and functions.
- **Duplicated constants / comment drift** — L8, S10, R8, W6, T3, T11. R8 is the costly
  one because the ceiling depends on the constant.
- **Still open from 09-11's list, unchanged:** R13/R19/L8 (fixture side is F12 here),
  R14 (R8 here reopens it), S-F5/S-F14/S-F17/S-F19/S-F6/S-F4 (measurement first, per
  `todo-next-week.md:164-166`), L7 (redesign), R24/D-A3/P-F10 (judgement). Two of the
  09-11 "not reachable" caveats were re-verified today: no force-unwraps (three slices),
  no `TODO`/`TEMP` (surface).

**New this run:**

- **X1 of this run — matchers fitted to one publisher.** Twelve instances; not visible
  on 09-11 because the store, Naver, GigaViewer and MangaUpdates matchers were all
  written on 09-12/13.
- **X5 UTC in views.** The model solved it; the views did not read the model.
- **X6 oldest-first feeds.** A source shape nobody had seen; recorded in a doc, not in
  code.
- **X8 `Int(Double)` traps** — the no-force-unwrap rule has a second spelling that the
  grep does not find.
- **Duplicate `ForEach` ids** — L1, R13/S5, S14: three instances of keying rows on a
  value the data does not guarantee unique.
- **`api.mangabaka.dev` is dead** and the review briefs still name it.
- **`shikimori.one` redirects** and the privacy list (`todo-next-week.md:79-80`) names the
  old host.

---

# 6. What the review could not determine

Every "likely" and "worth checking", with the one thing that settles it. Costs are the
reports' own. Search endpoints are 30 req/min shared per IP; do these in one sitting
and record every payload as a dated fixture.

## MangaBaka API (one session, ~10 requests)

| finding | measurement |
|---|---|
| S1 | `GET /v2/series/3397` — is `exists` a v2 field? Decides whether `AnimeAdaptation` needs both `exists` and `has_anime`. Also which endpoint `DetailCredits.swift:73` was verified on. |
| S1 | `GET /v1/series/3397` (not `/full`) — does the page's own fill carry `has_anime`? |
| W2/W3/S7 | Is `titles` order stable per series, and what orders it? Two GETs of 638 a day apart. It has already changed once since 09-10. |
| W7 | `q=%2BAnima` vs `q=+Anima`, `limit=1` — compare the first id. Two search requests. |
| W9 | `GET /v1/works/upcoming?limit=50` — any `release_date` not 10 characters? Also settles F14 (`count_type`) and the 09-11 R11 (window still 246?). |
| S9 | Does `/v1/publishers/search` trim `q`, and `/v2/series/search` trim `publisher=`? One request each with a trailing `%20`. |
| L11 | One `/v1/series/{id}` with both `tags` and `tags_v2` populated — is the flat list weight-ordered? |
| W10 | `grep` the 450-series sample from 09-12 for `-ro`/`-la` tags. No request. |
| W8 | One real 429 `Retry-After` header. Do not provoke it; capture the next one that happens. |
| W12 | `Profile` has never been captured; needs a token. Low. |
| L4 | Do series ids ascend with catalogue insertion? Compare ids of two series with known add dates. |

## Third-party hosts

| finding | measurement |
|---|---|
| R1 | Which Webtoons series return oldest-first? Survey ~20 feeds across ongoing / completed / Daily Pass; does `series.status == "completed"` predict it? |
| R2/F9 | Capture one `/fr/` and one `/id/` feed (7–20 KB) as fixtures; the `zh-hant` case is documented, Indonesian/Spanish/German/Thai are not. |
| R12a / F6 / F7 | One Naver `dailyPass` title — newest three or oldest three? And what the `articleList` carries besides episodes (외전, 후기, 프롤로그)? Does Naver write 부 for The Knight Only Lives Today? |
| F11 | `GET tonarinoyj.jp/rss` — what is in `pubDate`? The answer becomes the fixture. |
| F3 | One iTunes query each for a Seven Seas and a VIZ title. |
| T4 | A live series where the manga trails an untagged novel run. Apothecary Diaries is the shape but currently level. |
| T8/F5 | Does the store ever write "(Graphic Novel)" on a manga? One query for a Western-published title. |
| T5 | Is `shikimori.io` permanent, and does the app's UA pass the guard from a phone? A HEAD from a Mac is not evidence. |
| T2 | Does AniList answer `edges: []` or `errors` for a manga with no cast? Decides one branch or two. |
| T6/T7 | One Shikimori id with `[anime=…]`; one AniList id with `~~~` or `<br>`. |

## Device or run

| finding | measurement |
|---|---|
| R6, S2 | Simulator in `America/Los_Angeles`, one entry with `finish_date: 2026-01-01T00:00:00.000Z`, one volume dated `2021-01-01` — which year shows? |
| L3 | Which keyboards reach the chapter field: Arabic-locale number pad, hardware keyboard, paste. Decides whether "12,5" is reachable. |
| L6 | Count `/relationships` requests during one ten-page library load (signpost or `NetworkLedger`). Turns "likely" into a number. |
| R13/S5, L1, S14 | Duplicate-id rendering is undefined; a debug build with True Beauty's feed (three entries at `04:26:13`) or a library with "Ōoku" shows what SwiftUI does. |
| S15 | `Locale.current.localizedString(forScriptCode: "hant")` on device — nil or "Traditional"? |
| S12 | A store shelf with a numbering gap (volumes 1–14 and 30). |

## Decisions no measurement settles

- **T4 / F4** — does a comic's shelf ever show an untagged or deluxe edition when a
  tagged run exists? Finding T4 assumes no; F4 assumes editions are wanted.
- **T12** — is History "filtered by what the reader currently allows" meant to include
  formats and blocked tags (doc) or ratings only (code)?
- **T3/F15** — filter Google by `language` (the comment's promise) or drop the parameter
  from the signature and the key?
- **F6 / F17 / R4** — the Korean and Japanese episode-word allowlists (외전, 특별편,
  画目, 歩目, おまけ): count them as episodes, or not?
- **F19 row 1** — is `pageCap = 30` × `pageSize = 100` meant to be a 3,000 ceiling, and
  should the test say so as a number?

---

# 7. Proposed first batch

Lines and single functions only, grouped by file so one agent owns each file. Each
carries the test that proves it, with the real input. Per CLAUDE.md, every test is shown
failing before the fix. Fixtures named here are captured today's payloads, not typed.

**`Core/Model/Catalogue.swift` + `Core/Model/PublisherDetail.swift`** (W1)
- `founded: String?`, `closed: String?` in both; derive the year for `summary`.
- Test: `CatalogueTests.swift:121` and `PublisherPageTests.swift:31` changed to
  `"founded": "2008-07-01", "closed": null` (Kodansha USA, request 4 in `wire.md`).
  Both must fail first.

**`Core/Model/DisplayTitle.swift`** (W2)
- `:67` — prefer a `-Latn` title with a `native`/`official` trait, then any `-Latn`.
- Test: `DisplayTitleTests` with the full 34-title list from 638 today (both `ko-Latn`
  rows, untagged first); `.romanised` must return "Baekjakgaui Mangnaniga Doeeotda".

**`Core/Model/Series.swift`** (W3/S7, W4)
- `:241` — skip `-Latn` in `nativeLanguage`, or reduce to the primary subtag.
- `:121-122` — `Int(exactly:)`; `:344-345` — reject non-finite in `lenientDouble`.
- Tests: 3397's four native titles with `ko-Latn` moved first → `nativeLanguage == "ko"`
  and `coverLanguages` contains `"ko"`; a series row with `"year": "inf"` and
  `"rating_count": 1e19` decodes without trapping.

**`Core/Networking/APIClient.swift`** (W5, R7, F2; W7/W8 after §6)
- `:269` — `guard JSONSerialization.isValidJSONObject(body)` → `.transport`.
- `:35-45` — third fallback: `yyyy-MM-dd`.
- Expose `static func makeDecoder()`; `Fixture.decoder()` calls it.
- Tests: `LibraryChange` with `progressChapter: .infinity` throws, does not crash;
  `"start_date": "2026-08-27"` decodes; `library.json` decodes through `makeDecoder()`.

**`Core/Model/LanguageFlag.swift`** (W10, S15)
- `:22-23` — gate `name(for:)` on `knownRegions` as `emoji(for:)` already is; capitalise
  the script subtag before ICU.
- Test: `"es-la"` is not "Spanish (Laos)"; `"ko-ro"` is not "Korean (Romania)";
  `"zh-Hant"` and `"zh-Hans"` differ.

**`Core/Model/SeriesEdition.swift`** (W6)
- Comment to the spec's enums; `SeriesStatus.label(for: status)` at `:63`.
- Test: `detail` for `status: "hiatus"` reads "On hiatus".

**`Core/Volumes/AppleBooksVolume.swift`** (T1, T8/F5, T4, F3, F4) — one agent, bump `v4-`
- `:191` — add `|\s*[（(](\d+)[)）]` alternative.
- `:147` — `contains("novel") && !contains("graphic")`.
- `:121,127` — once any accepted row for a title carries a tag matching the kind, drop
  untagged rows of that title.
- Tests: `進撃の巨人 (1)`, `進撃の巨人(34)` → 1, 34 (live request 2); `Naruto (Graphic
  Novel) Vol. 1` accepted for a comic; Apothecary Diaries rows `01 (Manga)`…`16 (Manga)`
  plus untagged `Volume 3` → volume 3 is the manga (request 1); Seven Seas `Mushoku
  Tensei: Jobless Reincarnation (Manga) Vol. 1` and VIZ `Naruto, Vol. 1: Uzumaki Naruto`
  each parse; `volumes(in:titles:["Berserk"])` on `Berserk Deluxe Volume 12` asserts
  whichever the decision is.

**`Core/Volumes/GoogleBooksVolume.swift`** (T3/F15, T8) — bump `v1-`
- Route through the extracted Apple ranking; filter on `language` when given.
- Test: fixture with `language: "fr"` item at a number the shelf lacks → rejected when
  `language: "en"` is asked; `"The Apothecary Diaries: Volume 1"` untagged ranked first
  does not beat `"… 01 (Manga)"`.

**`Core/Volumes/AppleBooksClient.swift`** (T9)
- Drop `releaseDate`/`price` from the model, or decode the date as `String?`.
- Test: a 200-row envelope with one `releaseDate` of `2026-09-13T10:00:00.123Z` still
  yields 199 volumes.

**`Core/Characters/CharacterService.swift` + `AniListClient.swift`** (T2)
- Carry "refused" vs "answered nothing"; only a 403/5xx/transport sets `aniListDownUntil`.
- Test: `fallsBackOnEmptyCast`, then a second series must still ask AniList (stub
  records the request). Fails today.

**`Core/Characters/SeriesCharacter.swift`** (T5)
- `:125` base URL to `shikimori.io`; update `docs/todo-next-week.md:79-80`.
- Test: `URLProtocolStub` sees no request to `shikimori.one`.

**`Core/Schedule/ReleaseFeedService.swift`** (R3, R5, R1's guard)
- `:87-91` — prefer `naver.latestEpisodeNumber`; `totalCount` only when no title parsed.
- `gap` reads `finished` → new `.originalComplete` case.
- Tests: `ReleaseFeedServiceTests.swift:133-156` refixtured to 화산귀환 (`totalCount 185`,
  newest `174화`) → gap uses 174, and fails first; Naver `finished: true` with a stale
  last date → `.originalComplete`, not `.originalPaused`.

**`Core/Schedule/ReleaseSummary.swift`** (R1)
- Feed max far below `totalChapters` (or `progressChapter`) → `.none`.
- Test: True Beauty feed (Ep. 0–7, 2018; request 2 in `reader.md`) with
  `totalChapters ≈ 230` → `.none`; the Knight fixture with its own count still `.rhythm`
  (the existing control at `WebtoonsFeedTests.swift:48-52`).

**`Core/Schedule/WebtoonsFeedClient.swift` + `WebtoonsFeed.swift`** (R2/F9)
- After the redirect, rewrite the language segment to `en` and fetch that first; never
  `writeCache` a feed with zero entries.
- Test: the `/fr/fantasy/estatedeveloper/rss?title_no=5188` capture as a fixture — the
  client fetches `/en/…` first, and a feed parsed to zero entries is not cached.

**`Core/Schedule/WebtoonsEpisode.swift`** (R4, R11/F10, F6)
- `:81` — fold width, then `第?[0-9]+(話|回)` and `#[0-9]+`.
- `:110` — anchor: inside parentheses or at end; drop bare "the end".
- `:72-75` — decision on Korean episode words, then the allowlist.
- Tests: `[第１２２話]ふつうの軽音部` → 122, `[106話]クソ女に幸あれ` → 106, `[4375回]猫田びより`
  → 4375, `[#96]ゴーストフィクサーズ` → 96 (request 5); `"Episode 30: The End of Summer"`
  is not a finale, `"Episode 112 (Season 1 Finale)"` still is; `"외전 3화"` is not
  episode 3.

**`Core/Schedule/NaverFeedClient.swift`** (R12)
- `:127` — `guard parts[0] < 100`; `:93` — `let no: Int?` or delete.
- Test: an article with `"no": null` still decodes the feed.

**`Core/Schedule/ReleaseSchedule.swift`** (R10, R14)
- `:354-357` — set `season` in `cadence(for:)` via the helper `run` uses.
- `:87-89` — `GUESS` label.
- Test: Tower of God opened via `cadence(for:)` first → `season == 3`.

**`Core/Schedule/MangaUpdatesClient.swift`** (F17, F1)
- `:56-59` — episode-word rule for "Extra"/"Side Story"/"Omake".
- Test: `"Extra 3"` after `"c.120"` is not a sample; and a captured 2–3 row
  `{"results":[{"record":…}]}` decodes through `releases(seriesNumber:)`.

**`Core/Library/ReadingWrappedYear.swift`** (R6) and **`Features/Detail/VolumesSection.swift`** (S2)
- UTC calendar for `.year`/`.month`/`.day`; expose `SeriesWork.utcYear` or format with
  `.timeZone(.gmt)`.
- Test: `finish_date: 2026-01-01T00:00:00.000Z` in `America/Los_Angeles` counts in 2026;
  volume `2021-01-01` shows 2021.

**`Features/Detail/DetailCredits.swift`** (S1, S3, S14)
- `:77-78` — `exists == true || start != nil` now; `hasAnime` decoded next.
- `:54-59` — "Story" when artists differ, `Set` compare.
- `:168` — key by index.
- Tests: `NonsenseGuardTests` with the 3397 `/full` `anime` object (no `exists`,
  `has_anime: true`) → "Yes", fails first; `authors: ["Chu-Gong"]`, `artists:
  ["Seong-Rak Jang"]` → rows "Story" and "Art"; `["A","B"]` vs `["B","A"]` → one row.

**`Features/Detail/ReleaseSection.swift`** (R13/S5, S6)
- `:62` — `id` by index; `:111-113` — add the year when not this year.
- Test: True Beauty's three entries at `04:26:13` render three rows; a 2018 date prints
  "19 Sep 2018".

**`Core/Model/CatalogueService.swift`** (W11/S4)
- Try the parenthetical and pre-parenthetical halves; drop `?? hits.first` or require a
  prefix match.
- Tests: `"Ize Press (Yen Press)"` → Yen Press; `"Kodansha"` with the three live rows →
  Kodansha, not Kodansha USA; `"Kodansha Comics"` → nil rather than Kodansha USA.

**`Features/Library/LibrarySort.swift`** (L1)
- `indexLetter` folds diacritics and buckets non-Latin scripts.
- Test: `["Oshi no Ko", "Ōoku", "Ouran"]` → `jumpTargets` has one "O".

**`Features/Library/LibraryEditSheet.swift`** (L2; L3 after §6)
- `:120,233-235` — clamp before `Int`, or format with `.number.precision(...)`.
- Test: chapter `"99999999999999999999"` then "+1" does not trap; pasted `"inf"` does not
  reach `Double`.

**`Features/Schedule/ScheduleModel.swift`** (L8), **`Features/Detail/TrackerScores.swift`** (S10), **`Features/Detail/DetailHero.swift` + `Features/Discovery/DiscoverView.swift`** (S11), **`Features/Detail/DetailStatsStrip.swift`** (S13), **`Core/Model/ReadingPlatforms.swift`** (S8 Piccoma line), **`App/RootView.swift`** (S9 trim), **`Core/Characters/AniListClient.swift`** (T14), **`Core/Notifications/ReleaseReminders.swift`** (T13 labels), **`Core/Schedule/GigaViewerFeedClient.swift` + `ReleaseSource.swift`** (R15)
- One line each; tests: the interpolated constant appears in the string; `"1000.0k"`
  never prints (999,999 → "1.0m"); `"oel"` → "OEL"; `piccoma.com` is offered; a trailing
  space is not sent; a French locale prints "4 mars".

**`MangaBakaTests/`** (F12, F13, F11, F7, F18)
- Two more `library.json` entries (completed + rated + finished; dropped), redacted the
  same way; `CatalogueTests.swift:183-184` keys to `merged_with`/`name_path`;
  `tonarinoyj.jp/rss` captured verbatim replacing the hand-shaped GigaViewer fixture;
  `(season?, nil)` and `(nil, season?)` pairing tests from the Knight fixture; the Naver
  and GigaViewer 429 tests copied from `MangaUpdatesSpacingTests`.

**Held back from the batch, on purpose:** R8 (a file, and the ceiling must be re-derived
with it), R9 (a function with a diff against `TasteSource`), L3/L4/L5/L6 (function each,
one needs a §6 answer), T6/T7 (functions; unverified impact), T10 (refactor), F19 (an
hour, separate), and everything in §6's decision list.
