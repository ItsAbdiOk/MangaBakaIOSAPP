# Deep review — Discovery, Search, Mix, Stack

Read-only pass, 2026-09-11. Slice: `MangaBaka/Features/{Discovery,Search,Mix,Stack}/**`,
25 files, 4,300 lines. All 25 were read in full. Also read for context, outside the
slice: `App/RootView.swift` (the tabs body only), `MangaBakaTests/SearchModelTests.swift`,
`PaginationTests.swift`, `StackSaveTests.swift`.

Nothing was built or run. Claims about what happens *inside* `SeriesRepository`,
`ShelfStore`, `TagSearch` and `CatalogueService` are out of scope and are not made.

13 findings. Three of them can fire extra requests at a shared per-IP rate limit.

---

## A. Requests fired more often than the reader asked

### A1. `refill()` has no in-flight guard, so a fast swiper can run several network refills at once

- **What.** `StackModel.react` ends with `if queue.count <= 2 { await refill() }`, and
  `refill()` itself has no `guard !isLoading`. `react` is called from an unstructured
  `Task` per swipe, so a second swipe can enter `react` while the first is suspended
  inside `refill`, and start a second refill.
- **Where.** `MangaBaka/Features/Stack/StackModel.swift:218` (the call),
  `StackModel.swift:125-127` (`refill` sets `isLoading` but never reads it),
  `StackView.swift:204` (each swipe is its own `Task`). Compare
  `loadIfNeeded` at `StackModel.swift:117`, which *does* guard on `!isLoading` — the
  guard exists, it is just on the wrong entry point.
- **Why it matters.** Three quick swipes with the queue near empty issue three
  concurrent refills. On the profile path each one does
  `recommendationPage += 1` (`StackModel.swift:268`) before awaiting, so pages 1, 2 and
  3 are requested simultaneously and the exclusion lists are all built from the same
  stale `reacted` set. On the blend path, `fetchBatch` passes
  `forceRefresh: queue.isEmpty` (`StackModel.swift:362`), so every one of them bypasses
  the cache. Swiping fast is the normal way to use this screen. 180 req/min is shared
  with strangers on the same IP.
- **Effort.** A line: `guard !isLoading else { return }` at the top of `refill`, with the
  `isLoading = true` moved above it atomically (it already runs before the first await,
  so `@MainActor` makes it atomic).
- **Confidence.** Certain about the missing guard. Likely about the concurrency, since
  it depends on two `Task`s from two gesture ends overlapping — trivially reproducible by
  swiping twice inside one network round trip.

### A2. Every DNA chip tap is a `/v1/series/mix` request, with nothing serialising them

- **What.** `toggleTag` and `toggleTagMode` each end in `Task { await model.run() }`. There
  is no debounce, and `MixModel.run()` sets `isRunning = true` but never guards on it —
  only the Blend button is `.disabled(model.isRunning)`; the chips are not.
- **Where.** `MangaBaka/Features/Mix/MixFilterStrip.swift:157` and `:162`;
  `MixModel.swift:75-90`; the chips that call it are `MixFilterStrip.swift:99` and `:104`,
  and the DNA chips are `BlendDNAView.swift:60` → `MixView.swift:236`.
- **Why it matters.** Tuning is the point of this screen and the DNA shows ten strands
  (`BlendDNAView.swift:3`). A reader switching six strands off fires six blends. They
  return out of order, so `results`, `dna` and `moves` end up describing whichever
  request the network finished last, not the last thing tapped — and `moves` is computed
  against `previous = dna` captured at each call (`MixModel.swift:78`), so the "what
  changed" panel can show a delta between two states that never followed each other.
  Whichever run finishes first also sets `isRunning = false` (`MixModel.swift:90`),
  stopping the spinner and re-enabling Blend while a request is still out.
- **Effort.** A function: give `MixModel` a single re-blend task it cancels and replaces,
  the way `SearchModel.queryDidChange` already does (`SearchModel.swift:49-53`).
- **Confidence.** Certain that there is no guard and no debounce. Certain about the
  out-of-order write, which follows from `results = blended.recommendations` being
  unconditional at `MixModel.swift:84`.

### A3. `toggleType` does not re-blend but `toggleTag` does — the same strip, two rules

- **What.** Type chips change `model.filters.types` and stop (`MixFilterStrip.swift:165-171`);
  the reader must press Blend. Tag chips in the same strip re-blend immediately
  (`:157`). Tags added through `TagPickerSheet` — bound straight to
  `$model.filters.tags` at `MixView.swift:69` — also do not re-blend, so the *same tag*
  applies instantly from one control and silently from the other.
- **Where.** `MixFilterStrip.swift:157` vs `:171`; `MixView.swift:67-72`.
- **Why it matters.** After picking tags in the sheet, the grid on screen no longer
  matches the filters above it and nothing says so. This is the same class of defect as
  the filter-escape bugs already fixed in Search (`SearchModel.swift:87-95`).
- **Effort.** A decision then a line — pick one rule. Re-blending on every change is the
  wrong one until A2 is fixed.
- **Confidence.** Certain.

### A4. A lens or recent term may search twice

- **What.** `SearchIdleView`'s callbacks assign `model.query` and then run
  `Task { model.cancelPendingDebounce(); await model.search() }`. The assignment also
  changes `query.text`, which the search field observes with
  `.onChange(of: model.query.text) { model.queryDidChange() }` — scheduling a *fresh*
  300ms debounce after the explicit cancel has already run.
- **Where.** `MangaBaka/Features/Search/SearchView.swift:194-201` (the two callbacks),
  `SearchView.swift:101` (the `onChange`), `SearchModel.swift:49-53` (the debounce).
  `applyBrowse` has the same shape at `SearchModel.swift:130-139`.
- **Why it matters.** Two identical requests per tap on a 30 req/min budget shared with
  strangers. Most visible on `onRunTerm`, where `SearchQuery(text: term)` always changes
  the text.
- **Effort.** A line — have `search()`'s callers cancel *after* the assignment has been
  observed, or give `SearchModel` a "last applied text" the `onChange` compares against.
- **Confidence.** Worth checking. The ordering of SwiftUI's `onChange` delivery against a
  `Task{}` enqueued on the main actor in the same tick is not something I will assert from
  reading. It is cheap to settle: a `RecordingRepository` (it already exists,
  `SearchModelTests.swift:7`) driven through `onRunTerm`'s two statements, asserting
  `searchCount == 1` after 600ms. **The test fails without the fix or it is not a bug** —
  that is the whole check.

---

## B. State that survives when it should not, or dies when it should not

### B1. `loadMore` has no query generation, so a stale page can be appended to a new search

- **What.** `SearchModel.loadMore` snapshots `var next = query`, awaits the network, and
  on return appends to `results` and writes `query.page = next.page`. Nothing records
  which query the in-flight page belonged to. `guard !isSearching` at the top only helps
  when `loadMore` starts *after* the new search.
- **Where.** `MangaBaka/Features/Search/SearchModel.swift:98-124`, specifically the
  append at `:121` and the page write at `:122`.
- **Why it matters.** Scroll to the bottom (a page-2 request goes out), then type a new
  query inside that round trip. The 300ms debounce fires, `search()` sets `page = 1` and
  replaces `results`. Page 2 of the *previous* query then lands and is appended to them —
  the dedupe at `:111` will not catch it, because the ids are from a different query.
  The reader sees their new results with 30 unrelated series stuck on the end, and
  `query.page` is now 2 for a query that has only shown page 1, so the next scroll skips
  a page.
- **Effort.** A function: an incrementing `generation` bumped in `search()` and compared
  after the await in `loadMore`.
- **Confidence.** Certain from reading. `PaginationTests` covers this path only
  sequentially (`PaginationTests.swift:67-78` sets the new text *after* `loadMore`
  returns), so the interleaved case is genuinely untested.

### B2. The same race in `DiscoverModel`, narrower

- **What.** `loadMore(_:)` captures `index`, awaits, then writes
  `rows[index].series.append(...)` and `rows[index].page = nextPage`. A concurrent
  pull-to-refresh sets `rows[index].page = 1` and `hasReachedEnd = false`
  (`DiscoverModel.swift:90-91`) and replaces the series.
- **Where.** `MangaBaka/Features/Discovery/DiscoverModel.swift:140-167` against `:72-104`;
  the refresh trigger is `DiscoverView.swift:94`.
- **Why it matters.** Less bad than B1 — it is the same feed, so the content is not
  foreign — but the row ends up holding refreshed page 1 plus old page 2, with `page` set
  to 2, and `hasReachedEnd` reset. Requires pulling to refresh while a row page is in
  flight.
- **Effort.** A line: re-check a per-row token, or `guard rows[index].page == nextPage - 1`
  before appending.
- **Confidence.** Likely. The window is small.

### B3. `LensCounts` permanently gives up on any lens it was cancelled before reaching

- **What.** `load(_:)` inserts *every* pending lens into `asked` up front
  (`:48`), then fetches them one at a time with a 250ms gap. `cancel()` kills the loop.
  `asked` is never rolled back, and `load` filters on it (`:46`), so the lenses that had
  not been reached yet are never counted again for the life of the session.
- **Where.** `MangaBaka/Features/Search/LensCounts.swift:45-59`, with `cancel()` at `:68`.
  The caller is `SearchIdleView.swift:32-33`: `.task { counts.load(own) }` /
  `.onDisappear { counts.cancel() }`.
- **Why it matters.** The idle view disappears the instant the reader types one
  character (`SearchView.swift:189`). With six saved lenses the queue takes ~1.5s, so
  anyone who lands on Search and starts typing — the normal case — permanently loses the
  counts for lenses 3 through 6. They fall back to the rule text
  (`SearchIdleView.swift:121`), which is a correct-looking screen, so nobody would ever
  report it. This is exactly the charter's pattern 1 shape: the failure and the
  "nothing here" state are indistinguishable.
- **Effort.** A line: only insert into `asked` after a lens's count actually resolves,
  inside the loop.
- **Confidence.** Certain.

### B4. Discover's and the Stack's models are rebuilt on every `RootView` body pass, and `.id(titleRevision)` throws them away

- **What.** `searchModel`, `mixModel` and `browseModel` are held in `RootView` `@State`
  with a comment saying why ("rebuilding them per tab switch would drop a half-typed
  query or an assembled set of mix seeds"). `DiscoverModel` and `StackModel` are
  constructed inline in the same body and are not.
- **Where.** `MangaBaka/App/RootView.swift:93` and `:108` (inline) against `:119`, `:142`
  and `:187-189` (cached). The receiving views absorb it with
  `State(initialValue:)` — `DiscoverView.swift:29`, `StackView.swift:35` — so the
  *first* instance is kept and the per-pass allocations are discarded.
- **Why it matters.** Two things. (a) A fresh `DiscoverModel`/`StackModel` is allocated on
  every body pass and dropped. Harmless today because neither registers anything in
  `init` — but this is the exact shape that made `LibraryModel` replace its own listener,
  so it is worth closing rather than relying on. (b) `RootView.body` applies
  `.id(titleRevision)`, so changing the title preference destroys the TabView's identity:
  `searchModel` and `mixModel` survive (they live above the `.id`), the Stack's queue,
  `previous` card, `seenThisRun` and `savedThisRun` do not. Changing a display preference
  silently resets the stack mid-session and keeps the search.
- **Effort.** A line: give Discover and Stack the same `@State` holder the other three have.
- **Confidence.** Certain about the asymmetry and the `State(initialValue:)` absorption.
  Likely about the `.id()` consequence — it follows from how `.id` works, but I did not
  run it.

---

## C. Computed and discarded (charter pattern 3)

### C1. `lastSaveWentToLibrary` is written in two places and read nowhere

- **What.** Documented as *"Set when a save reached the reader's MangaBaka library, so the
  screen can say where it went rather than leaving them to guess."* No screen reads it.
- **Where.** Declared `MangaBaka/Features/Stack/StackModel.swift:32`, written at `:241`
  and `:246`. A repo-wide grep for `lastSaveWentToLibrary` outside that file returns
  nothing — not a view, not a test.
- **Why it matters.** The charter's third pattern exactly: a doc comment describing a
  caller that does not exist. The reader is told when a save *failed* to reach the
  account (`StackCaption.swift` via `warning(for:)`) and never when it succeeded, which
  is the asymmetry the property was added to remove. Half of what a dead-code scan
  reports here is a behavioural gap — this is one.
- **Effort.** A line either way. It is a product call: show it, or delete the property
  and its doc.
- **Confidence.** Certain.

### C2. `StackModel.source` is asserted by tests and shown to nobody

- **What.** The `Source` enum carries 12 lines of reasoning: *"Exposed so the screen can
  say so. 'Are you sure it's using my tastes?' is a fair question to ask of any
  recommender… a random queue is not personalised at all, and the app should not imply
  otherwise."* `StackView` never reads `model.source`.
- **Where.** `StackModel.swift:13-24` and `:29`. The only readers are
  `SurpriseAndStackTests.swift:88,107` and `RecommendationQualityTests.swift:277,297`.
  Grep for `yourProfile`/`yourSaves`/`yourLibrary` across `MangaBaka/` returns only
  `StackModel.swift`.
- **Why it matters.** The stated defect — the app implying personalisation it does not
  have — is still live; the fix was built and never connected. It is also a mild instance
  of pattern 2: four tests assert a value whose entire declared purpose is to reach a
  screen, and they would keep passing if it never did.
- **Effort.** A line in `StackHeader` or `StackCaption` to render it.
- **Confidence.** Certain.

### C3. An orphaned doc comment marks where a property was removed mid-edit

- **What.** `/// Set when a save could not reach the library. The local shelf still has
  it, so this is a note rather than a failure.` is immediately followed by
  `/// The warning to show under a given card, or nothing.` and then `func warning(for:)`.
  Two doc comments for two different things are stacked on one function; the property the
  first belonged to is gone.
- **Where.** `MangaBaka/Features/Stack/StackModel.swift:33-41`.
- **Why it matters.** Small on its own, but CLAUDE.md says never to delete a comment that
  records a measurement, and this is the visible residue of an edit that half-removed a
  property. It also sits directly above C1, which looks like the other half of the same
  unfinished change.
- **Effort.** A line.
- **Confidence.** Certain.

---

## D. Cost and correctness, smaller

### D1. `TagBreadth.step` sorts all 500 tag counts once per row, per body pass

- **What.** `step(for:among:)` does `tags.compactMap(\.seriesCount).sorted()` on every
  call, then a linear scan. `TagPickerSheet.breadth(_:)` calls it once per rendered row.
- **Where.** `MangaBaka/Features/Search/TagPickerSheet.swift:371-378` (the sort at `:373`),
  called from `:270`, used at `:192` (up to 40 search matches) and `:250` (8 per group).
- **Why it matters.** 40 rows × a 500-element `compactMap` + sort, re-run on every body
  pass while the reader types in the tag field. The result is identical for every row in
  a pass — the input `tags` does not change. Nothing is wrong on screen; this is
  wasted work on the main actor during typing, which is where it is least affordable.
- **Effort.** A line: compute the sorted counts once in the sheet and pass them in, or
  cache them on the `tags` `@State` write at `:67`.
- **Confidence.** Certain about the recomputation. I did not measure the cost, so I am
  not claiming a visible stutter — per CLAUDE.md, that number does not exist yet.

### D2. `SearchIdleView` marks every lens as counted before it counts any

Covered under B3; noted here because the same `asked`-before-the-fact pattern would also
lose counts if `repository.count` returns nil (`LensCounts.swift:54` only writes on a
non-nil answer, but the lens is already in `asked`). A lens whose count request fails
once never retries this session.

`LensCounts.swift:46-48, 53-54`. Effort: a line. Confidence: certain.

---

## E. The swipe stack, on its own terms

Hand-rolling is right here — there is no system equivalent to a throwable card — so this
is reviewed as a gesture, not as a missed `List`.

### E1. The thrown card's offset is not reset until the network write finishes

- **What.** `onEnded` animates `drag.width` to ±700 and then resets it inside
  `Task { await model.react(kind); drag = .zero }`. But `react` removes the card from the
  queue *first* (`StackModel.swift:202`) and only then awaits `shelf.record`,
  `pushSaveToLibrary` (an HTTP POST) and possibly `refill` (another request). Throughout
  all of that, `drag` is still 700 and it is applied to `card(current)` — which is now the
  **next** card.
- **Where.** `MangaBaka/Features/Stack/StackView.swift:202-207`, applied at `:86-87`;
  the card area is `.clipped()` at `:117` with a fixed `Metrics.stackArea` height at `:115`.
  `StackModel.swift:199-219` is the sequence that keeps it waiting.
- **Why it matters.** Save a card on a slow connection and the next card renders 700pt
  off-screen, rotated 8.4°, clipped away — the stack looks empty until the library POST
  returns. The two peeking neighbours and the caption below are still drawn, so it reads
  as a card that failed to load rather than one that has not been positioned yet. Worst
  exactly where it hurts: a save is the slow path (a skip stays local, `StackModel.swift:231`),
  and `Reduce Motion` readers are immune because they take the `drag = .zero` branch at
  `:200`.
- **Effort.** A line: reset `drag` when the queue advances, not when the write completes.
  The cleanest split is a synchronous `advance()` that `react` calls before it awaits.
- **Confidence.** Certain about the ordering. Likely about the visual result, which I
  reasoned from the modifiers rather than watched — but `.offset(drag)` on the current
  card with `drag.width == 700` inside a clipped fixed-height frame has only one outcome.

### E2. Undo does not exist, and the code says so honestly

There is no unswipe. The comment at `StackModel.swift:177-187` states the reason plainly
and offers `resetStack()` as the coarse way back, gated behind a confirmation that says
what it does *and does not* touch (`StackResetMenu.swift:42-45`). The account is
deliberately not rolled back. That is a defensible product decision recorded where the
next reader will find it, rather than a gap. **Not a finding** — noted because a reviewer
looking for "what happens to undo" should not have to re-derive it.

### E3. A rapid swipe cannot lose or double-count a card — checked, and clean

`react` takes `current`, then calls `queue.removeFirst()`, `reacted.insert`,
`seenThisRun += 1` and `savedThisRun += 1` **before its first `await`**
(`StackModel.swift:200-205`). On `@MainActor` that whole prefix is atomic, so two
overlapping `react` calls take two different cards. Neither counter can double, and no
card can be skipped. The `append` at `:172-175` also dedupes by id, so a card cannot
re-enter the queue behind a save. This was the thing most worth breaking and it does not
break — only the *refill* it triggers is unguarded (A1).

---

## What this slice does well

Same evidence standard.

- **The rate limit is treated as somebody else's budget, in code and in comments.** Both
  pagination paths dedupe and then *stop asking* rather than re-requesting —
  `SearchModel.swift:114-119` and `DiscoverModel.swift:157-163`, each with the reason
  written at the guard. `LensCounts.swift:9-23` documents its own cost, states the four
  things it does to keep it down, names the agreed fallback if it turns out too expensive,
  and says Abdi should be told rather than it changing quietly. That is a comment doing a
  job no test can.
- **The Search debounce is proven by a behavioural test, not a grep.** `debounceCollapsesABurst`
  (`SearchModelTests.swift:57-70`) drives four keystrokes through the real `queryDidChange`
  and asserts one request, with the rate limit quoted in the failure message. The brief
  for this review assumed only `TagSearch` had one; that assumption is wrong, and Search's
  is the better test of the two because it exercises the public entry point.
- **`saveWarning` is keyed to a series id, and the bug it fixes is recorded.**
  `StackModel.swift:43-50` explains that a bare string rendered under the *next* card and
  persisted through every later skip. `warning(for:)` at `:39` is the whole fix, in one
  expression.
- **`append` instead of replace, with the cost of the old behaviour stated.**
  `StackModel.swift:167-175`: a refill starts with two cards in hand, so replacing threw
  away two unseen series every single time.
- **Counters that refuse to overstate.** `seenThisRun`/`savedThisRun`
  (`StackModel.swift:64-71`) explicitly are *not* the shelf totals, because "5 saved" from
  a lifetime figure under the words "today's stack" would be a lie. The Search heading does
  the same thing for a different reason — "shown", not "results",
  `SearchView.swift:180-182`, because the same query reported 24 then 47 as the reader
  scrolled.
- **`SeedPickerSheet` builds its own `SearchModel` per presentation**
  (`SeedPickerSheet.swift:26`), and the doc quotes the reader's own words for the bug it
  fixes. This is the one place in the slice where a fresh model is unambiguously correct,
  and it is the one place that does it.
- **"Clear all" became undo-in-place rather than a confirmation** (`FilterSheet.swift:76-101`),
  with the reasoning for rejecting the dialog written down — a dialog in front of a sheet
  to guard a one-tap action.
- **`TagBreadth` is ranked, not scaled, because scaling was measured wrong on device.**
  `TagPickerSheet.swift:359-378`: "Seen on device as eight identical bars in a row." The
  constant (four steps) is the board's, and the derivation is stated. This is what the
  charter's fourth pattern asks for.
- **Reduce Motion is honoured in the throw** (`StackView.swift:199-203`) — still, per the
  earlier review, the only animating surface in the app that does.
- **Failure is per-row, not per-screen.** `DiscoverModel.isCompletelyEmpty` (`:51-53`) and
  `isShowingStale` (`:117-119`) split "one endpoint failed" from "the screen has nothing",
  and the stale bar reports the *oldest* thing on screen because "the honest age of a
  screen is that of its stalest part" (`:106-111`).
- **Accessibility is real here, not a label sprinkle.** The undraggable card exposes
  Save and Skip as custom actions (`StackView.swift:107-108`); `MixResults` collapses a
  card into one sentence (`MixResults.swift:86-91`); the breadth legend is a sentence for
  VoiceOver and a picture for everyone else, with the reason given
  (`TagPickerSheet.swift:94-98`); `StackHeader` restacks at accessibility sizes
  (`:17-34`) with the symptom it fixes named.

---

## Not reviewed

`SeriesRepository`, `ShelfStore`, `TagSearch`, `CatalogueService`, `CoverStore`,
`HistoryStore`, `FlowLayout`, `Metrics`/`Palette`, and every test file except the three
named at the top. Anything those files do is outside this slice and no claim is made
about them.
