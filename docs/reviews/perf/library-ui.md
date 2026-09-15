# Library screens — performance review

Files reviewed: 11 of 11 (~3,308 lines) — `LibraryModel.swift`, `LibraryView.swift`,
`LibraryList.swift`, `LibraryShape.swift`, `LibrarySort.swift`, `LibraryEditSheet.swift`,
`LibraryRouteCards.swift`, `PickBackUp.swift`, `ContinuationsRow.swift`,
`ReadingInsightsView.swift`, `WrappedView.swift` + `WrappedShapes.swift`. Findings by
confidence: 1 certain, 4 likely, 2 worth checking. Single highest-value change: P1 —
`CountUpNumber` (`WrappedShapes.swift:163-171`) keeps a `TimelineView(.animation)` firing
every display frame, forever, for as long as `WrappedView` is on screen, on every headline
card — not just for the ~0.45s the count-up actually takes.

This slice is in unusually good shape. Almost every hazard the charter names elsewhere in
the app was already found and fixed here, with the measurement in the comment. Read that
as the main finding: nothing below is as severe as a typical charter item, because this
folder has already been through this exercise.

## Requests in flight

| Call | Trigger | Priority | Awaited before draw? | Note |
|---|---|---|---|---|
| Library walk (`LibrarySnapshot.observePages`/`load()` via `LibraryModel.fetchAll()`, `LibraryModel.swift:379-426`) | `.task { await model.load() }`, `LibraryView.swift:146` — screen appearance | Not decided in this slice (`LibrarySnapshot`/`RateLimitGate` priority is Core/Library, not reviewed here) | No — first page draws as it lands; `isLoading` clears after page 1, `isWalking` covers the rest (`LibraryModel.swift:379-426`) | Already the good case: page-by-page draw, not "wait for all 13" |
| Same walk, retry | `StaleBar`/`FailureState` Retry → `model.reload()`, `LibraryView.swift:76, 258` | Same as above | No, same streaming behaviour | `reload()` invalidates the shared snapshot first (`LibraryModel.swift:361-377`) |
| `relationships(for:)` × up to 8, sequential (`ContinuationsModel.load`, `Core/Library/Continuations.swift:123-155`) | `.task(id: model.isComplete)`, `LibraryView.swift:129-132` — fires once the library walk finishes, not per page | Not decided in this slice (`SeriesRepositoryProtocol`, Core/Persistence) | No, row shows a skeleton/`InlineFailure` meanwhile (`ContinuationsRow.swift:24-47`) | Correctly gated on `isComplete`, not on every partial page (comment at `LibraryView.swift:122-128` records the old bug: it used to re-run per page, up to 10× on a 10-page walk) |
| Same, retry | `ContinuationsRow`'s `InlineFailure` retry → `ContinuationsModel.retry`, `ContinuationsRow.swift:44` / `Continuations.swift:160-163` | Same | No | Clears `loadedFor` and re-walks up to 8 requests again |
| One write (`LibraryChange` PATCH) | `LibraryEditSheet` Save tap only (`LibraryEditSheet.swift:268-290`) | User-initiated, explicit tap | Sheet shows a spinner and stays open until it resolves | The one call in this slice that touches the account directly; documented as deliberately explicit (`LibraryEditSheet.swift:5-8`) |
| None | `WrappedView`, `ReadingInsightsView` | — | — | Both are pure on-device computation over `entries` already in memory (`WrappedView.swift:174-196`, `ReadingInsightsView.swift:131-146`) — no network calls in either file |

**Nothing in this folder fires a request per keystroke.** `LibraryModel.searchText`'s
`didSet` calls `refreshListed()`, which only filters/sorts the in-memory array
(`LibraryModel.swift:24-27, 603-606`) — the comment at `:24-26` states this is deliberate
("a request per keystroke against a shared rate limit would be absurd for something
already on the device"), and it is true of every call site checked. The one field that
looks like a search box and actually could fire a request per keystroke —
`FilterPanel`'s year fields / result count (full2 work-list 43) — is Search/Browse, not
this slice.

## Main thread & rendering

- **P1 — `CountUpNumber` never stops redrawing.** `WrappedShapes.swift:146-173`. Each
  headline card (`yearCard`, `sprintCard` — up to 2 of the 8 Wrapped cards use
  `headlineCounting`) wraps its number in `TimelineView(.animation)`, which redraws on
  every display link tick unconditionally — `countUp` clamps `progress` to `1` once the
  0.45s animation is done (`WrappedShapes.swift:327-330`), but nothing tells the
  `TimelineView` to stop scheduling frames. As long as `WrappedView` is on screen, this
  body re-evaluates at the display's refresh rate (60-120Hz) for two `Text` views doing
  nothing after their first ~0.5s. Effort: a line — gate the schedule
  (`TimelineView(.animation(.linear(duration:), paused: progress >= 1))` or switch to a
  plain `@State` + `withAnimation` once `CountUpNumber.countUp` is only read at fixed
  checkpoints). Confidence: likely — reasoned from `TimelineView(.animation)`'s documented
  behaviour, not measured with Instruments on this device (see "Could not determine").
- **Good pattern, cite as such:** `ReadingInsightsView.recompute()` (`:131-146`) and
  `WrappedView.compute()` (`:174-196`) both hop to `Task.detached(priority: .userInitiated)`
  before touching `entries`, with a measured comment (19ms / tens of ms over 1,000 rows)
  justifying it. `LibraryModel.shape`, `.subtitle`, `.inProgress`, `.chaptersRead`,
  `.listed`, `.jumpTargets` are all `private(set)` and recomputed only from
  `refreshFromEntries()`/`refreshListed()`, never read fresh from `body` — with a comment
  at `LibraryModel.swift:158-162` citing the 3-4ms-per-property cost that made this
  necessary. `LibraryList.swift:55-59` replaced a `listed.map(\.id)` diff (a 513-element
  allocation + comparison per body pass) with a counter (`listedRevision`). All three are
  the exact charter-5 shape ("a measurement that measures the wrong thing") done
  correctly, in comments dated 2026-09-11 through -14.
- **`LibrarySort.sorted` for `.title`** (`LibrarySort.swift:34-45`) decorates once before
  sorting specifically to avoid `DisplayTitle.choose`'s locale/lock reads running
  ~2×n log n times per keystroke (documented at `:26-33`, citing work-list 79's ~9k→18k
  comparison measurement on 513 rows). This still runs synchronously on the main actor
  inside `refreshListed()` on every keystroke and every filter/sort change — for 945 rows
  that's one `O(n log n)` decorate-sort, which the file's own numbers put well under a
  frame; not flagged as a defect, just noting it is still main-actor work per keystroke,
  bounded by the fix already in place.
- **No `@State` churn found per scroll frame.** `LibraryList`'s row is a `Button` with no
  `@State`; `JumpIndex` (`LibraryList.swift:275-346`) only writes `activeIndex` on a
  changed drag sample, not continuously; `ProgressFootBar` (`PickBackUp.swift:112-137`)
  animates once on appear and once per `fraction` change, not per frame. This contrasts
  with `CoverGallery.swift` and `ScrollTracker.swift` (full2 items 64-65, outside this
  slice) which do write `@State` per scroll sample — worth noting this folder does not
  repeat that pattern.

## Rate-limit invisibility

- **What exists:** `LibraryView.partialLoad` (`:220-274`) is the fullest three-way
  treatment in the app — still-walking (spinner + honest "so far" count), stopped-with-a-
  failure (`StaleBar` with `deadline: failure.rateLimitDeadline`, `:257`), and hit-the-cap
  (a plain info line). The comment at `:250-256` explicitly records fixing the "one bar,
  three call sites, only one passed a deadline" defect this project has hit repeatedly
  elsewhere (full2 item 39, `DiscoverView.swift:76-89`, still unfixed there). `ContinuationsRow`
  uses `InlineFailure` for a partial continuations walk (`:32-46`) — no countdown (`InlineFailure`
  has no `deadline:` parameter to give it; not checked in this pass, out of slice), but it
  does distinguish "nothing to show" from "something failed" via `hasFailure`, which is
  the more basic of the two properties this charter cares about and is present here.
  `ReadingInsightsView` and `WrappedView` both show `StaleBar` (no deadline — a walk still
  in progress, not a rate-limit, so there is nothing to count down to) captioned "Built
  from the N series that loaded… updates once the rest finishes" (`ReadingInsightsView.swift:79-84`,
  `WrappedView.swift:76-82`) rather than hiding the screen until the walk completes —
  this is exactly the "here is what we had" framing the brief asks for.
- **What's missing:** `ContinuationsRow`'s `InlineFailure` cannot show a countdown even
  when the underlying cause is a rate limit, because `SeriesRepositoryProtocol.relationships(for:)`
  returns `[SeriesRelationship]?` — the real `APIError` (429 vs offline vs 500) is thrown
  away before it reaches this view (comment at `ContinuationsRow.swift:35-41` names this
  itself: "`SeriesRepositoryProtocol` swallows the real `APIError` before it gets here").
  So a continuations row throttled by the 30 or 180/min gate reads as "The request didn't
  complete" with a bare Retry, never "try again in Ns" — concrete idea: thread the real
  `APIError` (or at least its `rateLimitDeadline`) through `relationships(for:)`'s return
  type the way `LibrarySnapshot.load()` already threads `failure`/`isComplete` for the
  library walk itself, and give `InlineFailure` the same `deadline:` parameter `StaleBar`
  has. Effort: function + the Core/Persistence signature change (not this slice's file to
  edit). Confidence: certain the information is discarded today (read the two files
  directly), worth-checking whether it's worth adding `deadline:` to `InlineFailure`
  generally versus only here.

## Debuggability

- **Swallowed failure detail, no log line.** Same site as above:
  `ContinuationsModel.load` (`Continuations.swift:134-140`) turns every
  `relationships(for:)` failure into a bare `anyFailed = true` — offline, 429, and a
  malformed response are indistinguishable, and nothing is printed or signposted when
  `anyFailed` flips true. A silent throttle here would look identical to a silent parse
  failure on every future debugging session. One log line (`Signposts` or even
  `os_log("Continuations: relationships(for: %d) failed", seriesId)`) at the `continue`
  branch would make the difference between "empty because offline" and "empty because a
  decode broke" findable without attaching a debugger. Effort: a line. Confidence:
  certain the branch exists and is silent; worth checking whether Core/Persistence already
  logs this one level up (not reviewed here).
- **Good practice to note:** `LibraryModel.load()` wraps the whole walk in
  `Signposts.measure("Library load")` (`LibraryModel.swift:379-381`) — this is exactly the
  "one log line/signpost" ask, already done for the one call in this slice expensive
  enough to deserve it.
- **`hasAccount` is a dead alias with a stale justification.** `LibraryModel.swift:96-100`:
  "Deprecated alias kept only so call sites outside this batch that still read `hasAccount`
  keep compiling." A repo-wide check found zero non-test production call sites — it is
  referenced only from `LibraryModelTests.swift` and `NonsenseGuardTests.swift`. The
  comment describes callers that no longer exist (charter pattern 7, in miniature): either
  delete it and update the two test files to read `screenState` directly, or, if the tests
  are deliberately pinning the deprecated path as a regression guard, say so in the
  comment instead of describing phantom callers. Effort: a line + two test edits.
  Confidence: likely — confirmed by grep across `MangaBaka/` and `MangaBakaTests/`, not
  by tracing every call site by hand.

## Size

- No file in this slice is oversized enough to flag for a split beyond what SwiftLint's
  `type_body_length` has already forced (`LibraryRouteCards.swift`, `WrappedShapes.swift`
  are both extensions carved out for exactly that reason, and say so in their header
  comments). Largest file is `LibraryModel.swift` at 630 lines, but it is mostly comments
  recording measurements and past defects rather than logic — a genuine case where the
  size is the documentation, not bloat.
- No duplicated logic found between files in this slice. `LibraryEditSheet.chapterText`/
  `.parseChapter` is reused (not reimplemented) by `LibraryList.progressLine`,
  `PickBackUp.chapterLabel`, and `ReadingInsightsView.progressLine` — a single formatter
  called from four places rather than four copies, which is the shape the charter's
  "duplicated constants" item asks for elsewhere.
- `ArrivesModifier` (`MotionModifiers.swift`, outside this slice) and
  `ArrivalHapticModifier` (`WrappedShapes.swift:108-128`) independently compute
  `Motion.stagger(index)` to time a visual rise and a haptic tick to land together. This
  reads like a duplication at first, but the comment at `:102-107` states it is
  deliberate — kept as two call sites, timed off the same shared function, specifically so
  the tick and the rise cannot drift apart the way two hand-maintained constants would.
  Not filed as a finding; noted because the charter asks to check every "computed twice"
  site before assuming it is a bug, and this one is not.

## Hand-rolled controls vs. system ones (charter 6)

- **Jump index** (`LibraryList.swift:275-346`) — a hand-built A-Z rail with its own drag
  gesture, letter math, and accessibility adjustable action. `List` with
  `.searchable`/section index titles would give this for free via
  `UITableView`'s native index, but `List` also forces a different row/selection model
  than this screen's `Button`+`.buttonStyle(.press)` rows and its `zoomSource`/`zoomRoute`
  transition system (used throughout this slice for the cover zoom transition) — a full
  `List` migration is a redesign, not a line, and is not a free win here. Worth checking
  whether `List`'s section index (`.listSectionIndexVisibility` / index titles) could
  sit on top of the existing `LazyVStack`-based rows without giving up the zoom
  transition; not attempted in this pass.
- **Shape bar / filter chips** (`LibraryShape.swift`) — a custom proportional bar and a
  horizontal chip row. There is no system control for "proportional stacked bar as a
  filter", so this one is not shadowing anything; the filter chip row similarly has no
  direct system equivalent (a `Picker` would not show live per-state counts or filter
  visually by width). Not flagged.
- **`LibraryEditSheet`'s state/shelf picker** (`:91-117`) is a `FlowLayout` of custom chip
  buttons rather than a `Picker`/`Menu`. A `Picker(selection:)` with `.pickerStyle(.segmented)`
  or a `Menu` would cost less code and get free VoiceOver rotor support, at the cost of
  losing the multi-row wrapping layout and the fill animation described at `:114-116`. This
  is a real charter-6 candidate but a smaller one than the jump index; effort would be a
  function, not a line, since the chips currently double as the visual state legend.
- **Search field** (`LibraryView.swift:278-285`, `InlineSearchField`) was not defined in
  this slice (its type lives elsewhere) — not reviewed here beyond confirming this screen
  does not build its own text field or clear button from scratch.

## `ShelfDetailView` (charter 7)

Confirmed gone, not merely unreachable: no file named `ShelfDetailView.swift` exists
anywhere under `MangaBaka/` (repo-wide search, zero hits), and `LibraryView.swift:98-103`
carries a comment recording the deletion ("the 'Open the &lt;state&gt; shelf' button stood
here until `ShelfDetailView` was deleted (review Q6)"). This charter item is resolved for
the Library slice specifically — no other destination-with-no-presenter was found in the
11 files reviewed here (every `NavigationLink`/`path.append` in this slice has a caller:
`LibraryList` rows, `PickBackUp` cards, `ContinuationsRow` cards, and
`ReadingInsightsView`'s rows all push onto the same `path: [Series]` the screen owns, and
`LibraryEditSheet` is presented via `.sheet(item:)` from the one `editing` state it sets).

## Good news

- **Measured, not guessed, and the comments carry the numbers and dates.**
  `LibraryModel.swift:158-162` (3ms/4ms/sort per pass on 1,000 entries, "every pass against
  a 16.7ms frame"), `:270-274` (43ms vs 17µs, 0.86ms per body pass, dated 2026-09-11,
  `RedrawPerformanceTests`), `LibrarySort.swift:26-33` (~9k comparisons → 18k
  lock/locale reads → decorate-first fix), `ReadingInsightsView.swift:38-42` (19ms for
  four derived values on 1,000 entries; 13ms for tag verdicts alone).
- **The library walk streams rather than blocks.** `LibraryModel.fetchAll()`
  (`:379-426`) clears `isLoading` after page 1 and keeps a separate `isWalking` for the
  rest, with a comment recording the actual failure mode this fixed (work-list 4: a
  healthy walk on page 2-12 was shown the "hit the cap" message).
- **Mid-walk edits are not silently lost.** `pendingChanges`/`pendingInserts`/
  `pendingRemovals` (`:441-463, 573-629`) replay onto every subsequent page until the walk
  completes, with a named prior bug (work-list 15) motivating each one.
- **The one write path in this slice is deliberately conservative.**
  `LibraryEditSheet.changes` (`:381-408`) only ever sends fields the reader actually
  touched (`ratingTouched`/`noteTouched`), a `guard` documented against a real prior bug
  (work-list 82: an 85 silently rewritten to 80 by an unrelated edit).
- **Continuations correctly distinguishes "fetched empty" from "fetched nothing because
  it failed"** (`Continuations.swift:113-122, 148-154`), including not caching a
  session that saw nothing because it was offline as if it were a real, final answer.

## Could not determine

- **Does `CountUpNumber` (P1) actually cost anything measurable?** Needs Instruments: a
  trace of `WrappedView` sitting open for 5+ seconds after the count-up finishes, checking
  whether the `TimelineView` body re-evaluation shows up as sustained CPU/redraw activity
  versus being coalesced away by SwiftUI. The code path is real; the cost is reasoned, not
  measured.
- **What priority (`.userInitiated` vs `.background`) the library walk and the
  continuations walk actually request at `RateLimitGate`.** That decision is made in
  `Core/Library`/`Core/Persistence`, outside this slice's files, so the "Requests in
  flight" table above states the trigger and shape but not the priority column with
  confidence — would need reading `LibrarySnapshot.swift` and `SeriesRepository.swift`
  directly (partially covered by other slices' reports, not re-derived here).
- **Whether `InlineFailure` deserves a `deadline:` parameter generally**, or whether
  continuations is a one-off — would need a count of how many other `InlineFailure` call
  sites across the app front a rate-limited (vs. merely-failed) request; not counted in
  this pass, which was scoped to `MangaBaka/Features/Library/**`.
