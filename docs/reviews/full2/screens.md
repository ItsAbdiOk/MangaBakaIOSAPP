# Second-pass review — slice 4: the screens that fetch, and the series page

Scope: `Features/Discovery/**`, `Features/Search/**`, `Features/Mix/**`, `Features/Browse/**`,
`Features/Detail/**`, `Features/Schedule/**` at HEAD `fee95b0`. Read-only; no build, no test,
no simulator, no curl (nothing here needed a wire answer). Date: 2026-09-14.

**Fraction read.** 51 files, 14,430 lines. Read in full: every file in Search, Discovery, Mix,
Browse and Schedule, and in Detail: `SeriesDetailView` + its four extensions, `ScrollTracker`,
`DetailBarTitle`, `DetailBackdrop`, `DetailHero` (all but lines 1–30), `SeriesPager`,
`DetailOnwardRows`, `CharacterRow`, `PortraitImage`, `VolumesSection`, `CoverGallery`,
`LibraryControl`, `PublisherView`, `CharacterProfileView` (to line 447 of 533). About 4,500 of
those lines were read with comment-only lines stripped to fit the budget, so a comment that now
lies in those files would not have been caught. Nine small Detail files (`DetailScheduleBlock`,
`DetailStatsStrip`, `TrackerScores`, `AlternativeTitles`, `ReadRow`, `DetailSynopsis`,
`DetailCategories`, `DetailEditions`, `AppleVolumesRow`) plus `DetailTagSections`,
`DetailCredits`, `LinksSection`, `ReleaseSection` were grepped for lifecycle hooks, network calls,
formatters, force-unwraps and index maths only, not read line by line. Call it 90% read, 10%
scanned. Files outside the slice were opened only to settle a question the slice raised
(`SearchQuery`, `RootView+Session`, `RootView+Tabs`, `SeriesRepository+Mix`, `FailureState`,
`CommunityPulseService`, `TasteProfile.note`, `LibrarySnapshot.all`, `AniListClient`).

Prior reports honoured: `docs/reviews/full/discovery-ui.md`, `detail-ui.md`, the three walks,
`search/STATUS.md`, and `SUMMARY.md` §6 (do not fix) and §7 (could not determine). Nothing below
re-files an item from those unless it says why the earlier decision no longer holds.

---

## Ranked top ten (value against effort)

| # | Finding | Where | Effort | Confidence |
|---|---------|-------|--------|------------|
| 1 | The series page re-runs its whole `load()` — 4 MangaBaka legs, then cast, cadence, Apple, Google, Open Library, release feeds, MangaUpdates categories — and visibly resets to the unfilled series on **every pop-back** from a character sheet, a publisher page, a related series, and on every close of the cover gallery (F1) | `SeriesDetailView.swift:344, 489-495` | a function | likely |
| 2 | A tag tapped on a series page reached from Search does nothing visible: `openTag` runs but `searchPath` still holds the series page on top of the results (F5) | `RootView+Session.swift:441-458`, `RootView+Tabs.swift:108-117` | a line | likely |
| 3 | The publisher page re-fetches page 1 on every pop-back (loses paging, spends 2 of the 30/min) and always spends a third search-window request on a `count` the search response already carries; a source-text test pins the duplicate (F9, F10) | `PublisherView.swift:141, 359-393`; `PublisherPageTests.swift:123` | a function | certain (count), likely (re-run) |
| 4 | Publisher search spinner sticks forever after a keystroke cancels an in-flight search and the field drops to one character — the B-1 fix introduced it (F14) | `PublisherBrowser.swift:95-121` | a line | certain |
| 5 | The seed picker shows "Nothing called “x”." for 300 ms after every keystroke — it reads `isSearching` and ignores `isPending`, the exact E F4 bug the main Search screen fixed (F17) | `SeedPickerSheet.swift:172-183` | a line | certain |
| 6 | Removing the last token of a token-only search fires a **sort-only** search of the whole catalogue under an empty field, and Cancel leaves the app-chosen `popularity_asc` on every title typed afterwards (F6, F7) | `SearchModel.swift:216-240, 294, 586, 597`; `SearchQuery.swift:69-74` | a function | likely |
| 7 | The hero's `MeasureKey` retires the three measurers before `extras` and the cadence land, so the form is chosen against heights measured on the wrong column (F2) | `DetailHero.swift:49-53, 189-191, 213-216` | a function | likely |
| 8 | Every tap in Mix's tag picker fires a `/v1/series/mix` request 350 ms later while the sheet is still open (F20) | `MixFilterStrip.swift:59, 159-174`; `MixView.swift:81-85`; `TagPickerSheet.swift:343-351` | a few lines | likely |
| 9 | The community-pulse "remember `failedAt`, skip 60 s" fix in Lane D's fold-in list never landed: an offline reader still spends one request per Discover appearance (F12) | `Core/Model/CommunityPulseService.swift:32-40`; `DiscoverView.swift:148` | a few lines | certain |
| 10 | A 429 with nothing on screen falls back to the offline index and strands the reader there: `failure` is cleared, `answered` is set, so no countdown, no auto-retry, and Return is refused (F8) | `SearchModel.swift:368-372, 412-434, 302`; `SearchView.swift:333-344` | a function | likely |

Runners-up in order: F3 (`.cancelled` reaches three sections on the series page), F11
(Discover's per-row retry re-pays all four rows), F16 (`LibraryControlModel.needsAccount`
computed and never read), F22 (`CoverGallery` rebuilds its whole body per scroll frame), F23
(`CharacterProfileView` builds its own AniList and Shikimori actors).

---

## Yesterday's fixes, checked one by one

### The search tab on `.searchable`

- **Debounce paths.** Keystroke → `queryDidChange` → `scheduleDebouncedSearch`; scope tap and
  token removal → `filtersDidChange` → the same debounce, guarded on `hasAsked`; lens, recent,
  browse pick, series-page tag → `apply`/`applyAtOnce` → immediate `search()` with `appliedText`
  remembered so the field's own observer does not schedule a second request. Traced each; the
  `appliedText` sentinel is sound for every sequence I could construct, including a nil→nil
  assignment that never fires the observer (the stale `""` is consumed by the next keystroke
  and cannot suppress anything but a genuine `""` edit, which Cancel handles itself).
- **Cancel.** `SearchField.isCancel` needs empty text *and* no tokens. On Cancel the platform
  writes the text binding, the tokens binding and `isPresented`; the text observer runs
  `resetToIdle` (which cancels the debounce first), the tokens setter's `filtersDidChange`
  is then a no-op on `hasAsked == false`, and `cancelSearch` finishes it. Order-independent as
  far as I can see. One gap: `cancelSearch` does not touch `query.sort` — see F7.
- **Token-only search.** Works on the way in (`openTag`, `applyBrowse`). On the way *out* it
  is wrong — see F6.
- **Arriving from a tag on a series page.** `openTag` is correct in the model; the tab wiring
  is not — see F5.
- **Minimum length.** `askedText` is the one reading everywhere it matters. `search()` line
  293 returns silently for one character plus filters, leaving `hasAsked`/`isPending` as they
  were; reachable only through a saved lens with one-character text, which `SearchLensStore.save`
  cannot produce (it refuses `query.isEmpty`, and one character is empty). Not a finding.
- **Scroll reset.** Still fires on `generation`, i.e. before the answer (discovery-ui S-5,
  already on record).

### `ScrollTracker` and the series page

- The tracker is read in exactly two bodies: `DetailBackdrop.body` (line 165) and
  `DetailBarTitle.body` (line 34 via `crossfade`). `SeriesDetailView.body` passes the object and
  reads no property on it. The claim in the doc comment holds.
- What is not right: `ScrollTracker.update` wraps a *continuous* 0…1 value in
  `withAnimation(Motion.glide)` on every frame in which it changes (F24), and `DetailBackdrop`
  reads the offset at the bottom of a body that also builds the `AsyncImage`, the blur and the
  gradient (F25) — rasterised by `compositingGroup`, so the GPU cost is gone, but the view tree
  is still re-evaluated per frame.
- **The `MeasureKey` gate.** Cannot leave a measurer mounted forever: the ZStack's own
  `onGeometryChange` fires with its initial value on mount, so `measuredFor` is always written
  once a width is known. It *can* retire too early — F2.

### `StaleBar(deadline:)` — the two sites left

- `DiscoverView.swift:76-89`. No `deadline:`; instead a hand-mounted `Countdown` under the bar
  (gap 46, written before `StaleBar` grew a deadline). The recorded reason — `staleDetail` is a
  frozen string — is true of the *detail* line but is not a reason to withhold the deadline:
  `StaleBar` mounts its own live countdown and fires `retry` when it reaches zero, which this
  site's countdown never does. This is now charter §6, hand-rolling what the component
  provides. Pass `deadline: model.staleFailure?.rateLimitDeadline` and delete lines 84-89.
  Effort: a few lines. Confidence: certain that the line is redundant; whether Discover *wants*
  an automatic retry (four requests, two from the 30/min family) is the decision — the
  Search screen took it (decision 4), Discover has not. Recommend yes: the bar's own manual
  Retry already does the same four.
- `ScheduleView.swift:64-70`. No `deadline:`; the bar is built from
  `announcedStaleLine`, a `(headline, detail)` tuple that hides the `APIError` behind it
  (`ScheduleModel.swift:318-321`). The deadline is one line away
  (`snapshot.libraryFailure?.rateLimitDeadline`), but the retry here is `model.load()`, which
  re-runs the library snapshot — the 13-request, ~25 MB walk on a real account. An automatic
  re-walk the instant a 429 lifts is the wrong default for that cost. **The reason holds**, but
  it is not written anywhere; write it at line 65 so the next pass does not re-file this.

### Discover's cancelled-load handling

- `loadRows` skips `.staleAfter(.cancelled)` rows and only sets `hasLoadedOnce` when none were
  cancelled; a cancelled first load therefore re-asks on the next appearance, and the walk saw
  no permanent skeletons. Correct as far as reading can tell. Two loose ends: F11 (per-row
  retry re-pays every row) and F13 (`staleFailure` is the screen's first failure, not the stale
  row's).

### Mix sends tag ids

- **Not inert.** `SeriesRepositoryProtocol` declares the four-parameter `mix(...tagIDs:)` as a
  requirement (`SeriesRepository.swift:76-81`), `SeriesRepository+Mix.swift:14-19` implements
  it, and the protocol-extension default at `SeriesRepository.swift:918-924` is only reached by
  stubs. `mixTagQuery` keeps the numeric `tag=` values `SearchQuery.queryItems` already resolved
  through the bundled taxonomy and adds the recorded ids, dropping names. Every path that builds
  a blend — Blend button, strand toggle, filter strip, tag picker, Reshuffle, FailureState
  retry — goes through `MixModel.run()` and gets the same ids. The one path that could still
  send nothing for a picked tag: a name with no id in `tagIDsByName` *and* no match in the
  bundled taxonomy — reachable only by the picker's own rows, which always call `onPick`.
  Recorded as a negative result.

### The accessibility pass, in this slice

- Every `textQuaternary` move in the slice diff (`git show 0c4f940`) is to `textTertiary` for
  glyphs, spinners and disabled affordances, and to `textMuted` for two numbers the reader is
  meant to read (`BrowseView` counts under 100, the struck-through DNA strand). Both muted
  sites carry the 4.66:1 measurement. No string ended up at the wrong level that I can see.
  `SectionHeader`, `CoverImage` and `StackSections` are outside the slice; their call sites here
  compile (tree is green) and pass the same arguments as before. `DetailBarTitle`'s
  "mount only while `crossfade > 0`" change is correct and the fade is untouched.

---

## Findings

### F1 — `.task(id: series.id)` re-runs the entire page load on every re-appearance

- **What.** `SeriesDetailView` loads through `.task(id: series.id)`. A `.task` is cancelled on
  disappear and started again on appear, and a `NavigationStack` push (a character profile is a
  sheet, but a publisher page, an author page and every related-series tap are pushes onto the
  same path) and a `fullScreenCover` (the cover gallery) both take the page through
  disappear/appear. So coming back re-runs `load()` from the top.
- **Where.** `SeriesDetailView.swift:344` (the task), `:489-495` (`loadCore` sets
  `isLoading = true`, `filled = nil`, `refreshDerived()` before the first await), `:545-559`
  (`loadOnward` fans out seven legs), `+Releases.swift:43-58` (cast), `:76-107` (cadence, a
  MangaUpdates request behind a 3 s spacer when the DB row is stale), `+Store.swift:48-100`
  (Apple then Google then up to 12 × 3 s Open Library HEADs), `+Categories.swift:14-28`
  (MangaUpdates again), `:587-600` (`taste.note` → `snapshot.all()` on every re-run).
- **Why it matters.** Visible: `filled = nil` and `refreshDerived()` run before any await, so a
  page opened from a v2 feed (no description, no chapter count) drops its synopsis, its chapter
  stat and its onward rows to skeletons (`DetailOnwardRows.onwardRowState` returns `.loading`
  for any empty row while `isLoading`) the instant the reader comes back, then refills from the
  six-hour cache. The cast row flashes to placeholders (`CharacterRow.state` puts `isLoading`
  first). Spent: the four MangaBaka legs are cached, but the seven onward legs are asked again
  — cadence and categories each behind MangaUpdates' 3 s spacer, Open Library up to 36 s of
  background HEADs — for a page the reader has already read. Measurement: `Signposts.measure
  ("Detail readable")` is re-recorded on every pop-back, so the signpost now measures cache
  hits as often as first opens (charter §5). Sequence: open any series → tap a related cover →
  back. Or: tap the cover → Done.
- **Fix.** Keep `.task(id: series.id)` (it is what re-loads under the pager) but make the body
  idempotent: `@State private var loadedID: Int?`; in `load()`, `guard loadedID != series.id
  else { return }` before `loadCore`, and set `loadedID = series.id` after `loadCore` returns
  with a non-failure. Section-level retries already bypass `load()`. Reset `loadedID = nil`
  only in the `StaleBar` retry path if a full re-ask is wanted there (it calls `loadCore`
  directly today, so nothing changes).
- **Effort.** A function. **Confidence.** Likely — the platform behaviour is well established,
  but it has not been watched on this stack; one `print` at the top of `load()` and one
  pop-back settles it. **Lens.** Optimisation, load balancing, speed, measurement.

### F2 — `MeasureKey` retires the hero's measurers before the inputs that shape the column arrive

- **What.** The three off-screen columns are unmounted once `measuredFor == MeasureKey(seriesID,
  width, typeSize)`. But the column's height depends on things that are not in the key and
  arrive after the first layout: `series.totalChapters` (the `.chapters` line), `series.status`
  and `series.type` (the kicker), `series.authors` and the native title (the byline),
  `series.titles` (the "Also known as" button), and `schedule`/`isScheduleLoading`/
  `scheduleFailure` (the whole `DetailScheduleBlock`).
- **Where.** `DetailHero.swift:49-53` (the key), `:189-191` (the gate), `:213-216` (the schedule
  block inside the measured column), `:250-254` (the chapter line), `SeriesDetailView.swift:523`
  (`filled` lands after the first layout), `:547` (cadence lands later still).
- **Why it matters.** A series opened from Discover arrives as a v2 payload with no
  `totalChapters` and no `status`. The measurers run against that column, retire, and then
  `extras` fills in a chapter count and a status line: the `.chapters` form was measured one or
  two lines shorter than it now is, so it is chosen where it no longer fits, and the gap under
  the cover that the whole mechanism exists to prevent comes back. The reverse happens with
  the cadence: measured with `isScheduleLoading == true` (the block is in the column), retired,
  then the ask answers `.none` and the block leaves — the visible column is shorter than measured
  and a compact form is chosen where the full one had room.
- **Fix.** Add the shaping inputs to the key. Cheapest correct form: `struct MeasureKey {
  seriesID, width, typeSize, kicker: String?, byline: String?, chapterCount: String?, titleCount:
  Int, scheduleShape: Int }` where `scheduleShape` is 0/1/2 for none/loading-or-failed/estimate,
  computed from the same properties `column(_:fill:)` reads. Or, less precisely, `.onChange(of:
  series) { measuredFor = nil }` and the same for `schedule`, `isScheduleLoading`,
  `scheduleFailure` — `Series` is already `Equatable`.
- **Effort.** A function. **Confidence.** Likely: the key omission is certain by reading; the
  size of the visible gap depends on the series. **Lens.** Bugs.

### F3 — `.cancelled` still reaches three sections on the series page

- **What.** C2 was fixed for cadence (`+Releases.swift:89-97`), Mix and Discover, but not for
  categories, cast or the volumes shelf.
- **Where.** `+Categories.swift:25-26` catches every `APIError` into `categoriesFailure`;
  `DetailCategories.swift:125-126` renders `failure != nil` ahead of `isLoading`.
  `+Releases.swift:57` writes `firstCastFailure(result)` when `result.failed`, and
  `CharacterService` reports a cancelled `URLSession` as a failure like any other (no
  `cancelled` branch in `Core/Characters/CharacterService.swift`). `+Store.swift:76-78` writes
  any `.failure(error)` including `.cancelled` into `appleFailure`.
- **Why it matters.** With F1 in place the sequence is: open a series → tap the cover (the
  gallery is a `fullScreenCover`, so the page disappears and its task is cancelled mid-flight)
  → Done. The page re-runs `load()`; cast and Apple show skeletons because their `isLoading`
  flags come first, but categories shows an `InlineFailure` reading "Cancelled" with a Retry for
  the 3 s+ MangaUpdates spacing until the re-ask lands. After F1 is fixed the cancelled writes
  simply stick: "Cancelled" under Characters, Volumes and What-it's-like on a page the reader is
  looking at.
- **Fix.** In all three: `if case .cancelled = error { return }` before writing the failure —
  the same three lines cadence uses.
- **Effort.** A line ×3. **Confidence.** Likely (certain for categories, which catches
  everything; likely for cast and Apple, whose clients I did not read end to end). **Lens.**
  Errors.

### F4 — Cover gallery: `progress` is `@State` on the gallery root, written per scroll frame

- **What.** The detail-ui F1 pattern, one screen deeper. `progress` is written from
  `onScrollGeometryChange` on every horizontal scroll sample and read by `backdrop`, which is
  in the root body — so the whole gallery body, the `LazyHStack` of `ZoomableCover`s and two
  1000 pt `DetailBackdrop`s, re-evaluates per frame during a swipe.
- **Where.** `CoverGallery.swift:44` (`@State progress`), `:153-158` (the per-frame write),
  `:169-183` (the read), `:46-93` (the root body that owns both).
- **Fix.** Reuse `ScrollTracker` (it is already a `@MainActor @Observable` holder of a
  `CGFloat`): keep a `@State private var tracker = ScrollTracker()`, write `tracker.offset =
  position`, and move `backdrop` into a small `struct GalleryBackdrop: View { let pages; let
  tracker }` that alone reads it.
- **Effort.** A function. **Confidence.** Likely; the simulator cannot measure it (U7 applies).
  **Lens.** Speed.

### F5 — A tag tapped on a series page reached from Search opens nothing

- **What.** `onOpenTag` runs `searchModel.openTag(tag)` and sets `selection = .search`. It never
  pops `searchPath`. A series page reached from Search lives *in* `searchPath`
  (`detail($0, path: $searchPath)`), so the tab is already selected and the page stays on top:
  the results change underneath and the reader sees nothing happen. From another tab, a
  `searchPath` left non-empty by an earlier session shows that stale series page instead of the
  results.
- **Where.** `RootView+Session.swift:441-458`; `RootView+Tabs.swift:108-117`;
  `SeriesDetailView.swift:576, 580`.
- **Fix.** `searchPath.removeAll()` before `selection = .search` in the `onOpenTag` closure.
- **Effort.** A line. **Confidence.** Likely — the wiring is certain by reading; whether
  `NavigationStack` animates the pop and the tab switch cleanly is a device question. The
  series-page walk never tapped a tag. **Lens.** Bugs.

### F6 — Removing the last token of a token-only search fires a sort-only search

- **What.** `openTag` and `applyBrowse` set `sort = "popularity_asc"` when none is set.
  Removing the token through the field's × runs `filtersDidChange`, which is guarded on
  `hasAsked` but not on `askedText`; `search()`'s only guard is `query.isEmpty`, and `isEmpty`
  counts `sort`. So the query `{tags: [], sort: popularity_asc}` goes to the wire: the entire
  catalogue by popularity, 30 rows under an empty field, with a heading "N results ·
  Popularity" — exactly the "filter-only search under an unlabelled grid" that
  `queryDidChange`'s comment (lines 187-191) says an empty field must never run.
- **Where.** `SearchModel.swift:236-240` (`filtersDidChange`), `:294` (the `isEmpty` guard),
  `:586, 597` (the sorts), `SearchQuery.swift:69-74` (`isEmpty` counts `sort`).
- **Fix.** In `filtersDidChange`: `guard hasAsked else { return }` → `guard hasAsked,
  query.asAsked.text != nil || !SearchToken.tokens(for: query).isEmpty else { resetToIdle();
  return }` — a field with no text and no tokens is idle, whatever the panel still holds, which
  is the rule `queryDidChange` already applies to text.
- **Effort.** A few lines. **Confidence.** Likely (certain by reading that the request goes
  out; not watched). **Lens.** Bugs, load balancing.

### F7 — Cancel keeps the app-chosen sort, so later typed searches are not by relevance

- **What.** `cancelSearch` clears text, tags, genres and publisher and calls `resetToIdle`,
  which touches neither `sort` nor `randomSeed`. After any Browse pick or series-page tag,
  `sort == "popularity_asc"` survives Cancel, and every title typed afterwards is sent with
  `sort_by=popularity_asc` — the reader typed "one piece" and gets the most popular series
  whose fuzzy match includes it, not the relevance order that finds ONE PIECE first (the
  measurement at `SearchModel.swift:177-179` is about `random`, but the shape is identical).
  The heading does say "· Popularity", so it is visible — but the reader never chose it.
- **Where.** `SearchModel.swift:216-223, 243-254`; the sorts at `:586, 597`.
- **Fix.** `cancelSearch` also sets `query.sort = nil; query.randomSeed = nil`. Cancel is
  documented as "start over". A sort the reader picked on the panel is lost too; that is the
  price of one rule, and the panel's Sort chips remain one tap away.
- **Effort.** A line. **Confidence.** Certain by reading. **Lens.** Bugs.

### F8 — The offline fallback after a 429 strands the reader with no way back to the network

- **What.** A blocking `.rateLimited` with nothing on screen calls `runOfflineSearch`, which sets
  `failure = nil`, `answered = query.asAsked`, `origin = .offlineIndex`. From then on: no
  countdown (the countdown reads `failure`), no auto-retry, the offline `StaleBar` has no retry
  closure by design, Return does nothing (`search()` line 302 refuses a byte-identical re-ask
  when `failure == nil`), and `loadMore` pages the offline index. The reader is on stale
  offline results for that query until they change the text or toggle "Browse offline" twice.
  `SearchView.swift:333-337`'s comment says retrying "happens on its own the next time a
  search succeeds against the network" — nothing schedules one.
- **Where.** `SearchModel.swift:368-372` (the fallback decision), `:412-434`
  (`runOfflineSearch` clears `failure`), `:302` (the re-ask refusal); `SearchView.swift:333-344`.
- **Fix.** Remember the deadline: on a rate-limited fallback keep `failure = blockingError`
  alongside `origin = .offlineIndex` (the grid already renders `StaleBar(deadline:)` from
  `failure` with `retry: search()`), and have `search()` treat a retry with `origin ==
  .offlineIndex` as never "already answered" — i.e. add `origin == .network` to the condition at
  `:302`. Genuine `.offline` keeps today's behaviour.
- **Effort.** A function. **Confidence.** Likely. **Lens.** Errors, better way.

### F9 — The publisher page spends a `count` request for a number the search already carries

- **What.** `load()` runs `repository.search(query)` and `repository.count(query)` in parallel.
  `count` is a `limit=1` `/v2/series/search` (`SeriesRepository+Count.swift:16-21`) — the same
  30/min family — and `FeedResult.total` (`SeriesRepository.swift:411`) already holds
  `pagination.count` from the first request. This is E F1 exactly, fixed on Search a day ago
  and still here. `PublisherPageTests.swift:123` asserts the source text `async let counted =
  repository.count(query)`, i.e. the test pins the duplicate (charter §2).
- **Where.** `PublisherView.swift:365-366, 377-382`.
- **Fix.** `total = result.total`; delete `counted`; only fall back to `count` when
  `result.total == nil`. Rewrite the test to assert behaviour: one search call per load on a
  counting stub.
- **Effort.** A line plus a test. **Confidence.** Certain. **Lens.** Load balancing.

### F10 — The publisher page reloads page 1 on every re-appearance

- **What.** `.task(id: order)` has no "already loaded" guard. Popping back from a series
  opened in the grid re-runs `load()`: `page = 1`, `series` replaced with page 1, two (with
  F9, three) search-window requests, and the reader's paging and place in the grid gone. The
  same D-1 that Discover fixed with `hasLoadedOnce`.
- **Where.** `PublisherView.swift:141, 359-364`.
- **Fix.** `@State private var loadedOrder: Order?`; `.task(id: order) { guard loadedOrder !=
  order || series.isEmpty else { return }; await load(); loadedOrder = order }`. Pull-to-refresh
  keeps calling `load()` directly.
- **Effort.** A few lines. **Confidence.** Likely (same caveat as F1). **Lens.** Load
  balancing, bugs.

### F11 — Discover's per-row failure retries all four rows

- **What.** A row that asked and failed shows `InlineFailure` whose retry is
  `model.load(forceRefresh: true)` — every row, two of them from the 30/min family, for one
  row's failure. A rate-limited row therefore re-pays the whole screen on the tap that was
  meant to retry it.
- **Where.** `DiscoverView.swift:228-230`; `DiscoverModel.swift:101-106` has no per-row entry.
- **Fix.** `DiscoverModel.retryRow(_ id: Row.ID)`: one `repository.feed(row.kind, forceRefresh:
  true)` and the same write the group loop does for one index (factor lines 150-170 into
  `apply(result, to: index)`).
- **Effort.** A function. **Confidence.** Certain. **Lens.** Load balancing.

### F12 — The community-pulse backoff was listed as folded in and never written

- **What.** SUMMARY.md §4 Lane D lists "`CommunityPulseService.swift:32-40` (remember `failedAt`
  and skip for 60 s, so an offline reader does not spend a request per Discover appearance)"
  among the six small items folded into the lane. The file has no `failedAt`; `load()` is still
  `guard pulse == nil`, and `DiscoverView.swift:148`'s `.task { await pulse?.load() }` runs on
  every appearance. This is D-6, still open, recorded as done.
- **Where.** `Core/Model/CommunityPulseService.swift:32-40`; `DiscoverView.swift:148`.
- **Fix.** As specified: `private var failedAt: Date?`; `guard pulse == nil, failedAt.map {
  Date().timeIntervalSince($0) > 60 } ?? true else { return }`; set `failedAt = Date()` in the
  catch. Label 60 s a guess.
- **Effort.** A few lines. **Confidence.** Certain. **Lens.** Load balancing; a fix that does
  not do what the record says.

### F13 — `staleFailure` names the screen's first failure, not the stale row's

- **What.** `isShowingStale` was made per-row for gap 13, but `staleFailure` still returns the
  screen-wide `failure`, which is whichever row's error the task group delivered first. Row A
  `.offline` with nothing cached (empty, correctly shows its own `InlineFailure`) and row B
  rate-limited with content: the bar says "Offline" with B's age, and no countdown, because the
  `.rateLimited` case at `DiscoverView.swift:84` never matches.
- **Where.** `DiscoverModel.swift:211-214`, `:177`.
- **Fix.** `rows.first { $0.failure != nil && !$0.series.isEmpty }?.failure`.
- **Effort.** A line. **Confidence.** Likely. **Lens.** Errors.

### F14 — The publisher search spinner never clears after a cancelled request

- **What.** The B-1 fix added `guard !Task.isCancelled else { return }` after the request so a
  keystroke mid-flight does not flash a failure. It returns with `isSearching` still `true`.
  The replacement task only resets it after its own sleep — and if the new text is one
  character or empty, `schedule()` returns at line 98-103 without touching `isSearching`.
  Sequence: type "se", wait 350 ms (spinner up, request out), delete to "s". Spinner forever.
- **Where.** `PublisherBrowser.swift:98-103, 107, 115-116`.
- **Fix.** Add `isSearching = false` to the short-text branch (line 99), and move the reset at
  116 above the cancellation guard (a cancelled task is not searching either).
- **Effort.** A line. **Confidence.** Certain. **Lens.** Bugs.

### F15 — The series page's `StaleBar` retry and the section retries are fine; `loadTaste` is not

- **What.** `loadTaste` calls `taste.note(shown.withTags(...))`, which reads
  `snapshot.all()` — the whole library — to find one entry (`TasteProfile.swift:130-141`). Reader
  N8 recorded the re-absorb; this is the read beside it, and with F1 it runs on every
  re-appearance too.
- **Where.** `SeriesDetailView.swift:595-597`; `Core/Library/TasteProfile.swift:132-133`.
- **Fix.** Outside this slice: `LibrarySnapshot.entry(for: seriesId)` (one row) and use it in
  `note`. From this slice: nothing, once F1 stops the repeat.
- **Effort.** A function (persistence). **Confidence.** Certain. **Lens.** Optimisation (C5).

### F16 — `LibraryControlModel.needsAccount` is set and never read

- **What.** A reader with no token gets `store.screenState == .noAccount`, `needsAccount = true`,
  `entry` stays nil — and `LibraryControl.body` renders nothing at all: no "Add to library", no
  line saying why. `needsAccount` has no reader anywhere in the app (grep: only the unrelated
  `APIError.needsAccount`). Charter §3.
- **Where.** `LibraryControl.swift:35, 70-72, 203-218`.
- **Fix.** Either render it — a muted "Add a MangaBaka token in Settings to track this" line
  where the button would be — or delete the property and say in a comment that the control is
  intentionally absent without an account. The first is what the Library tab does
  (`.noAccount` has a screen written for it since Q7).
- **Effort.** A few lines. **Confidence.** Certain. **Lens.** Bad practice, errors.

### F17 — The seed picker ignores `isPending`

- **What.** `results` shows a spinner only while `search.isSearching`. During the 300 ms debounce
  `isPending` is true, `isSearching` false, `results` empty and `failure` nil, so `emptyCopy`
  returns "Nothing called “x”." after every keystroke and it flickers to a spinner when the
  request goes out. This is E F4, fixed on `SearchView` by adding `isPending` to the decision,
  not carried to the picker.
- **Where.** `SeedPickerSheet.swift:172-176`.
- **Fix.** `if (search.isSearching || search.isPending) && search.results.isEmpty`.
- **Effort.** A line. **Confidence.** Certain. **Lens.** Bugs.

### F18 — `ScheduleModel.measuredLine` allocates a `RelativeDateTimeFormatter` per body read

- **What.** The same per-body formatter Discover was told to make static this week
  (`DiscoverModel.swift:219-223` now does). `measuredLine` is read by `controls` on every pass of
  `ScheduleView.body`.
- **Where.** `ScheduleModel.swift:148-149`.
- **Fix.** `private static let ageFormatter` as in `DiscoverModel`.
- **Effort.** A line. **Confidence.** Certain. **Lens.** Optimisation.

### F19 — Schedule re-reads the whole library on every re-appearance

- **What.** `.task { await model.load() }` with no guard: every pop-back from a series row runs
  `service.snapshot()`, `librarySnapshot.all()` (the whole library, deduped and decoded) and
  `calendar.mine`. `ReleaseCalendar` caches, so no request; the cost is the decode. Meanwhile
  `isLoading = true` flips `hasNeverMeasured`/`isEmpty` false for a frame, so a never-measured
  library briefly shows `scopeCard` ("0 estimated of N in scope") before `firstRunCard` returns.
- **Where.** `ScheduleView.swift:100`; `ScheduleModel.swift:300-312, 334-342`, `:130, 190`.
- **Fix.** Guard `load()` on `hasLoadedOnce` the way Discover does, keeping `followBuild()`
  resumption (lines 305-309) unconditional — that is the part re-appearance genuinely needs.
- **Effort.** A few lines. **Confidence.** Likely. **Lens.** Optimisation.

### F20 — Every tap in Mix's tag picker is a blend request

- **What.** `TagPickerSheet` writes `selected` (bound to `$model.filters.tags`) on every toggle.
  `MixView.filterStrip` observes `model.filters` and calls `requestBlend`, which after 350 ms
  runs `model.run()`. So while the reader is still in the sheet, each pause between taps is a
  `/v1/series/mix` request — a reader picking five tags in six seconds spends five blends nobody
  can see (the sheet covers the grid), each answering with a DNA that re-orders the chips
  underneath.
- **Where.** `MixFilterStrip.swift:59, 159-174`; `MixView.swift:81-85`;
  `TagPickerSheet.swift:343-351`.
- **Fix.** `guard !isPickingTags else { return }` at the top of `requestBlend`, and
  `.sheet(isPresented: $isPickingTags, onDismiss: { requestBlend() })` so the sheet's close is
  the one blend.
- **Effort.** A few lines. **Confidence.** Likely. **Lens.** Load balancing.

### F21 — Mix's lens save reports nothing; Search's does

- **What.** Gap 55 ("saved" indistinguishable from "the tap missed") was fixed on Search with
  a toast keyed on `save`'s return. Mix calls `lenses?.save(...)` and drops the `Bool`.
- **Where.** `MixView.swift:93-99` vs `SearchView.swift:109-121`.
- **Fix.** Same toast pair; `ToastCentre` is already in the environment.
- **Effort.** A few lines. **Confidence.** Certain. **Lens.** Errors.

### F22 — `MixView` decodes the shelf on every appearance, seeds or no seeds

- **What.** `.task { suggestedSeeds = await model.suggestedSeeds() }` runs on every Mix
  appearance, and the row it feeds is shown only while `model.seeds.isEmpty`.
- **Where.** `MixView.swift:54-56, 71-73`; `MixModel.swift:117-119`.
- **Fix.** `.task { guard model.seeds.isEmpty else { return }; … }`.
- **Effort.** A line. **Confidence.** Certain. **Lens.** Optimisation.

### F23 — `CharacterProfileView` builds its own AniList and Shikimori actors

- **What.** Both clients default to fresh instances (`var aniList: AniListClient =
  AniListClient()`), and `CharacterRow.swift:95` constructs the sheet with neither passed. Each
  profile open is a new actor with its own `RequestSpacing`, its own `Retry-After` backoff and
  its own outage memory — none shared with the app's `CharacterService` clients that just
  fetched the cast. C4 (two `MangaUpdatesClient`s, detail-ui F3), the same shape.
- **Where.** `CharacterProfileView.swift:23, 25`; `CharacterRow.swift:94-96`.
- **Fix.** Thread the two clients from `AppServices` through `CharacterRow` (it already takes
  `characters:` on the page; add `aniList`/`shikimori` or expose them on `CharacterService`)
  and pass them at line 95.
- **Effort.** A function. **Confidence.** Likely (that they are separate is certain; how often
  a 429 from one is unknown to the other is not measured). **Lens.** Load balancing, bad
  practice.

### F24 — `ScrollTracker.update` animates a per-frame value

- **What.** `crossfadeProgress` is continuous over 60 pt of travel; `update` wraps every change
  in `withAnimation(Motion.glide)`. At scroll speed that is a new animation per frame towards a
  target one frame old — the bar title's opacity trails the finger and the transaction cost
  is paid for nothing the eye can see. (The doc comment on line 28-31 explains the *named
  method*, not the animation; I could not find where the animation came from.)
- **Where.** `ScrollTracker.swift:32-40`.
- **Fix.** Assign `crossfade = progress` directly; if a settle is wanted, animate only the
  mount/unmount in `DetailBarTitle` (`showsBarTitle`), which is the one discontinuity.
- **Effort.** A line. **Confidence.** Likely. **Lens.** Optimisation, better way.

### F25 — `DetailBackdrop` reads the tracker at the bottom of a body that builds the blur

- **What.** The offset read at line 165 sits in the same body as the `AsyncImage`, the blur,
  the saturation and the gradient. `compositingGroup` means the GPU work is one bitmap offset
  per frame (item 55), but the SwiftUI tree above it is still diffed per frame.
- **Where.** `DetailBackdrop.swift:100-166`.
- **Fix.** Split the offset into a child: `ParallaxOffset(tracker:) { wash }` that alone reads
  `tracker.offset`.
- **Effort.** A function. **Confidence.** Likely; needs U7's Instruments run to price. **Lens.**
  Speed.

### F26 — `FilterPanel` counts on every chip and every year digit

- **What.** `.onChange(of: query) { scheduleCount }` with a 350 ms debounce, and `previewCount`
  is a `limit=1` search-window request unless `knownTotal` matches. The year fields write the
  binding per digit, so "2020" typed at a normal pace is up to four count requests; the tag
  picker's per-toggle `selected` write is the same. This is by design (the "Show N results"
  label), but the design was priced when the count was on the general window; it is on the
  30/min one.
- **Where.** `FilterPanel.swift:148-152, 328-355, 439-443`.
- **Fix.** Count on commit for the year fields (`.onSubmit` / focus loss) and while a picker
  sheet is up, hold the count until it closes — the same shape as F20. Consider 800 ms for the
  chip debounce; label it a guess.
- **Effort.** A few lines. **Confidence.** Likely. **Lens.** Load balancing.

### F27 — `PublisherView.loadMore` advances `page` before the request, so a retry skips the failed page

- **What.** `page += 1` at line 403; on a blocking failure `loadMoreFailure` is set and `page`
  stays advanced. The trailing `InlineFailure`'s retry calls `loadMore` again → `page += 1`
  again → page N+2 is fetched and page N+1 is never seen. `SearchModel.loadMore` got this right
  (comment at lines 513-516).
- **Where.** `PublisherView.swift:403, 424`.
- **Fix.** Advance `page` only after `result.blockingError == nil`.
- **Effort.** A line. **Confidence.** Likely. **Lens.** Bugs.

### F28 — Two Mix debounces that do not know about each other

- **What.** Strand toggles debounce in `MixModel.blendAfterEdits` (`pendingBlend`); filter
  changes debounce in `MixView.requestBlend` (a static `pendingFilterBlend`). Neither cancels the
  other, so a strand tap followed within 350 ms by a type chip is two `/v1/series/mix` requests;
  the generation guard drops the first answer but both are spent.
- **Where.** `MixModel.swift:201-210`; `MixFilterStrip.swift:157-174`.
- **Fix.** Route `requestBlend` through a `MixModel.blendAfterEdits()` made internal — one
  debounce, one task.
- **Effort.** A few lines. **Confidence.** Worth checking (the sequence is rare). **Lens.**
  Load balancing.

### F29 — Smaller items, one line each

- `LibraryControl.swift:102-106, 155` — `add` and `remove` update the control's own `entry` and
  never tell `store` (`LibraryModel`); `apply` at `:124` does. The Library tab is stale until
  its next walk after an add from a series page. Worth checking against library-ui's list.
- `FilterSheet.swift:43` — `onSaveLens` runs `save(); dismiss()`: `isNamingLens = true` is set
  while the filter sheet is still presented. Whether SwiftUI queues or drops the second sheet
  is a device question; the search walk saw "Lens saved", so it probably queues. Worth
  checking, low.
- `SeedPickerSheet.swift:26` — `SearchModel(repository:)` with the default preference closures;
  fine because the repository filters on the wire, but the offline branch of that model (never
  reached here; `preferOffline` is never set) would not honour the reader's ratings. Note only.
- `ScheduleModel.swift:337` — `Dictionary(uniqueKeysWithValues:)` over library entries. Safe
  today because `LibrarySnapshot.load()` dedupes by series id (`LibrarySnapshot.swift:199-215`);
  one refactor away from the trap reader N5 recorded. `Dictionary(_:uniquingKeysWith:)` costs
  nothing and removes the dependency.
- `DiscoverModel.swift:114` — `staleSince = nil` at the start of a forced refresh drops the
  bar while the refresh is in flight; it reappears if the refresh fails again. A flicker on a
  slow retry, not a defect.
- `SearchEmptyState.swift:113-124` — the quick actions write through `library` and not through
  `LibraryModel`, same as the first bullet.

---

## Crash-risk sweep (result: clean, re-verified)

No `!` force-unwrap, `try!`, `as!`, `.first!` or `fatalError` in any file read. Every server
number that reaches `Int` goes through `Int(wholeOrClamped:)` (`DetailStatsStrip.swift:58,61`,
`TrackerScores.swift:54-55`, `LibraryControl.swift:297,311,315`, `BlendDNAView.swift:131`,
`+Store.swift:37,87`). Index maths guarded: `DetailCredits.swift:154,167` check `count`,
`CoverGallery.swift:175,179,193` use `[safe:]`, `CoverGallery.swift:170`'s `Int(progress.rounded
(.down))` is bounded by content size. `MainActor.assumeIsolated`: none in the slice. Unbounded
memory: none new; `LensCounts.asked` and `MixModel.tagIDsByName` grow with lenses and tags,
both small.

## What the slice does well (same evidence standard)

- **Measurements travel with the code.** `SearchQuery.swift:14-17, 22-28, 33-39, 42-46,
  49-52, 54-56, 104-116, 121-131, 182-186` each carry a date, a request and the numbers
  it answered. `MixFilterStrip.swift:75-88` records not just a measurement but the discovery
  that the *previous* measurement measured nothing, and why. That is how F12 and F9 were
  findable in an afternoon.
- **Generation guards are everywhere they need to be.** `SearchModel` (search and paging),
  `DiscoverModel.loadRows` and `loadMore` (with the `reloads` counter and the comment "tried
  first; the test caught it"), `MixModel.run`, `PublisherView.load` — five screens, one idiom,
  each dropping a stale answer rather than clobbering a newer one.
- **The cancelled-load accounting on Discover is correct** (`DiscoverModel.swift:122-141,
  172-183`): a cancelled row keeps what it had and does not count as loaded, which is the
  only combination that avoids both the permanent skeleton and the four-request re-ask.
- **Pure decision functions with tests instead of ViewInspector.** `contentKind`,
  `SearchHeading.text`, `SearchField.isCancel`, `MixResults.state`, `DetailOnwardRows.
  onwardRowState`, `CharacterRow.state`, `DetailHero.form`, `SeedPickerSheet.emptyCopy`,
  `BlendDNAView.diff` — the screen's logic is reachable from a unit test, which is why the
  23-test triage yesterday had something to triage.
- **`SeriesPager` seeds its position in `init`** (`SeriesPager.swift:31-36, 50`) with the
  reason recorded (item 56) — the fix that stops page 0's nine requests, done at the right
  layer.
- **The series-page `StaleBar` carries the walk's evidence in place**
  (`SeriesDetailView.swift:235-247`): four screenshots, byte-identical, and the exact reason
  the deadline was never passed. A comment that will still be true in a year.
- **Mix's tag-id fix is real end to end** — protocol requirement, concrete implementation,
  `mixTagQuery` folding names to ids, every blend path through one `run()`. Checked because
  the brief asked whether it could be inert; it is not.

## What I could not determine, and what settles each

- **Does `.task(id:)` re-fire on pop-back and on `fullScreenCover` dismissal in this
  `NavigationStack`?** (F1, F3, F10, F19.) One `print("load", series.id)` at the top of
  `SeriesDetailView.load()`, one related-cover tap, one back. Expect two lines. If only one,
  F1/F10/F19 are withdrawn and F3 shrinks to the gallery case.
- **Does the offline fallback ever happen on a 429 in practice?** (F8.) `NetworkLedger` for
  one `rateLimited` on a search with empty results; or force it with a stub. Decides whether
  F8 is live or theoretical.
- **Does the hero's form visibly change after `extras` lands?** (F2.) One series opened from
  Discover with a two-line title and a known chapter count, screenshot at t=0 and t=2 s.
  Expect the column to grow past the cover in the second.
- **How often does `count(query)` hit URLCache rather than the wire?** (F9, F26 — U17 still
  open.) The two `URLProtocolStub` tests SUMMARY §7 describes; if the second identical
  count is served locally, F26 is mostly theoretical.
- **Is `filtersDidChange`'s sort-only request reachable through the platform's token ×?**
  (F6.) Certain by reading; one tap on the token's × after `openTag` with the ledger open
  confirms a `/v2/series/search?limit=30&sort_by=popularity_asc` with no `tag`.
- **`LazyHStack` in `SeriesPager`** (U2) remains unmeasured; nothing in this pass changes it.

## Negative results, recorded so they are not re-derived

- Mix tag ids: not inert (above).
- `LibrarySnapshot.all()` is deduplicated at the walk, so `ScheduleModel.swift:337` cannot trap
  on today's data.
- The accessibility palette moves in this slice are all at a defensible level; no string moved
  to a level below AA.
- `SearchModel`'s `appliedText` sentinel survives every sequence I could build, including
  nil→nil applies.
- `MixResults`, `MixModel.run`, `loadCadence` and `DiscoverModel` all drop `.cancelled` correctly;
  the three that do not are F3.
- No file in the slice reads `tracker.offset` or `tracker.crossfade` outside the two views that
  should.
