# Discovery screens — Discover, Search, Mix, Stack

Reviewed 22 of 30 files in full (all four models, all four screen-root views, the
filter/tag/lens machinery, the Stack's supporting views); the other 8 (mostly small
sheets and header/hint components under 130 lines) were skimmed for the request/main-
thread questions but not line-by-line. Findings by confidence: 2 certain, 3 likely, 2
worth checking. Highest-value change: **P1** — `CommunityPulseService` and `LensCounts`
aside, nothing here is actually broken; the highest-value change is dropping
`CommunityPulseCard`'s request to `.background` (P1) since it is the one place a purely
decorative fetch competes at full priority with the four rows the reader is actually
looking at, at the exact moment — launch — when that priority matters most.

This slice is, on the whole, the best-instrumented part of the codebase I've seen in
this pass: almost every debounce, dedup and priority choice below carries a comment with
a date, a measured number, and the incident it fixes. That is unusual and it made this
review faster, not slower — I could check a claim against the code instead of having to
reconstruct why something is shaped the way it is.

## Requests in flight

| Call | Trigger | Priority | Awaited before draw? | Verdict |
|---|---|---|---|---|
| 4 row feeds (rising/hiddenGems/trending/newReleases) | `DiscoverView.task` on first appear only (`hasLoadedOnce` guard), or pull-to-refresh | `.userInitiated` (default, `SeriesRepository+Cache.swift:363`) | No — `isLoading` skeleton draws immediately, rows fill in as each answers | Correct: this is the visible content |
| Row `loadMore` (paging) | Card 4-from-end `onAppear` (`DiscoverView.swift:280-284`) | `.background` (`DiscoverModel.swift:296`) | No | Correct, already fixed 2026-09-13 per its own comment |
| `CommunityPulseService.load()` | `DiscoverView.task`, fires alongside the 4 row feeds at launch (`DiscoverView.swift:146`) | `.userInitiated` (default — `getRoot` takes no priority param, `APIClient.swift:376-380`) | No, card renders last and silently absent until it lands | **P1 — see below** |
| `RecentlyViewedModel.load()` | `DiscoverView.task` (`DiscoverView.swift:145`) | N/A — local `HistoryStore` read, no network | — | Fine |
| `SearchModel.search()` | Debounced 300 ms after a keystroke (`SearchModel.swift:155,203-210`); immediate for Return/lens/browse/Surprise-me | `.userInitiated` (default, `SeriesRepository+Paging.swift:54`) | `isSearching`/`isPending` gate the grid so nothing draws mid-flight | Correct, extensively proven (see Good news) |
| `SearchModel.loadMore()` | Scroll to grid bottom | `.userInitiated` (default) | `isLoadingMore` | Fine — this is the visible grid growing, not a background top-up |
| `LensCounts.load()` walk | Search idle screen appears | `.background`, one at a time, 250 ms spacing (`LensCounts.swift:96-127`) | No | Correct, well documented |
| `LensCounts.count()` (filter-panel live preview) | Debounced 350 ms after any filter/year/picker change (`FilterPanel.swift:76,355-386`) | `.background` (`LensCounts.swift:163-165`) | No | Correct |
| `MixModel.run()` (Blend) | Tap on Blend, or a debounced strand/filter edit (350 ms, `MixModel.swift:51,227-236`) | `.userInitiated` (default, `SeriesRepository+Mix.swift:33`) | `isRunning` dims the existing grid rather than blanking it | Correct — see MixResults note below |
| `StackModel.fetchBatch()` (mix/surprise feed) | Initial load, a reaction that leaves ≤2 cards, empty-state retry | `.userInitiated` while the Stack tab is visible, `.background` otherwise (`StackModel.swift:224,739`, wired from `StackView.swift:110-111`) | Card advances instantly (queue mutated before any `await`); see Main-thread note below for what *does* wait | Correct priority split, but see P2 |
| `StackModel.fetchProfilePage()` / `profileIsUsable()` | Same refill path, tried first when a library is present | Delegated to `LibraryProviding` (outside this slice) | — | Not reviewed (implementation lives outside Discovery/Search/Mix/Stack) |
| `TagPickerSheet.load()` | Sheet opens (Search's and Mix's tag pickers both use it) | Bundled list shown instantly; one `catalogue.tags(limit: 500)` network call, de-duplicated by `CatalogueService`'s own `tagsInFlight` | Bundled fallback draws first | Fine — one request per sheet-open, filtering is local afterward (`TagSearch`, outside this slice) |
| `FilterPanel.loadGenres()` | `pickerRow.task` on appear, and again if "Genres" is tapped before that task lands | `CatalogueService.genres()` — coalesced via its own `genresInFlight` (`Core/Model/CatalogueService.swift:37-38`) | — | Two call sites, one request: confirmed the service dedupes, not a bug |

### P1 — CommunityPulseCard fetches at full priority at the exact moment it matters least
**What:** the "grace note" pulse card (its own doc comment: "a screen that apologises for
failing to show one has made it more important than it is") fires its one network call at
`.userInitiated`, in the same `.task` burst as the four rows of actual content, at launch.
**Where:** `MangaBaka/Core/Model/CommunityPulseService.swift:60` (`client.getRoot` takes no
priority argument, so it falls to `APIClient`'s `.userInitiated` default,
`APIClient.swift:376-380`); triggered from `MangaBaka/Features/Discovery/DiscoverView.swift:146`.
**Why it matters:** at launch, five `.userInitiated` requests go out together (4 rows + pulse)
against the reserved-180 general window. The pulse card is cosmetic and rendered last, under
everything else — losing the race to a real request costs it nothing, but today it can take a
slot a row's retry might have wanted. This is the mirror image of the `LensCounts`/`loadMore`
pattern already applied elsewhere in this same slice, just missed here.
**Effort:** a line — add `priority: .background` to `getRoot`'s signature (one new optional
parameter, default `.userInitiated` to avoid touching other call sites) and pass `.background`
from `CommunityPulseService.load()`.
**Confidence:** certain (traced both the call site and the default).

### P2 — a swipe's *next* action can wait on the network, even though the card itself doesn't
**What:** `StackView.react(_:)` sets `isReacting = true` before calling `await model.react(kind)`
and only clears it in a `defer` that runs when that whole call returns — and `model.react`
itself, when the queue drops to ≤2 cards, `await`s `refill()` before returning
(`StackModel.swift:492`). While `isReacting` is true, the Save/Skip buttons are disabled
(`StackView.swift:438,462`) and a released drag is dropped rather than queued
(`StackView.swift:338-341`).
**Where:** `MangaBaka/Features/Stack/StackView.swift:375-388` (the `isReacting` gate) and
`MangaBaka/Features/Stack/StackModel.swift:456-493` (`react`, `await refill()` at line 492).
**Why it matters:** the current card advances immediately (`queue.removeFirst()` runs before
any `await`, `StackModel.swift:459`), so visually nothing stalls — but the *next* swipe or
button tap is silently ignored for as long as the top-up network request takes, because it's
serialized behind the same `await` chain the confirmation toast depends on. On a slow
connection this reads as "the app stopped responding to my second swipe" with no visible
cause (no spinner is shown for this — the loading skeleton only appears when the queue is
fully empty). This is exactly the kind of thing Abdi's ask 2 is about: background work
(topping up the deck) competing with the reader's next tap.
**Effort:** a function — split `react()` so the refill, when triggered, runs as a detached
task the caller doesn't await; `isReacting` would then only span the queue-advance and the
shelf write, which is genuinely fast.
**Confidence:** likely — verified by reading the `await` chain and the two disable sites; not
measured on a device with an artificially slow network, so the actual stall duration in
practice is unconfirmed.

## Prefetch and what competes with a tap

`DiscoverModel`'s only true prefetch is `loadMore` (the next page of a row, `.background`,
triggered 4 cards from a row's end) — it does not fire anything at launch beyond the four
row loads themselves, which are the actual content, not a prefetch. There is no "warm the
detail page" prefetch anywhere in this slice: `DiscoverView.open(_:from:)` and
`MixResults`'/`StackView`'s equivalents just append to `path`, they do not pre-fetch the
series detail page's own requests (`SeriesRepository+Cache.swift`'s `extras` bundle, outside
this slice). So the answer to "what happens to an in-flight prefetch when the reader opens
a series page" is: nothing here needs answering, because nothing in Discover/Search/Mix/Stack
prefetches series-detail data — the only in-flight background work a series-page open could
race is a row's `loadMore` (harmless, additive, unrelated priority) or Stack's queue refill
(P2, above) or `LensCounts`' walk (already `.background`, already queued, already resilient to
interruption — `LensCounts.cancel()` exists though nothing in this slice currently calls it
from a navigation event; not confirmed whether that omission ever matters in practice since
the walk is throttled to one request/250 ms already).

## Stack: what it does well, and the one open question

`StackModel.refill()` de-duplicates overlapping top-up calls by handing every caller the same
in-flight `Task` (`StackModel.swift:305-320`), with a specific comment about the exact bug
(a third refill sneaking in) that a naive `if refillTask == nil` guard produced. Queue refills
never replace the queue, only append (`append(_:)`, `StackModel.swift:389-410`), so a refill
racing a fast double-swipe cannot throw away unseen cards. `isVisible` is genuinely wired
(`StackView.swift:110-111`) to flip the refill's own priority between `.userInitiated` and
`.background` depending on whether the reader is looking at the tab — confirmed by reading
both files, not assumed. The seed pool rotates through the reader's saves/library so the deck
does not narrow onto the same three series forever (`StackModel.swift:240-248,715-727`). A
swipe never blocks on the network **to show the next card** — only, per P2, on the *following*
input while a refill is in flight.

One stale comment, not a behavioural bug: `StackModel.swift:216-219`'s doc comment on
`isVisible` still says "not yet wired; see the 2026-09-13 rate-limit report" — but
`StackView.swift:110-111` wires it. Low value to fix (a sentence), flagging so it isn't
mistaken for open work. **Confidence: certain.**

## Main thread & rendering

- **`OfflineIndexDateLabel.short(_:)` allocates two `DateFormatter`s per call, inside `body`.**
  `MangaBaka/Features/Search/SearchView.swift:344-345` calls it from the `StaleBar` headline
  every time `SearchView.body` re-evaluates while `model.origin == .offlineIndex` — which is
  on every `@Observable` change to `SearchModel` while browsing offline (a new search, a page
  landing, `isSearching` flipping). `DiscoverModel.swift:258-262` solves the identical problem
  (`RelativeDateTimeFormatter` is expensive to spin up) with a `static let` built once; this
  site wasn't given the same treatment. Not a per-scroll-frame cost (this `Group` isn't re-laid
  out by scrolling alone), but a real, avoidable allocation on a hot path for anyone using
  "Browse offline." **Effort: a line — hoist both formatters to `static let`s. Confidence:
  certain.**
- No image decoding, sorting, or DB reads found inside any `body` in this slice.
  `TagBreadth.sortedCounts(of:)` — the one place a per-row sort could have landed — is computed
  once per tag list load and threaded through as `sortedCounts`, with a comment explicitly
  citing the "forty rows each sorting five hundred counts" cost it avoids
  (`TagPickerSheet.swift:561-566`). `DiscoverView`'s weekday string is cached against the
  calendar day rather than recomputed every render (`DiscoverView.swift:180-200`). These are
  both already-fixed instances of the exact pattern being hunted for here, which is why I'm
  citing them under Good news too.
- `@State` churn: nothing found that writes unrelated state on every keystroke or scroll tick.
  `FilterPanel`'s `.onChange(of: query)` only reschedules a debounce timer, not a synchronous
  fetch (`FilterPanel.swift:158,355-386`).

## Rate-limit invisibility

What exists today, and where it's used in this slice:
- **`StaleBar`** (with a `deadline:` countdown from `APIError.rateLimitDeadline`) — used by
  Discover (`DiscoverView.swift:82-91`) and Search (`SearchView.swift:328-336`) whenever a
  refresh fails but there is still content on screen. Both read as "showing what you had,"
  never a bare "too many requests" card, as long as anything was cached.
- **`InlineFailure`** — used for a single failed row (`DiscoverView.swift:227`) or a single
  failed page (`DiscoverView.swift:243`, `SearchView`'s pageFailure equivalent), so one
  throttled row/page never blanks the rest of the screen.
- **`FailureState`** — the last resort, only shown when there is genuinely nothing cached
  (`DiscoverView.swift:358-361`, `MixResults.swift:56-58`, `TagPickerSheet.swift:71`).
- **`MixResults`' dimmed-grid re-blend** (`MixResults.swift:20,35,71-121`) is the strongest
  instance of "reads as still loading" in this slice: a re-blend never wipes the grid, it dims
  the existing one to 0.6 opacity and shows "Re-blending…" in the header — exactly what Abdi's
  ask 1 wants, already built, with a comment citing the specific regression (gap 43) it fixes.

**What's missing:** Stack has no equivalent of `StaleBar`/dimmed-grid for the queue-refill
case in P2 above — when a refill is genuinely rate-limited (not just slow), the reader gets a
locked action row with no visual explanation at all; nothing says "topping up" or shows a
countdown the way Discover's row-level `StaleBar`/`InlineFailure` does. Given the queue itself
still shows the current+next card fine, the gap is narrow (it only matters once the deck is
down to the last 1-2 cards and a refill stalls) but it's the one place in this slice where a
throttle would currently be genuinely invisible rather than read as "still loading."
**Effort: a small view — a corner note or the disabled-button state getting a label change
while `isLoading` is true during a low-queue moment. Confidence: worth checking** (I did not
find a code path that currently surfaces `StackModel.failure` anywhere in `StackView` at all —
worth confirming on a device with the network throttled, since if `failure` truly has no
renderer, that's a bigger gap than described here).

## Debuggability

- **`RecentlyViewedRow.load()`/`record()` swallow every failure with no log line.**
  `MangaBaka/Features/Discovery/RecentlyViewedRow.swift:42-44,48` — if `HistoryStore.entries`
  or `.record` throws (a corrupt local store, say), the row just silently stays empty or stops
  updating, forever, with nothing in the logs to say why. Contrast with `StackModel.react`'s
  careful `recorded` flag and warning toast for the same class of failure
  (`StackModel.swift:465-486`) — the pattern exists in this codebase, just not here.
  **Effort: a line each (a `Logger` call in the catch path). Confidence: certain.**
- **`StackModel.performRefill()`'s `reacted = (try? await shelf.reactedIDs()) ?? []`**
  (`StackModel.swift:332`) and **`buildSeedPoolIfNeeded()`'s equivalent** (`:653`) go silent on
  failure too: a throw here means every previously-skipped series is eligible to resurface in
  the deck with nothing logged, no counter, no visible symptom besides "I swear I already
  skipped this one" — which is precisely the kind of production-only, unreproducible-from-a-
  bug-report failure the charter is hunting for. **Effort: a line. Confidence: certain the
  swallow exists; worth checking whether `shelf.reactedIDs()` can realistically throw in
  practice (the underlying store wasn't reviewed as part of this slice).**
- **`SearchLensStore.init`'s decode failure is silent** (`SearchLens.swift:59-62`): if
  `UserDefaults`-stored lenses fail to decode (a schema change, corrupted data), `own` just
  stays empty and every saved lens is gone with no log and no distinction from "reader never
  saved one." Lower real-world odds than the two above (it only fires on a schema change), but
  the failure mode — a reader's saved lenses vanishing with zero trace — is the kind of thing
  that would otherwise get filed as "search lost my presets" with nothing to go on.
  **Effort: a line. Confidence: certain the swallow exists; likely to matter only across an
  app update that changes `SearchLens`'s or `SearchQuery`'s shape.**

## Size

- No dead code, duplicated logic, or mergeable types found in this slice beyond what's
  already tracked in `open-items-2026-09-15.md`. The four models are each doing one clearly-
  scoped job; the file splits (`SeriesRepository+Priority`/`+Cache`/`+Paging`/`+Count`/`+Mix`,
  `FilterPanel`'s extension, `TagPickerSheet`'s extension) are all lint-length splits with a
  comment saying so, not accidental duplication — checked each one's stated reason against
  what's actually in it, per the charter's warning about half of "dead code" reports being a
  behavioural gap instead.
- One genuine near-duplicate: `FilterPanel.countDebounce` (350 ms) and `SearchModel.queryDebounce`
  (300 ms) are two separately-declared, separately-guessed constants for conceptually the same
  "wait for the reader to stop" idea, sitting 50 ms apart for no stated reason — already flagged
  in `open-items-2026-09-15.md` (full2 E F10/E F12/T#8) and in `FilterPanel.swift:68-71`'s own
  comment, so not re-counted as new here, just confirmed still true at these exact lines.

## Good news, with evidence

- `SearchModel`'s debounce, dedup, and offline-fallback logic (`SearchModel.swift`, 714 lines)
  is the most heavily proven file in this slice: nearly every branch cites a specific incident
  it fixes (screens F2, F5, F7, F8, F9, gap 7, gap 51, item 129), a query-comparison helper
  (`asAsked`) exists specifically so a byte-identical re-ask costs nothing, and the clock is
  injected so the 300 ms debounce is actually testable rather than assumed.
- `LensCounts` (`LensCounts.swift`) queues rather than drops a lens added mid-walk (gap 53),
  paces itself at one request per 250 ms, and stops the whole walk the first time a count comes
  back `nil` rather than hammering the rest of the queue into the same refusal
  (`LensCounts.swift:113-123`) — a specific, sensible reaction to a 429 that nothing had to ask
  me to point out.
- `MixModel`'s single debounce for both strand taps and filter writes (`MixModel.swift:51-57`)
  replaced two independent, un-coordinated debounces that used to race each other — cited with
  the exact screens finding (F28) that proved it.
- `TagBreadth.sortedCounts` and `DiscoverView`'s cached weekday string (cited under Main thread
  above) are both already-applied instances of "compute once, not per render."

## Could not determine

- Whether Stack's queue-refill rate limit (P2's `.background` path when `isVisible == false`,
  or a genuine 429 at `.userInitiated`) is ever actually visible to the reader as anything —
  I did not find `StackModel.failure` read anywhere in `StackView.swift`'s body. If it truly has
  no renderer, Stack is worse off here than Discover/Search/Mix, which all render `failure`
  somewhere. Settling this needs a straight `grep -n "model.failure" StackView.swift` cross-check
  against every other `failure`-reading view (done — zero hits) plus a device run with the
  network conditioner on, to see what actually happens when a refill 429s with the deck down to
  one card.
- The real-world stall duration for P2 (net effect of `await refill()` inside the `isReacting`
  gate) — I traced the code path but did not measure it on a device or in a test with an
  artificial delay. A `RequestBudgetTests`-style test that asserts the Save button stays
  enabled/disabled around a slow `feed()` call would settle it directly.
- Whether `MixModel.suggestedSeeds()`'s and `StackModel`'s several `shelf.entries(.saved)` calls
  ever throw in practice — `ShelfStore` itself is outside this slice, so I can say the failure
  is swallowed silently at every call site listed above, but not how often, if ever, it actually
  fires. A test that makes `ShelfStore` throw and checks whether anything is logged would settle
  it.
