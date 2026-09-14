# Deep review, slice 6 — the screens that fetch

2026-09-14. Read-only against `99a1124`. Nothing built, run or edited. Slice:
`Features/Discovery` (883 lines), `Features/Mix` (1,244), `Features/Browse` (472),
`Features/Search` (3,571).

**Read in full (4,072 of 6,170 lines, 66%):** every file in Discovery, Mix and
Browse; in Search, `SearchModel` (632), `SearchView` (452), `SearchToken` (93),
`SearchField` (113), `SearchIdleView` (183). **Read only where a finding led
there:** `TagPickerSheet.swift:318-340`, `LensCounts.swift:194-201`. **Not read:**
`FilterPanel`, `SearchEmptyState`, `SearchLens`, `SaveLensSheet`,
`FilterPickerSheets`, `FilterSheet`, the rest of `TagPickerSheet` and `LensCounts` —
all covered by yesterday's six-report Search review, none touched by the
`.searchable` rebuild. Opened to verify a claim: `SeriesRepository.swift` (FeedKind,
`feed`, `mix`, `FeedResult`), `+Paging`, `+Cache`, `+Priority`, `RateLimitGate`,
`RequestPriority`, `APIClient` (perform, conditional get), `APIError` (cancelled),
`CoverStore`, `CoverImage`, `RowAmbient`, `CommunityPulseService`, `CatalogueService`,
`ShelfStore`, `HistoryStore`, `SearchQuery`, `RootView.swift:150-312`,
`RootView+Failures.swift:1-30`, `BrowseDestination`, `Resources/TagTaxonomy.json`,
`SearchAndMixTests.swift:288-303`.

Already on record and **not re-filed**: the 56 fixed Search findings
(`docs/reviews/search/STATUS.md`), and the Discover/Mix/Browse rows of
`docs/reviews/failures-discovery.md` (D1–D14, M1–M10, B1–B4) — every one I checked
has landed (`gap 13/15/47` in `DiscoverModel`, `gap 11/43/44/45` in Mix, `gap 39` in
Browse). What follows is what those passes did not look at: what fires on re-appear,
what a cancellation does, what a filter change actually sends, and what the view
builds per state change.

## Measurements made today (2026-09-14, `curl`, `api.mangabaka.org`)

| Question | Request | Answer |
|---|---|---|
| Does `/v1/series/mix` honour a tag by **name**? | `series=14619&strict=false&limit=3&tag=Isekai` | First id `25479` — identical to the same call with **no** `tag` at all (`[25479, 13724, 17868]`). Shared tags of the first row: Nekomimi, Animal Transformation… no Isekai. **A name is ignored.** |
| …by **id**? | `…&tag=94` | First id `523141`, shared tags led by `{94, Isekai}`. **An id filters.** |
| Does `tag_mode=or` do anything on mix, measured with ids this time? | `…&limit=10&tag=94&tag=748` with and without `&tag_mode=or` | Same ten ids in the same order both ways (`398925, 57607, 44139, …`). No effect. |
| Is "Regression" in the bundled taxonomy? | `Resources/TagTaxonomy.json` (2,686 entries) vs `/v1/tags?q=Regression&limit=5` | Not bundled; the API's tag count is 7,146 (`CatalogueService.swift:96`). `SearchAndMixTests.swift:301` already shows it going out as the literal `"Regression"`. |

## Ranked top ten (value against effort)

1. **Mix's "Require tags" silently does nothing for any tag the bundle cannot name** — M-1. Measured. A function.
2. **Discover re-fetches and throws away paged rows on every tab switch and every pop from a series page** — D-1. A function.
3. **A cancelled Discover load is shown as a "Cancelled" failure, then re-requested** — D-2. A line.
4. **Return on a one-character field with a filter set runs a filter-only search under that letter** — S-1. A line.
5. **A token-only search (tag from a series page, a Browse pick) is wiped when a cover is tapped** — S-2. A line. Likely, not certain.
6. **Mix shows a strand twice for the 350 ms after it is excluded; permanently if the re-blend fails** — M-2. A line.
7. **Rating and the tag picker change Mix's query without re-blending; type and tag chips do** — M-4. A line.
8. **Every saved series is rendered and its cover fetched the moment Mix opens with no seeds** — M-5. A line.
9. **Scope-bar taps are undebounced `/v2/series/search` requests, one per tap** — S-3. A line.
10. **A keystroke while a publisher search is in flight flashes "Could not search publishers"** — B-1. A line.

Everything else below is real but smaller.

---

## Discover

### D-1. `load()` re-runs on every appearance and resets every row to page 1

- **What** — `.task { await model.load() }` has no id and no "already loaded" guard, so it runs each time the Discover tab is reselected and each time a series page is popped; `loadRows` then replaces every row's `series` with page 1 and resets its paging.
- **Where** — `DiscoverView.swift:146`; `DiscoverModel.swift:96-140` (`:115` `rows[index].series = result.series`, `:120-123` `page = 1`, `hasReachedEnd = false`, `reloads += 1`); `SeriesRepository.swift:467-469` (cache hit inside `freshness`), `:502-505` (a conditional GET at `.userInitiated` once past it — 1,800 s for New releases, 3,600 s for Trending, `FeedKind.freshness`).
- **Why it matters** — a reader who scrolled Trending to page 3 (60 covers), opened one and came back gets 20 covers and a horizontal offset clamped to wherever the shorter row ends; the next scroll to the end fetches page 2 again. Inside the TTL it is four actor-serialised cache reads (80 `Series` decodes) plus a `COUNT(*)` per appearance; past it, four `.userInitiated` requests (304s, but requests — the ledger and the 180/min counter both see them) for a screen the reader did not ask to refresh. `cancelSearch`-style "the reader left, keep what they had" is what every other screen does.
- **Fix** — in `loadRows`, when a row already has content and the result's origin is `.cache`, leave `series`/`page`/`hasReachedEnd` alone (the cache is what the row is already showing) and only apply `.network`/`.staleAfter` results; and give `load()` a `hasLoadedOnce` short-circuit unless `forceRefresh`. Keep `.refreshable` as the explicit path.
- **Effort** — a function. **Confidence** — certain that `.task` re-runs on reselect/pop and that rows are reset; *worth checking* whether the iOS 26 `Tab` keeps the content view alive (silent replace) or rebuilds it (skeleton flash — see D-5). One `print` in `DiscoverModel.loadRows` and a tab switch settles it.
- **Lens** — 3, 6.

### D-2. Cancellation is recorded and rendered as a failure

- **What** — a load cancelled because the reader navigated away is written into `rows[index].failure` and `failure` as `.cancelled`, which `APIError` documents as "never meant to reach a screen — callers drop it silently".
- **Where** — `DiscoverModel.swift:124-126` (`if case let .staleAfter(error) = result.origin { rows[index].failure = error; firstFailure = … }`); `APIError.swift:288-291`; `APIClient.swift:173-179` (URLError.cancelled → `.cancelled`); `SeriesRepository.swift:524-529` (`feed` returns `.staleAfter(error)` with whatever was cached — nothing, on first launch); rendered at `DiscoverView.swift:202-207` (`InlineFailure`, headline "Cancelled") and `:336-339` (`FailureState` when every row is empty).
- **Why it matters** — tap "Pick back up" or switch tabs within the first second of a cold launch: `.task` is cancelled, the four in-flight requests die, four rows say "Cancelled", and the return trip (D-1) issues four more. Eight requests and a flash of failure for one screen. `Task.isCancelled` is never consulted in `loadRows`.
- **Fix** — in the `for await` loop: `if case .staleAfter(.cancelled) = result.origin { continue }` (leave `isLoading` as it was so the next load's skeleton is honest), and `guard !Task.isCancelled` before `failure = firstFailure`. Same one-liner in `loadMore` for `pageFailure`.
- **Effort** — a line. **Confidence** — certain by construction; likely to be seen on a device (the Stack tab is one tap away at launch).
- **Lens** — 2, 6.

### D-3. `RootView` builds a `DiscoverModel` it never shows

- **What** — the Discover tab is built during `RootView.body` with `discoverModel ?? DiscoverModel(repository:)`; `discoverModel` is only created in a `.task` that runs after that body, and `DiscoverView` keeps its first model in `State(initialValue:)`. Every later `RootView.body` allocates another throwaway.
- **Where** — `RootView.swift:206`; `:299-305` (`if discoverModel == nil { discoverModel = … }`); `DiscoverView.swift:36`.
- **Why it matters** — harmless today because nothing else reads `discoverModel` — but this is exactly the shape of gap 77 (`RootView+Failures.swift:9-21`), where `mixModel` was a different instance from the one on screen. The comment at `:300` ("created once and kept") is not true for the first tab. If the tab content is rebuilt on reselect (D-1's open question), the second appearance swaps in RootView's never-loaded instance and the screen goes back to skeletons.
- **Fix** — construct the four models in `RootView.init` (or as `@State` with a default that closes over `repository` via an `AppServices` singleton), and drop the `??` fallbacks so there is one instance per screen by construction.
- **Effort** — a function. **Confidence** — certain for Discover; worth checking for Mix/Search/Browse, whose tabs are probably built lazily after the `.task` has run.
- **Lens** — 3, 9.

### D-4. Formatters allocated per body evaluation

- **What** — `staleDetail` creates a `RelativeDateTimeFormatter` and `todayLine` runs `Date().formatted(…)` on every `DiscoverView.body`.
- **Where** — `DiscoverModel.swift:172-179`; `DiscoverView.swift:176-180`.
- **Why it matters** — body runs on every `rows` mutation (D-6). A formatter is ~0.5 ms to build; small, but it is the kind of main-thread cost that adds up under a stale bar during scroll.
- **Fix** — `private static let relative = RelativeDateTimeFormatter()`; format the weekday once per day in `.task` or cache it in the model.
- **Effort** — a line. **Confidence** — certain, low impact. **Lens** — 7.

### D-5. One `rows` array means every page fetch rebuilds four rows

- **What** — `rows` is a single observed property; `loadMore` toggles `rows[index].isLoadingMore` twice, and `ForEach(model.rows)` re-evaluates all four `rowView`s each time, each recomputing `RowAmbient.tint` (six BlurHash DC decodes and an HSB conversion).
- **Where** — `DiscoverModel.swift:195-196`; `DiscoverView.swift:122-124`, `:229` (`.rowAmbient(row.series)`); `RowAmbient.swift:67-89`.
- **Why it matters** — per page fetch: 2 body passes × 4 rows × `tint`. Not measured; `BlurHash.averageColour` may be cheap. Flagged because it is the one per-state-change cost on this screen the brief asked about.
- **Fix** — make `Row` a small `@Observable` class so `isLoadingMore` invalidates one row; or memoise `tint` on the row keyed on the first six ids.
- **Effort** — a function. **Confidence** — worth checking: an Instruments "SwiftUI View Body" count while paging Trending settles it. **Lens** — 8.

### D-6. Community pulse retries on every appearance with no backoff

- **What** — `load()` is guarded on `pulse == nil`, so after a failure every Discover appearance (tab switch, pop) spends one `/v0/frontpage/community-pulse` request.
- **Where** — `CommunityPulseService.swift:32-40`; `DiscoverView.swift:148`.
- **Why it matters** — offline or throttled, each visit costs a request from the 180/min window for a "grace note". Bounded by how often the reader returns; not a loop.
- **Fix** — remember `failedAt` and skip for, say, the same 60 s the gate's own backoff uses.
- **Effort** — a line. **Confidence** — certain, low impact. **Lens** — 6.

---

## Mix

### M-1. "Require tags" sends names that `/v1/series/mix` ignores

- **What** — Mix stores required tags by **name** and hands them to `SearchQuery.queryItems`, which resolves names to ids through the bundled taxonomy and sends anything it cannot resolve as the literal name. The bundle holds 2,686 of the API's 7,146 tags. `/v1/series/mix` ignores a name outright (measured today, table above).
- **Where** — `MixFilterStrip.swift:85-91` (`toggleTag(strand.name)` — `strand.tagId` is in scope and discarded), `:151-163`; `TagPickerSheet.swift:329-336` (`selected.append(name)` — `tag.id` in scope); `SearchQuery.swift:223-235` (`wireTagIDs`, fallback `?? tag`); `SeriesRepository.swift:535-540` (`mix` reuses `filters.queryItems`); `Resources/TagTaxonomy.json` (2,686 entries).
- **Why it matters** — a reader taps a DNA chip like "Regressed Male Lead" (id 2461, not bundled) to require it; the chip lights, the re-blend runs, and the results are exactly the unfiltered blend. Nothing says so. The same names reach `/v2/series/search` from Search's picker and Browse (`BrowseDestination.swift:29` passes `$0.name`), where a name "finds a fraction" (`SearchQuery.swift:120-126`) — already on record for Search; for Mix the fraction is zero.
- **Fix** — carry the id. Smallest: `MixModel` keeps `tagIDsByName: [String: Int]`, filled from every `dna.strands` answer and from the picker's `Tag`s (give `TagPickerSheet` an `onPick: (Tag) -> Void` beside the name binding); `SeriesRepository.mix` takes `tagIDs: [Int]` and appends them directly, bypassing `wireTagIDs` for Mix. Cleaner and longer: `SearchQuery.tags: [TagRef]` with `id: Int?, name: String`, decoded `IfPresent` for old lenses. Add a test that a DNA strand with an unbundled name reaches the wire as its id — it fails today with the name.
- **Effort** — a function (the map) or a redesign (`TagRef`). **Confidence** — certain on the wire; the "ignored" half rests on today's three-request measurement and should be re-checked before the redesign.
- **Lens** — 1, 3.

### M-2. An excluded strand is drawn twice until the re-blend lands

- **What** — `toggleStrand` appends the strand to `excludedStrands` synchronously; `dna.strands` still contains it for the 350 ms debounce plus the request; `BlendDNAView` renders both lists.
- **Where** — `MixModel.swift:135-138`, `:147-155` (debounce); `BlendDNAView.swift:32-37` (two `ForEach`es), `:98` (`matchedGeometryEffect(id: strand.tagId)`).
- **Why it matters** — two chips with one id in a `ForEach` and one `matchedGeometryEffect` id: a runtime warning and a doubled chip, one struck through, for ~½ s on every exclusion. If the re-blend fails, `run()` now (correctly) keeps the old `dna` (`MixModel.swift:107-114`) — and the duplicate is permanent. Re-including has the mirror problem: the strand leaves `excludedStrands` (`:131`) before it is back in `dna`, so the chip vanishes for the same window.
- **Fix** — `ForEach(dna.strands.filter { !excluded.contains($0.tagId) })` at `BlendDNAView.swift:32`; on re-include, keep the strand in `excludedStrands` (drawn as included) until the next `run()` clears it.
- **Effort** — a line each. **Confidence** — certain by construction. **Lens** — 1.

### M-3. A cancelled blend is shown as "Cancelled"

- **What** — `requestBlend`/`blendAfterEdits` cancel the pending task whether it is still sleeping or already inside `run()` awaiting the network. The request dies with `.cancelled`; `run()` passes its generation guard (the replacement is still asleep and has not bumped it) and stores `failure = .cancelled`.
- **Where** — `MixFilterStrip.swift:144-151`; `MixModel.swift:147-155`, `:103-114` (`guard mine == generation` then `failure = error`); `SeriesRepository.swift:564-569`; `MixResults.swift:35-38` (`.failure` wins when results are empty).
- **Why it matters** — tap a type chip, then another ~400 ms later: on a first blend the grid area shows `FailureState` "Cancelled" with a Retry for the 350 ms until the replacement runs; with results up, the grid un-dims and "Reshuffle" flickers back. `APIError.swift:288-291` says callers must drop this case.
- **Fix** — in `run()`: `if case .cancelled = error { return }` before `failure = error` (the `defer` still clears `isRunning`; the replacement sets it again 350 ms later). Better still, do not cancel a task that has passed its sleep — track `isSleeping` and let the in-flight run finish under the generation guard.
- **Effort** — a line. **Confidence** — certain by construction. **Lens** — 2.

### M-4. Three filter controls, one of them re-blends

- **What** — type chips and tag chips call `requestBlend()`; the rating segments and the tag picker sheet write `model.filters` and nothing re-blends.
- **Where** — `MixFilterStrip.swift:161,171` (re-blend); `:34` (`RatingSegments(minimum: $model.filters.minimumRating)`, no `onChange`); `MixView.swift:74-82` (`TagPickerSheet(selected: $model.filters.tags…)`, no `onDismiss`).
- **Why it matters** — set 8+ after a blend and the grid keeps showing 6.1-rated series under a control that says 8+; add a tag from the picker and the chip appears selected over results that never required it. The reader has to know that Blend/Reshuffle is what applies it — the chips taught them otherwise.
- **Fix** — replace the two explicit calls with one `.onChange(of: model.filters) { _, _ in requestBlend() }` on the strip (debounced already), and delete the per-chip calls.
- **Effort** — a line. **Confidence** — certain. **Lens** — 1.

### M-5. Every saved series is built, animated and fetched when Mix opens with no seeds

- **What** — `suggestedSeeds()` returns the whole saved shelf (no `LIMIT`), and the section draws it in a non-lazy `HStack`, so every `CoverImage` starts its `.task(id:)` at once.
- **Where** — `MixModel.swift:82` → `ShelfStore.swift:46-61` (no limit; decodes every payload on the actor); `MixView.swift:71-73` (`.task` on every appearance), `:177-192` (`HStack`, `.arrives()`, `.enterScale()` per item); `CoverImage.swift:78` (`.task(id: url)`); `CoverStore.swift:57-70` (unbounded `inFlight`).
- **Why it matters** — a Stack user with 300 saves opens Mix: 300 payload decodes on the `ShelfStore` actor, 300 view bodies, 300 arrival springs, and 300 cover requests queued against the image host in one frame — for a row that shows six. Repeated on every appearance of the tab.
- **Fix** — `LazyHStack`, and `.prefix(24)` in `suggestedSeeds()` (or `LIMIT 24` in `ShelfStore.entries`).
- **Effort** — a line. **Confidence** — certain by construction; magnitude scales with the shelf. **Lens** — 6, 7.

### M-6. A filter tap with no seeds prints a blend error

- **What** — `requestBlend()` runs `run()` regardless of seeds; with none, `run()` sets `message = "Add at least one series to blend from."`, which `MixResults` renders.
- **Where** — `MixFilterStrip.swift:144-150`; `MixModel.swift:86-91`; `MixResults.swift:38,59-63`.
- **Why it matters** — a reader setting Manhwa before picking seeds is told off for a request they did not make. The Blend button already explains the same rule by being disabled (`MixView.swift:232`).
- **Fix** — `guard !model.seeds.isEmpty else { return }` at the top of `requestBlend`.
- **Effort** — a line. **Confidence** — certain. **Lens** — 9.

### M-7. `tagMode` is written and never sent

- **What** — `toggleTag` sets `filters.tagMode = "and"` and `TagPickerSheet` writes `mode`; `SearchQuery.queryItems` sends `tag_mode=and` from the tag count alone and ignores the field.
- **Where** — `MixFilterStrip.swift:159-162`; `MixView.swift:79`; `SearchQuery.swift:133-136`, `:22-29`.
- **Why it matters** — dead writes that read as live; the next person tunes them. The measurement note at `MixFilterStrip.swift:67-71` ("same 50 ids with and without `tag_mode=or`") was taken with tag **names**, which mix ignores (M-1) — it measured nothing (charter pattern 5). Re-measured today with ids 94+748: still identical with and without `or`, so the conclusion stands on real evidence now.
- **Fix** — delete the `tagMode` writes; update the comment to cite the id-based measurement and date.
- **Effort** — a line. **Confidence** — certain. **Lens** — 9, charter 5.

### M-8. The `SearchModel.message` shim outlived its reason

- **What** — `SearchModel.message` exists "so `SeedPickerSheet` keeps compiling… delete once that caller reads `failure` itself"; both changes landed and the sheet still reads `message`.
- **Where** — `SearchModel.swift:102-108`; `SeedPickerSheet.swift:172,175`.
- **Fix** — read `search.failure?.userFacingMessage` in the sheet, delete the shim.
- **Effort** — a line. **Confidence** — certain. **Lens** — 9.

### M-9. The seed picker's search outlives the sheet

- **What** — dismissing the sheet drops its `SearchModel`; an in-flight debounced search keeps running (`[weak self]`, so the answer is discarded) and its search-window slot is spent.
- **Where** — `SeedPickerSheet.swift:19,26`; `SearchModel.swift:124,188-192`.
- **Fix** — cancel `debounceTask` when the sheet disappears (`.onDisappear { search.cancelPendingDebounce() }` cancels the sleeping task; the in-flight one is the same task, so the request is cancelled too).
- **Effort** — a line. **Confidence** — certain, low impact. **Lens** — 6.

---

## Browse

### B-1. A keystroke during an in-flight publisher search flashes a failure

- **What** — `schedule()` checks cancellation only before the request. A keystroke cancels the task mid-request; `searchPublishers`'s `try?` turns `.cancelled` into `nil`; the old continuation writes `didFail = true, results = []`.
- **Where** — `PublisherBrowser.swift:104-114`; `CatalogueService.swift:205-213`.
- **Why it matters** — type "seven" one letter at a time past the first debounce and "Could not search publishers just now." shows between each cancelled request and the next 350 ms debounce. It also resets `isSearching` under a request that is about to start.
- **Fix** — `guard !Task.isCancelled else { return }` after the `await`, before touching state.
- **Effort** — a line. **Confidence** — certain by construction. **Lens** — 2.

### B-2. A genres-only failure is never retried

- **What** — `load()` returns early when `tags` is non-empty, so if tags loaded and genres failed, the genre row stays empty for the session.
- **Where** — `BrowseModel.swift:82` (`guard tags.isEmpty`), `:85-89`.
- **Fix** — `guard tags.isEmpty || genres.isEmpty`. `CatalogueService` already dedupes and does not cache a failure (`:44-47,54-56`), so the retry is one request.
- **Effort** — a line. **Confidence** — certain. **Lens** — 2.

### B-3. Genres and tags fetched one after the other

- **Where** — `BrowseModel.swift:85-86`.
- **Fix** — `async let`. One round trip off the first paint of Browse.
- **Effort** — a line. **Confidence** — certain, small. **Lens** — 7.

### B-4. `sections` regroups and re-sorts on every body

- **What** — `visibleTags` filters and `sections` groups + sorts 200 tags as computed properties read from `body`.
- **Where** — `BrowseModel.swift:53-70`; `BrowseView.swift:60`.
- **Why it matters** — every `showsSpoilers` toggle and every `blocked` change re-runs it. 200 tags is sub-millisecond; recorded as a note, not a defect.
- **Fix** — none needed at 200; cache if the limit grows.
- **Effort** — —. **Confidence** — certain, negligible. **Lens** — 8.

Browse's catalogue load otherwise reads well: `CatalogueService.tags` serves a smaller ask from a bigger cache and dedupes in-flight (`:69-72`), and the screen's three-way skeleton/failure/list is exactly the gap-39 fix (`BrowseView.swift:39-45`).

---

## Search — what the `.searchable` rebuild introduced

Checked: `hasAsked`/`isPending`, `SearchToken`, `SearchScope`, `cancelSearch`, the
scroll reset, the minimum-length rule. The state machine is sound; the holes are at
its edges.

### S-1. Return on a one-character field with a filter runs a filter-only search under that letter

- **What** — the minimum-length rule lives in `askedText`; a keystroke path goes idle when it is nil, but `search()` only guards `!query.isEmpty`, which is false whenever any filter is set.
- **Where** — `SearchQuery.swift:170-180` (`askedText`), `:69-74` (`isEmpty`); `SearchModel.swift:181-185` (keystroke → idle), `:261-267` (`search()` guard); `SearchField.swift:48-52` (`onSubmit` → `search()`).
- **Why it matters** — Type=Manhwa on the panel, type "a", press Return: `q` is omitted, 21,596 manhwa arrive under a field showing "a" and a heading "21,596 results". The LW#59 shape by a different door. Recents refuses the term (`LensCounts.swift:196`), so the two rules disagree again.
- **Fix** — in `search()`: `if let text = query.text, !text.isEmpty, query.askedText == nil { isPending = false; return }` — a typed-but-too-short field is not an ask, whatever the filters.
- **Effort** — a line. **Confidence** — certain by construction. **Lens** — 1.

### S-2. A token-only search is thrown away when a result is tapped

- **What** — `onChange(of: isPresented)` treats "dismissed with empty text" as Cancel. A search made of tokens alone — a tag from a series page (`openTag`), a Browse pick, a lens with no text — has empty text by definition.
- **Where** — `SearchField.swift:53-60` (`guard !presented, text.isEmpty else { return }; model.cancelSearch()`); `SearchModel.swift:199-206`, `:563-568`.
- **Why it matters** — series page → tap "Isekai" → results → tap a cover → back: the idle panel, token gone. The file's own doc comment (`SearchField.swift:12-18`) says a push dismisses the field and relies on the text guard to tell that from Cancel — the guard cannot when there is no text.
- **Fix** — guard on `text.isEmpty && SearchToken.tokens(for: model.query).isEmpty`, or remember whether the field had text *before* dismissal and only cancel when the platform emptied it.
- **Effort** — a line. **Confidence** — likely; depends on `isPresented` flipping on push, which the author's comment asserts. One tap on a token-only result on the simulator settles it.
- **Lens** — 1.

### S-3. Scope taps and token removals fire an immediate request each

- **What** — `filtersDidChange` cancels the debounce and calls `search()` at once; the "already answered" skip cannot apply because the query differs.
- **Where** — `SearchField.swift:73-96` (both setters → `filtersDidChange`); `SearchModel.swift:212-216`.
- **Why it matters** — All → Manga → Manhwa → Manhua in two seconds is three `/v2/series/search` requests from the 30/min window, each superseding the last (generation guard) so two answers are downloaded and thrown away.
- **Fix** — route through the existing 300 ms debounce (`queryDidChange`'s task) instead of `search()` directly; the scope bar reads the query back, so nothing visible changes.
- **Effort** — a line. **Confidence** — certain. **Lens** — 6.

### S-4. A Recent suggestion may search twice

- **What** — `.searchCompletion(term)` sets the text and submits. The text change reaches `queryDidChange` and schedules a debounce; `onSubmit` searches at once. If the change observer runs after the submit, the debounced `search()` fires 300 ms later, and unless the first answer landed inside that window `answered` does not match, the generation bumps, and the first answer is discarded — the E F5 shape, handled for `apply` via `appliedText` but not here.
- **Where** — `SearchField.swift:104-111`, `:48-52`; `SearchView.swift:88`; `SearchModel.swift:125-131`, `:160-164`.
- **Fix** — have `onSubmit` mark the text as applied (expose `SearchModel.noteSubmitted()` that sets `appliedText = query.text ?? ""` before `search()`), so the trailing observer is ignored the same way.
- **Effort** — a line. **Confidence** — worth checking: the order of `onChange` versus `onSubmit` is SwiftUI's; the ledger (`NetworkLedger`) after one suggestion tap would show one request or two.
- **Lens** — 6.

### S-5. The scroll reset fires before the answer

- **What** — `generation` bumps at the start of `search()`; the grid, still showing the previous answer dimmed, jumps to the top ~½ s before it is replaced.
- **Where** — `SearchView.swift:89-91`, `:326`; `SearchModel.swift:290`.
- **Fix** — reset on `results` changing while `generation` differs from the one last scrolled for — or accept it (R F5 asked for a reset; this is a timing note).
- **Effort** — a line. **Confidence** — certain, cosmetic. **Lens** — 9.

### STATUS.md's open items

- **#35 (three debounce constants)** — nothing new; S-3 adds a fourth path with *no* debounce, which is the one worth fixing.
- **#58 (silent disabled bookmark)** — not in the files I read; not reviewed.
- **#60 (AutoFill chip)** — platform; `SearchField.swift:40-47` documents the limit correctly. Nothing to add.

---

## Cross-cutting: the rate-limit picture for these four screens

- Discover: 4 `.userInitiated` on first load (two of them `/v2/series/search`, i.e. the **30/min** family — `FeedKind.path`, `SeriesRepository.swift`), plus one general for the pulse; paging at `.background` (`DiscoverModel.swift:205`), which is right. D-1/D-2 multiply the first-load cost by re-appearances.
- Mix: one general (`/v1/series/mix`) per blend, debounced at 350 ms for chips and strands (`MixModel.strandDebounce`); the seed picker's search is a full `SearchModel` on the 30/min window at `.userInitiated`.
- Browse: two general on first load, cached for the process; publisher search debounced 350 ms, general.
- Search: one search-family request per debounced keystroke, per scope tap (S-3), per token removal, per Return that changes the query; lens counts and preview counts at `.background` under the 20-slot cap (`RateLimitGate.swift:107`).
- Nothing in the slice fires per scroll tick: Discover's `onAppear` per card only calls `loadMore` under `canLoadMore` and `CoverStore.prefetch` skips cached and in-flight URLs (`CoverStore.swift:84-89`).
- **No force-unwraps, `try!`, `as!`, `fatalError` or `assumeIsolated` in the slice** (grep, 2026-09-14). `BlendDNAView.swift:113` uses `Int(wholeOrClamped:)`.

## What the slice does well

- `DiscoverModel.loadMore` records why the reload check compares `reloads` rather than `page` and that the first attempt failed a test (`DiscoverModel.swift:207-213`); the generation guard on `loadRows` carries its gap number (`:78-84`). Both are findable because the comment says what was tried.
- Feed freshness is derived from the endpoints' own `x-cache-ttl-cdn-seconds` and `limit` from each endpoint's maximum (`SeriesRepository.swift`, `FeedKind.limit`/`freshness`), and the conditional GET is a dated measurement (`:476-482`, 2026-09-13: no `ETag`, `Last-Modified` + 304 with a zero-byte body).
- Two independent rate-limit families with a reserved foreground share, each constant labelled a guess where it is one (`RateLimitGate.swift:98-115`).
- Discover and Search both dedupe ids across pages before `ForEach` (`DiscoverModel.swift:230-231`, `SearchModel.swift:498-499`), and paging reads the API's `pagination.next` rather than inferring the end from a filtered page (`+Paging.swift:10-14`).
- `MixResults.state`, `SeedPickerSheet.emptyCopy`/`capFootnoteText`, `BlendDNAView.diff`, `SearchHeading.text`, `SearchToken`, `SearchScope` are pure decisions with tests, in a project with no ViewInspector.
- `PublisherBrowser` and `CatalogueService.searchTags` return nil, not `[]`, on failure, and the screens say which (`PublisherBrowser.swift:36-45`).
- `RowAmbient` records its strength as a guess with the measured pixel values that led to it (`RowAmbient.swift:26-31`).
- `WhatsNewState.isDue` is pure and says why, with the write moved to `.task` (`WhatsNew.swift:58-80`).
- `SearchQuery.wireTagIDs` is backed by four dated count measurements showing why names are the wrong wire form (`SearchQuery.swift:120-126`) — which is what made M-1 checkable.

## What I could not determine

1. **Whether the iOS 26 `Tab` keeps Discover's content view alive across a tab switch** (D-1/D-3): silent page-1 replace versus a skeleton flash. One `print` in `DiscoverModel.init` and `loadRows`, one tab round-trip.
2. **Whether a `NavigationStack` push sets `.searchable(isPresented:)` to false** (S-2): the author's comment says yes. Tap a token-only result on the simulator and pop.
3. **`onChange(of: text)` versus `onSubmit` ordering for `searchCompletion`** (S-4): read `NetworkLedger` after one suggestion tap — one request or two.
4. **Cost of `RowAmbient.tint` per body** (D-5): Instruments, SwiftUI View Body, while paging Trending.
5. **How many tags the DNA typically returns outside the bundle** (M-1's blast radius): log `wireTagIDs`' unresolved names for a day of blends. The bundle is 2,686 of 7,146, so a third to a half of DNA strands is a fair prior.
6. **Whether `/v1/series/mix` rejects or ignores an unknown id** — not needed for M-1's fix, but `tag=99999999` once would tell whether a stale id fails loud.
