# Search engine review — correctness, latency, request budget

2026-09-13. Read-only. Files read in full: `SearchModel.swift`, `LensCounts.swift`,
`SearchQuery.swift`, `SeriesRepository+{Paging,Count,Priority}.swift`, `RateLimitGate.swift`,
`RequestPriority.swift`, `OfflineCatalogue.swift`; the search paths of `APIClient.swift`
and `SeriesRepository.swift`; the wiring in `SearchView.swift`, `FilterPanel.swift`,
`SearchEmptyState.swift`, `SearchIdleView.swift`; `/v2/series/search` in
`docs/schemas/mangabaka_openapi.json`; the tests named below. No build, no test run,
no simulator — every claim is from reading, and every "certain" below means "certain
from the code as written", not "observed on a device".

Findings: 14 (3 certain-and-user-visible, 6 budget, 5 encoding/constants).
Done well: 8. Not reviewed: listed at the end.

---

## Answers to the brief's questions, short form

- **Debounce**: 300 ms (`SearchModel.swift:146`). Not derived, not labelled a guess.
- **Cancellation**: a keystroke cancels the pending debounce *and* the in-flight search
  that debounce is running (`SearchModel.swift:114`, one `Task` carries both). Explicit
  `search()` does not cancel anything (`:155-160`, deliberate).
- **Stale overwrite race**: closed by `generation` (`:178-189`, `:334`). A late page for a
  replaced search is dropped, not appended. Correct.
- **Empty query**: never fires (`:136`, `:162`). Whitespace-only counts as empty
  (`SearchQuery.swift:53`) — but only `.whitespaces`, so a lone newline pasted in is
  "not empty" and fires `q=\n`. Cosmetic.
- **Trailing whitespace / case / diacritics**: all produce distinct requests. `q` is sent
  untrimmed (`SearchQuery.swift:97`), never lowercased, never folded. Nothing compares the
  new query to the last one answered, so `"naruto"` → backspace → `"o"` again is two more
  requests for an answer already on screen.
- **Minimum length**: none. One character fires a request (`:136` only checks emptiness).
  `RecentSearches.record` has a minimum of 2 (`LensCounts.swift:183`) — the two disagree.
- **Paging**: `limit = 30` (`SearchQuery.swift:41`), page ≤ 100 not enforced. "Has more"
  reads `pagination.next` (`SeriesRepository+Paging.swift:67`) — the todo-next-week item is
  **done**, verified. Duplicate ids across pages: deduped (`SearchModel.swift:358-359`).
  Local rating/format filtering shrinks pages; bounded by 3 consecutive empty pages (`:310`).
- **Caching**: **none** for search, by design (`SeriesRepository.swift:28-30`). An identical
  query typed twice is two requests. `URLCache` may serve one if the server sends browser
  cache headers (spec says "cached 1 hour by default" — CDN side; browser headers not on
  record) — and even then the local 30/min window is still charged (`RateLimitGate.swift:139`
  runs before `URLSession`), which is the safe direction.
- **Offline**: `OfflineCatalogue` is consulted only on the toggle or after a blocking
  offline/429 failure (`SearchModel.swift:183`, `:219`). Never as a first-paint.
  `EmbeddingIndex` is not used on the search page and *cannot* be for text — it has no
  text encoder, only series-to-series neighbours (`EmbeddingIndex.swift:6-10`). Not a gap.
- **Sorting**: API order preserved; no client re-sort (`:227`, `:369`). Offline sorts
  once per call, stable (`OfflineCatalogue.swift:334-341`).
- **Priority budget**: respected for lens counts (`.background`, `LensCounts.swift:99`)
  and follow checks. **Not** for the filter panel's preview count — see F3.

## Request count for one typical interaction

Type 6 characters, open a result, back, clear. Search-family requests only
(`/v2/series/search`, the 30/min window).

| Step | Requests | Where |
|---|---|---|
| Type "naruto" at ~200 ms/key | 1 | one debounce fires (`SearchModel.swift:145-149`) |
| Same, with one >300 ms pause mid-word | 2 | each pause fires |
| Press Return after results landed | **+1, identical to the last** | `SearchView.swift:139-142` — no "already answered" check (F2) |
| Open a result | 0 | detail legs are `/v1/series/...`, general family |
| Back | 0 | results retained, nothing re-fetches |
| Clear | 0 | `SearchModel.swift:136` guard |
| Idle screen reappears, first time this session | N (one per saved lens) | `SearchIdleView.swift:52`, background priority, 250 ms apart |
| Open the filter sheet over results | **+1** | `FilterPanel.swift:121` `.task` — a count the search already carried (F1) |
| Each filter chip / tag toggle, >350 ms apart | +1 each, **userInitiated** | `FilterPanel.swift:120,288` (F3) |

Baseline is 1–3 for the typed interaction, which is good. The three bold rows are the
waste, and the last one is the lockout path.

---

## Findings

### F1. The search response's total is fetched and thrown away; the filter sheet then spends a request to ask for it again
- **What**: `SeriesRepository.search` decodes `pagination.count` into `FeedResult.total`
  (`SeriesRepository+Paging.swift:68`); `SearchModel` never reads `.total` (grep: no hit
  in `SearchModel.swift`). Opening `FilterSheet` over results runs
  `.task { scheduleCount(for: query) }` (`FilterPanel.swift:121`) → `counts.count` →
  `repository.count` → a second `/v2/series/search?limit=1` for the same query.
- **Where**: `SeriesRepository+Paging.swift:68`, `SearchModel.swift:227-239`,
  `FilterPanel.swift:121`, `LensCounts.swift:142-144`.
- **Why it matters**: charter #3. One wasted search-window slot per sheet open, and the
  results heading says "12 shown" (`SearchView.swift:224-230`) when the model already
  knows "12 of 4,118". The reader has no idea how deep the results go until the sheet.
- **Effort**: a function — add `private(set) var total: Int?` to `SearchModel`, set it from
  `result.total`, pass it to `FilterSheet` as the initial `resultCount`, and skip the
  `.task` count when the sheet's query equals the last-searched query.
- **Confidence**: certain.

### F2. Return after a debounced search re-sends the identical request
- **What**: `onSubmit` cancels the debounce and calls `search()` unconditionally
  (`SearchView.swift:139-142`; same shape at `:111`, `:217`, `:259`). If the 300 ms
  debounce already fired and answered, this is a byte-identical second request. Nothing in
  `SearchModel` remembers the last query it answered.
- **Where**: `SearchView.swift:139-142`, `SearchModel.swift:161-240`.
- **Why it matters**: pressing Return after typing is the default habit for most readers;
  every such search costs 2 of 30. The same absence means backspace-and-retype ("naruto"
  → "narut" → "naruto") costs 2 more.
- **Effort**: a few lines — `private var answered: SearchQuery?` set at `:227`; `search()`
  returns early when `query == answered` and `failure == nil`. (Compare with `page` reset
  to 1 and `text` trimmed.)
- **Confidence**: certain.

### F3. Filter-preview counts run at `userInitiated` and can lock the reader out of their own search
- **What**: `LensCounts.count(_:)` calls `repository.count(query)` with no priority
  (`LensCounts.swift:143`), which is `.userInitiated` (`SeriesRepository+Count.swift:17-19`).
  Every chip, status, sort, tag or tag-mode change in `FilterPanel`/`TagPickerSheet`
  mutates the bound `query` → `.onChange` → one count after 350 ms (`FilterPanel.swift:120,
  282-293`). Cancelling `countTask` after the gate has reserved a slot does not un-spend it.
- **Where**: `LensCounts.swift:142-144`, `FilterPanel.swift:120`, `:288`,
  `RateLimitGate.swift:136-146`.
- **Why it matters**: `RateLimitGate.reserve` exists precisely so "at least 10 are always
  free the instant the reader actually searches" (`RateLimitGate.swift:101-107`). A preview
  is not a search. A reader exploring the tag picker — 30 toggles in a minute is a slow
  browse — hits `:142` and their next typed query is refused locally with a countdown.
  This is the one path found where the reader can lock *themselves* out.
- **Effort**: a line — pass `priority: .background` at `LensCounts.swift:143`. Background
  waits rather than fails, and the caller already cancels a superseded count. Optionally
  raise the 350 ms to something closer to a second: a preview is not latency-sensitive.
- **Confidence**: certain for the mechanism; "30 toggles in a minute" is a plausible-use
  claim, not a measurement.

### F4. "Nothing matched" shows during the debounce, before any request has gone out
- **What**: `contentKind` returns `.empty` whenever the query is non-empty, `isSearching`
  is false, and results are empty (`SearchEmptyState.swift:27-30`). `isSearching` is only
  set inside `search()` (`SearchModel.swift:171`). So on the first keystroke of a fresh
  search there is a ≥300 ms window — plus the time a cancelled in-flight search takes to
  unwind (`:173` defer) — where the screen says "Nothing matched 'n'".
- **Where**: `SearchModel.swift:136-149` (no pending state), `SearchEmptyState.swift:27-30`,
  `SearchEmptyState.swift:95-97`.
- **Why it matters**: the first thing a reader sees after typing one letter is a failure
  message, then a skeleton, then results — with `.blurReplace` transitions on each step.
  Charter #2: `SearchScreenTests.swift:203-209` asserts exactly this state is `.empty`,
  so the tests agree with the bug.
- **Effort**: a few lines — a `private(set) var isPending` set true at `:145` and false
  at `:171`/`:136`, and `contentKind` treats pending like searching (or keeps the previous
  kind).
- **Confidence**: certain from the code; the live-walk agent should be able to see it.

### F5. Applying a lens, browse or "Surprise me" while text is in the field fires two requests and discards the first answer
- **What**: `apply`/`applyBrowse` remember `next.text` so the field's `onChange` can ignore
  the edit (`SearchModel.swift:402`, `:412`, `:123-126`). When `next.text` is `nil` and the
  field had text, `appliedText` is `nil`, `onChange` fires for `"naruto" → nil`, the guard
  at `:123` is `if let` and does not match, and a 300 ms debounce schedules a second
  `search()`. That bumps `generation`, so the *first* request's answer fails `:189` and is
  thrown away; the reader waits 300 ms + a second round trip.
- **Where**: `SearchModel.swift:123-127`, `:402`, `:412`, `SearchView.swift:143`.
- **Why it matters**: every text-less lens, every genre/tag browse, and "Surprise me"
  (`SearchView.swift:216`, which does not set `appliedText` at all — it mutates `sort` and
  calls `search()`; `sort` is not observed so that one is fine) tapped while the field is
  non-empty costs 2 slots and doubles perceived latency. `SearchModelTests.swift:49-69`
  covers only `apply` *with* text, so it passes.
- **Effort**: a line — make `appliedText` an `Optional<Optional<String>>`-free sentinel:
  store `appliedText = next.text ?? ""` and compare against `query.text ?? ""`.
- **Confidence**: likely. Depends on `onChange(of: String?)` firing for a non-nil → nil
  change, which it does for any `Equatable` change; not run.

### F6. The year filter is silently dropped on the wire, though the API documents the parameter
- **What**: `yearFrom`/`yearTo` are "offline-only" because "no live check has confirmed
  the online search endpoint's year parameter names" (`SearchQuery.swift:22-28`).
  `docs/schemas/mangabaka_openapi.json` lists `published_start_date_lower` /
  `published_start_date_upper` on `/v2/series/search`, "Accepts YYYY, YYYY-MM, or
  YYYY-MM-DD" (and `year_lower`/`year_upper` on v1). `queryItems` never sends either.
- **Where**: `SearchQuery.swift:22-29`, `:84-116` (no year item), `SeriesRepository+Count.swift:28`.
- **Why it matters**: charter #1 in reverse — the model has the field, the API has the
  parameter, and the two never meet. Online, a lens "Manhwa from 2020" shows every year,
  `activeFilterCount` (`:71`) tells the empty state "1 filter active" for a filter that was
  never applied, and the "Show N results" count is for the unfiltered query. The same lens
  answers differently online and offline.
- **Effort**: a few lines plus one live measurement (the spec is not a payload; someone
  needs to curl `published_start_date_lower=2020&published_start_date_upper=2020` once and
  record the count). Then two `URLQueryItem`s in `queryItems`.
- **Confidence**: likely (spec-verified, not live-verified — exactly the caveat the comment
  asks for).

### F7. `sort_by=random` pages without `random_seed`, so page 2 is a fresh shuffle
- **What**: the spec has `random_seed` (−1…1) "to ensure consistent sorting" across pages.
  The app sends `sort_by=random` alone (`SearchQuery.swift:105`); `loadMore` documents that
  duplicates are "the normal outcome" under random (`SearchModel.swift:354-357`) and
  dedupes them.
- **Where**: `SearchQuery.swift:105`, `SearchModel.swift:354-357`, `SearchView.swift:216`.
- **Why it matters**: charter #6. Each page 2+ of "Surprise me" is 30 rows of which most
  may already be shown; after 3 mostly-duplicate pages the walk trips `stoppedEarly`
  (`:375-386`) and the reader reads "Stopped early" on a 300k-row catalogue. Three
  requests spent to add a handful of rows.
- **Effort**: a few lines — `var randomSeed: Double?` on `SearchQuery`, set once per
  "Surprise me" tap, sent as `random_seed`, cleared with `sort` at `:134`.
- **Confidence**: likely — the duplicate rate under random is not measured here, only the
  mechanism.

### F8. `q` is sent untrimmed, so a trailing space is a new request for the same answer
- **What**: `isEmpty` trims for the emptiness check (`SearchQuery.swift:53`) but
  `queryItems` sends `text` verbatim (`:97`). `"one "` (a pause after the first word of
  "one piece") is a different URL from `"one"`.
- **Where**: `SearchQuery.swift:87-97`.
- **Why it matters**: one extra request per pause-after-a-word for a result that will be
  identical (the API's fuzzy `q` will not change on a trailing space — an assumption; not
  measured). It also defeats any `URLCache` hit the server might allow.
- **Effort**: a line — trim at `:97`. Pair with F2 so the trimmed text is what is compared.
- **Confidence**: certain that the URLs differ; "identical results" is unmeasured.

### F9. No page cap; page 101 is a permanent "Try again"
- **What**: the spec caps `page` at 100. `loadMore` increments without bound
  (`SearchModel.swift:329`). At 30/page that is row 3,001; the server presumably answers
  4xx, which becomes `pageFailure` and an `InlineFailure` whose retry asks for page 101 again.
- **Where**: `SearchModel.swift:325-351`, `SearchQuery.swift:42-43` (documents the cap, does
  not enforce it).
- **Why it matters**: a reader who scrolls 3,000 rows of "Isekai" (7,105 results) ends on a
  retry button that can never succeed. Rare; a dead end when it happens.
- **Effort**: a line — `guard next.page <= 100 else { hasMore = false; return }`.
- **Confidence**: certain for the mechanism; what the server returns for page 101 is not
  on record.

### F10. Undated, underived constants (charter #4)
| Constant | Where | Status |
|---|---|---|
| 300 ms search debounce | `SearchModel.swift:146` | no derivation, no guess label. Interacts with F4 (the "Nothing matched" window is this long) and with typing cadence: at 200–300 ms/keystroke, a hesitant typer fires on every pause. |
| 350 ms count debounce | `FilterPanel.swift:288` | no derivation; a second debounce constant for the same shared window, 50 ms different from the first for no stated reason. |
| 250 ms lens-count spacing | `LensCounts.swift:34` | "enough that six lenses are a trickle" — no number behind it. With background priority now capping at 20 slots, the spacing is doing less than it was. |
| `limit = 30` | `SearchQuery.swift:41` | no derivation. API default is 10, max 100. 30 is 10 rows of the 3-column grid, which may be the reason; unsaid. |
| `maxConsecutiveEmptyPages = 3` | `SearchModel.swift:310` | labelled "arbitrary". Fine. |
| `pow(2, count)` capped at 60 | `RateLimitGate.swift:212` | no label; exponential backoff base and cap both unstated guesses. |
| `reserve = 10`, 200 ms poll, 15 min cap, 20 s timeout | `RateLimitGate.swift:107,115,91`, `APIClient.swift:26` | all labelled GUESS. Done right. |
| recents: 6 stored / 4 shown / min length 2 | `LensCounts.swift:163,169,183` | 4 labelled a guess; 6 and the length-2 minimum are not. |
- **Effort**: a comment each; the debounce and `limit` are the two worth a sentence of
  reasoning since they shape every search.
- **Confidence**: certain (these are the numbers in the files).

### F11. A single malformed row fails the whole page
- **What**: `getWithPagination` decodes `[Series]` as one array (`APIClient.swift:97-101`);
  Swift's array decoding throws on the first bad element. `search` catches it as
  `.decoding` (`SeriesRepository+Paging.swift:70-76`), which is not offline-eligible
  (`SearchModel.swift:253`), so the reader sees a full `FailureState`.
- **Where**: `APIClient.swift:97-101`, `SeriesRepository+Paging.swift:60-61`.
- **Why it matters**: charter #1's whole history — four decode mismatches so far, each of
  which would have blanked search for every query that happened to page over the bad row.
  `Series` has since been hardened (string-or-number fields, three tag shapes), so this is
  a resilience gap rather than a live bug.
- **Effort**: a file — a lossy array wrapper that skips undecodable elements and logs them,
  used for `[Series]` payloads only.
- **Confidence**: worth checking — no current payload is known to trip it.

### F12. Two search debounces with two owners
- **What**: `SearchModel.queryDidChange` debounces text (`:145`); `FilterPanel.scheduleCount`
  debounces filters (`:282`). Separate tasks, separate constants, separate cancellation.
  A reader who types *and* opens filters gets both.
- **Where**: `SearchModel.swift:145-149`, `FilterPanel.swift:282-293`.
- **Why it matters**: shotgun surgery — tuning "how eagerly does search talk to the network"
  is two edits in two files, and F3's fix (priority) lives in a third.
- **Effort**: a function — move the preview count into `SearchModel` as
  `previewCount(for:)` with its own debounce, so the panel is a dumb view.
- **Confidence**: certain.

### F13. The offline index re-filters and re-sorts all 19,300 rows on every page
- **What**: `matches` calls `filteredAndSorted` on the full entry list for every call
  (`OfflineCatalogue.swift:167-181`, `:231-258`) — a substring test on 19,300 titles plus a
  full sort — and page 2 repeats it to slice `[30..<60]`.
- **Where**: `OfflineCatalogue.swift:175-181`, `:244-257`.
- **Why it matters**: on an actor, so it does not block the main thread; but the cost per
  keystroke offline is unmeasured. The 200 ms load figure is the only measurement in the
  file and it is the wrong one for this question.
- **Effort**: a function — cache `(query, filters) → sorted ids` for the last query so
  paging is a slice. Only worth it if a measurement says the filter is slow on device.
- **Confidence**: worth checking — an unmeasured cost, not a known problem.

### F14. Offline "has more" reads `hits.count == limit`, the inference the online path was fixed to stop making
- **What**: `hasMore = hits.count == query.limit` (`SearchModel.swift:284`). Correct
  *here*, because the offline slice is not filtered after the fact — but it is the exact
  shape that broke online paging, sitting 50 lines from the comment explaining why.
- **Where**: `SearchModel.swift:281-284`.
- **Why it matters**: the next person to add a post-slice filter to `runOfflineSearch`
  reintroduces the bug. `OfflineCatalogue.count(...)` exists (`:187`) and would give a real
  "more exists" answer for free (it is the same filtered list's `.count`).
- **Effort**: a line — `hasMore = offset + hits.count < total` with `total` from the same
  filtered list (which F13 would make free).
- **Confidence**: certain that it is currently correct; the finding is fragility.

---

## Done well

- **The stale-response race is closed properly.** `generation` is bumped per search and
  checked after every await (`SearchModel.swift:178-189`, `:271`, `:334`), and the test at
  `SearchModelTests.swift:330` proves a late page for a replaced query is dropped.
- **`hasMore` reads the API's `pagination.next`, not survivor count**
  (`SeriesRepository+Paging.swift:67`, `FeedResult` doc at `SeriesRepository.swift:369-379`),
  with the "Isekai stuck at 30" measurement recorded beside it. The todo item is done.
- **A failed page is not the end of the feed** (`+Paging.swift:76`, `SearchModel.swift:347-351`)
  and is kept distinct from a filtered-empty page and from a real end (`:42-56`).
- **The empty-page walk is bounded** (`SearchModel.swift:310`, `:375-386`) with the budget
  reasoning written down and the constant labelled arbitrary.
- **Rate limiting is per family with a local sliding window and a reserve for the reader**
  (`RateLimitGate.swift:33-50`, `:136-149`, `:185`), every guessed constant labelled, and the
  clock injected so the tests advance time rather than sleep (`:69-79`).
- **Lens counts are one request per lens per session, spaced, background, and stop on the
  first refusal** (`LensCounts.swift:91-115`), with the queue-not-snapshot bug and its fix
  recorded (`:37-48`).
- **The `+` encoding decision is a measurement, not a guess** (`SearchQuery.swift:88-96`,
  dated, with both URLs and the id they answered).
- **Random sort is turned off the moment the reader types** with the exact measurement
  that motivated it (`SearchModel.swift:128-135`: 32 results without ONE PIECE vs 411 with it
  first).

## Unsure

- Whether `api.mangabaka.org` sends browser-side `Cache-Control` on `/v2/series/search`.
  If it does, `URLCache` (256 MB, `AppServices.swift:191`) is already serving repeated
  identical searches and F2/F8 cost server nothing — but they still cost local window slots.
  `NetworkLedger` latencies near zero for repeated searches would settle it.
- What the server returns for `page=101` (F9).
- Whether a trailing space changes fuzzy `q` results (F8).
- The on-device cost of an offline substring search over 19,300 titles (F13).

## Not reviewed

- `SeriesRepository+Cache.swift` — no search path in it (grep: zero hits for "search").
- `APIError.swift` beyond `.cancelled`/`.rateLimited`/`.offline` handling; the countdown
  and auto-retry behaviour (`FailureState`, `Countdown`, `RetryGate`) — the failure-kit slice.
- `Series` decoding itself against a recorded `/v2/series/search` payload (charter #1
  proper) — no recorded search payload was found under `docs/`; only the spec.
- `TagPickerSheet`, `SaveLensSheet`, `SearchLens` persistence, `CatalogueService`.
- `SeedPickerSheet`'s use of `SearchModel` (Mix batch).
- `PublisherView.swift:372-373` fires `search` and `count` concurrently at `.userInitiated`
  — two search-window slots per publisher page open; noted, not reviewed.
- Discover's `trending`/`newReleases`/`surprise` feeds are search-family
  (`SeriesRepository.swift:254-258`) and spend the same window at `.userInitiated`
  (`+Paging.swift:16`); cached 1 h / 30 min / never. Not reviewed beyond noting they share
  the budget.
