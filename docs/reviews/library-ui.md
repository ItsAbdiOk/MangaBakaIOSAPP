# Deep review — `MangaBaka/Features/Library/**`

Read-only pass, 2026-09-11. 13 files, 2,382 lines, all read in full. No build, no
test run. Cross-slice files (`LibrarySnapshot`, `ReadingInsights`,
`ReadingWrapped`, `RootView+Session`, `LibraryModelTests`) were read only far
enough to settle a question raised inside this slice, and are named where that
happened.

14 findings. The known `ShelfDetailView` unreachability is not re-reported; the
sweep for *other* instances of charter pattern 7 is in L3 and L6.

---

## L1. A failed library load is recorded and then shown as "Nothing saved yet"

- **What** — `LibraryModel.failure` is assigned and no view in the app ever reads
  it, so an offline, unauthorised or mid-walk failure renders as the empty-library
  onboarding card.
- **Where** — assigned at `LibraryModel.swift:218`; the only readers of any
  `model.failure` in the app are `DiscoverView.swift:268` and
  `LibraryControl.swift:130`. `LibraryView.swift` never mentions it. The branch
  that runs instead is `LibraryView.swift:60-66`, falling through to
  `emptyLibrary` at `LibraryView.swift:139`.
- **Why it matters** — trace it: `LibrarySnapshot.load()` sets
  `result.failure = error; result.isComplete = false`
  (`LibrarySnapshot.swift:106-107`) and returns zero entries. `apply` then runs
  `hasAccount = !rows.isEmpty || !complete` (`LibraryModel.swift:235`) →
  `false || true` → **`hasAccount` stays true**. `entries.isEmpty` is true, so the
  reader sees *"Nothing saved yet — Swipe through the stack and anything you keep
  lands here"* with an "Open the stack" button. A reader with 937 tracked series,
  on a plane, is told their library is empty and invited to start one. This is
  charter pattern 1's exact signature, one layer up: the failure is not swallowed
  by the network code — `LibrarySnapshot.swift:27` says so explicitly, *"The
  failure is carried rather than swallowed"* — it is swallowed by the view that
  was never given a failure branch. Charter pattern 3: the whole mechanism was
  built and the last step is missing.
- **Effort** — a function: a `FailureState` branch in `LibraryView.list`, before
  the `entries.isEmpty` check, keyed on `model.failure != nil`. `DiscoverView:268`
  already has the shape to copy.
- **Confidence** — certain.

## L2. The "All" pill counts 937 and produces a list of about 500

- **What** — the filter row's "All" chip is given `model.total`, which includes
  dropped entries, while the list "All" produces excludes them.
- **Where** — `LibraryView.swift:69` passes `total: model.total`;
  `LibraryFilterRow.swift`… `LibraryList.swift:200` renders
  `pill("All", count: total, …)`; `LibraryModel.swift:110` is
  `rows = rows.filter { $0.state != .dropped }` on the nil-filter path.
  `LibraryModel.swift:51` is `var total: Int { entries.count }`.
- **Why it matters** — on the reference account the model's own comment
  (`LibraryModelTests.swift:31`) records 46% dropped. So the chip reads "All 937",
  the header below it reads "All series" (`LibraryList.swift:26`), and the list
  under both has roughly 500 rows. The shape bar directly beside it
  (`LibraryView.swift:74`) is drawn from the same `model.shape`, which *does*
  include dropped — so the bar shows a dropped band whose rows are absent from the
  list the bar sits above. Hiding dropped is deliberate and well argued
  (`LibraryModel.swift:96-99`); stating a total the screen does not honour is not.
  This is the charter-4 sibling you asked about: two counts of "the library", and
  the one that wins on screen is not the one that wins in the label.
- **Effort** — a line, once a decision is made: either pass
  `model.listed.count`-equivalent (entries minus dropped) as the "All" count, or
  label the chip "All 937 · 429 shown". The first is a line; the second is a
  design call.
- **Confidence** — certain on the mechanism; the reference percentages come from
  the comments, not from a run.

## L3. `shelves` and everything built on it is recomputed on every page and read by nothing

- **What** — the shelf derivation runs on each of the ~13 page applications per
  load, and its only production reader sits inside the callback that is never
  invoked.
- **Where** — `LibraryModel.swift:236` calls `Self.shelves(from: rows)` inside
  `apply`. `shelves` (`:269`), `note(for:entries:)` (`:278`), `Shelf.covers`
  (`:21`), `visibleShelves` (`:244`), `matchCount` (`:257`) and `shapeLine`
  (`:174`). Grepping the whole app: `session.library.shelves` appears once, at
  `RootView+Session.swift:28`, inside the `onOpenShelf` closure —
  and `LibraryView` stores `onOpenShelf` at `LibraryView.swift:35` and **never
  calls it**. `visibleShelves`, `matchCount` and `shapeLine` appear only in
  `LibraryModelTests.swift` (`:307, :322, :106`). `ShelfCard.swift` has no
  reference outside its own file.
- **Why it matters** — this is the answer to "is anything ELSE in pattern 7's
  state". It is the same root as the known `ShelfDetailView` finding, but it has a
  cost the write-up does not name: `shelves(from:)` groups the whole library,
  sorts the groups, and builds a `note` string per state — including
  `entries.filter { !($0.note ?? "").isEmpty }` and two more full-shelf walks
  (`:281, :286, :294`) — and it does this **once per arriving page**, thirteen
  times per load on a 939-entry account, on the main actor, for output nothing
  draws. Separately, `shapeLine` (`:174`) is a paragraph of prose that no view in
  the app renders, and `LibraryModelTests.swift:100` tests it as though it were
  live — charter pattern 2: a test that proves a string nobody will ever read.
- **Effort** — a file, and it is the same product decision the unknowns doc has
  already raised. If the answer is "delete", `shelves`, `visibleShelves`,
  `matchCount`, `shapeLine`, `Shelf.note`, `Shelf.covers`, `ShelfCard.swift`, the
  `onOpenShelf` parameter and its six tests go together.
- **Confidence** — certain that nothing production-side reads them; the
  delete-vs-wire-up call is not mine.

## L4. The shape bar is recomputed on every keystroke, filter tap and sort change

- **What** — `refreshDerived()` rebuilds all three derivations whenever any one
  input changes, but `shape` depends only on `entries`.
- **Where** — `LibraryModel.swift:70-74`. `shape = Self.shape(of: entries)` at
  `:71` sits alongside `listed` and `jumpTargets`, and `refreshDerived` is the
  `didSet` of `searchText` (`:29`), `filter` (`:32`) and `sort` (`:35`).
- **Why it matters** — the comment eight lines above (`:59-63`) is the measurement
  that justifies storing these at all: *"3ms, 4ms and another sort respectively …
  against a 16.7ms frame"*. Typing one character into the library search box
  therefore costs the 4ms filter plus the ~6ms sort **plus a wholly unnecessary
  3ms** rebuilding a set of per-state counts that search cannot change — search
  does not change any entry's state, and the shape bar is not search-scoped
  (`LibraryView.swift:74` passes `model.shape` unconditionally). At eight
  characters typed that is 24ms of main-actor work thrown away, on the one code
  path where the reader is watching for latency. The same applies to every filter
  tap and every sort change.
- **Effort** — a line: move `shape = Self.shape(of: entries)` out of
  `refreshDerived` and into `apply` (`:236`), next to `shelves`.
- **Confidence** — certain on the redundancy; the 3ms is the file's own recorded
  number, not one I measured.

## L5. `inProgress` and `subtitle` recompute on every body pass — the two the measurement missed

- **What** — the derivation audit that produced `shape`/`listed`/`jumpTargets`
  stopped there; two more O(n) computed properties are read directly from
  `LibraryView`'s body.
- **Where** — `LibraryModel.swift:163` `inProgress` (a full `filter` over
  `entries` followed by a `sorted`), read at `LibraryView.swift:90`.
  `LibraryModel.swift:151` `subtitle` (`entries.count { ($0.rating ?? 0) > 0 }`,
  a full walk), read at `LibraryView.swift:115`.
- **Why it matters** — this is the direct answer to your third question. The
  comment at `LibraryModel.swift:59-63` states the principle — *"SwiftUI evaluates
  a body far more often than a person changes a filter"* — and then three
  properties were fixed and these two were not, in the same class, read from the
  same body. Every body pass of `LibraryView` walks 939 entries twice and performs
  one sort. `inProgress` is the more expensive of the two (filter + sort) and it
  also returns a fresh array each pass, so `PickBackUp` can never see an
  unchanged input. Neither has a recorded number, which is exactly the "ones
  nobody measured" you asked for — I have not measured them either, and I am
  flagging them as *structurally identical to the three that were measured at
  3/4/6ms*, not as a measured regression.
- **Effort** — a function: give both the same `private(set) var` + `refreshDerived`
  treatment, recomputed in `apply` (`subtitle` and `inProgress` depend only on
  `entries`, so neither belongs in the search/filter/sort path either).
- **Confidence** — certain that they recompute per pass; **worth checking** what
  it actually costs — measure before fixing, per CLAUDE.md.

## L6. The live library list has no way to edit an entry; the unreachable screen has one

- **What** — the redesign that replaced shelf cards with `LibraryList` dropped the
  per-row edit affordance, and the only copy of it survives on the screen nothing
  presents.
- **Where** — `ShelfDetailView.swift:212-215` carries both
  `.accessibilityAction(named: "Edit")` and a `.contextMenu { Button("Edit"…) }`,
  with a comment (`:210-211`) explaining why editing is deliberate rather than
  tap-through. `LibraryList.swift:60-112` — the row a reader actually sees — has
  neither. A project-wide grep for `swipeActions` returns nothing at all;
  `contextMenu` appears only at `ShelfDetailView:213`, `CopyableArtwork:24` and
  `BrowseView:220`.
- **Why it matters** — charter pattern 7 asks for "a route that survived a
  redesign". This is its inverse and it is worse: a *capability* that did not
  survive one, and whose only implementation is now unreachable, so the loss is
  invisible to a grep for dead code. From the Library screen the sole route to
  `LibraryEditSheet` is push into the series detail and use
  `LibraryControl.swift:145`. Marking a chapter read on a series you are
  mid-way through is three taps and a full detail fetch.
- **Effort** — a function: lift the `contextMenu` + `accessibilityAction` block
  from `ShelfDetailView:209-215` onto `LibraryList.row`, and give `LibraryList` an
  `onEdit` the way `ShelfDetailView` has one. Note that fixing it this way, rather
  than deleting `ShelfDetailView`, is the argument *for* option 1 in
  `unknowns-2026-09-11.md` — the capability is worth keeping, the screen may not
  be.
- **Confidence** — certain.

## L7. The jump index's buttons are 20x13pt

- **What** — each letter in the A-Z rail is a 260pt² tap target against Apple's
  1,936pt² minimum.
- **Where** — `LibraryList.swift:178`, `.frame(width: 20, height: 13)` inside the
  `Button` label, with `spacing: 1` at `:172`. `Metrics.tapTarget` is 44
  (`Metrics.swift:62`) and is used correctly eight lines away at
  `LibraryList.swift:54`, and again at `LibraryShape.swift:51, 87`.
- **Why it matters** — the rail only appears past 200 entries
  (`LibraryModel.swift:143`), so on a real library it has 15-26 letters at 14pt
  pitch, and a missed tap lands on the adjacent letter and scrolls somewhere
  wrong. This is a different defect from the 30pt chips in
  `findings-todo.md` C4 — 13pt is under a third of the minimum, and unlike a chip
  the rail has no second route to the same action. It is also the one place in
  this slice where the 44pt rule was not applied, which is what makes it look
  deliberate: the rail cannot be 44pt per letter without being taller than the
  screen. That constraint is real, and it is the argument for taking the system
  control instead (see §Q2 below) rather than for shipping 13pt.
- **Effort** — a redesign of that control, not a line. 26 × 44pt is 1,144pt on an
  852pt screen, so widening the frame does not fit. The honest options are a drag
  gesture over the rail (how UIKit's own index behaves — you slide, you do not
  tap), or `List` + `.sectionIndexTitles`.
- **Confidence** — certain on the measurement; the fix is a design call.

## L8. Editing anything silently truncates a fractional chapter

- **What** — the edit sheet reads `progressChapter` through `Int`, so saving an
  unrelated field rewrites 12.5 to 12.
- **Where** — `LibraryEditSheet.swift:29`,
  `_chapter = State(initialValue: entry.progressChapter.map { String(Int($0)) } ?? "")`,
  against `LibraryEditSheet.swift:235`,
  `if newChapter != entry.progressChapter { change.progressChapter = .some(newChapter) }`.
- **Why it matters** — the sheet's own doc comment (`:5-8`) promises *"only the
  fields actually touched are sent"*, and this defeats it. Open the sheet on an
  entry at chapter 12.5, change only the rating, tap Save: `newChapter` is 12.0,
  `12.0 != 12.5`, so a `progress_chapter` write the reader never asked for is sent
  to their real account. `progressChapter` is `Double` throughout
  (`LibraryList.swift:124`, `PickBackUp.swift:79`, `ReadingInsightsView.swift:164`
  all cast through `Int` for display), and the API models it as a Double, so half
  chapters are representable. The `+1` button (`:118`) has the same rounding.
- **Effort** — a line for the read (format without `Int` when the value is not
  integral), plus deciding whether the keypad should accept a decimal point — the
  field is `.numberPad` at `:107`, which on most locales has no `.`, so a reader
  cannot type 12.5 back even if it round-trips.
- **Confidence** — **likely**, not certain. The truncation is certain from the
  code. What I have not verified is whether `/v1/my/library` ever returns a
  fractional `progress_chapter` in practice — no recorded payload in the repo
  shows one. That is the check worth doing before fixing, and if the answer is
  "the API only ever sends integers", the right fix is to say so in a comment and
  make the model an `Int`, not to leave both.

## L9. "Nearly half of your library is dropped" is a hardcoded sentence, not a count

- **What** — a specific statistical claim about the reader's library is a literal
  string, shown to every reader regardless of their numbers.
- **Where** — `ReadingInsightsView.swift:190`, as the `note:` of the "What you
  give up on" section.
- **Why it matters** — 46% is the reference account's figure and it is recorded in
  three places as *that account's* measurement (`LibraryModel.swift:268`,
  `ShelfCard.swift:9-11`, `LibraryModelTests.swift:31`). Here it has been promoted
  to a statement about whoever is holding the phone. A reader who drops 5% of what
  they start is told nearly half their library is dropped, on a screen whose
  entire stated premise (`:15-17`) is that a claim must say what it is drawn from,
  and which goes to the trouble of computing and printing its own sample size
  eight lines later (`:199-202`). Everything around it is honest; this line is
  not. Charter pattern 4, in its most literal form: a number that shapes output,
  fitted to one example, with nothing marking it as one.
- **Effort** — a line: compute the dropped share from `entries` and either state
  it or drop the sentence.
- **Confidence** — certain.

## L10. The finish/abandon thresholds are undocumented magic numbers in a view

- **What** — 0.6 and 0.3 decide which tags are reported as "what you finish" and
  "what you give up on", with no derivation and no `guess` label, in a view file.
- **Where** — `ReadingInsightsView.swift:173` `($0.completionRate ?? 0) >= 0.6`
  and `:176` `($0.completionRate ?? 1) <= 0.3`.
- **Why it matters** — CLAUDE.md requires an underived constant to be labelled a
  guess, and the charter names "a threshold in a view file rather than in
  `Metrics`" explicitly. These two also interact in the way the charter warns
  about: raise 0.6 and the "finish" list empties; raise 0.3 and tags start
  appearing in both lists at once (nothing prevents overlap if the gap is
  closed). The gap between them is itself an undeclared decision — tags between
  30% and 60% are reported as neither, which is most tags. Contrast
  `LibraryModel.swift:136-144`, where the 200-entry jump-index threshold carries
  three lines saying where it came from and why the design board's own caption
  overruled the board's drawing. That is the standard this file is 12 characters
  short of.
- **Effort** — a line each, plus the sentence saying where they came from.
- **Confidence** — certain.

## L11. A hand-built switch where `Toggle` would do

- **What** — the privacy control is a `Button` wrapping a custom
  `SwitchIndicator`, re-implementing what `Toggle` provides.
- **Where** — `LibraryEditSheet.swift:180-200`; `SwitchIndicator` is defined at
  `SettingsRow.swift:121`.
- **Why it matters** — charter pattern 6. What the system provides and this does
  not: the switch's drag gesture (you can only tap this one), the standard
  on/off haptic, `.isToggle` traits, Switch Control and Full Keyboard Access
  behaviour, and Dynamic Type scaling of the switch itself. The accessibility
  value is re-declared by hand at `:199` precisely because the trait is missing.
  What taking `Toggle` costs the mockup: close to nothing —
  `Toggle(isOn:).tint(Palette.accent).labelsHidden()` beside the existing
  `VStack` renders the same control, and the row's own padding and typography are
  untouched. This is the cheapest pattern-6 win in the slice. It is used in three
  Settings rows too, so the change is bigger than one file if taken everywhere —
  but the Library sheet alone is a self-contained edit.
- **Effort** — a function here, a file if applied across Settings.
- **Confidence** — likely. I have read `SwitchIndicator`'s call sites but not its
  body's animation, so "renders the same control" is an expectation, not a
  verified pixel match.

## L12. Two rating scales in one app

- **What** — the reader's own rating is shown out of 5 in the Library and out of
  10 in Wrapped.
- **Where** — `LibraryList.swift:141` `Int((rating / 20).rounded())` with
  `accessibilityLabel("Rated … out of 5")` at `:145`;
  `LibraryEditSheet.swift:31, 237` also `/20` and `*20`;
  `ReadingInsightsView.swift:217` `"%.1f★"` over a value `ReadingInsights`
  already divided by 20 (`ReadingInsights.swift:191`). Against
  `WrappedView.swift:173` `let scaled = abs(critic.gap / 10)`, printed as
  *"points under everyone else"* at `:176-180`.
- **Why it matters** — I checked the units and the subtraction itself is sound:
  `ReadingWrapped.swift:111` confirms both sides are on the API's 0-100 scale, and
  `StackSections.swift:127` says the Stack shows 0-100 on "the 10-point scale the
  mockup uses". So `/10` is consistent with the Stack and inconsistent with every
  other screen in this slice. A reader who rates everything 4 stars in the edit
  sheet is told in Wrapped that they sit "1.2 points under" — 1.2 of what is never
  stated, and the nearest scale they have seen is out of 5. This is not a bug; it
  is two deliberate mockup decisions that meet on one reader's screen.
- **Effort** — a line, but it is a product call, and the Stack is outside this
  slice so the decision is wider than the Library.
- **Confidence** — certain on the inconsistency, deliberately undecided on which
  scale is right.

## L13. `monthName` builds a `DateFormatter` per call

- **What** — a formatter allocation and locale lookup inside a view helper.
- **Where** — `WrappedShapes.swift:56`,
  `DateFormatter().monthSymbols?[max(0, min(11, month - 1))] ?? "\(month)"`.
- **Why it matters** — small: it is called once per body pass of `busiestCard`,
  not in a loop, so this is an allocation and not a frame. It is listed because
  `DateFormatter` construction is the classic hidden cost and the clamp is doing
  the work a `Date.FormatStyle` would do for free. The clamp itself is correct and
  safe — no force-unwrap, no crash on a bad month.
- **Effort** — a line.
- **Confidence** — certain the allocation happens; the cost is negligible and I am
  not claiming otherwise.

## L14. The "no account" test covers the case that cannot happen and not the one that does

- **What** — `hasAccount`'s only test exercises a clean empty response, which is
  the branch a real reader will almost never hit, and not the failure branch of
  L1.
- **Where** — `LibraryModelTests.swift:109-115`: `StubLibrary(entries: [])` →
  `#expect(!model.hasAccount)`. The stub returns `isComplete: true`, so
  `LibraryModel.swift:235` evaluates `false || false` → false, and the test
  passes. Substitute the real failure path (`isComplete: false`) and the same line
  gives true.
- **Why it matters** — charter pattern 2, in the "a test whose failure mode is not
  the behaviour" sense. The test is not wrong; it is aimed at the branch that is
  hard to reach and silent about the branch that produces L1's wrong screen. Any
  fix for L1 needs this test's sibling — load with a stub that fails on page one,
  assert the reader is not told their library is empty — and per CLAUDE.md that
  test must be shown failing before the fix lands.
- **Effort** — a function.
- **Confidence** — certain on the mechanics; I did not run it.

---

## Your question 2, answered per control

Only three of the hand-built controls in this slice are worth the argument. The
rest are correct as they are, and saying so matters as much as the findings.

**`InlineSearchField` (`LibraryView.swift:181`) vs `.searchable`.** The system
gives scope bars, the cancel button, keyboard dismissal on scroll, the search
field's own Dynamic Type behaviour, and Spotlight-style handoff — all of which
this reimplements or forgoes. The cost is not visual: `.searchable` needs a
navigation bar to attach to, and this screen deliberately has none
(`LibraryView.swift:106-108` records *why* — the bar collapsed and took Settings
with it). So taking `.searchable` means first taking `.navigationTitle`, which is
the fix `ios-design-review-2026-09-10.md:120` already identifies for the scroll
edge effect on all four tab roots. **These are the same change, and doing the
navigation-title fix first makes `.searchable` nearly free.** That is the
concrete finding here, not "use `.searchable`".

**`LibraryList`'s `LazyVStack` (`LibraryList.swift:15`) vs `List`.** What `List`
provides that this slice currently has none of: swipe actions (project-wide grep
for `swipeActions`: zero hits), `.sectionIndexTitles` (which would replace
`JumpIndex` and L7 with it), cell reuse rather than SwiftUI's lazy-stack
recycling at 939 rows, and the standard row-selection accessibility rotor. The
cost to the mockup is real and specific: the Library screen is *one* scroll
containing the header, search field, filter row, shape bar, three route cards,
the PickBackUp strip and then the list — moving to `List` makes all of that
`List` content, and each of those eight elements needs
`.listRowInsets(EdgeInsets())`, `.listRowSeparator(.hidden)` and
`.listRowBackground(Color.clear)` to keep its current appearance. That is
achievable and it is not free. **My honest read: the swipe actions are the prize
(L6 is currently a missing capability), and they can be had without `List` —
`.swipeActions` requires `List`, but a `contextMenu` does not, and
`ShelfDetailView:213` proves the team already chose `contextMenu` for exactly
this and explained why (`:210`).** So: take the `contextMenu`, leave the
`LazyVStack`. "Use `List`" is not the finding.

**`JumpIndex` (`LibraryList.swift:167`) vs `.sectionIndexTitles`.** The system
index is drag-tracked, not tap-tracked, which is the whole reason it works at
13pt — and that is L7's real content. Taking it costs the capsule-on-material
styling (the system index is unstyleable), requires `List` with real sections,
and sections conflict with the four sorts (an A-Z section index is meaningless
under "Recently updated", which `LibraryModel.swift:142-143` already knows). So
this one is genuinely a toss-up, and the cheap fix for L7 is to add a drag
gesture to the existing rail rather than to adopt `List` for it.

**Correct as hand-built, no finding:** `LibraryFilterRow`
(`LibraryList.swift:192`) — a scrolling row of pills carrying counts has no
system equivalent; a segmented `Picker` cannot scroll or show counts.
`LibraryShapeBar` (`LibraryShape.swift:9`) — there is no system proportional bar,
and it already routes both the bar and its legend through 44pt targets
(`:51, :87`). `FlowLayout`, the five-star row (`LibraryEditSheet.swift:146`), and
`sortControl` — the last of which *does* take the system control
(`Picker` inside `Menu`, `LibraryList.swift:37-58`) and is the model for the
rest.

---

## What this slice does well

- **The derivation comment at `LibraryModel.swift:57-63`** states the cost of
  each of three derivations, the frame budget it is measured against, and the
  library size it was measured on. It is the reason L4 and L5 were findable at
  all — the principle was written down, so the two places it was not applied stand
  out. Most codebases would not have given me the number to argue with.
- **`LibraryList.swift:106-111`** records a real bug and its symptom before the
  line that fixes it: keying rows on the index letter collapsed SwiftUI
  identities, *"rows showed the wrong state chip, and under a title sort the stack
  left a screen-high gap"*. That is a comment explaining why with the evidence,
  exactly as CLAUDE.md asks.
- **`LibraryModel.swift:228-232`** is the best comment in the slice: it explains
  why `apply` is deliberately *not* guarded on `rows.isEmpty`, because the early
  return left `isComplete` optimistic — *"which is the exact bug this whole
  partial-data idea exists to prevent"*. A future reader tempted to add that guard
  back is stopped. (L1 is the gap one layer above this, which makes the care taken
  here more striking, not less.)
- **`LibrarySort.comparator` (`LibrarySort.swift:27-65`)** gives every case a
  stable tiebreak with the reason recorded (`:24-26`), handles nil dates
  explicitly rather than by accident (`:36-39`, with the old wrong behaviour
  named), and `dateAdded` is honest about standing in for a field the API does not
  send (`:60-62`). `sortTitle` (`:73`) drops leading articles, with the concrete
  consequence stated.
- **`ReadingInsightsView.swift:63-78` and `WrappedView.swift:68-93`** both move
  their heavy derivations off the main actor via `Task.detached`, each with the
  measurement and the frame budget in the comment above it. Both re-run on every
  visit rather than keying on a count, and `ReadingInsightsView.swift:57-59`
  explains why: *"a library can change without changing size"*.
- **`LibraryModelTests.swift:20-27`** decodes real JSON — including the
  capitalised `"Series"` key that charter pattern 1 names as a live hazard —
  rather than constructing a `LibraryEntry` from the model. That is the opposite
  of the fixture problem the charter describes.
- **`PickBackUp`'s exclusion of paused** (`LibraryModel.swift:157-162`) is
  justified with the number it produced on a real library (226 series) and the
  reason paused is not a nudgeable state. `PickBackUp.swift:78-83` guards both
  operands and clamps, so no division by zero and no bar past 100%.
- **No force-unwraps.** I checked every `!` in the thirteen files: the only
  occurrences are boolean negation and `!=`. `WrappedShapes.swift:56` clamps its
  array index rather than trusting the month. `ShelfDetailView.swift:230-236`
  explicitly handles a reader being past the recorded chapter total and records
  why the two displays had disagreed. The charter asks for this claim to be
  re-verified rather than assumed — verified, for this slice.
- **The accessibility work is present and reasoned.** `LibraryShape.swift:24-27`
  names Apple's audit finding (a 370x7 hit area) and states the fix;
  `LibraryList.swift:52-54` does the same for a 129x17 menu label;
  `LibraryList.swift:147-154` explains why an unrated row shows nothing rather
  than a dash, with the contrast ratio. L7 is the one place this was not done, and
  it is conspicuous against the rest.
