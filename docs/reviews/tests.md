# Deep review — the tests

2026-09-13. Read-only. Charter pattern 2 (tests that agree with the bug) applied
to `MangaBakaTests/**` and `MangaBakaUITests/**`, with the day's focus: fixtures
that are one happy example. Nothing was built, run, edited or fetched.

## Scope

121 test files. **Read in full (14):** `AppleBooksTests`, `WebtoonsFeedTests`,
`NaverFeedTests`, `GigaViewerFeedTests`, `ReleaseCalendarTests`,
`ReleaseFeedServiceTests`, `CatalogueTests`, `LibraryDecodingTests`,
`APIShapeContractTests`, `SourceTestGuardTests`, `FlowAffordanceTests`,
`FixtureLoading`, `SourceTree`, `GoogleBooksTests` (matcher + decoding suites).
**Read in part (20):** `DetailFidelityTests`, `AccessibilityTests`,
`CharacterSourceTests`, `ShikimoriCharacterProfileTests`, `SeasonReadingTests`
(release-row suite), `ScheduleServiceTests`, `CadenceTests`, `SeriesWorkTests`,
`SeriesExtrasTests`, `CommunityPulseTests`, `SeriesWebLinkTests`,
`WireNullabilityTests`, `SeriesDecodingTests`, `CoverTests`, `WrappedFixtures`,
`SeriesFactory`, `ReadingPlatformsTests`, `LinkGroupingTests`,
`AccessibilityAuditTests` (UI), `MangaUpdatesSpacingTests`. All five files under
`Fixtures/` were inspected. **Not opened (87):** the rule and view-model suites
(Wrapped, Insights, Taste*, Library*, Mix*, Search*, Stack*, Reminder, Motion,
DesignToken, and the rest). Their fixtures are built from the model by
construction (`WrappedFixtures.swift:19-45`); the question for them is F15 below.

Production files were read only where a claim about a test needed the rule it
guards: `AppleBooksVolume.swift`, `GoogleBooksVolume.swift`, `WebtoonsEpisode.swift`,
`WebtoonsFeed.swift`, `NaverFeedClient.swift`, `GigaViewerFeedClient.swift`,
`ReleaseFeedService.swift`, `ReleaseCalendar.swift`, `UpcomingWork.swift`,
`MangaUpdatesClient.swift`, `APIClient.swift:25-46`, `LibraryEntry.swift`,
`ShikimoriDescriptionParser.swift:1-40`, and the two OpenAPI schemas under
`docs/schemas/`.

Already established and not re-derived: W13 (the hand-typed endpoint list) is
fixed — `APIShapeContractTests.swift:95-121` now derives the list from source.
The `FlowAffordanceTests` and `AccessibilityTests` greps the charter names are
gone or rewritten (`FlowAffordanceTests.swift:5-15` records why). The UI audit
navigation bug (charter 5) is fixed at `AccessibilityAuditTests.swift:143-157`.
`SeriesMergeTests.swift:29` was cleared by the 2026-09-11 control (SUMMARY §7).

Confidence tally: **certain 13, likely 5, worth checking 5.**

---

## Findings, by value

### F1. No test decodes a MangaUpdates release list with anything in it

- **What** — Every MangaUpdates stub in the suite answers `{"results":[]}`. The
  `results[].record` wrapper and the `prefix(limit)` truncation have never seen
  a row.
- **Where** — `MangaUpdatesSpacingTests.swift:35`, `ScheduleServiceTests.swift:60`,
  `SecurityTests.swift:16,39`, `RecommendationQualityTests.swift:132` (all
  `{"results":[]}`); wrapper at `MangaUpdatesClient.swift:76-78`; the only row
  decode is standalone, `SeasonReadingTests.swift:124-138`, which builds a bare
  `Release`, never a `SearchResponse`.
- **Why it matters** — `Row.record` is non-optional. A row without `record`, or
  a wrapper key change, throws `APIError.decoding` for the whole answer, and
  `ReleaseScheduleService` reads that as a cadence it cannot estimate (SUMMARY
  R7). Every series on the Schedule tab goes "unavailable" at once, and every
  test stays green — the charter's pattern 1 tell (a wrapper decoded with no
  payload beside it), on the endpoint that feeds the whole cadence feature.
- **Effort** — one captured 2–3 row response as a fixture file, one test through
  `releases(seriesNumber:)` against `URLProtocolStub`. The schema
  (`docs/schemas/mangaupdates_openapi.json`, `ReleaseSearchResponseV1`) agrees
  with the wrapper, so this is a guard, not a bug report.
- **Confidence** — certain that it is untested; likely harmless today.

### F2. The contract tests decode with a decoder the app never uses

- **What** — "A real library response decodes" and the v1/v2 shape tests use a
  test-built `JSONDecoder` (`convertFromSnakeCase` + `.iso8601`), not
  `APIClient`'s, whose date strategy is a private custom closure.
- **Where** — `FixtureLoading.swift:27-31`; `LibraryDecodingTests.swift:20-21`;
  `APIShapeContractTests.swift:25-29`; production: `APIClient.swift:12`
  (`private let decoder`) and `:32-46`. 42 `Fixture.decoder()` call sites plus 10
  hand-rolled decoders in tests, against one production decoder.
- **Why it matters** — `library.json` carries `"2026-08-27T00:00:00.000Z"`
  (fractional seconds). The production strategy tries with-fraction then plain
  and throws its own error otherwise; `.iso8601` is a different parser. A date
  the app's decoder rejects — or a strategy change in `APIClient` — is not what
  these "real response decodes" tests measure. Pattern 5: the denominator is a
  different decoder.
- **Effort** — make the decoder a `nonisolated static func makeDecoder()` on
  `APIClient` and have `Fixture.decoder()` call it. One function, 52 call sites
  unchanged.
- **Confidence** — certain.

### F3. The Apple Books fixture is one publisher per rule, and the reduction hides the rest

- **What** — Each numbering rule is proved on the publisher that motivated it
  (Yen Press, Square Enix, J-Novel Club, the French edition, the JP store) and
  the live 60-result answer is "reduced" rather than stored. Two publisher
  conventions are absent and, by reading the regex, rejected outright: Seven
  Seas' `"Mushoku Tensei: Jobless Reincarnation (Manga) Vol. 1"` (the kind
  bracket *before* the marker) and VIZ's subtitled `"Naruto, Vol. 1: Uzumaki
  Naruto"` (text after the number).
- **Where** — `AppleBooksTests.swift:20-38` (reduced), `:40-64`, `:113-130`;
  the pattern at `AppleBooksVolume.swift:198` requires the bracket to trail and
  `\s*$` after it.
- **Why it matters** — exactly the Square Enix shape of 2026-09-13: a whole
  publisher's catalogue produces an empty shelf and the suite is green. Seven
  Seas is one of the three largest English manga publishers.
- **Effort** — two fixture lines, each shown failing first. Store the verbatim
  iTunes answer as `Fixtures/solo-leveling-gb.json` the way the Webtoons RSS is
  stored, so the next reduction cannot pick only the shapes the model handles.
- **Confidence** — likely. The two shapes are the publishers' known
  conventions, not a response recorded in this repo — which is the point.

### F4. `"Berserk Deluxe Volume 12"` proves `split`, not the shelf

- **What** — The test asserts `split(...).number == 12` and stops. `split`
  captures the title as `"Berserk Deluxe"`, so `volumes(titles: ["Berserk"])`
  drops it; the deluxe edition is invisible on the Berserk page and the test
  says the opposite.
- **Where** — `AppleBooksTests.swift:147`; `AppleBooksVolume.swift:118-119`
  (`wanted.contains(normalise(parts.title))`).
- **Why it matters** — omnibus/deluxe editions ("Berserk Deluxe", "Vinland
  Saga Deluxe", "3-in-1") are how several long series are sold on the store.
- **Effort** — one assertion (`volumes(in:titles:["Berserk"])` is empty) and a
  product decision on whether editions belong on the shelf.
- **Confidence** — certain.

### F5. `(Graphic Novel)` reads as a novel

- **What** — `isNovelTag` is `tag.contains("novel")`; no fixture carries a
  tag other than comic/novel/Manga/Light Novel.
- **Where** — `AppleBooksVolume.swift:147`; fixtures `AppleBooksTests.swift:25-32,
  49-55`.
- **Why it matters** — a comic tagged "(Graphic Novel)" is dropped from a comic
  series and offered to a novel one.
- **Effort** — one fixture line.
- **Confidence** — worth checking whether the store uses that suffix; the rule
  is certain by reading.

### F6. Naver's Korean numbering is "any N화", the rule the Webtoons parser rejected

- **What** — `readKorean` matches `[0-9]+화` anywhere in the title, so a side
  story `"외전 3화"` or a special `"특별편 2화"` is episode 3 or 2. The Naver
  fixture has only `"3부 235화"`/`"3부 236화"`; the title tests have only the
  happy `"235화"` and `"3부 235화"`.
- **Where** — `WebtoonsEpisode.swift:72-75`; `NaverFeedTests.swift:19-20`;
  `WebtoonsFeedTests.swift:120-125`.
- **Why it matters** — this is the Afterword bug (`WebtoonsEpisode.swift:25-30`,
  "an allowlist of the episode word, not a test for a number") reintroduced on
  the Korean side. A side story at the top of a Naver list reports the original
  as episode 3, and `TranslationGap` then says the translation is ahead of the
  original. Pattern X1 from the summary: a rule applied n−1 times.
- **Effort** — one fixture line per non-episode form; the fix is a decision
  about Korean episode words.
- **Confidence** — likely. Naver lists 외전/후기/프롤로그 in the same
  `articleList`; not recorded in this repo.

### F7. The feed pairing that exists in the repo is never run through the service

- **What** — The Knight fixture's `latestSeason` is 1 *only* because
  `readSeason` reads "Season 1" out of the finale note `"Episode 112 (Season 1
  Finale)"`; every other title is season-less. Paired with a Naver feed whose
  titles carry no 부, `gap()` hits `default: return .none`. No test covers
  `(season?, nil)` or `(nil, season?)`.
- **Where** — `WebtoonsEpisode.swift:88-90`; `ReleaseFeedService.swift:86-96`;
  `ReleaseFeedServiceTests.swift:50-63` covers only 2-vs-3; the RSS fixture's
  own test at `WebtoonsFeedTests.swift:77-83`.
- **Why it matters** — the section goes silent for a series that has just
  finished a season — the case the finale rule was written for.
- **Effort** — two tests built from the existing fixture and `episode()` helper.
- **Confidence** — certain for the untested branch; whether Naver names 부 for
  that series is worth checking.

### F8. `totalCount` is a count of articles, and the fixture shows it

- **What** — The Naver fixture's newest `no` is 654 and `totalCount` is 653:
  the count is article-based. The `(nil, nil)` branch uses `totalCount` as the
  original's episode number, and its test builds `totalCount: 140` as truth.
- **Where** — `NaverFeedTests.swift:15,19`; `ReleaseFeedService.swift:87-91`;
  `ReleaseFeedServiceTests.swift:133-156`.
- **Why it matters** — a non-seasoned series with a prologue, notices and side
  stories reads as N episodes ahead when it is level. The one fixture where
  `totalCount` is the right number is the only one.
- **Effort** — one captured response for a non-seasoned series with a
  non-episode article, then a test.
- **Confidence** — worth checking.

### F9. Unparseable Webtoons dates vanish, and no fixture has one

- **What** — An `<item>` whose `pubDate` fails RFC-822 is dropped silently and
  `parse` still returns a feed. The docs record zh-hant localising dates
  (`週二, 08 9月 2026`) and the placeholder redirect lands on `/fr/` and `/id/`
  editions; no fixture is anything but the English feed, and no test says what a
  feed of twenty unparseable dates becomes.
- **Where** — `WebtoonsFeed.swift:234`; `WebtoonsFeedTests.swift:183-195`
  (redirect to `/fr/` proved, its feed never parsed);
  `docs/release-sources-2026-09-12.md` "Non-English".
- **Why it matters** — the five-in-six recovery (`WebtoonsFeed.swift:117-127`)
  routes exactly those readers to non-English feeds, whose output is either
  fine or an empty feed indistinguishable from "no releases". Pattern 1 half B.
- **Effort** — capture one `/fr/` feed (7–20KB) as a fixture; one test that a
  feed with no parseable dates is reported, not emptied.
- **Confidence** — certain that it is untested; impact worth checking.

### F10. `marksFinale` matches the substring "the end"

- **What** — `"(?i)finale|final episode|(?i)the end"` is a substring match. The
  only negative control is `"Episode 111"`.
- **Where** — `WebtoonsEpisode.swift:110`; `WebtoonsFeedTests.swift:82`.
- **Why it matters** — `"Episode 30: The End of Summer"` marks the season
  ended; the reader is told "Season ended" instead of "late" — the opposite
  claim, which is the exact reason the rule exists (`WebtoonsFeed.swift:70-76`).
- **Effort** — one assertion line; a word-boundary fix.
- **Confidence** — certain by reading; frequency likely.

### F11. The GigaViewer fixture is the model's own shape

- **What** — Hand-written, undated, and the only place the RSS `pubDate` format
  is asserted. The docs record the JSON `publishedAt` (ISO 8601) and the item
  title shape, never an RSS `pubDate`. `[最終話]` and `[番外編]` forms are
  absent. And `descriptionDropped` asserts `!items.isEmpty`, which cannot fail.
- **Where** — `GigaViewerFeedTests.swift:12-37` (fixture), `:50-58` (the
  no-op test); formatter `GigaViewerFeedClient.swift:188-194`;
  `docs/release-sources-2026-09-12.md` "Japanese publishers".
- **Why it matters** — if the real feed writes `+0900` or a Japanese weekday,
  every item is dropped at `:243` and the seven-host adapter is dead on arrival
  while green. The Webtoons fixture is verbatim precisely so this cannot happen
  there.
- **Effort** — capture one `tonarinoyj.jp/rss` verbatim; replace
  `descriptionDropped` with a fixture containing an `<img>` in `<description>`
  and an assertion on the parsed item's fields.
- **Confidence** — certain that the shape is unrecorded.

### F12. `library.json` is one reading state, no rating, no finish

- **What** — Both captured entries are `state: reading`, `rating: null`,
  `finish_date: null`, `progress_volume: null`, `note: null`, `Entries: []`.
  Every rule that turns on rating, finish date or a terminal state is tested
  only on model-built entries.
- **Where** — `Fixtures/library.json`; `WrappedFixtures.swift:19-45`;
  `LibraryDecodingTests.swift:80-86` asserts only `.reading`/17/20.
- **Why it matters** — SUMMARY R13 (finish date on a drop), R19 (rating 0 vs
  null) and L8 (fractional `progress_chapter`) are all open *because* no
  recorded payload shows those fields populated. The fixture side of those
  three findings is this one.
- **Effort** — one more captured entry (completed, rated, finished; a dropped
  one), redacted the same way. One fixture edit closes the evidence gap for
  three open findings.
- **Confidence** — certain.

### F13. Retry fixture uses keys the tag endpoint does not send

- **What** — `merged_into` and `full_name`; the wire is `merged_with` and
  `name_path` (schema `V1_Series_Tag`), which the same file's `tagPayload` gets
  right.
- **Where** — `CatalogueTests.swift:183-184` vs `:52-64`.
- **Why it matters** — passes because every field is optional; it proves the
  retry against a payload that has never existed. Small, but it is the file
  the summary points to as the tag-shape reference.
- **Effort** — one line.
- **Confidence** — certain.

### F14. Upcoming works never carry `count_type` or an omnibus sequence

- **What** — The schema's `count_type` (`main|extra|other`) and
  `sequence_string` example `"1-5"` are absent from every fixture; `volume`
  prefixes `"Vol. "` to whatever arrives.
- **Where** — `ReleaseCalendarTests.swift:8-22`; `UpcomingWork.swift:71-75`;
  `docs/schemas/mangabaka_openapi.json` `V1_Work_Default`.
- **Why it matters** — an art book or guidebook in the window is announced as
  "Vol. 1".
- **Effort** — one fixture line; a `count_type` field.
- **Confidence** — worth checking whether the window sends non-main works.

### F15. Google Books decodes `language` and no fixture varies it

- **What** — every item is `language: "en"`. The matcher does not filter on it
  and Apple's blurb rule has no Google equivalent, so a French "Hunter x Hunter,
  Vol. 1" passes here and is rejected there. Also `VolumeInfo` has no
  `subtitle`, and Google splits title/subtitle for some publishers.
- **Where** — `GoogleBooksTests.swift:11` (default `"en"`), fixture `:110-120`;
  `GoogleBooksVolume.swift:16, 84-93`.
- **Why it matters** — the shelf is Apple's plus "any number only Google has"
  (`AppleBooksTests.swift:272-274`), so a foreign Google edition fills a gap
  Apple deliberately left empty.
- **Effort** — one fixture line with `language: "fr"`; the test then records
  whichever behaviour is intended.
- **Confidence** — likely (language); worth checking (subtitle).

### F16. Shikimori: no test for a tag outside the handled set

- **What** — `[anime=ID]`, `[manga=ID]`, `[person=ID]`, `[img]`, `[list]` are
  documented Shikimori BBCode not in the nine-id sample; the parser's stated
  failure mode is literal brackets reaching the translator, and nothing
  exercises it.
- **Where** — `ShikimoriDescriptionParser.swift:14-20` (the honest provenance);
  `ShikimoriCharacterProfileTests.swift:71-125` (all tags in the sample).
- **Effort** — one test with an unhandled tag asserting what the reader sees.
- **Confidence** — likely.

### F17. MangaUpdates chapter text: "Extra 3" is chapter 3

- **What** — `firstNumber` takes the leading digits of any chapter string; the
  only decorated fixture is `"c.12 (end)"`. `"Extra 3"`, `"Side Story 2"`,
  `"Omake"` are ordinary MangaUpdates chapter strings.
- **Where** — `MangaUpdatesClient.swift:56-59`; `SeasonReadingTests.swift:147-152`.
- **Why it matters** — a side story becomes a `SeasonReading.Sample` at chapter
  3 after chapter 120; the season rule (charter 4) fires on it.
- **Effort** — one fixture line; the fix is the episode-word rule again.
- **Confidence** — likely.

### F18. Two 429 back-off paths have no test

- **Where** — `NaverFeedClient.swift:48-51`, `GigaViewerFeedClient.swift:105-108`.
  MangaUpdates' has one (`MangaUpdatesSpacingTests.swift`). Also untested:
  Naver's `dailyPass` shape (three public entries, below `Cadence.minimumDates
  = 4` at `Cadence.swift:79`), the one shape the docs call out as thin.
- **Effort** — one test each, copied from the MangaUpdates one.
- **Confidence** — certain.

### F19. Tests that assert on source text — 113 reads in 34 suites

`SourceTestGuardTests` gates them all; the problem is what they measure. Their
failure mode is a rename, and a stub with the right name satisfies them
(`FlowAffordanceTests.swift:9-11` records the last time that bit). Those where
the pinned value is a computed value that could be a `nonisolated static` and
asserted directly:

| Where | Pins | Could be |
|---|---|---|
| `DetailFidelityTests.swift:313-322` | parses `pageCap = ` out of `LibrarySnapshot.swift` because `:22-23` are `private static`; asserts `cap > 10` | `LibrarySnapshot.pageCap * pageSize >= 937`. As written, `pageSize = 20` passes with a 600-entry ceiling — the wrong denominator again |
| `DetailFidelityTests.swift:165-168` | `blur(radius: 72`, `saturation(1.7)`, `opacity(0.34)`, `scaleEffect(1.6)` as text | four `static let`s on `DetailBackdrop` (or `Metrics`), asserted as values |
| `AppleBooksTests.swift:253-267` | the JP-fallback `if` and the "couldn't be reached" string | a pure `static func storeAnswer(home:japanese:) -> (volumes, note)` — the sibling test at `:236-246` already does it right for `countLine` |
| `AccessibilityTests.swift:52-55, 59-63` | `accessibilityAction(named: "Save")`, the token `accessibilityReduceMotion` | the UI test that presses the action (`FlowAffordanceUITests`) |
| `AccessibilityTests.swift:245-249` | `allowsHitTesting(false)` anywhere in `Metrics.swift` | a view test on the modifier |
| `CoverLayoutTests.swift:35-57` | `.frame(width: width, height: height)`, `.overlay { CoverGloss(radius: radius) }` | layout values |
| `SeriesWebLinkTests.swift:50-56`, `ReleaseSectionWiringTests.swift:13-22`, `DetailFidelityTests.swift:176-179, 294, 331, 383-404` | call-site text (`shareURL: SeriesWebLink.url(for: shown)`, `loadReleases()`, `await store.reload()`, `"Copied"`) | wiring; the honest version is `DetailFidelityTests.swift:425-441`, which asserts the *absence* of the wrong call as well |

Not every one should move — the absence assertions and the whole-tree scans
(`MotionTests.swift:79-88`, `DesignTokenTests.swift:45-54`,
`AccessibilityTests.swift:32-47`) are doing something a value test cannot. The
first three rows are the ones worth an hour.

---

## Done well

- **Verbatim fixture with a control.** `Fixtures/knight-only-lives-today.rss`
  is the live feed, dated (`WebtoonsFeedTests.swift:7-11`); the series was
  chosen *because* it is the awkward case. `cadenceControl` (`:65-73`) re-runs
  the estimate with the afterwords left in to prove the 7 is the series'
  rhythm, and `agreesWithCatalogue` (`:46-51`) checks the number against an
  independent source. That is CLAUDE.md's control rule, applied.
- **Fixtures that keep the disagreement.** `NaverFeedTests.swift:19-20` keeps
  `no: 654` beside a title that says 236, and `:34-36` says why.
  `AppleBooksTests.swift:40-45` records the phone observation, the store's
  relevance order and the wrong cover it produced. `GoogleBooksTests.swift:50-66`
  keeps the Ize Press item with no `imageLinks` and adds the positive control.
- **Proof-by-revert written into the test.** `ReleaseCalendarTests.swift:70-94`
  and `CatalogueTests.swift:151-168` each state the bug, fail without the fix,
  and `CatalogueTests.swift:46-49` explains the earlier false pass ("a cache
  that stored the response and returned [] passed this before").
  `ReleaseCalendarTests.swift:162-168` records that the fixture agreed with the
  bug.
- **Per-test network stubs with a clock.** `URLProtocolStub.setHandler` +
  `defer { reset() }` + `TestClock` + a fresh cache directory per client
  (`AppleBooksTests.swift:156-162`, `NaverFeedTests.swift:91-97`,
  `GigaViewerFeedTests.swift:90-96`), and `.serialized` where the stub is shared.
  Cache-life tests advance the clock rather than sleeping.
- **A test on the tests.** `SourceTestGuardTests.swift:20-74` reads every suite
  for an ungated source read, and `:76-82` guards its own accessor. The header
  names the two builds it cost.
- **The sweep derives its list from source.** `APIShapeContractTests.swift:95-121`
  is the W13 fix done properly, with the old failure named at `:85-87`.
- **Honesty about what cannot be verified.** `CharacterSourceTests.swift:7-13`
  says the AniList shapes come from the schema, not a response, and what would
  slip through. `GoogleBooksTests.swift:77-80` says the `fife` test proves the
  parameter is appended, not that Google honours it.
  `ShikimoriDescriptionParser.swift:14-20` lists the nine ids and separates
  observed tags from documented ones.
- **Fixture hygiene.** `Fixture.data` throws on a missing file rather than
  returning empty (`FixtureLoading.swift:5-14`); `SeriesFactory.swift:5-8`
  records the three times a new field broke every suite.
- **Absence asserted, not only presence.** `DetailFidelityTests.swift:425-441`
  is the right shape for a source-text test: it fails on the wrong wiring as
  well as on missing wiring, which a stub cannot satisfy.
- **The `countLine` test** (`AppleBooksTests.swift:236-246`) is the model for
  F19: the view's computed value asserted directly, no source read.

## Open questions

1. Are Seven Seas and VIZ listed on Apple Books in the forms F3 names? One
   iTunes query each settles it; no network was used here.
2. Does Naver write 부 for "The Knight Only Lives Today", and what does its
   article list carry besides episodes (F6, F7, F8)? One request.
3. What does `tonarinoyj.jp/rss` actually put in `pubDate` (F11)? One request,
   and the answer becomes the fixture.
4. Does a `/fr/` or `/id/` Webtoons feed localise `pubDate` the way `zh-hant`
   does (F9)?
5. F19's first row: is `pageCap = 30` with `pageSize = 100` meant to be the
   3,000 ceiling, and should the test say so as a number?
6. The 87 files not opened are rule suites over model-built entries. F12 is
   the cheapest way to find out whether any of their rules disagree with a
   real payload: add the entries, then run the existing suites against a
   decoded `library.json` instead of `WrappedFixtures`.
