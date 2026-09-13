# Search page — deep review synthesis

2026-09-13. Synthesis of the six slice reports in this directory, read against the charter
(`.claude/skills/deep-review/charter.md`). Nothing here was re-derived from source; every
`File:line` is quoted from the report named beside it. Report ids: **UX** = ux-ia.md,
**E** = engine.md, **C** = catalogue.md, **R** = results-motion-a11y.md, **T** = tests.md,
**LW** = live-walk.md. "LW ✔" marks a finding the simulator walk saw on screen.

The owner's ask: "everything related to the search page — optimised, UI that makes sense, an
amazing experience."

---

## 1. Counts

- Raw: **74** findings — UX 14, E 14, C 10, R 15 (+4 minors), T 13, LW 8 observations (3 of the
  8 are re-sightings of code findings).
- Same defect seen from several slices (14 merges):
  - idle chip dead-end: UX#1 + UX#13 ("0 shown" is its side effect) + LW §1 chip-tap
  - discarded `FeedResult.total`: E F1 + R F13
  - frozen 429 countdown on `StaleBar`: R F9 + T#2
  - year filter never sent: UX#3 + E F6
  - preview count at `.userInitiated`: UX#9 + E F3
  - debounce constants, three owners: E F10 + E F12 + T#8 (→ 2 findings)
  - genres sent as `tag=`: C#2 + C#7 + LW Genres-sheet inconsistency
  - hand-rolled field: UX#6 + R F5 (field scrolls away)
  - sub-44pt controls: R F6 + R F8
  - × leaves filters/sort behind: UX#5 + LW §1 Type-survives-×
  - recents under-record: UX#10 + LW §2
  - two tag fetches: C#10 folds into C#3
- **Deduped: 60** findings. Of those, 6 are LW ✔ on-screen confirmations; 1 LW observation
  (sub-2-character queries) has no code explanation in any report — see §7.
- Done-well items: 40 across the six reports. The state machine being one pure tested function
  (`SearchEmptyState.swift:17-41`, R) is why the top fix below is one branch.

## 2. Cross-cutting causes

**A. Screen state is derived from `query.isEmpty`, not from what was actually requested.**
`contentKind` (`SearchEmptyState.swift:27-31`) has three inputs — query empty, searching,
results — and none for "the reader has asked" or "a request is pending". `SearchQuery.isEmpty`
(`SearchQuery.swift:52-57`) counts filters as content. Explains: UX#1 (chip tap → "Nothing
matched", LW ✔), UX#13 ("0 shown"), UX#5/LW (× runs a filter-only search instead of returning to
idle, LW ✔), E F4 ("Nothing matched" during the 300 ms debounce), R F1 (grid replaced by skeleton
on every debounced request, `SearchModel.swift:171` + `SearchEmptyState.swift:28`), R F10
(`hasMore` not reset per search, `SearchModel.swift:171-179`, so the "end" haptic fires on a
new query). Tests pin the wrong states: `SearchScreenTests.swift:197-209` (T, UX#1, E F4).

**B. Computed, then discarded or re-fetched.** `pagination.count` decoded at
`SeriesRepository+Paging.swift:68`, never read by `SearchModel` (E F1, R F13); the sheet then
spends a `limit=1` request to ask again (`FilterPanel.swift:121`). No memory of the last
answered query (E F2, `SearchView.swift:139-142`; E F8 untrimmed `q`, `SearchQuery.swift:97`;
E F5 double request on lens apply, `SearchModel.swift:123-127`). `Tag.level/namePath/
contentRating/isSpoiler` decoded and unread in the picker (C#4, C#5, C#6, `Catalogue.swift:22-36`).
`CoverQuickActions` built, tested, unreachable (R F3). `OfflineCatalogue.count` exists and the
offline toggle still hits the network (UX#2, `FilterPanel.swift:281-294`).

**C. The model and the wire never met (charter #1 in both directions).** Year fields exist
and are not sent though the schema has `published_start_date_lower/upper` (UX#3, E F6,
`SearchQuery.swift:22-29`); genres go out as `tag=` and find 6–14% of `genre=` (C#2, live-measured
2,017 vs 34,220); "Match any" sends nothing and the API ignores `tag_mode` anyway (C#1, three
live measurements); `sort_by=random` without `random_seed` (E F7); no page-100 cap (E F9);
every 429 fixture invents `Retry-After` (T#1, `RateLimitTests.swift:169` says GUESS); **no
recorded `/v2/series/search` payload exists** (T#12).

**D. Request budget spent by things that are not searches.** Preview counts run at
`.userInitiated` on the 30/min window (E F3, UX#9, `LensCounts.swift:143`), with their own 350 ms
debounce in the view (E F12, `FilterPanel.swift:288`), even offline (UX#2); Return re-sends an
answered query (E F2). Lens counts were correctly moved to `.background` the same day
(`LensCounts.swift:95-99`) — the fix exists, one call site missed it. Nothing tests the priority
arrives (T#11, `SeriesRepository+Priority.swift:32-34`).

**E. Constants fitted to one device, one guess, or three copies.** 111pt card width in four
files, derived from a 393pt phone (R F11); three columns regardless of type size (R F4, 523pt
into 357pt at AX); 300/350/250 ms debounces with no derivation (E F10, T#8); `perGroup = 8`
(C#4); `limit = 30` unexplained (E F10).

**F. Tests that pin literals, source text, or invented shapes.** Debounce tests pass with
the debounce deleted (T#7); `familyScopedBackoff`'s "second assertion" is a `try?` (T#3);
`countsOncePerLens` asserts before the `Task` runs (T#6); `cardsWidenWithText` greps for
`scaledWidth` while the grid overlaps (R F4, `AccessibilityTests.swift:131-136`); the audit
never opens Search (R F2, `AccessibilityAuditTests.swift:121-136`); `FormatFilterTests` and
`RequestBudgetTests` promise Search and test Discover (T#10); nine source-text tests (T#13).

**G. Two vocabularies / two doors presented as one.** Genres ≠ tags but share `query.tags`
(C#2, C#7); Browse replaces the query while the pickers add to it (UX#11); "Surprise me" is
undone by typing while the Random chip is sticky (UX#11); Tags sheet has groups/counts/search,
Genres sheet is a flat list (LW ✔ §1); live tag page (4 roots) replaces the bundled 17 (C#3).

**H. Hand-rolled where the platform provides.** `TextField` in a box instead of
`.searchable` on the `role: .search` tab (UX#6, R F5, `SearchView.swift:123-177`,
`RootView.swift:240-246`), which is also why the field scrolls away, why there is no Cancel,
no scopes, no tokens, no suggestions, and why a fixed 40pt height had to be hand-set (R F6).
Ten headers at one weight (UX#7).

## 3. The three highest-value changes

**1. Give the state machine a fourth input: "asked", and keep the grid while searching.**
- Why: cause A is behind the headline defect. The filter builder Abdi asked for on 2026-09-12
  (`d344224`) breaks on the first tap (UX#1, LW ✔), and every debounced keystroke flashes
  skeleton → results (R F1) after briefly saying "Nothing matched" (E F4).
- What: `SearchModel` gains `hasAsked` (set in `search()`, cleared when text empties) and
  `isPending` (set at `SearchModel.swift:145`, cleared at `:171`); `contentKind` returns `.idle`
  when `!hasAsked`, `.results` when `isSearching && !results.isEmpty`, treats pending as
  searching; `hasMore` reset at the top of `search()`; × clears `sort == "random"` and returns
  to idle. Heading hidden when count is 0.
- Effort: a function (`contentKind`) + 6 lines in `SearchModel` + 4 tests that fail first.
- Gain: the idle panel works; typing stops flickering; "0 shown / Nothing matched" gone.

**2. Keep what the response already carries, and route every count through the model at
background priority.**
- Why: causes B and D. The reader never sees "411 results"; the sheet re-asks for a number
  it was handed; a slow filter-builder can 429 their own first search (E F3); Return costs
  two slots (E F2).
- What: `SearchModel.total` from `result.total`; `answered: SearchQuery` short-circuits an
  identical `search()`; `q` trimmed at `SearchQuery.swift:97`; `previewCount(for:)` moves
  into `SearchModel` with one debounce constant, `.background`, skipped when the query equals
  `answered`, and answered by `OfflineCatalogue.count` when `preferOffline` is on; heading
  "N results" (fallback "shown"). `appliedText` sentinel fix (E F5).
- Effort: a function in `SearchModel`, a file's worth of deletion in `FilterPanel`
  (`:277-294`), a line in `LensCounts.swift:143` as the interim.
- Gain: roughly half the search-window spend in a typical filter-then-search session, no
  self-lockout, a real total in the heading and on the sheet without a second request.

**3. Send what the API accepts, and stop drawing what it does not.**
- Why: cause C. Year is a first-class control that does nothing online; Genres under-report
  7–17×; "Match any" is a lie; random paging reshuffles.
- What: `SearchQuery` gains `genres: [String]` (sent `genre=`), year items
  (`published_start_date_lower/upper`), `randomSeed` (sent with `random`, cleared with `sort`),
  page cap 100; "Match any" removed until the API honours `tag_mode`; year captioned "offline
  only" until the live measurement lands. Each parameter needs one dated `curl` recorded
  beside the field (charter #1) before it ships.
- Effort: a file (`SearchQuery` + `OfflineCatalogue.passesGenre`) + small edits in
  `FilterPanel.swift:129`, `SearchModel.swift:396`, `TagPickerSheet.swift:190-191`.
- Gain: filters do what their labels say; a Romance search returns the catalogue, not 14% of it.

The `.searchable` redesign (§5) is the fourth. It is the biggest experience lift and needs a
prototype and Abdi's call on the no-navigation-bar trade made for all four tabs (UX#6).

## 4. Ranked list, value ÷ effort

Effort: L = line(s), F = function, Fi = file, R = redesign. Confidence as the reports gave it.

| # | Ids | What | File:line | Effort | Conf. |
|---|---|---|---|---|---|
| 1 | UX#1, UX#13, LW ✔ | Chip tap on idle flips to "Nothing matched"; `contentKind` has no "asked" input | `SearchEmptyState.swift:27-31`, `SearchQuery.swift:52-57`, `SearchView.swift:368-372` | F | certain |
| 2 | R F1 | Grid replaced by skeleton on every debounced request | `SearchModel.swift:171`, `SearchEmptyState.swift:28` | F | certain |
| 3 | E F4 | "Nothing matched" shown during the debounce | `SearchModel.swift:136-149`, `SearchEmptyState.swift:27-30` | L | certain |
| 4 | E F3, UX#9 | Preview counts at `.userInitiated` on the 30/min window; self-lockout path | `LensCounts.swift:143`, `SeriesRepository+Count.swift:17-19`, `FilterPanel.swift:288` | L | certain |
| 5 | UX#2 | Offline toggle on, count request still fired per chip | `FilterPanel.swift:281-294`, `OfflineCatalogue.swift:187` | L | certain |
| 6 | E F1, R F13 | `total` decoded and discarded; sheet re-fetches it; heading says "shown" | `SeriesRepository+Paging.swift:68`, `FilterPanel.swift:121`, `SearchView.swift:360-373` | F | certain |
| 7 | E F2 | Return re-sends the identical answered query | `SearchView.swift:139-142`, `SearchModel.swift:161-240` | L | certain |
| 8 | C#2, C#7, LW ✔ | Genres sent as `tag=`: 2,017 vs 34,220 for slice_of_life; offline drops them silently | `FilterPanel.swift:129`, `SearchModel.swift:396`, `SearchQuery.swift:101`, `OfflineCatalogue.swift:319-326` | Fi | certain (live) |
| 9 | UX#3, E F6 | Year drawn, counted as active, never sent; schema has the parameter | `SearchQuery.swift:20-28, 84-115`, `FilterPanel.swift:354-361` | F + 1 curl | likely |
| 10 | UX#5, LW ✔ | × after Surprise me / with a Type chip runs a filter-only search, not idle | `SearchView.swift:145-153`, `SearchModel.swift:133-135` | L | certain |
| 11 | R F9, T#2 | 429 over live results: frozen "Retrying in 30 s", no auto-retry; test asserts the string | `SearchView.swift:298-305`, `APIError.swift:314-321`, `FailureState.swift:139-165`, `SearchModelTests.swift:172` | F | certain |
| 12 | T#1 | All 429 fixtures invent `Retry-After`; without it the reader gets a static dead end | `RateLimitTests.swift:335-340, 414-416, 456-461`, `APIClient.swift:201-209` | L + measurement | certain unrecorded |
| 13 | C#1 | "Match any" sends nothing; API ignores `tag_mode` (164 either way) | `TagPickerSheet.swift:190-191`, `SearchQuery.swift:102-104` | L/F | certain (live) |
| 14 | R F2 | Accessibility audit never opens Search | `AccessibilityAuditTests.swift:121-136` | L | certain |
| 15 | R F6, R F8 | Field 40pt, Filters 40pt, Browse/Surprise 30pt — all under 44 | `SearchView.swift:156,170,209,417` | L | certain |
| 16 | R F4 | Three fixed columns overflow at AX sizes (523pt into 357pt); test greps source | `SearchView.swift:30-33`, `CoverImage.swift:255-260`, `AccessibilityTests.swift:131-136` | F | certain (maths) |
| 17 | R F10 | No visible end of results; `hasMore` not reset so the haptic lies | `SearchView.swift:76-80`, `SearchModel.swift:171-179, 383-384` | L ×3 | certain |
| 18 | UX#10, LW ✔ | Recents miss "typed, tapped a cover"; tapping a recent does not move it up | `SearchView.swift:140,258`, `SearchEmptyState.swift:47-51` | L | certain |
| 19 | LW ✔ | Filters button carries no badge when a filter is active | `SearchView.swift:160-175` (button); `SearchQuery.swift:66-72` has the count | L | observed |
| 20 | UX#7 | Ten headers at one weight; Search is the odd tab out | `SearchIdleView.swift:61,132,151`, `FilterPanel.swift:298-305`, `Typography.swift:112-120` | L | certain |
| 21 | R F7 | VoiceOver hears nothing on results or empty | `SearchView.swift:185-192`, `Skeleton.swift:100` | F | certain |
| 22 | E F5 | Lens/browse with text in the field: two requests, first answer discarded | `SearchModel.swift:123-127, 402, 412` | L | likely |
| 23 | E F8 | `q` untrimmed — trailing space is a new request | `SearchQuery.swift:97` | L | certain |
| 24 | E F7 | `random` without `random_seed`: page 2 is a reshuffle, "Stopped early" on 300k rows | `SearchQuery.swift:105`, `SearchModel.swift:354-357` | L | likely |
| 25 | E F9 | No page cap; page 101 is a permanent retry | `SearchModel.swift:325-351` | L | certain |
| 26 | C#3, C#10 | Live 500-tag page replaces the bundled 2,686 (17 roots → 4) | `TagPickerSheet.swift:338-345`, `CatalogueService.swift:69-101` | F | certain (live) |
| 27 | C#5 | Picker ignores content rating/spoiler/blocked; blocked pick returns 0 with no hint | `TagPickerSheet.swift:329,339`, `SeriesRepository.swift:731` | F | certain (live) |
| 28 | C#4 | Only level-2 tags browsable; Isekai unreachable; "N more" undercounts | `TagPickerSheet.swift:249-251, 282, 292` | L + F | certain |
| 29 | R F11 | 111pt literal in four files, right for 393pt phones only | `SearchEmptyState.swift:54`, `Skeleton.swift:85`, `MixResults.swift:137`, `PublisherView.swift:313` | Fi | certain |
| 30 | R F12 | Page 1 not deduped; skeleton grid does not match the results grid | `SearchModel.swift:227`, `Skeleton.swift:88` vs `SearchView.swift:30-33` | L | (a) check, (b) certain |
| 31 | R F14 | Cards past the sixth wait 270 ms after scrolling into view | `SearchEmptyState.swift:61-63`, `Motion.swift:60-69` | L | likely |
| 32 | R F15 | Card meta is type · score; no year/status to tell two matches apart | `SearchEmptyState.swift:52-57`, `CoverImage.swift:277-291` | F | likely |
| 33 | R F5 | Field scrolls away; new results land mid-list | `SearchView.swift:36-39`; no `.scrollPosition` | F (reset) / R (field) | likely |
| 34 | UX#6 | Hand-rolled field on the `role: .search` tab forgoes scopes/tokens/suggestions/Cancel | `SearchView.swift:123-177`, `RootView.swift:240-246`, `SearchClearButton.swift` | R | certain hand-rolled |
| 35 | E F10, E F12, T#8 | 300/350/250 ms debounces, two owners, none derived | `SearchModel.swift:146`, `FilterPanel.swift:288`, `TagSearch.swift:35` | F | certain |
| 36 | T#7 | Debounce tests pass with the debounce removed | `SearchModelTests.swift:83-97`, `TagSearchTests.swift:65-80` | L (2 tests) | likely |
| 37 | T#3 | `familyScopedBackoff`'s named assertion is a `try?` | `RateLimitTests.swift:80-83, 92, 100, 158` | L | certain |
| 38 | T#6 | `countsOncePerLens` asserts before the `Task` runs | `LensTests.swift:119-131` | L | certain |
| 39 | T#4 | Offline content-rating filter has no test | `OfflineCatalogueTests.swift:81-248`, `OfflineCatalogue.swift:264-268` | L (2 tests) | certain |
| 40 | T#9 | `searchDeduplicates` never checks pages requested; `stoppedEarly` untested | `PaginationTests.swift:91-106`, `SearchModel.swift:310` | L (2 tests) | certain |
| 41 | T#10 | "Format filter holds everywhere" / "30 req/min for search" test Discover only | `FormatFilterTests.swift:47-153`, `RequestBudgetTests.swift:47-91` | L (2 tests) | certain |
| 42 | T#11 | Nothing observes `LensCounts` asks at `.background` | `SeriesRepository+Priority.swift:32-34`, `LensTests.swift:224-293` | L | certain |
| 43 | T#5 | `showResultsIsOneSearch` cannot catch what its comment says | `SearchModelTests.swift:99-123` | F | certain |
| 44 | T#12 | No recorded `/v2/series/search` payload anywhere in Fixtures | `MangaBakaTests/Fixtures` | measurement | certain |
| 45 | T#13 | Nine source-text tests; two fragile ones (`inertUntilFiltered`, `tagsBeforeBlending`) | `LensTests.swift:324-328, 431-454` | L | certain |
| 46 | UX#11 | Browse replaces, pickers add; Surprise vs Random chip differ | `SearchModel.swift:390-406`, `FilterPanel.swift:75-83, 162-179` | product + Fi | certain behaviour |
| 47 | UX#8 | First-time screen: lens footnote before lenses exist; sheet copy says "top", they sit at bottom | `FilterPanel.swift:255-261`, `SaveLensSheet.swift:30`, `SearchIdleView.swift:46-49` | L | certain |
| 48 | UX#4 | Year-only lens named "Everything" | `SearchLens.swift:98-117` | L | certain |
| 49 | UX#12 | Lens silently overwritten; stale comments; `isOwn` unread | `SearchLens.swift:28-33, 71`, `LensCounts.swift:119-122` | L | certain |
| 50 | R F3 | `CoverQuickActions` complete, tested, presented nowhere | `CoverQuickActions.swift:1-182`, `CoverImage.swift:24,66` | product + L | certain |
| 51 | E F11 | One malformed row fails the whole page | `APIClient.swift:97-101`, `SeriesRepository+Paging.swift:70-76` | Fi | worth checking |
| 52 | E F14 | Offline `hasMore` uses the inference the online path was fixed to stop | `SearchModel.swift:281-284` | L | certain (fragility) |
| 53 | E F13 | Offline re-filters 19,300 rows per page | `OfflineCatalogue.swift:167-181, 231-258` | F (after measuring) | worth checking |
| 54 | C#6 | `Tag.level` root is 1 on the wire, 0 in doc and fixture | `Catalogue.swift:24-25`, `CatalogueTests.swift:55-57,73` | L | certain |
| 55 | C#8 | Local tag match diacritic-sensitive, offline title match is not | `TagSearch.swift:59` vs `OfflineCatalogue.swift:312` | L | certain |
| 56 | C#9 | `/v1/tags?q=` not in schema; relies on a 2026-09-10 measurement | `CatalogueService.swift:76-79,121-127` | none (record) | worth checking |
| 57 | UX#14 | `FilterSheet` doc names a caller that does not exist | `FilterSheet.swift:12-14` | L | certain |
| 58 | LW | Save-lens bookmark: silent on miss, felt small | `SaveLensButton` (in `FilterPanel.swift:255-261`) | L | worth checking |
| 59 | LW | Queries under ~2 chars render an unrelated grid labelled "30 shown" | unexplained — see §7 | ? | observed |
| 60 | LW | System AutoFill chip floats over results after lens tap | field `textContentType` (not cited) | L | minor |
| — | R minors ×4 | O(n) `firstIndex` per cell; no cover prefetch on page land; pager stops at 30; redundant `.isButton` | `SearchEmptyState.swift:46-83`, `CoverImage.swift:298` | L each | certain |

## 5. The "amazing experience"

What Search should feel like, drawn from the six reports' observations. Opinionated on purpose.

**First-time reader.** Tapping the Search tab should land the cursor in the field with the
keyboard up (the `role: .search` tab already exists, `RootView.swift:240-246`; today nothing
focuses, LW §1). Under the field, three things and only three: a row of scopes (All · Manga ·
Manhwa · Manhua · Novel — the "manga vs manhwa" ask in one tap, no panel), the Recent list as
`.searchSuggestions` that vanish once typing starts, and the filter builder with real section
headers (`typeSectionHeader()` for Recent/Filters/Your lenses, UX#7). No lens footnote until a
filter is set (UX#8). The walk called the cold screen "a lot to take in … not obviously
delightful" (LW §1); hierarchy plus focus is most of the fix.

**Typing.** No skeleton over a grid that has content — dim the grid and let the magnifier
pulse (it already does, `SearchView.swift:130`); skeleton only when the grid is empty (R F1).
Never "Nothing matched 'n'" during the debounce (E F4). Minimum two characters before a
request: the walk saw junk at one character (LW ✔ §2), Recents already refuse one-character
terms (`LensCounts.swift:183`), and the two rules should agree (E "Minimum length"). Return
after an answered query is free (E F2); a trailing space is free (E F8). Heading reads "411
results" and ticks with `countsNotCuts` as pages land (E F1, R F13).

**Results.** Card meta "Manga · 2019 · Ongoing" — year and status answer "is this the one I
meant"; score answers a browsing question Search is not asking (R F15). A trailing "That's all
32" line, not a haptic nobody can see (R F10). Stagger the first screen only (R F14). Long-press
should offer Save to library — `CoverQuickActions` is built and tested; wire it or delete it,
but decide (R F3). On a 429 with results up: a ticking countdown, auto-retry, and "Still
showing 'one piece'" so the grid is never anonymous (R F9). Columns from `.adaptive(minimum:)`
so 375/393/430pt phones and AX sizes all fit (R F4, R F11).

**Filters.** Picked tags, genres and a publisher become tokens in the field — visible,
individually removable, gone with Cancel (UX#6). Type becomes scopes. Status, sort, rating and
year stay in the hand-rolled `FilterPanel`, because tokens express "is Isekai" well and "rating
≥ 8, 2020–2024, sort by popularity" badly. The Filters button carries `activeFilterCount` as a
badge (LW ✔). "Match any" goes until the API honours it (C#1). Year is captioned "offline only"
the day this ships and wired the day the curl is recorded (E F6). Genres get the Tags sheet's
counts and search-within, or the two become one picker with two sections (LW §1, C#2). Browse
either becomes the sole picker and *adds*, or the header chip goes (UX#11).

**Adopt from the platform:** `.searchable` + `.searchScopes` + `.searchSuggestions` +
`.searchable(text:tokens:)` + `dismissSearch` (UX#6); `.scrollPosition` reset to top on a new
generation (R F5); `AccessibilityNotification.Announcement` on results/empty and `.isHeader`
on the heading (R F7); `.adaptive` grid columns (R F4/F11). This needs a navigation bar on the
Search tab — the no-bar trade was made for all four tabs (`ScrollEdge.swift:93-95`) and Search
is where it costs most (UX#6). Prototype it before committing.

**Keep hand-rolled, because they are done well:** `FilterPanel` as one view with two hosts
(UX done-well), `Countdown`/`FailureState`/`StaleBar` (give `StaleBar` the deadline it lacks),
`RateLimitGate` with its labelled guesses, BlurHash placeholders and the cache-hit fade rule
(R done-well), the empty state's copy and "Random with these filters" (LW §3: "best UX moment
of the walk"), the lens save sheet's "stores the filters, not the results" (LW §3), Reduce
Motion honoured on every path (R done-well). **Retire** with the redesign: `SearchClearButton`,
the hand-built Recent section, the fixed-height field frame.

**Constraint:** no `extension Animation` shorthands — they crash the Release compiler. All
motion goes through the existing `Motion.*` tokens (`Motion.swift:39-53`) and
`MotionModifiers`.

## 6. Verdict per slice

- **UX / IA (idle screen, panel, lenses, recents)** — fix in place. The panel and lens
  store are sound; the defects are one missing state input (UX#1), copy (UX#8), hierarchy
  (UX#7) and small wiring (UX#4/5/10/12). **The field itself: replace** with `.searchable`
  after a prototype — the reasons are in §5 and UX#6; the argument is that six findings
  (UX#6, R F5, R F6, R F8, LW no-badge, UX#10's suggestions) are symptoms of the one choice.
- **Engine (`SearchModel`, `SearchQuery`, gate, paging)** — fix in place. Generation race,
  `pagination.next`, family-scoped gate, offline fallback are right and tested (E done-well).
  The fixes are additive state (`total`, `answered`, `isPending`, `randomSeed`, page cap) and
  one move (preview count into the model, E F12).
- **Catalogue (tags, genres, publishers)** — fix in place for the wire (C#1, C#2, C#5); the
  tag picker's browse mode is a **refactor** (merge live into bundled by id, drill-down or
  descendant counts, `namePath` subtitle — C#3, C#4). `CatalogueService` caching and failure
  handling stay (C done-well).
- **Results / motion / a11y** — fix in place. The state machine, motion tokens and Reduce
  Motion handling are the strongest code in the slice; grid sizing (R F4, R F11) is a small
  refactor across four files, done once.
- **Tests** — fix in place, plus two additions: a recorded, dated `/v2/series/search`
  fixture (T#12) and a Search-tab budget test (T#10). Delete the two fragile source-text
  tests (T#13); keep the absence checks.
- **Live walk** — repeat after batch 1 with an accessibility tree and non-ASCII input (§7).

## 7. What the review could not determine

| Question | Why it matters | What settles it, safely |
|---|---|---|
| What a real 429 from `api.mangabaka.org` carries (T#1) | Without `Retry-After` the reader gets a static "Search is paused" | Do **not** trigger one: the limit is per IP and shared with strangers (charter). Instead (a) make `APIClient.swift:207` fall back to the gate's own computed deadline so the answer stops mattering for the reader; (b) log the header set of any 429 the app receives organically into `NetworkLedger` with a date; (c) ask upstream / read the API's source if public. |
| Sub-2-character queries show an unrelated grid labelled "30 shown" (LW ✔ §2, #59) | Looks like search ignoring input | Two `curl`s: `q=o&limit=3` vs bare `limit=3`, compare ids. If identical, the API ignores short `q` and the app should not send it (minimum 2). If different, look for a leftover filter/sort in the walk's session state (UX#5). |
| The accessibility tree (LW §4) | Icon-only bookmark, ×, share have unknown labels | Add "Search" to `AccessibilityAuditTests.swift:121-136` (R F2) and run the `MangaBakaAccessibility` scheme; or Accessibility Inspector on the simulator. Both are heavy lanes — warn first. |
| Emoji / CJK input (LW §3) | Untested encoding of `q` | `xcrun simctl pbcopy` then paste in the simulator; plus a unit test that `SearchQuery.queryItems` percent-encodes ワンピース and an emoji (no device needed). |
| Whether search responses carry browser `Cache-Control` (E unsure) | Decides how much E F2/F8 cost the server | One `curl -I`; or `NetworkLedger` latencies near zero on a repeated query. |
| What `page=101` returns (E F9) | Whether the cap is a 4xx or silent empty | One `curl` with `limit=1`. |
| Trailing space changes fuzzy `q` (E F8) | Whether trimming changes results | Two `curl`s, compare first ids. |
| `tag_mode` has any working shape (C#1) | Whether "Match any" can ever exist | Ask upstream; three shapes already measured dead. |
| `/v1/tags?q=` still works (C#9) | `TagSearch` degrades silently if not | One `curl`. |
| Duplicate ids within one random page (R F12a) | Whether page-1 dedupe is needed | Three `curl`s of `sort_by=random&limit=30`, count repeats. |
| Offline substring cost on 19,300 rows (E F13) | Whether the cache is worth writing | Time `OfflineCatalogue.matches` on device; needs a build. |
| Skeleton never seen in the walk (LW §2) | R F1 says it must show on every request | Consistent with fast responses; settled by the `contentKind` test in batch 1, not a screenshot. |

## 8. Fix batches

Batches run one after another; lanes inside a batch run in parallel and share no file. Every
lane writes its tests first and pastes the failure. Agents do not build; compile once per batch.

**Batch 1 — the state machine and the budget (all "a line/function"; no product calls)**
- Lane A — `SearchModel.swift`, `SearchEmptyState.swift`, `SearchView.swift`,
  `SearchModelTests.swift`, `SearchScreenTests.swift`. Findings: #1, #2, #3, #6, #7, #10,
  #17, #22, #23 (trim comparison side), #25, #30a, #18 (record in the grid tap). Tests to fail
  first: `contentKind(isQueryEmpty: false, hasAsked: false) == .idle`; `contentKind(isSearching:
  true, results: 30) == .results`; `search()` twice with the same query → 1 request; `hasMore`
  false→true after a new search; `× with sort == random` → idle; `total` set from a stub
  returning `count: 411`.
- Lane B — `FilterPanel.swift`, `LensCounts.swift`, `SeriesRepository+Count.swift`. Findings:
  #4 (`.background` at `LensCounts.swift:143`), #5 (offline gate → `OfflineCatalogue.count`),
  #19 (badge), #35 (label the 350 ms a guess, name the constant), #47 (footnote), #58 (44pt
  bookmark). Tests live in Lane D.
- Lane C — `SearchQuery.swift`, `SearchQueryYearTests.swift`, `SearchAndMixTests.swift`.
  Findings: #9 (year items — after the curl), #23 (trim at `:97`), #24 (`randomSeed`), #8
  (add `genres` field + `genre=` item only; wiring is batch 2). Tests: `queryItems` contains
  `published_start_date_lower=2020`; `q` for `"one "` equals `q` for `"one"`; `random_seed`
  present with `sort_by=random`; `genre=romance` not `tag=romance`.
- Lane D — tests only: `RateLimitTests.swift` (#37), `LensTests.swift` (#38, #42, delete
  #45's two fragile tests), `OfflineCatalogueTests.swift` (#39), `PaginationTests.swift` (#40),
  `FormatFilterTests.swift` + `RequestBudgetTests.swift` (#41), `AccessibilityAuditTests.swift`
  (#14), `StubRepositoryBase` (priority-recording `count`). Each new test must fail on HEAD
  except #14, which is an audit run; note which fail only until Lane B lands.

**Batch 2 — the wire, the pickers, the grid, the stale bar**
- Lane A — `FailureState.swift`, `Countdown.swift`, `APIClient.swift`, `APIError.swift`,
  `SearchView.swift` (call site only). Findings: #11 (`StaleBar(deadline:)` + `Countdown` +
  auto-retry + "Still showing '…'"), #12 (fallback to gate deadline when the header is absent),
  #51 (lossy `[Series]` decode, optional). Tests: same failure with `until: nil` → no countdown
  (control); with `until` → `Countdown` mounted; 429 without header → non-nil deadline.
- Lane B — `SearchIdleView.swift`, `SaveLensSheet.swift`, `SearchLens.swift`,
  `SearchModel.applyBrowse` region, `BrowseDestination.swift`, `FilterSheet.swift`, `FilterPanel`
  genre wiring (`:129, :154-157, :383-429`), `OfflineCatalogue.passesGenre`. Findings: #8
  (wire `genres`), #20 (headers), #47 (sheet copy), #48, #49, #57, LW Genres-sheet counts and
  search-within. Tests: `describe` names a year-only lens; `applyBrowse(genre:)` writes
  `genres` not `tags`; offline genre-only query does not return the whole index.
- Lane C — `TagPickerSheet.swift`, `CatalogueService.swift`, `TagTaxonomy.swift`,
  `TagSearch.swift`, `CatalogueTests.swift`, `TagSearchTests.swift`. Findings: #13 (remove
  "Match any"), #26 (merge live into bundled by id; `isPartial = next != nil`), #27 (rating/
  spoiler/blocked filter), #28 (`namePath` subtitle; descendant counts), #54, #55, #36's
  `TagSearch` half. Tests: merged list keeps 17 roots after a 4-root live page; blocked id is
  greyed; root `level == 1` fixture with a dated provenance.
- Lane D — `CoverImage.swift`, `Skeleton.swift`, `SearchEmptyState.swift` (grid only),
  `MixResults.swift`, `PublisherView.swift`, `Metrics.swift`, `AccessibilityTests.swift`.
  Findings: #15, #16, #29, #30b, #31, #32, R minors. Tests: column count is 2 at
  `.accessibility1`; replace `cardsWidenWithText`'s source grep with a width assertion; meta
  string for a 2019 ongoing manga reads "Manga · 2019 · Ongoing".

**Batch 3 — the redesign (needs Abdi's yes; one lane, one agent, worktree)**
- `SearchView.swift`, `SearchClearButton.swift` (delete), `RootView.swift` (bar on the Search
  tab), `SearchModel.swift` (preview count moves in, #35), `ScrollEdge.swift` if the bar
  changes it. Findings: #33, #34, #21, #46 (after the product call), #50 (after the product
  call), #60. Prototype first on a branch; measure the window spend of "type a word, pick two
  tokens, scroll" with `RequestBudgetTests`' new Search case before and after.

**Batch 4 — measurements and the re-walk (no code; heavy lanes, warn first)**
- The `curl`s in §7 (each recorded beside the field it settles, dated); a recorded
  `/v2/series/search` page into `Fixtures/` (#44); the live walk repeated with `inspect`
  working and `simctl pbcopy` for ワンピース and an emoji; the accessibility scheme with
  Search in the audit.
