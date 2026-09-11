# Remaining screens — Schedule, Browse, Onboarding, Taste, Shelf, Chrome

Whole-codebase slice review, 2026-09-11. Read-only; no build was run.

## Denominator

Read in full, every line — the whole slice, 1,677 lines across 10 files:

- `MangaBaka/Features/Schedule/ScheduleModel.swift` (247), `ScheduleView.swift` (243),
  `ScheduleRow.swift` (116), `AnnouncedSection.swift` (122)
- `MangaBaka/Features/Browse/BrowseView.swift` (231), `BrowseModel.swift` (69),
  `PublisherBrowser.swift` (106)
- `MangaBaka/Features/Onboarding/OnboardingView.swift` (398)
- `MangaBaka/Features/Taste/TasteModel.swift` (76)
- `MangaBaka/Features/Shelf/ShelfStore.swift` (69)
- `MangaBaka/Features/Chrome/` — **empty directory, zero files, zero tracked files.**

Read in full outside the slice, to answer reachability: `MangaBaka/App/RootView.swift`
(278), `MangaBaka/App/RootView+Session.swift` (148), `MangaBaka/App/BrowseDestination.swift`
(32).

Read in part (targeted, by line range or grep — findings below cite only lines I actually
read): `MangaBaka/Core/Schedule/ReleaseSchedule.swift` (lines 1–300 of 369),
`MangaBaka/Core/Catalogue/CatalogueService.swift` (lines 29–113),
`MangaBaka/Core/Schedule/UpcomingWork.swift` (grep), `Cadence.swift` (grep),
`SettingsView.swift` (lines 60–75), `LibraryEntry.swift` (grep).

**Not reviewed:** `Cadence.estimate` arithmetic (`Cadence.swift` in full),
`ReleaseSchedule.swift` 300–369, `MangaUpdatesClient`, `BlockedTagsStore`, `FlowLayout`,
`InlineSearchField`, `CoverImage`, `Palette`/`Metrics`. The sibling report
`docs/reviews/reader.md` covers the schedule models; its `ReleaseReminders` and
`ReleaseSchedule` findings are not repeated here.

---

## 1. Reachability — every view in the slice, traced

| View / type | Reachable? | Route |
| --- | --- | --- |
| `ScheduleView` | Yes | Library tab → `LibraryView(onOpenSchedule:)` → `showsSchedule` → `RootView+Session.swift:63`. Second route: `SeriesDetailView(onOpenSchedule:)` at `RootView.swift:248` sets the same flag. |
| `ScheduleRow` | Yes | `ScheduleView.swift:220`, plus `DetailScheduleBlock.swift:85` reuses its static wording. |
| `AnnouncedSection` | Yes | `ScheduleView.swift:25`. |
| `ScheduleModel` | Yes | Constructed at `RootView+Session.swift:65`. |
| `BrowseView` | Yes | Search tab → `SearchView(onBrowse:)` → `showsBrowse` → `BrowseDestination` → `RootView.swift:151–164`. |
| `BrowseModel` | Yes | `RootView.swift:153`, cached at `:189`. |
| `PublisherBrowser` | Yes | `BrowseView.swift:39–43`, and `BrowseDestination.swift:28–29` always supplies both `catalogue` and `onOpenPublisher`, so the optional branch is never taken in production. |
| `OnboardingView` | Yes | `RootView.swift:74–85`, `fullScreenCover` on `!onboarding.hasCompleted`. |
| `ShelfStore` | Yes | `AppServices.swift:46`; used by `StackModel.swift:104` and `MixModel.swift:45`. |
| `TasteModel` | **No.** | **Nothing in `MangaBaka/` references it.** Only `MangaBakaTests/TasteModelTests.swift:35`. |
| `Features/Chrome` | n/a | Empty directory. |

### Finding 1 — `TasteModel` is orphaned, and a test is the only thing keeping it alive

- **What** — `TasteModel` has no production caller; its screen was deleted and its route
  repointed, but the model survived because a unit test still constructs it.
- **Where** — `MangaBaka/Features/Taste/TasteModel.swift:10`. Its only reference is
  `MangaBakaTests/TasteModelTests.swift:35`. The route that used to reach it now goes
  elsewhere: `RootView+Session.swift:54–62` presents `ReadingInsightsView` on
  `showsTaste`, with a comment saying exactly that.
- **Why it matters** — charter pattern 7, and worse than `ShelfDetailView`: this one is
  invisible to the tool that was supposed to catch it. Commit `0c4f114` ran Periphery over
  105 findings and deleted `TasteView` (204 lines) as unreferenced, but Periphery counts
  the test as a reference, so the model beneath the deleted screen was left behind. Six
  computed properties — `ratingHistogram`, `ratingLine`, `shapeLine`, `shelfCounts`,
  `commonestRating`, `ratedCount` — are exercised only by tests that were written for a
  screen no reader can open. `TasteModelTests` is a live, green test suite measuring
  nothing a user can see.
- **Effort** — a decision, then a file. Either delete `TasteModel.swift` and
  `TasteModelTests.swift` together, or fold `ratingHistogram`/`ratingLine` into
  `ReadingInsightsView`, which is what actually renders on that route now.
- **Confidence** — certain. Grepped the whole of `MangaBaka/` for `TasteModel`; the only
  hits are its own declaration and the test.

### Finding 2 — `MangaBaka/Features/Chrome/` is an empty directory

- **What** — the directory exists on disk with no files and no tracked content.
- **Where** — `MangaBaka/Features/Chrome/`. `git ls-files` returns 0; the last commit to
  touch it is `1c996f6` ("Use Apple's tab bar instead of drawing one"), which removed the
  hand-built chrome.
- **Why it matters** — cosmetic only, but it is a lie in the file tree: it tells the next
  reader (human or agent) that there is a Chrome module to look at. It is also why this
  slice was budgeted at more lines than exist.
- **Effort** — a line (`rmdir`).
- **Confidence** — certain.

---

## 2. Onboarding — interruption, offline, and the once-only setting

The flow itself is sound, and deliberately so: it is not a gate
(`OnboardingView.swift:5–8`), Skip is on every screen (`:49`), and the no-network case is
designed for rather than ignored (`:97–104`, placeholder tiles at `:122–129` when the
rising feed has not answered). **Interrupted or killed mid-flow, the reader simply sees it
again from page 0** — `hasCompleted` is only written on an explicit exit
(`:394–397`), so there is no half-completed state and nothing is lost. That is the right
trade.

Two things are wrong.

### Finding 3 — "Connect an account" marks onboarding done before any account exists

- **What** — tapping Connect completes onboarding unconditionally, so a reader who is
  offline, mistypes a token, or backs out of Settings has permanently spent the app's only
  account pitch and gets no second chance at it.
- **Where** — `MangaBaka/App/RootView.swift:78–83`: `onConnectAccount` calls
  `onboarding.complete()` first, then navigates to Settings. Nothing re-presents the flow;
  `OnboardingState` (`OnboardingView.swift:383–397`) has no `reset()`.
- **Why it matters** — concrete input: first launch on cellular with no signal. Reader
  taps "Connect an account", lands on a token field, `validateToken`
  (`RootView.swift:268–277`) returns `.unknown(...)` because the network is down, they
  leave. Onboarding never appears again, and the three things an account buys
  (`OnboardingView.swift:279–298`) are never stated anywhere else in the app. The screen
  that exists to establish the one setting worth establishing loses it on the most likely
  failure.
- **Effort** — a function. Either defer `complete()` until the token check succeeds or the
  reader leaves Settings, or leave completion where it is and give Settings/Library a
  standing "connect an account" affordance so the pitch is not once-only.
- **Confidence** — likely. The behaviour is certain from the code; whether Abdi considers
  the once-only pitch acceptable is a product call.

### Finding 4 — `wantsAccountFocus` is set once and never cleared

- **What** — the flag that tells Settings to open with the token field focused is latched
  true for the rest of the process lifetime.
- **Where** — declared `MangaBaka/App/RootView.swift:64`, set true at `:81`, and there is
  no other assignment anywhere (grepped all of `MangaBaka/`). Consumed at
  `RootView+Session.swift:80` → `SettingsView.swift:14` → `:71` (`focusOnAppear:`).
- **Why it matters** — input: tap "Connect an account" during onboarding, then later open
  Settings from the Library screen to change a content rating. The token field steals
  focus and the keyboard covers the screen, every time, for a reader who came to do
  something else. Only affects readers who took the Connect branch, which is why it would
  never show up in a first-run walkthrough.
- **Effort** — a line: clear it when Settings appears, or pass it as a one-shot.
- **Confidence** — certain that it is never reset; likely on the visible symptom, since I
  did not read `focusOnAppear`'s implementation in the token field component.

---

## 3. The schedule screen — what it claims the model cannot support

First run is genuinely fixed (`ScheduleModel.swift:87–117`, `ScheduleView.swift:36–41`),
and the estimate is derived rather than guessed — `firstRunEstimate` multiplies scope by
`MangaUpdatesClient.minimumInterval` and says so (`:95–108`). The states that were not
fixed are where the problems are.

### Finding 5 — a measurement that fails is indistinguishable from one that never started

- **What** — `ScheduleProgress.failure` is written on every request error and read by no
  view in the app.
- **Where** — written at `MangaBaka/Core/Schedule/ReleaseSchedule.swift:274`
  (`progress.failure = error.userFacingMessage`). Grepping `MangaBaka/Features/` and
  `MangaBaka/App/` for `progress.failure` returns nothing; `ScheduleModel.swift` never
  mentions `failure`, and `ScheduleView.swift` never renders it.
- **Why it matters** — charter pattern 3 exactly: computed, then dropped. Input: tap
  "Measure now" with no network, or with MangaUpdates rate-limiting. Every request throws,
  each is recorded as a failure row, and `snapshot()` counts a failed row as `pending`
  (`ReleaseSchedule.swift:179–182` — "Never asked, or asked and failed. Both are still to
  do"), so `measuredAt` stays nil. The build ends, `isRunning` goes false, and
  `hasNeverMeasured` (`ScheduleModel.swift:93`) becomes true again — the screen returns to
  the identical "Nothing measured yet" card it showed three minutes earlier, with no error,
  no toast, and no hint that anything was attempted. The reader's only available
  conclusion is that the button does not work.
- **Effort** — a function: surface `progress.failure` on the measuring/scope card when a
  build ends with it set. The value is already there and already user-facing text.
- **Confidence** — certain about the wiring; certain about the end state, since every path
  through `snapshot()` for a failed row increments `pending` and leaves `newest` nil.

### Finding 6 — a partial build hides the part that is missing

- **What** — after a build that measured some series and failed or skipped the rest, the
  count of unmeasured series disappears from the screen entirely.
- **Where** — `ScheduleModel.swift:69–74`: `measuredLine` only mentions
  `snapshot.pending` in the `measuredAt == nil` branch. Once one series succeeds,
  `measuredAt` is non-nil (`ReleaseSchedule.swift:185`, `:207`) and the line becomes
  "Measured 5 minutes ago". `scopeLine` (`:65–67`) then reports `"12 estimated of 55 in
  scope"`, and `groups` (`:126–192`) renders only `snapshot.dated` and `snapshot.undated`.
  `pending` is rendered nowhere else in `ScheduleView.swift`.
- **Why it matters** — input: a build interrupted by the app being suspended after 12 of
  55 series, which the design explicitly anticipates
  (`ReleaseSchedule.swift:215–219`, "the app can be suspended part way through a
  three-minute job"). The reader sees 43 of their series silently absent from a screen
  headed "Next chapters", with a timestamp saying it was measured and a scope line whose
  two numbers do not account for them. "12 estimated of 55" reads as "43 could not be
  estimated" — which is the one thing it does not mean; `undated` is where that lives. The
  honest number exists in the snapshot and is not shown.
- **Effort** — a line in `scopeLine` or `measuredLine`, e.g. append "· 43 still to
  measure" whenever `pending > 0`, regardless of `measuredAt`.
- **Confidence** — certain.

### Finding 7 — leaving the measuring screen freezes it permanently, against its own copy

- **What** — `onDisappear` cancels the progress poll and nothing ever restarts it, so
  returning to a mid-build Schedule screen shows a frozen progress bar and a disabled
  Re-measure button.
- **Where** — `ScheduleView.swift:57` (`.onDisappear { model.stop() }`) →
  `ScheduleModel.swift:243–246` cancels `pollTask` and nils it. The only place `pollTask`
  is ever created is `measure(refresh:)` at `ScheduleModel.swift:218`, which runs only
  from the two buttons (`ScheduleView.swift:83`, `:160`). `load()`
  (`ScheduleModel.swift:194–200`) refreshes `snapshot` and `progress` once and does **not**
  restart the poll.
- **Why it matters** — input: tap Measure, then tap any row to open a series
  (`ScheduleView.swift:220` pushes onto `path`). `onDisappear` fires, the poll dies. The
  actor build keeps running — `stop()` does not cancel it — so `progress.isRunning` stays
  true in the service. Come back: `isMeasuring` is still true, so the measuring card is
  shown with whatever `done`/`total` it last held, the progress bar never moves again, and
  the Re-measure button is `.disabled(model.isMeasuring)` (`:94`). The screen is stuck
  until the process restarts. The card directly above it reads *"Results appear as they
  land. Leaving the screen does not lose progress — it resumes where it stopped"*
  (`ScheduleView.swift:116–119`). The work does resume; the screen does not, and the copy
  is what makes the reader trust the frozen bar instead of suspecting it.
- **Effort** — a function: restart polling from `load()` (or from `.task`/`onAppear`)
  whenever `progress.isRunning` is true. There is no scene-phase handling either, so the
  same freeze happens on backgrounding.
- **Confidence** — likely. The wiring is certain — nothing restarts `pollTask`. The one
  thing I could not settle by reading is whether SwiftUI re-runs `.task` on a
  `NavigationStack` pop; if it does, `load()` gives one stale-free snapshot and the bar
  still never moves again, so the finding holds either way.

### Finding 8 — an announced volume suppresses the explanation for an empty schedule

- **What** — when nothing is in scope but at least one announced volume exists, the screen
  renders the announced list and then deliberately nothing, so the reader is never told why
  the estimates are absent.
- **Where** — `ScheduleView.swift:28–32`: `if model.isEmpty && model.announced.isEmpty {
  emptyState } else if model.isEmpty { EmptyView() }`. The suppressed `emptyState`
  (`:234–241`) is the only place the app explains the scope rule (reading/rereading/paused
  only).
- **Why it matters** — input: a reader whose library is all completed and dropped, with one
  announced volume. They get a single date card under a header promising "Next chapters"
  for everything they read, and no sentence saying completed and dropped series are
  excluded on purpose. That rule is one the reader never set and cannot infer.
- **Effort** — a line: show the empty-state message below the announced section rather than
  instead of it.
- **Confidence** — certain about the branch; likely that it is unintended, since the
  comment at `:22–24` only argues that the announced section should appear, not that the
  explanation should vanish.

### Finding 9 — `ScheduleView.emptyState` still carries DRAFT COPY

- **What** — the empty state is marked as draft awaiting Abdi's wording.
- **Where** — `ScheduleView.swift:230–233`.
- **Why it matters** — already flagged in-code and to Abdi on 2026-09-10, so this is a
  reminder, not a discovery. Noted because Finding 8 makes the same text harder to reach.
- **Effort** — a line. **Confidence** — certain.

---

## 4. Browse — paging, the request pattern, and one false claim

The request pattern is good and I found nothing that fires per keystroke. Opening Browse
costs exactly two requests (`BrowseModel.swift:66–67`), both guarded: `load()` returns
early once `tags` is populated (`:63`), the `BrowseModel` itself is retained across tab
switches (`RootView.swift:189`), and `CatalogueService.genres()` both caches and
de-duplicates in-flight calls (`CatalogueService.swift:30–32`). Publisher search is
debounced at 350 ms with cancellation (`PublisherBrowser.swift:89–104`). Against a 180/min
shared limit that is comfortable.

### Finding 10 — Browse claims "the 200 most-used tags" and the API does not return them

- **What** — the subtitle tells the reader the list is the most-used tags in the taxonomy.
  A measurement already recorded in this codebase says `/v1/tags?limit=N` is not ordered by
  usage, so the list is an arbitrary 200 of 7,127, sorted after the fact.
- **Where** — the claim: `BrowseModel.swift:19–27` and its subtitle string at `:26`,
  rendered at `BrowseView.swift:74`. The fetch: `CatalogueService.swift:46–70`, which
  passes only `limit` and sorts the returned page locally at `:62`. The contradicting
  measurement is eight lines below it, at `CatalogueService.swift:79–83`: *"There are 7,127
  tags... Measured against the live API on 2026-09-10: `/v1/tags?limit=500` does not
  contain Romance"*. Romance is a tag on thousands of series. If the 500 most-used did not
  include it, the 200 "most-used" do not either.
- **Why it matters** — charter pattern 5. The doc comment at `BrowseModel.swift:20–23`
  argues carefully that a bare count would be "a number about this request rather than
  about MangaBaka" — and then the wording it settled on makes a stronger claim than the
  count would have. A reader who scans the list for Romance and does not find it concludes
  MangaBaka has no Romance tag. The local sort at `CatalogueService.swift:62` is what makes
  it look right: the 200 arrive sorted by count, so the top of the list genuinely is
  heavily-used, and the absence is invisible.
- **Effort** — a line for the copy ("200 of 7,127 tags" or "a sample of the tag tree"); a
  function if the list should actually be the most-used, which needs an ordering parameter
  the API may not have.
- **Confidence** — likely. Certain that the code passes no ordering and that the recorded
  measurement contradicts the claim; I did not re-verify against the live API, and did not
  run a build.

### Finding 11 — the subtitle counts tags the screen does not show

- **What** — the subtitle uses `tags.count` (the raw fetch) while the list renders
  `visibleTags` (filtered).
- **Where** — `BrowseModel.swift:26` reads `tags.count`; the rows come from `sections`
  (`:44–51`), built from `visibleTags` (`:34–41`), which drops merged tags, spoiler tags,
  and any tag with `seriesCount == 0`.
- **Why it matters** — the header says 200 and the reader can count fewer. Small, but it
  is the same class of error as Finding 10 in a screen whose whole design argument is that
  its numbers are honest about what they describe.
- **Effort** — a line: `visibleTags.count`. Note this makes the number move when the
  spoiler toggle flips, which is arguably correct.
- **Confidence** — certain.

### Finding 12 — a stale publisher search can overwrite a newer one

- **What** — the debounced search task has no cancellation check after its `await`, so a
  cancelled in-flight request still assigns its results.
- **Where** — `PublisherBrowser.swift:97–104`. There is a `guard !Task.isCancelled` before
  the network call (`:99`) and none after it (`:101–103`).
- **Why it matters** — input: type `seven`, pause 400 ms (task A fires and is in flight),
  type ` seas` (task B cancels A, but A is past its guard and keeps going). Whichever
  returns last wins. If A returns last the reader sees results for `seven` under the query
  `seven seas`. `isSearching` has the same race — A's `isSearching = false` at `:102` hides
  the spinner while B is still running.
- **Effort** — a line: a second `guard !Task.isCancelled else { return }` after the await.
- **Confidence** — likely. Certain that the check is missing; whether
  `catalogue.searchPublishers` itself honours cancellation and throws early I did not
  verify (it swallows with `try?` at `CatalogueService.swift:104`, which suggests it does
  not).

### Finding 13 — a doc comment describes output the code cannot produce

- **What** — `note(_:)` is documented as producing "Imprint · closed 2019"; it never emits
  a year.
- **Where** — `PublisherBrowser.swift:73` (the doc) against `:78–83` (the code, which
  appends the bare string `"closed"`).
- **Why it matters** — minor on its own, but the surrounding paragraph (`:74–77`) argues
  that the reader needs to know a publisher shut down *and roughly when* before tapping.
  The code delivers half of that, and the comment reads as though it delivers all of it —
  so the gap is documented as closed.
- **Effort** — a line, in whichever direction: fix the comment, or append the year if
  `PublisherRecord` carries one.
- **Confidence** — certain about the mismatch. I did not read `PublisherRecord` to see
  whether a closing year is available.

### Finding 14 — a stale duplicated tag count

- **What** — two different totals for the tag taxonomy, in two files.
- **Where** — `BrowseModel.swift:22` says 7,105 tags; `CatalogueService.swift:79` says
  7,127, with a date and a method.
- **Why it matters** — the charter's "duplicated constants" note, in miniature. Neither
  number reaches the screen, so nothing is wrong today; the hazard is that the undated copy
  is the one a future reader reaches first.
- **Effort** — a line: give the count one home, or date the copy.
- **Confidence** — certain.

---

## 5. Smaller findings

### Finding 15 — `TasteModel.ratingHistogram` files an unrated 0 as one star

- **What** — a rating of exactly 0 is clamped into the one-star bucket rather than skipped.
- **Where** — `TasteModel.swift:31`: `max(1, min(5, Int((rating / 20).rounded())))`.
  `rating` is `Double?` on a 0–100 scale (`LibraryEntry.swift:49–50`); the guard at `:30`
  only skips `nil`.
- **Why it matters** — inflates `ratedCount` and can make one star the "commonest", which
  is the exact sentence `ratingLine` (`:49–54`) prints. The comment at `:39–40` notes that
  one star being commonest on a real library "is the interesting part" — which is a claim
  this clamp could manufacture. Currently unreachable (Finding 1), so the cost is zero
  until someone revives the code.
- **Effort** — a line. **Confidence** — likely; depends on whether the API ever sends 0
  rather than null for unrated, which I did not verify.

### Finding 16 — dead branch in `ScheduleRow.stateText`

- **What** — `days == 0 ? "Due today"` inside the late branch can never fire.
- **Where** — `ScheduleRow.swift:91`. `isLate` is true only when
  `overdueDays > 0` (`Cadence.swift:57–58`), so `abs(overdueDays)` is at least 1 there.
- **Why it matters** — nothing today. Worth a line because `PresentationTests.swift:94–106`
  covers this function, and a test suite that covers an unreachable branch is how a wrong
  belief about the function survives.
- **Effort** — a line. **Confidence** — certain.

---

## What this slice does well

Named with the same evidence standard.

- **The schedule screen refuses to launder an estimate into a fact.** Confidence and
  lateness are rendered as two separate things (`ScheduleRow.swift:5–9`), with the reason
  recorded: merging them once shipped "LIKELY · expected 6 days ago" as a healthy green
  pill. `provenance` (`:112–115`) prints the sample count and the last release date on
  every row, so the number says what it was built from. `AnnouncedSection.swift:3–11`
  states the fact/estimate boundary in the type's own doc and enforces it in code —
  `ScheduleModel.swift:137–141` drops any series with an announced date out of the guessed
  groups, so the same series never appears twice with two different answers.
- **`groups` is ordered by a measurement, not a preference.** `ScheduleModel.swift:120–125`
  records that 61% of estimates on a real library were already in the past, and puts "Past
  due" second rather than treating late as an exception — with the number that forced the
  decision written down beside it.
- **`ScheduledWork.Reason`** (`ReleaseSchedule.swift:16–26`) distinguishes "on hiatus",
  "not on MangaUpdates" and "too few releases" and shows the right one on the row
  (`ScheduleRow.swift:36–39`). Three different silences that would otherwise all look like
  an empty cell — this is the opposite of charter pattern 1.
- **Browse's request discipline.** Two requests per session, cached, in-flight
  de-duplicated, guarded, and retained across tab switches
  (`BrowseModel.swift:63`, `CatalogueService.swift:30–32`, `RootView.swift:189`) — plus a
  350 ms debounce with cancellation on the one field that takes typing
  (`PublisherBrowser.swift:89–99`), with the rate limit named as the reason at `:85–86`.
- **`PublisherBrowser`'s doc records a live check and an upstream bug**
  (`PublisherBrowser.swift:5–12`): `/v1/publishers` answers 503, `/v1/publishers/search?q=`
  works, checked 2026-09-10 — and it says plainly that the A-Z it would rather have needs
  the endpoint that is down. That is a negative result recorded with its reason, which is
  what CLAUDE.md asks for and what stops the idea being re-proposed.
- **Onboarding refused to bundle cover art and said why.**
  `OnboardingView.swift:97–104` records that the board asked for bundled fallback covers,
  that Abdi agreed, and that it was not done anyway because redistributing publisher
  artwork is not something MangaBaka's licence can grant — with the alternative shipped
  (`:122–129`) rather than the problem left open.
- **Onboarding is genuinely not a gate, and the code proves it rather than claiming it.**
  Skip sits on page one (`:49`) with the reason stated at `:16–17`, and `AccountPage`'s
  decline is a full-width button with the argument for that weight written above it
  (`:336–338`).
- **`BrowseView`'s tag rows are one accessibility stop with a real label.**
  `BrowseView.swift:209–219`: children ignored, a composed label ("Boxing, 19 series,
  spoiler tag"), and blocking exposed as a named accessibility action rather than
  context-menu-only — so the one control that works at theme level is reachable without a
  long press.
- **`ShelfStore`'s `clear()` deliberately does not touch the reader's account**
  (`ShelfStore.swift:50–56`), with the reasoning: undoing a swipe must not delete entries
  from someone's real library. A destructive action scoped narrower than its name would
  allow, and argued for.
- **No force-unwraps.** Every optional in the slice is handled with `??`, `guard let`,
  `if let` or a safe subscript (`OnboardingView.swift:116`). The charter's claim still
  holds for these ten files.
