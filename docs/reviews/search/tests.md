# Search review — the tests that guard the Search tab

Date 2026-09-13. Read-only; nothing was built or run. Files read in full:
`SearchModelTests`, `SearchScreenTests`, `SearchAndMixTests`, `SearchQueryYearTests`,
`LensTests`, `TagSearchTests`, `CatalogueTests`, `FormatFilterTests`,
`OfflineCatalogueTests`, `RateLimitTests`, `RequestBudgetTests`, `URLProtocolStub`,
`FixtureLoading`, `SourceTree`, `SeriesFactory` (stub base). Read to check what a test
actually exercises: `SearchModel.swift`, `LensCounts.swift` (incl. `RecentSearches`),
`SearchQuery.swift`, `SearchView.swift:100-330`, `FilterPanel.swift:255-295`,
`OfflineCatalogue.swift:228-300`, `RateLimitGate.swift`, `APIClient.swift:200-210`,
`APIError.swift:309-321`, `FailureState.swift` (StaleBar), `SeriesRepository+Paging.swift`,
`SeriesRepository+Count.swift`, `PaginationTests.swift:39-192`, `SeriesRepositoryTests.swift:285-325`,
`docs/schemas/mangabaka_openapi.json` (search params, `V1_Error_429`). Denominator: 11 suites
files named in the brief, 3 helpers, ~3,300 test lines.

Two things to know before the findings. (1) There is **no recorded `/v2/series/search`
response anywhere in `MangaBakaTests/Fixtures`** — `control.json`, `rising.json` (v2 discover,
dated 2026-09-08), `mix.json` (v1 mix, dated 2026-09-09) are the only MangaBaka series
fixtures; every search-path test answers `{"status":200,"data":[]}` or a hand-built row. (2) The
`URLProtocolStub` is keyed per test (`Test.current`) and the session stamps the key into a
header at `makeSession()` time, so the `.serialized` attributes on the stubbed suites are now
belt-and-braces rather than load-bearing — no gating fault found, and no `setHandler`
undercount found in the slice (checked below).

## Findings, by value

### 1. Every 429 the tests know about carries a `Retry-After` header the API never promises
- **What** — all five 429 fixtures in the slice invent `headers: ["Retry-After": "60"]`; the schema's `V1_Error_429` is `{status, message}` with no header, and `RateLimitTests.swift:169-170` says outright: "GUESS … nothing on record says what MangaBaka actually sends on a 429."
- **Where** — `RateLimitTests.swift:335-340, 414-416, 456-461`; `RateLimitTests.swift:169`; `docs/schemas/mangabaka_openapi.json` `components.schemas.V1_Error_429` (properties `status`, `message` only). Consumer: `APIClient.swift:201-209` builds `.rateLimited(retryAfter: displayed)` from that header alone, so a 429 with no header throws `until: nil`; `APIError.swift:314-317` then returns `countdown == nil`; `FailureState.swift:81-82` only mounts `Countdown`/auto-retry when the deadline is non-nil.
- **Why it matters** — this is charter #2 on the headline gap-7 fix. If MangaBaka's real 429 has no `Retry-After` (the schema suggests it does not), a reader who trips the *shared* per-IP limit sees "Search is paused" with no countdown and no automatic retry — the exact static-sentence dead end the fix was written to remove — while the whole test suite passes. The only 429 that would ever count down is the app's own local refusal (`RateLimitGate.swift:141-144`, which computes `until` itself).
- **Effort** — one live measurement (drive the search family to 31 in a minute, capture the response headers verbatim into `Fixtures/search-429.json` with a date), then one test per consumer path with the real shape. If the header is absent, `APIClient.swift:207` should fall back to the gate's own computed deadline — a line.
- **Confidence** — certain that it is unrecorded (the test says so, the schema agrees); worth checking what the wire actually sends.

### 2. "Expected a live countdown, not a frozen sentence" asserts a frozen sentence
- **What** — the test's proof of a "live countdown" is `model.failure?.countdown != nil`, and `APIError.countdown` is a `String?` computed once at read time ("Retrying in 38s."). On the path this test covers — results still on screen — the view renders it through `StaleBar(detail: String)`, which has no `Countdown`, no timer and no auto-retry.
- **Where** — `SearchModelTests.swift:172`; `APIError.swift:314-321`; `SearchView.swift:299-303` (`detail: failure.countdown ?? failure.userFacingMessage`, `retry:` manual); `FailureState.swift:139-165` (`StaleBar.detail` is a plain `Text`). Contrast `SearchModel.swift:213-215`, whose comment promises "the network answer is seconds away and auto-retry will fetch it" for this very branch.
- **Why it matters** — charter #5. The number the test checks moves (nil → non-nil) but measures the model, not the reader's screen: with results showing, a 429 prints "Retrying in 38s." that never changes and never retries. Doubly wrong copy — it names a retry that will not happen. The blocking-failure path (`SearchView.swift:274-279`) does get a real `Countdown` with `autoRetry: true`; the results-present path does not.
- **Effort** — test: assert on `until` (a `Date`) rather than the string, and add a control that the same failure with `until: nil` yields no countdown. View: give `StaleBar` an optional deadline and reuse `Countdown` — a function. Belongs to the view slice; flagged here because the test is what lets it pass.
- **Confidence** — certain.

### 3. `familyScopedBackoff` has no second assertion — the `try?` swallows the one the comment names
- **What** — the doc comment says "this test's second assertion is exactly the one the old behaviour violated." That line is `try? await searchGate.reserveSlot(for: "/v1/my/profile", …)`, which discards a throw. The old global-block behaviour would pass this test unchanged. Same shape at lines 100 and 158.
- **Where** — `RateLimitTests.swift:80-83` (the claim), `:92`, `:100`, `:158` (each `try?` with no `#expect`).
- **Why it matters** — charter #2/#5. Per-family scoping is what stops a search 429 from closing the series page's `/v1/series/{id}/*` legs (the 2026-09-13 fix); nothing in the suite would notice it regressing to a global block. The 31st-search test at `:158` likewise never proves `/v1/discover/rising` is unaffected.
- **Effort** — three lines: wrap each in `await #expect(throws: Never.self) { try await … }` (or a `do/catch` that records an `Issue`).
- **Confidence** — certain.

### 4. The offline index's content-rating filter has no test, and the fallback tests can't see it either
- **What** — every `OfflineCatalogueTests` call passes `allowedRatings: []`, which `passesRating` treats as "allow everything" (`guard !allowed.isEmpty else { return true }`). `SearchOfflineFallbackTests` uses `SearchModel`'s default `["safe","suggestive"]` but only asserts `!results.isEmpty`. Deleting `passesRating(_:allowed:)` outright would leave both suites green.
- **Where** — `OfflineCatalogueTests.swift:81-83, 106-108, 122-124, 142-144, 156-158, 173-175, 185-199, 205-207, 218-223, 234-236, 246-248` (all `allowedRatings: []`); `OfflineCatalogue.swift:264-268`; `SearchModelTests.swift:412-424, 466-482, 484-495`; `SearchModel.swift:99` (default), `:263-270` (call).
- **Why it matters** — the fallback is the one path that shows results *without* the server's `content_rating` filter. A regression here shows a reader who has explicit content off the whole 19,300-title index, offline or under a rate limit, and no test says a word. Charter #2 in the "fixture agrees with the model" sense: the control decode (`rawEntries`) is right there and already carries `contentRating`, so the expected set is one filter away.
- **Effort** — one test in `OfflineCatalogueTests` mirroring `blockedTagExcludes` (expected = raw entries whose `contentRating` is nil or in the allowed set), plus a `RecordingRepository` fallback test asserting no returned `Series.contentRating` outside the default set. Two tests.
- **Confidence** — certain.

### 5. `showResultsIsOneSearch` cannot surface the regression its comment describes
- **What** — the comment (lines 99-107) says the test exists to catch a future edit wiring a chip's binding through `queryDidChange()`. The body mutates `model.query.types/statuses/minimumRating` directly — three struct writes — and asserts `searchCount == 0` with no suspension point. It never touches `FilterPanel`, never calls `queryDidChange()`, and even if it did, `cancelPendingDebounce()` on the next line would cancel the debounce before it fired.
- **Where** — `SearchModelTests.swift:99-123`.
- **Why it matters** — charter #5: a test that would pass if the thing it guards regressed. The real guard for "filters must not search on their own" is that `FilterPanel` binds `$model.query` with no observer (`SearchView.swift:109, 247`; the only `.onChange` is on `query.text` at `SearchView.swift:141`) — a view fact nothing tests. Note the panel *does* fire a network `count` per settled filter change (`FilterPanel.swift:120, 281-294`, 350 ms debounce) — see finding 8.
- **Effort** — either delete the misleading comment and keep the test as the `search()`-is-one-request sanity it actually is, or pull the panel's binding wiring into a testable rule. A function.
- **Confidence** — certain.

### 6. `countsOncePerLens` asserts before the work it is guarding could run
- **What** — `counts.load(lenses)` then `#expect(repository.calls == 2)` on the next line, with no `await`. `LensCounts.load` does its counting inside `Task {}` on the main actor; the test is main-actor and never suspends, so a regression that scheduled a duplicate count would still read 2 here.
- **Where** — `LensTests.swift:119-131`; `LensCounts.swift:84-116`.
- **Why it matters** — charter #5. The "once per session" promise is what keeps the idle screen from spending the shared 30/min search window every time it is shown (`LensCounts.swift:10-17`). As written the test proves that a synchronous call did not synchronously call a stub.
- **Effort** — after the second `load`, `try await Task.sleep(for: LensCounts.spacing * 2)` (or poll for a bounded time) then assert. Two lines.
- **Confidence** — certain.

### 7. The debounce tests pass with the debounce removed
- **What** — `debounceCollapsesABurst` and `TagSearchTimingTests.debounceCollapsesTyping` issue their keystrokes in a synchronous loop. Each `queryDidChange()`/`update(query:)` cancels the previous `Task` before the loop yields, so only the last task ever runs whether the sleep is 300 ms or 0 ms. What they prove is cancel-on-change, not "wait ~300 ms".
- **Where** — `SearchModelTests.swift:83-97` (loop at 88-91); `TagSearchTests.swift:65-80` (loop at 73-75); `SearchModel.swift:145-149`; `TagSearch.swift:35`.
- **Why it matters** — the 30/min shared window is the reason the debounce exists (`SearchModel.swift:15-19`). A real reader types with 80-150 ms between keys; a debounce of 50 ms would fire on most words and both tests would stay green. There is also no lower-bound assertion anywhere ("no request before ~300 ms"), so the number is pinned only from above by the 600 ms sleeps.
- **Effort** — one test: type `s`, sleep 100 ms, type `so`, sleep 100 ms, type `sol`, then sleep 600 and assert `searchCount == 1`; add a control that a single keystroke followed by 100 ms has `searchCount == 0`. Same shape for `TagSearch`.
- **Confidence** — likely (reasoned from main-actor scheduling: tasks created inside a non-suspending main-actor function cannot start until it suspends; a build would confirm in seconds).

### 8. Three debounce constants, none derived, one untested
- **What** — `SearchModel` waits 300 ms (inline literal), `FilterPanel`'s preview count waits 350 ms (inline literal), `TagSearch.debounce` is 250 ms. None says why it differs from the others or labels itself a guess; the 350 has no test at all and drives a real `/v2/series/search` request (`count`) per settled filter change and on every appearance of the panel with a non-empty query.
- **Where** — `SearchModel.swift:146`; `FilterPanel.swift:120-121, 288`; `TagSearch.swift:35`; tests: `SearchModelTests.swift:38, 58, 66, 92` (comment "SearchModel's own 300ms debounce"), `TagSearchTests.swift:77, 100, 113, 126, 146, 157` (`TagSearch.debounce * 3`), nothing for 350.
- **Why it matters** — charter #4 and "duplicated constants". Tuning one moves the reader's experience in one place only. The 350 ms one is the riskiest: it goes out at `.userInitiated` (`LensCounts.swift:142-144` → `SeriesRepository+Count.swift:17-18`), so a reader flicking through rating segments spends full-window search slots that no test counts.
- **Effort** — a `Metrics.debounce` (or per-feature `static let`s with a one-line reason) and a test for the panel's schedule rule, which means pulling `scheduleCount`'s decision out of the view body. A file.
- **Confidence** — certain for the duplication; likely for the request cost (read, not measured).

### 9. `searchDeduplicates` says "and stops asking" but never checks what was asked
- **What** — the comment promises the model "stops asking, rather than re-requesting the same page into a rate limit"; the assertion is `hasMore == false`. With `totalPages: 3` the model actually requested pages 1, 2 *and* 3 (each repeating page 1) and `hasMore` went false because page 3 was the stub's last page, not because the dedupe stopped anything. With `totalPages: 10` it would request 1-4 and set `stoppedEarly`.
- **Where** — `PaginationTests.swift:91-106` (no `requestedPages` assertion); `SearchModel.swift:354-387` (`maxConsecutiveEmptyPages = 3`, loop).
- **Why it matters** — charter #5. The bound that keeps a run of duplicate/filtered pages to three extra requests (`SearchModel.swift:310`) is untested — `stoppedEarly` and `maxConsecutiveEmptyPages` appear in no test file — and the one test near it measures the stub's page count instead.
- **Effort** — assert `repository.requestedPages == [1, 2, 3, 4]` and `stoppedEarly == true` against a 10-page repeating stub; keep the 3-page case as the "genuine end" control. Two tests.
- **Confidence** — certain.

### 10. "The format filter holds everywhere" never touches search
- **What** — all four `FormatFilterTests` and both `FilterApplicationTests` call `feed(.rising)`. The file's own comment says "Search honours the parameter", but the local `allowsFormat` post-filter on `SeriesRepository.search` (`SeriesRepository+Paging.swift:60`) is untested for search, and `RequestBudgetTests` ("30 req/min for search") likewise only ever loads `.rising`.
- **Where** — `FormatFilterTests.swift:47, 60, 79, 98, 130, 153`; `RequestBudgetTests.swift:47, 61, 76, 91`; `FormatFilterTests.swift:11-12`.
- **Why it matters** — charter #5: the suite names promise Search coverage the bodies do not deliver. A budget test for the Search tab — N lenses on the idle screen, one typed word, one filter change, one scroll — does not exist, and the rate limit that matters is search's 30, not discover's 180.
- **Effort** — one search test in `FormatFilterTests` (stub returns a novel under `formats=["manga"]`, assert dropped); one `RequestBudgetTests` case driving `SearchModel` + `LensCounts` through the real repository and stub and asserting the search-family request count. Two tests.
- **Confidence** — certain.

### 11. Nothing observes that `LensCounts` asks at `.background`
- **What** — the 2026-09-13 change routes the idle-screen walk through `repository.count(_, priority: .background)`, but every stub in `LensTests`/`SearchScreenTests` overrides the plain `count(_:)`, and the protocol extension forwards the priority-taking call to it, dropping the priority on the floor. No test can tell `.background` from `.userInitiated`.
- **Where** — `LensCounts.swift:95-99`; `SeriesRepository+Priority.swift:32-34`; `LensTests.swift:224, 242, 279, 293`; `SearchScreenTests.swift:135`; `RateLimitTests.swift:229-316` (tests the gate's priority behaviour, not who uses it).
- **Why it matters** — charter #3-adjacent: the value is passed and nothing checks it arrives. Regressing it to `.userInitiated` re-creates the "Too many requests" on the series page that the change fixed (`RateLimitTests.swift:217-223`).
- **Effort** — a `StubRepositoryBase` override of the priority-taking `count` that records the priority, one assertion. A few lines.
- **Confidence** — certain.

### 12. Fixtures built from the model, not a response — the list (charter #2)
Provenance = a dated "captured/verified live" note beside the payload.

| Fixture | Where | Provenance |
|---|---|---|
| `{"status":200,"data":[]}` (used as every search answer) | `SearchAndMixTests.swift:25`, `:207, :290, :310`; `SeriesRepositoryTests.swift:298` | no (envelope shape only) |
| 429 body + `Retry-After: 60` | `RateLimitTests.swift:335-340, 414-417, 456-461` | no — self-declared GUESS (`:169`) |
| Mix recommendation row (`mixKeepsReason`) | `SearchAndMixTests.swift:159-171` | no; a dated `mix.json` exists and is not used here |
| v1/v2 tag shapes (`tagsDecodeFromBothShapes`) | `SearchAndMixTests.swift:232-240` | no date for the tag-shape claim (line 198's 2026-09-09 note is about `schema=full`) |
| `year`/`rating_count` as string and number | `SearchAndMixTests.swift:249-258` | no; `rising.json` has `year: null`, `rating_count: 541038` (int) — the string variant is unrecorded |
| Genres `[{"label","value"}]` | `CatalogueTests.swift:20-22, 37` | no |
| `tagPayload` (3 tags, `name_path`, `merged_with`) | `CatalogueTests.swift:52-64`, `:323-325` | partial — `:318-322` names the schema type but no capture date |
| Publisher rows | `CatalogueTests.swift:125-133` | **yes** — "verified live 2026-09-13" (`:114-121`) |
| `{"id","name"}` publisher rows | `CatalogueTests.swift:156-158, 174-180, 194-200, 214` | no (derived) |
| `page(["manga","manhwa","novel"])` 4-key rows | `FormatFilterTests.swift:26-35, 71-73, 122-124` | no — claims "Exactly the live response shape" (`:39`) for a 4-key row |
| `RequestBudgetTests.payload` (nulls, v1-style cover) | `RequestBudgetTests.swift:15-28` | no |
| `OfflineIndex.json.gz` | `OfflineCatalogueTests.swift:27-37` | **yes** — the real bundled export, with an independent control decode |
| `SeriesFactory.make` series | `SearchModelTests` throughout | n/a — model-level tests, no decode |

The two with a real cost are the 429 (finding 1) and the empty envelope: because no search test ever decodes a populated `/v2/series/search` page, `FeedResult.hasMore`'s read of `pagination.next` on the *search* endpoint is proven only by the discover fixture and by stubs that set `hasMore` directly.

### 13. Tests that assert on source text — the Search-tab list (charter #2)
All gated by `.enabled(if: SourceTree.isAvailable)`; all would pass against a stub of the right name.

| Test | Where | Pins |
|---|---|---|
| `onlyTheSheetSaves` | `LensTests.swift:314-322` | `!SearchView.contains("Save as a lens")`, `FilterPanel.contains("SaveLensButton")` |
| `inertUntilFiltered` | `LensTests.swift:324-328` | the literal call `SaveLensButton(isEnabled: !query.isEmpty)` |
| `noPresetsProperty` | `LensTests.swift:335-339` | absence of `static let presets` |
| `noPresetReferences` | `LensTests.swift:341-353` | absence of `SearchLens.presets` / `"Presets"` in four files |
| `sheetUsesThePanel` | `LensTests.swift:362-367` | `FilterPanel(` present, `RatingSegments(` absent in `FilterSheet` |
| `idleScreenUsesThePanel` | `LensTests.swift:369-373` | `FilterPanel(` present in `SearchIdleView` |
| `mixCanSaveALens`, `tagsBeforeBlending`, `pickedTagsSurvive` | `LensTests.swift:431-454` | `SaveLensButton`, `model.filters.isEmpty`, a 40-character `if` snippet, `pickedBeyondDNA` — Mix, in a file named Lens |
| `sharedControl`, `noStepperLeft` | `RatingSegmentsTests.swift:41-62` | `RatingSegments(minimum:` present, `Stepper(` absent |
| `definedOnce` | `PresentationTests.swift:176-195` | absence of a sort-tuple literal, presence of `SortOrder.all` |

The absence checks (presets gone, no second sort list, no Stepper) are doing something a value test cannot and should stay. `inertUntilFiltered` and `tagsBeforeBlending` are the fragile ones — a whitespace change breaks them and a renamed-but-equivalent call passes them; `FilterPanel.canShow(query:)` at `SearchScreenTests.swift:57-75` is already the behavioural version of the first.

## The eight behaviour questions

| # | Behaviour | Status | Where |
|---|---|---|---|
| a | Stale response after a newer one | **partial** — page 2 of an old search is dropped (`stalePageIsDropped`, `SearchModelTests.swift:330-353`). Missing: two *page-1* searches racing (slow "naruto" landing after fast "bleach") — the `mine == generation` guard at `SearchModel.swift:189` has no test; and cancel-in-flight via `queryDidChange` mid-request has none | — |
| b | Empty query never fires | **partial** — `clearingIsLocal` (`SearchModelTests.swift:125-136`) covers `""` via `queryDidChange`; no test calls `search()` directly with an empty or whitespace-only query and asserts 0 requests (`SearchModel.swift:162-170`, `SearchQuery.swift:52`). `applyBrowseSetsTagAndSort` (`:370`) asserts `!isEmpty` for browse |
| c | 429 → countdown + auto-retry | **partial / mismeasured** — `rateLimitedSearchKeepsPreviousResults` (`SearchModelTests.swift:148-173`) pins results kept + `countdown != nil`; see findings 1 and 2. Auto-retry itself (`FailureState.autoRetry`, `Countdown.onReachZero`) has no test in the slice; `StateFamilyTests.swift:80` tests `RetryGate` only |
| d | Paging dedupe | **covered** — `searchDeduplicates` (`PaginationTests.swift:91-106`), with the caveat in finding 9; offline dedupe covered by `pagingIsDisjointAndContiguous` (`OfflineCatalogueTests.swift:182-200`) |
| e | Recent-search recording rules | **partial** — the store's rules are well covered (`LensTests.swift:23-91`: dedupe case-insensitively, cap 6, show 4, ignore ≤1 char, persist, remove). Missing: *when* a term is recorded. Recording happens only on field submit and on "Show results" (`SearchView.swift:140, 258`), never on a debounced search, a lens run or a recent-term re-run — untested and unstated |
| f | Inline `FilterPanel` ↔ sheet state sharing | **source-text only** — `FilterPanelWiringTests` (`LensTests.swift:360-374`). Both hosts bind `$model.query` and `$model.preferOffline` (`SearchView.swift:109-115, 247-251`); no behaviour test, and no test that the sheet's `onApply` and the panel's `onShowResults` do the same thing |
| g | Content rating on search results | **partial** — server-side param is pinned (`searchFiltersContent`, `SearchAndMixTests.swift:64-74`; `searchAndCountAgreeOnFilters`, `SeriesRepositoryTests.swift:290-314`). Offline/fallback path: missing (finding 4). No local post-filter exists for search, so a server that ignored the param would show everything — untested and unmeasured |
| h | Offline fallback | **covered** — `SearchOfflineFallbackTests` (`SearchModelTests.swift:398-496`): toggle sends zero requests, paging stays offline, 500 does not fall back, `.offline` and `.rateLimited` do. Gaps: offline *with results already on screen* replaces them with cover-less index rows (`SearchModel.swift:218`, `!isOffline` excludes offline from `keepWhatIsShown`) — untested and worth a product look; offline with zero index matches renders as `EmptyState` "nothing matched" rather than "you're offline" (`failure = nil` at `SearchModel.swift:285`) — untested |

## Constants: behaviour or copied literal?

| Constant | Source | In tests | Verdict |
|---|---|---|---|
| Debounce 300 ms | `SearchModel.swift:146` (inline) | sleeps of 600 with a comment | upper bound only; no lower bound (finding 7) |
| Panel preview debounce 350 ms | `FilterPanel.swift:288` | none | untested (finding 8) |
| `TagSearch.debounce` 250 ms | `TagSearch.swift:35` | `TagSearch.debounce * 3` | referenced, not asserted |
| Page size 30 | `SearchQuery.swift:41` | `model.query.limit` (`SearchModelTests.swift:312, 336, 350`); literal `pageSize: 30` in stubs | never asserted on the wire (`limit=30`); schema max 100, default 10 |
| Recents kept 6 / shown 4 | `LensCounts.swift:163, 169` | literals 6 and 4 with expected arrays (`LensTests.swift:38, 83-84`) | **behaviour** — good; 4 is labelled a guess in source |
| ≤1-char terms ignored | `LensCounts.swift:183` | `record("a")` → empty (`LensTests.swift:48`) | behaviour; the 1 is unlabelled |
| `searchLimit` 30, `reserve` 10 | `RateLimitGate.swift:98, 107` | `RateLimitGate.searchLimit` / `.reserve` (`RateLimitTests.swift:146, 248, 295`) | copied by reference — a change to 300 passes; the doc says 30 |
| `maxHonouredRetryAfter` 15 min | `RateLimitGate.swift:91` | `<= RateLimitGate.maxHonouredRetryAfter` (`:179`) | copied by reference |
| Backoff cap 60 s | `RateLimitGate.swift:212` | literal `<= 60` (`:203`) | **behaviour** |
| `maxConsecutiveEmptyPages` 3 | `SearchModel.swift:310` | none | untested (finding 9) |
| `LensCounts.spacing` 250 ms | `LensCounts.swift:34` | avoided by polling | untested by design; fine |
| "Budget of 6" | design doc | literal (`RequestBudgetTests.swift:81`) | behaviour, but for Discover, not Search (finding 10) |

## Gating and the `setHandler` trap

- `.serialized` is on `SearchAndMixTests`, `StackCardDataTests`, `SearchLensTests`, `SavedLensTests`, `CatalogueTests`, `FormatFilterTests`, `FilterApplicationTests`, `RateLimitClientTests`, `RateLimitClearingTests`, `RateLimitWriteTests`, `RequestBudgetTests`. With per-test stub keys (`URLProtocolStub.swift:26-38`) it is no longer load-bearing; harmless. `RequestPriorityBudgetTests` (`RateLimitTests.swift:229-316`) is *not* serialized and uses real 50-150 ms sleeps; its assertions are shaped so machine load makes them pass more easily, not fail — acceptable, but they are not proof under contention.
- `.enabled(if: SourceTree.isAvailable)` is present on every source-reading suite in the slice (`LensTests.swift:311, 333, 360, 422`; `RatingSegmentsTests.swift:39`; `PresentationTests.swift:176`). No ungated source read found.
- `setHandler` resets the request log (`URLProtocolStub.swift:43-47`). Every request-count assertion in the slice follows a single `setHandler` per test (`CatalogueTests.swift:45`; `RateLimitTests.swift:348-356, 373, 427-436, 473-487, 499-507`; `RequestBudgetTests.swift:48, 79-81, 93`; `SearchAndMixTests.swift:120`). `SeriesRepositoryTests.swift:298-311` calls `setHandler` twice but reads `.last` after each, correctly. No undercount found.
- Stub key inheritance: `SearchModel`, `LensCounts` and `FilterPanel` all use unstructured `Task {}` (inherits task-locals, so `Test.current` survives) and the session header is stamped at `makeSession()`; a future `Task.detached` in either model would silently route its requests to the shared bucket and be invisible to `requests` — worth a comment on `URLProtocolStub.currentKey`.

## Charter #5 — names that promise Search, bodies that do something else

- `FormatFilterTests` "The format filter holds everywhere" and `RequestBudgetTests` "Request budget … 30 req/min for search" — Discover only (finding 10).
- `SearchAndMixTests.swift` carries `StackCardDataTests` (`:200-261`, the surprise feed and `Series` decode leniency) and three pure-Mix tests (`:80-193`) under a file named for Search; `SearchLensTests` (`:264-325`) tests `SeriesRepository.search`'s `tag`/`tag_mode` encoding, not lenses.
- `LensTests.swift` carries `MixFilterTests` (`:422-455`) and `TagBreadthTests` (`:382-419`, the tag picker's bar).
- `showResultsIsOneSearch` (finding 5) and `searchDeduplicates` (finding 9) — comments promise a guard the body does not provide.

## Done well

- **Gated continuations instead of sleeps for races.** `SlowPageTwoRepository.gate` (`SearchModelTests.swift:300-321`) and `GatedRepository` (`SearchScreenTests.swift:132-141`) hold a request open until the test has set up the race, with a bounded poll (`:343-344`, `:117-122`) so a real bug fails rather than hangs. The comment at `SearchModelTests.swift:339-342` records the 3/3 pre-push failure that motivated it.
- **Controls beside the fixes.** `emptyAnswerIsNotAFailure` (`SearchModelTests.swift:179-190`) is the control for the rate-limit test; `serverErrorDoesNotFallBackOffline` (`:452-464`) for the fallback pair; `randomBrowsingSurvives` (`:269-280`) for `typingClearsRandom`; `applyBrowseReplacesTheQuery` (`:376-386`) for the tag route. Each says what it is a control for.
- **Independent control decode for the offline index.** `OfflineCatalogueTests.RawWire` (`:16-20`) re-decodes the real gzip without touching the actor, and every filter test derives its expected set from it (`:101, :116-118, :133-138, :151, :169`) — the "two measurements, one control" standard, applied.
- **Live measurements dated in test comments.** `typingClearsRandom` (`SearchModelTests.swift:253-256`: 32 vs 411 results), `TagSearchTests.swift:9-11` (`?limit=500` lacks Romance), `FormatFilterTests.swift:8-10` (fourteen manhwa under `type=manga`), `CatalogueTests.swift:114-121, 146-150, 168-170` (publishers, 2026-09-13). These are what made finding 1 findable at all — the 429 comment says "GUESS" out loud.
- **"Expected to fail before the fix" is written down**, with the exact assertion that would fail: `LensTests.swift:186-189`, `RateLimitTests.swift:80-83, 241-244`, `CatalogueTests.swift:117-121, 148-150, 170`. Finding 3 exists only because one of those sentences could be checked against the body.
- **The stub is keyed per test and says why.** `URLProtocolStub.swift:26-35` records the cross-suite contamination that forced it ("a MangaUpdates request from the schedule suite as its first request").
- **The right decoder.** `Fixture.decoder()` is `APIClient.makeDecoder()` (`FixtureLoading.swift:28-35`), with the note about the earlier wrong-decoder measurement.
- **Pure view rules extracted for testing.** `SearchHeading.text`, `SearchView.contentKind`, `FilterPanel.canShow`, `TagPickerStatus.resolve`, `RecentSearches.visible`, `OfflineIndexDateLabel.short` (`SearchScreenTests.swift`, `LensTests.swift:82-90`) — the honest alternative to source-text tests, already in use.

## Not reviewed

- `PaginationTests.swift` beyond `:39-192` (Discover row paging), `InlineSearchTests.swift` (Library tab), `BlockedTagsTests.swift` (read only the grep for request counts), `SeriesRepositoryTests.swift` beyond `:285-325`, `EmbeddingIndexTests.swift`, `TagTaxonomyTests`, `StateFamilyTests` (RetryGate), `FetchedTests`, the UI tests (`FlowAffordanceUITests`, `MangaBakaAccessibility`).
- `TagPickerSheet`/`GenrePickerSheet`/`SaveLensSheet` beyond `TagPickerStatus` — no tests found for the picker's selection, search mode or the "Match any/all" buttons (the catalogue slice covers the behaviour).
- Whether `Countdown` actually fires `onReachZero` once and only once — `Countdown`'s own tests, if any, are outside this slice.
- Nothing was run: every "would pass" claim above is by reading the test body against the code it calls, not by mutating and re-running. Finding 7 is the one that most deserves a two-second mutation check.
