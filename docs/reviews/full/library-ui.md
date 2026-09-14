# Deep review — Library and Stack UI (slice 5)

2026-09-14. Read-only: nothing built, run, edited or committed. HEAD `1f118cd`.

## Coverage

Slice: `Features/Library/**` (17 files, 3,498 lines), `Features/Stack/**` (6 files,
1,637), `Features/Shelf/**` (1 file, 118). **Read in full: 23 of 24 files (5,124 of 5,253
lines).** `ShelfDetailView.swift` read at lines 1–105 and 235–338 only — the brief marks
it known and it is not re-filed here.

Read outside the slice, for wiring and cost only: `Core/Library/LibrarySnapshot.swift`
(whole), `Core/Library/LibraryEntry.swift` (whole), `App/RootView+Session.swift` 1–100 and
280–310, `App/RootView.swift` 85–130, 195–250, 295–318, `Features/Shared/CoverImage.swift`
(whole), `Core/Images/CoverStore.swift` (whole), `DesignSystem/MotionModifiers.swift`
(whole), `Features/Shared/ScrollEdge.swift` 1–102, `Features/Shared/InlineSearchField.swift`
1–60, `Core/Model/DisplayTitle.swift` 23–48, `Core/Model/TitlePreference.swift` 51–60,
`Core/Library/Continuations.swift` 123–148, `Core/Library/LibraryService.swift` 41–70,
282–294, 338–343, `Core/Library/ReadingWrapped.swift` 50–54, 119–126,
`Core/Persistence/AppDatabase.swift` 169–180, `Core/Model/Series.swift` 336–343, tests
`LibraryModelPagingTests`, `LibraryModelTests` (grep), `JumpIndexTests`, `StackMotionTests`,
`StackSaveTests` (grep).

Prior findings L1–L11 and the failures-library table were checked against the code; all
but the ones named below are fixed and not re-filed. The header subtitle, the "All" chip,
the toast hit shape and `ShelfDetailView` reachability are excluded per the brief.

## Ranked top ten (value against effort)

| # | Finding | Where | Effort | Conf. |
|---|---------|-------|--------|-------|
| 1 | An edit saved while the library walk is still landing pages is overwritten by the next page, and the pre-edit row is cached for six hours (§1) | `LibraryModel.swift:328-341, 357-363`; `LibrarySnapshot.swift:100-103, 119-121, 205-208` | function | certain |
| 2 | Every normal multi-page walk shows the page-cap copy "Showing the first 100 / 200 / …" from page 2 until the last page lands (§2) | `LibraryModel.swift:401`; `LibraryView.swift:243, 262, 269-281` | function | certain |
| 3 | Retry after a partial failure shows the old "Some of your library didn't load" bar for the whole new walk (§3) | `LibraryModel.swift:297-309, 82-85, 401` | line | certain |
| 4 | `isComplete` is never passed to Insights or Wrapped, so their "Built from the N that loaded" bar can never show (§4) | `RootView+Session.swift:44-57, 63-66`; `ReadingInsightsView.swift:24`; `WrappedView.swift:23` | line ×2 | certain |
| 5 | Decoded covers are held by every row the reader has scrolled past — the 96 MB cache cap does not bound it (§5) | `LibraryList.swift:22, 110`; `CoverImage.swift:32`; `CoverStore.swift:30-34` | line or file | likely |
| 6 | One library edit posts "Saved" twice — two toasts, two VoiceOver announcements (§6) | `LibraryEditSheet.swift:271`; `RootView+Session.swift:306` | line | certain |
| 7 | Editing only the note rewrites an untouched rating to the nearest multiple of 20 (§7) | `LibraryEditSheet.swift:36, 379-380` | function | worth checking |
| 8 | Every visit to the Stack tab decodes the whole saved shelf and reads every reaction timestamp before the first network request starts (§8) | `StackView.swift:95`; `StackModel.swift:264-269`; `ShelfStore.swift:46-64, 92-96` | function | likely |
| 9 | A quick second tap on Save/Skip reacts to the next card before it is visible; a second save inside 550 ms cancels the first flight (§9) | `StackView.swift:353-367, 384-388, 405-407, 419` | function | likely |
| 10 | Title sort evaluates `Locale.preferredLanguages` and rebuilds the display title on every comparison, on the main actor, per keystroke (§10) | `LibrarySort.swift:44-51, 73-79`; `DisplayTitle.swift:23-27`; `LibraryModel.swift:29, 142, 190` | function | likely |

Everything else is in §11 onward, in roughly descending value.

## The findings

### 1. An edit during the walk is overwritten by the next page, then cached stale

- **What** — `LibraryModel.apply(_:to:)` patches the row in `entries` and asks the snapshot
  to patch its cache, but while the walk is in flight the snapshot has no cache to patch,
  and the next page emission replaces `entries` wholesale with the walk's accumulated
  rows, which were fetched before the write.
- **Where** — `LibraryModel.swift:357-363` (patch in memory, then `snapshot.apply`);
  `LibrarySnapshot.swift:205-208` (`guard var result = cached` — `cached` is nil for the
  whole walk, set only at `:120`); `LibrarySnapshot.swift:100-103` (`result.entries` is the
  accumulator; `onPage?(result.entries)` hands the whole accumulated list back);
  `LibraryModel.swift:328-336, 395` (`entries = rows` replaces the patched row);
  `LibrarySnapshot.swift:119-121` (that stale result is what gets cached for six hours,
  `:46`). The Edit action is offered during the walk — `LibraryList.swift:159, 237-239` —
  while "Open the shelf" is gated on `isComplete` (`LibraryView.swift:108`) for the
  neighbouring reason.
- **Why it matters** — Sequence on the reference account (10 pages, ~3 s, no disk cache):
  open Library, long-press a row from page 1, Edit, set 5 stars, Save. The PATCH lands in
  ~300 ms, "Saved" is shown, then page 3 lands and the row shows its old rating again. The
  disk cache written at the end holds the old rating; every launch for six hours shows it.
  The server has the new value, so the app disagrees with the account it just wrote to.
- **Fix** — In `LibraryModel`, keep `private var pendingChanges: [Int: LibraryChange]`;
  `apply(_:to:)` records into it when `!isComplete`; `apply(_ rows:isComplete:)` re-applies
  every pending change to the matching rows after `entries = rows` and clears the
  dictionary when `complete`. In `LibrarySnapshot.apply(seriesId:change:)`, when `cached ==
  nil && inFlight != nil`, stash the change and apply it to `result` before `cached = result`
  / `writeCache` at `:119-121`. Test: `PagedLibrary(total: 300)` with page 2 gated on a
  continuation; call `apply(change, to: id-from-page-1)` between pages; assert the row after
  `load()` returns. Control: the same test with the edit after `load()` passes today.
- **Effort** — a function. **Confidence** — certain. **Lens** — 1 (bug), 8 (data race the
  compiler cannot see).

### 2. The page-cap copy shows during every normal walk

- **What** — `partialLoad` has three branches — spinner, failure bar, "Showing the first N"
  — chosen on `isLoading`, then `partialFailure`, then everything else. `isLoading` is
  switched off when the *first* page lands, so from page 2 to the last page a healthy walk
  takes the third branch.
- **Where** — `LibraryModel.swift:401` (`isLoading = false` in `apply`, with its comment
  about the spinner stopping at page one); `LibraryView.swift:243` (`if model.isLoading`),
  `:262` (`partialFailure`, nil on a healthy walk), `:269-281` (the cap copy).
- **Why it matters** — On the reference account, without a fresh disk cache, the screen
  reads "Showing the first 100", then "…200", up to "…900", each with the info icon that
  means "this is all you get", for the three seconds the walk takes. The comment at
  `LibraryModel.swift:76-81` says callers combine `partialFailure` with `isLoading` to tell
  "still walking" from "hit the cap"; `isLoading` cannot carry that, because `:401` reuses it
  for "first page drawn". `LibraryModelPagingTests` (lines 20-45) only assert the end
  states, so nothing pins the mid-walk one — charter 2, by omission.
- **Fix** — Add `private(set) var isWalking = false` to `LibraryModel`; set true at
  `fetchAll` (`:317`), false after `snapshot.load()` returns (`:340`), and false in
  `forget()`. `partialLoad` spinner branch: `if model.isWalking`; cap branch stays as the
  final else. Test: `PagedLibrary(total: 300)` with an `observePages` hook — after page 1,
  `isWalking == true && isLoading == false`; after `load()`, `isWalking == false`.
- **Effort** — a function. **Confidence** — certain. **Lens** — 1.

### 3. Retry after a partial failure shows the stale failure bar through the new walk

- **What** — `reload()` clears `entries` but not `failure`; the first page of the new walk
  flips `isLoading` off, so `partialFailure` returns the previous walk's error until the
  final `failure = result.failure` at the end.
- **Where** — `LibraryModel.swift:297-309` (`reload` — no `failure = nil`), `:82-85`
  (`partialFailure` reads `failure` whenever `!entries.isEmpty && !isComplete`), `:401`
  (`isLoading = false` on page one), `:341` (failure only replaced after the whole walk);
  `LibraryView.swift:262-268` (the bar, with Retry).
- **Why it matters** — Tap Retry on "Some of your library didn't load — 200 so far": page 1
  of the new walk lands, the bar comes back saying the same thing with "100 so far", and a
  second Retry mid-walk starts a third walk (`reload` bumps the generation and invalidates,
  so it is safe, but it is a wasted 10 requests against the 180/min window).
- **Fix** — `failure = nil` after `entries = []` at `:307`, and again at the top of
  `fetchAll` (`:317`). Test: `PagedLibrary(total: 300, failOnPage: 3)`, `load()`, then set
  `failOnPage = nil`, `reload()` with a page observer, assert `partialFailure == nil` after
  page 1.
- **Effort** — a line. **Confidence** — certain. **Lens** — 1, 2.

### 4. `isComplete` never reaches Insights or Wrapped

- **What** — Both views take `var isComplete = true` "until the shell (batch 6) passes the
  real value". The shell never did; the `StaleBar` in each is unreachable.
- **Where** — `ReadingInsightsView.swift:20-24, 71-76`; `WrappedView.swift:19-23, 74-79`;
  the call sites `RootView+Session.swift:44-57` and `:63-66` pass `entries` and `path`
  only. `revision` (`ReadingInsightsView.swift:51`, `WrappedView.swift:33`) also keys on it,
  so the "walk finished" half of that recompute trigger is dead too.
- **Why it matters** — Open "Your reading" while the walk is on page 3 of 10: "312
  chapters" over 300 entries, no bar saying it is built from a third of the library, and
  when the walk finishes the count changes so it recomputes silently to a different number.
  The failures audit (`failures-library.md` row "Your reading (Insights)") rated this H and
  the view side was built; the wiring was the half that did not land.
- **Fix** — `isComplete: session.library.isComplete` at both call sites. Delete the two
  "until batch 6" comments.
- **Effort** — a line each. **Confidence** — certain. **Lens** — 2 (a failure reported as a
  complete result); charter 3.

### 5. Covers held by every row scrolled past, unbounded by the cache

- **What** — `LazyVStack` creates rows on demand and does not discard them; each row's
  `CoverImage` holds its decoded `UIImage` in `@State`. `CoverStore`'s 96 MB cost cap bounds
  the cache, not the rows.
- **Where** — `LibraryList.swift:22` (`LazyVStack`), `:110-116` (one `CoverImage` per row);
  `CoverImage.swift:32` (`@State private var loaded: UIImage?`), `:107-123` (assigned and
  never cleared); `CoverStore.swift:30-34` (cap on the `NSCache` only), `:126`
  (`byPreparingForDisplay` — the bitmap is fully decoded, so the held object is the decoded
  size). Lazy stacks retaining created children is Apple's documented behaviour (WWDC20
  "Stacks, Grids, and Outlines in SwiftUI").
- **Why it matters** — A 38 pt row asks for the x150 variant (`cover.url(forHeight:scale:)`,
  `CoverImage.swift:39`): ~150×225×4 ≈ 135 KB decoded. Scroll the 513 "All" rows to the
  bottom: ~70 MB in row state on top of whatever the cache holds; open the dropped shelf
  (429) or search-clear a few times and the stack keeps growing. Not a crash on a 16 Pro;
  a jetsam risk on a 2 GB device with the schedule and Search tabs also warm. **Not
  measured** — see the unknowns.
- **Fix** — Cheapest: in `CoverImage`, `.onDisappear { loaded = nil; isReady = false }`. The
  synchronous `cached(url)` path (`:109-118`) repaints a returning row in the same frame,
  so nothing flickers; the cost is one dictionary lookup per reappearance. This touches a
  shared view (every screen), so it is a cross-slice change. Alternative: `List` (§ "List
  versus the hand-built scroll view").
- **Effort** — a line (shared) or a file (`List`). **Confidence** — likely. **Lens** — 8
  (unbounded memory), 7.

### 6. Two "Saved" toasts per edit

- **What** — The sheet shows "Saved" and dismisses; the shell's `saveLibraryChange` shows
  "Saved" again. The second replaces the first visually, but `ToastCentre.show` posts an
  `AccessibilityNotification.Announcement` each time.
- **Where** — `LibraryEditSheet.swift:271`; `RootView+Session.swift:306`;
  `ToastCentre` announcement at `Features/Shared/ToastCentre.swift:77`.
- **Why it matters** — A VoiceOver reader hears "Saved. Saved." after every edit; the
  second announcement can also pre-empt the sheet's dismissal focus change.
- **Fix** — Delete `LibraryEditSheet.swift:271`. The shell's toast is the one that survives
  a dismissed sheet (the gap-110 comment at `:261-266` is the reason to keep that one).
- **Effort** — a line. **Confidence** — certain. **Lens** — 9.

### 7. An untouched rating is rewritten to the nearest multiple of 20

- **What** — The sheet rounds the server's 0–100 rating to five stars on the way in and
  compares `stars × 20` with the original on the way out; any rating that is not a multiple
  of 20 differs, so it is sent even when the reader only edited the note.
- **Where** — `LibraryEditSheet.swift:36` (`Int(wholeOrClamped: ($0 / 20).rounded())`),
  `:379-380` (`newRating = Double(rating * 20)`; `if newRating != entry.rating`). Compare the
  chapter field, where the same file records fixing exactly this ("a reader at 12.5 who
  edited only the rating used to have 12 written back", `:32-33`).
- **Why it matters** — If MangaBaka stores 85 for an entry (the API field is 0–100; whether
  the website ever writes a non-multiple of 20 is **unverified** — half stars would be
  multiples of 10), editing the note PATCHes `rating: 80`. The note trim at `:382-384` has
  the same shape at lower stakes: a server note with a trailing newline is re-sent
  trimmed.
- **Fix** — `@State private var ratingTouched = false`, set in the star button at `:174`;
  in `changes`, only compute/compare the rating when `ratingTouched`. Same guard for the
  note (`noteTouched` on `onChange(of: note)`), or compare trimmed-to-trimmed.
- **Effort** — a function. **Confidence** — worth checking (the payload question).
  **Lens** — 1.

### 8. The Stack tab pays for the whole shelf on every visit, before its first request

- **What** — `.task { await model.loadIfNeeded() }` re-runs on every appearance (each tab
  switch back). `loadIfNeeded` awaits `refreshSaved()` (decode every saved `Series` payload)
  and `refreshTodayProgress()` (read every reaction timestamp ever) before it checks whether
  there is anything to do, and before `refill()` starts the network.
- **Where** — `StackView.swift:95`; `StackModel.swift:264-269`; `ShelfStore.swift:46-64`
  (`entries(.saved)` decodes all payloads), `:92-96` (`SELECT addedAt FROM shelfEntry` —
  unbounded); `StackModel.swift:198-201` (all timestamps bucketed in Swift after every
  reaction, `:430`). Index: `AppDatabase.swift:180` is `(kind, addedAt)`, which does not
  serve `ORDER BY addedAt DESC LIMIT 60` at `ShelfStore.swift:109-116` without a sort.
- **Why it matters** — First paint of the Stack waits on DB read + N decodes before the
  feed request is even sent; on a reader with a few hundred saves that is tens of ms
  serialised ahead of a ~300 ms network round trip, and it is repeated on every tab
  switch though `react` keeps `saved` in step (`:413`). The timestamp read grows with every
  swipe forever. **Not measured.**
- **Fix** — In `loadIfNeeded`: `async let` the two refreshes and the `refill()` decision;
  skip `refreshSaved()` when `!saved.isEmpty` (reset already empties it, `:387`). Replace
  `reactionTimestamps()` with `func reactionCount(since: Date) -> Int` (`SELECT COUNT(*)
  WHERE addedAt >= ?`), computing `startOfDay` in `StackModel`; keep `countToday` as the
  pure rule for the test. Add a migration index on `addedAt` alone.
- **Effort** — a function. **Confidence** — likely. **Lens** — 3, 7.

### 9. Double reactions and a clobbered save flight

- **What** — Nothing rejects a second reaction while the first is still animating. The
  model removes the head synchronously, so a second tap within the ~0.45 s arrival acts
  on a card the reader has not seen. Separately, `beginSaveFlight` clears `flightSeries`
  after a fixed 550 ms without checking whose flight it is.
- **Where** — `StackView.swift:405-407, 419` (buttons never disabled), `:353-367` (`react`,
  no in-flight guard), `:315-340` (gesture end also calls `react`); `StackModel.swift:396-399`
  (`removeFirst` before the first `await`); `StackView.swift:384-388` (the unconditional
  `flightSeries = nil`), `:159` (the real card is hidden while `flightSeries != nil`).
- **Why it matters** — Double-tap "+" (or tap "+" during a drag's release): two series
  saved, the second sight-unseen, both POSTed as `plan_to_read` to the account
  (`StackModel.swift:454`). Two saves inside 550 ms: the first Task hides the second ghost
  mid-flight and the real card pops back to full opacity.
- **Fix** — `@State private var isReacting = false`; set at the top of `react`, clear after
  `await model.react(kind)`; `.disabled(isReacting)` on both buttons and `guard !isReacting`
  at the top of the gesture's `onEnded` commit path. In `beginSaveFlight`, capture
  `series.id` and only clear when `flightSeries?.id == id`.
- **Effort** — a function. **Confidence** — likely (wants a device double-tap to confirm
  the second reaction is observable; the model path is certain). **Lens** — 1, 9.

### 10. Title sort rebuilds the display title on every comparison

- **What** — `sortTitle` calls `series?.displayTitle` (a full `DisplayTitle.choose`) and
  `lowercased()` up to three times, per side, per comparison. `choose`'s default arguments
  `Locale.preferredLanguages` and `TitleSettings.preference` (a lock) are evaluated on every
  call, whether or not the early return at line 30 uses them.
- **Where** — `LibrarySort.swift:44-51, 73-79`; `DisplayTitle.swift:23-27`;
  `TitlePreference.swift:53-60`; called from `LibraryModel.swift:190` on every
  `searchText`/`filter`/`sort` change (`:29, 32, 35`) and again per entry in `jumpTargets`
  (`:198-203` via `indexLetter` → `sortTitle`).
- **Why it matters** — 513 listed rows sorted by title ≈ 9k comparisons ≈ 18k
  `displayTitle` + 18k `Locale.preferredLanguages` (a CFPreferences read each) + ~54k
  `lowercased()`, on the main actor, per keystroke in the search field. The comment at
  `LibraryModel.swift:126-130` cites "3ms, 4ms and another sort" but not the sort, the
  date, or the method — charter 5. The stored-derivation design is right; the sort inside it
  is the expensive part.
- **Fix** — Schwartzian transform in `listed`: `rows.map { ($0, $0.sortTitle) }` once, sort
  on the key with `localizedCaseInsensitiveCompare`, map back. Cache `sortTitle` per
  `seriesId` in `LibraryModel` on `apply(_ rows:)` (titles change only with the title
  preference, which bumps `titleRevision` and rebuilds the tab). Measure first: a
  `#expect` on the wall clock of `listed(from: 942 fixture entries, sort: .title)` versus
  `.dateAdded` as the control.
- **Effort** — a function. **Confidence** — likely. **Lens** — 3, 7.

### 11. `hasCredentials` is never wired; `.noAccount` is unreachable

- **What** — `LibraryModel` takes `hasCredentials` defaulting to `{ true }` "until batch 6
  wires the real check from `TokenStore`"; no production caller passes it.
- **Where** — `LibraryModel.swift:95-100, 108` (the default); the only `hasCredentials:`
  arguments in the repo are in `LibraryModelPagingTests.swift:108, 120`.
  `ScreenState.noAccount` (`:45, 62`) and the `noAccount` view (`LibraryView.swift:321-329`)
  are therefore dead; `LibraryModelPagingTests.swift:105-110` keeps them alive — charter 7
  with a charter-2 test.
- **Why it matters** — A reader with no token pays a 401 request per Library visit and sees
  the generic "This part needs an account" failure — acceptable, per the failures audit —
  but the screen written for them never appears, and the audit's proposal that
  `hasAccount` "must come from the token" was built on the model side only.
- **Fix** — Either pass `hasCredentials: { tokenStore.hasToken }` where `session.library`
  is constructed (Session; not read here), or delete `.noAccount`, the view, `hasAccount`
  (`LibraryModel.swift:70-74`, used only by `NonsenseGuardTests.swift:184` and
  `LibraryModelTests.swift:157`) and the two tests. The first is the one the comments
  promise.
- **Effort** — a line plus a test. **Confidence** — certain. **Lens** — 9; charter 7.

### 12. Dead members kept alive by tests

- **What** — Production code nothing calls: `ShelfCard` (whole file), `LibraryModel.visibleShelves`,
  `matchCount`, `shapeLine`, `Shelf.covers`.
- **Where** — `ShelfCard.swift:5-91`; `LibraryModel.swift:404-418` (`visibleShelves`,
  `matchCount`), `:277-287` (`shapeLine`), `:20-21` (`covers`, read only by `ShelfCard`).
  Callers: `LibraryModelTests.swift:122-128, 360-394` only. Prior review noted `ShelfCard`
  unused on 2026-09-13; still true.
- **Why it matters** — 150 lines that compile, test green, and describe a shelf-card screen
  that was replaced by the list (`LibraryList.swift:3-9`). The tests prove the dead code
  agrees with itself (charter 2).
- **Fix** — Delete all five and their tests. Keep `isSearching` (`:420-422`, used by
  `isFiltering`).
- **Effort** — a file. **Confidence** — certain. **Lens** — 9; charter 7.

### 13. `StackModel.isVisible` is never set

- **What** — The foreground/background request-priority split reads a flag no view writes.
- **Where** — `StackModel.swift:207-217` (declared, "not yet wired"), `:631` (read).
- **Why it matters** — Every stack refill is `.userInitiated`. In practice refills are only
  triggered from the Stack screen (`react`, first appear, retry), so the observable cost is
  one case: a reaction's POST + refill continuing after the reader switches tabs. Small —
  but the comment promises a behaviour the app does not have.
- **Fix** — `StackView`: `.onAppear { model.isVisible = true }`, `.onDisappear {
  model.isVisible = false }`. Or delete the property and the branch at `:631`.
- **Effort** — a line. **Confidence** — certain (unwired); impact low. **Lens** — 6; charter 3.

### 14. `resetStack()` keeps the recommender's page cursor

- **What** — Reset clears the shelf, the queue and the seeds, but not `recommendationPage`
  or `canUseProfile`; the next deal asks for page N+1.
- **Where** — `StackModel.swift:384-394` versus `:236, 243, 509`.
- **Why it matters** — The reader who resets because "a handful of swipes sent every card
  the same way" (`:366-369`) gets a deal that skips the first N×20 profile recommendations —
  the very cards they swiped wrongly, now no longer excluded server-side either (the
  exclusion list comes from the emptied shelf, `:521`). Depends on MangaBaka's page ordering
  being stable across calls — **unverified**.
- **Fix** — `recommendationPage = 0` and `isColdStart = false` in `resetStack()`. Leave
  `canUseProfile` (a status answer, not a cursor).
- **Effort** — a line. **Confidence** — likely. **Lens** — 1.

### 15. Seed pool fetches a library page outside the shared snapshot

- **What** — When the profile recommender is unusable and there are no local saves, the
  stack fetches `/v1/my/library?page=1&limit=50` itself.
- **Where** — `StackModel.swift:584-591`; the snapshot the rest of the app shares is
  `LibrarySnapshot` (`RootView.swift:41`), and its doc explains why one walk exists
  (`LibrarySnapshot.swift:4-18`).
- **Why it matters** — ~1.3 MB (50 × the 26 KB/entry measured at `LibrarySnapshot.swift:7-8`)
  against the 180/min window to answer a question the snapshot's disk cache already
  answers offline. And "highest priority first" (`:585-586`) sorts an arbitrary server-ordered
  first 50, not the library's top 50.
- **Fix** — Give `StackModel` an optional `LibrarySnapshot` (RootView already holds one)
  and use `await snapshot.all()` filtered and sorted as now. Rare path; low urgency.
- **Effort** — a function. **Confidence** — certain (duplicate fetch). **Lens** — 6, 3.

### 16. The jump rail can still emit a duplicate letter for Ø, Æ, Ł, Đ, Þ, ß

- **What** — L1 folded diacritics so "Ōoku" files under O. Letters that are not
  base+diacritic do not fold: `Ø`, `Æ`, `Ł`, `Đ`, `Þ`, `ß` become "…", while the
  collation sorts them among O, A, L, D, T, S. "…" lands mid-run, and `jumpTargets` dedupes
  only against `seen.last`.
- **Where** — `LibrarySort.swift:94-99` (`isASCII` gate → "…"), `:48`
  (`localizedCaseInsensitiveCompare`); `LibraryModel.swift:198-203` (`seen.last?.letter`);
  `LibraryList.swift:268` (`ForEach(id: \.element.letter)` — duplicate id).
- **Why it matters** — "O", "…", "O" in the rail; SwiftUI's behaviour on duplicate
  `ForEach` ids is undefined (the same open question the summary lists for L1/S14). Only
  reachable with ≥200 title-sorted rows and one such title; rare, but the fix is a line.
- **Fix** — Dedupe `jumpTargets` with a `Set<String>` (first occurrence wins), which is
  correct for any future non-adjacent case too. Test: fixture with "Oyasumi", "Øyet",
  "Ozma" sorted by title → one "O" target.
- **Effort** — a line. **Confidence** — likely (ICU root collation of Ø as an O variant is
  documented; the fixture would settle it). **Lens** — 8.

### 17. Insights and Wrapped do not recompute after an edit that keeps the count

- **What** — `revision` is `"\(count)-\(isComplete)"`; a rating or state change via
  `LibraryModel.apply(_:to:)` changes neither.
- **Where** — `ReadingInsightsView.swift:51, 109`; `WrappedView.swift:33, 156`;
  `LibraryModel.swift:357-363`.
- **Why it matters** — Insights → row → series page → "Completed" via `LibraryControl` →
  back: "It finished without telling you" still lists it. Same for Wrapped's "This year".
- **Fix** — `private(set) var revision = 0` on `LibraryModel`, bumped in both `apply`s and
  `forget`; pass it in and key `.task(id:)` on it. Or accept `entries` (Equatable) as the id
  — `LibraryEntry` is `Equatable` and 942 comparisons per body is fine, but the count
  string was chosen to avoid exactly that.
- **Effort** — a line each plus pass-through. **Confidence** — likely. **Lens** — 1.

### 18. `refreshDerived` redoes entries-only work per keystroke

- **What** — `shape`, `allCount`, `subtitle` (two extra passes) and `inProgress`
  (filter + sort) depend only on `entries` but recompute on every search, filter and sort
  change.
- **Where** — `LibraryModel.swift:137-144` versus the three `didSet`s at `:29, 32, 35`.
- **Fix** — Split into `refreshFromEntries()` (called from `apply(_ rows:)`, `apply(_:to:)`,
  `forget`) and `refreshListed()` (the three `didSet`s). Pairs with §10.
- **Effort** — a function. **Confidence** — certain (waste), impact a few ms. **Lens** — 3.

### 19. The scroll-edge scrim animates state on every scroll sample past its saturation point

- **What** — `onScrollGeometryChange(for: CGFloat)` emits every changed offset; the
  action runs `withAnimation` for each, though `opacity(forTravel:)` is 1 past 12 pt.
- **Where** — `ScrollEdge.swift:52-63`, `:24, 31-33`. Applied to Library at
  `LibraryView.swift:166`.
- **Why it matters** — Verified by reading that this does *not* re-evaluate the list: the
  `@State` lives in the modifier, and `content` is not rebuilt. So the shape bar and jump
  index are not redrawn per tick (the brief's question). The cost is one animated
  state write per sample for the length of a 942-row scroll — small, and free to remove.
- **Fix** — Transform `min(offset, ScrollEdge.fadeIn)` in the `for:` closure so the value
  stops changing and the action stops firing. Shared file — cross-slice.
- **Effort** — a line. **Confidence** — certain. **Lens** — 3.

### 20. `inProgress` sorts with no tiebreak

- **Where** — `LibraryModel.swift:268-275` (`priority ?? 0` only). `LibrarySort.swift:24-26`
  documents why every sort here carries one: `sort` is not documented stable, and most
  entries share a priority of 0.
- **Why it matters** — "Pick back up" (and Discover's copy of it) can reorder between
  refreshes.
- **Fix** — `($0.priority ?? 0, $1.seriesId) > ($1.priority ?? 0, $0.seriesId)` or an
  explicit `seriesId` tiebreak.
- **Effort** — a line. **Confidence** — certain. **Lens** — 9.

### 21. Per-row arrival blur on a 942-row list

- **What** — Every row that scrolls into view for the first time animates opacity, a 6 pt
  blur and an 8 pt offset for ~0.45 s; every cover also carries a `scrollTransition`.
- **Where** — `LibraryList.swift:46` (`.arrives(index:)`), `:116` (`.enterScale()`);
  `MotionModifiers.swift:21-38` (blur in the arrival), `:89-102` (per-frame scroll
  transition). The comment at `LibraryList.swift:43-45` addresses the stagger *delay*
  (capped at 6, `Motion.swift:60`); it does not address the blur.
- **Why it matters** — A blur is an offscreen pass per row per frame while it animates;
  a fast fling has a dozen rows mid-arrival at once, each with a cover. **Not measured**,
  and the simulator cannot measure it; this is the one finding in the slice that needs a
  device and Instruments.
- **Fix** — If it hitches: `.arrives` only for `index < 12` (the first screenful), plain
  rows after; or a blur-free variant for list rows. If it does not hitch, record that.
- **Effort** — a line. **Confidence** — worth checking. **Lens** — 7.

### 22. Small ones

- `WrappedShapes.swift:79-81` — `DateFormatter()` allocated per body pass for a month name.
  Use `Calendar.current.monthSymbols`. A line. Lens 3. Certain.
- `StackSections.swift:156-158` — `compact(1_000_000)` renders "1000.0k". Use
  `count.formatted(.number.notation(.compactName))`. A line. Lens 4. Certain; whether any
  MangaBaka rating count reaches it is unverified.
- `StackModel.swift:384-394` + `:279-288` — `resetStack` joins a refill already in flight
  (`refillTask`) that was built from the pre-reset seeds, and its `append` lands on the
  emptied queue. Benign in the common case; `refillTask?.cancel()` in `resetStack` plus a
  `Task.isCancelled` check before `append` makes "fresh stack" mean fresh. A few lines.
  Lens 1. Worth checking.
- `StackView.swift:302-307` vs `:316-320` — the commit decision uses
  `value.translation.width` while the card's visible offset is `drag`, which stops
  updating when a sample is vertical-dominant. A card shown at +60 can commit at +100. Use
  `drag.width` in `onEnded`. A line. Lens 1. Worth checking.
- `LibraryEditSheet.swift:71` — `.preferredColorScheme(.dark)` duplicates
  `RootView.swift:315`. A line. Lens 9. Certain, harmless.
- `StackView.swift:178-182` — the card element has custom actions and a hint but no
  `.isButton` trait, so VoiceOver does not say "button" for the double-tap. Add
  `.accessibilityAddTraits(.isButton)`. A line. Lens 9.

## Not findings — checked and cleared

- **Index maths on an empty or single-item stack** — `current = queue.first`, `next` guarded
  (`StackModel.swift:261-262`); `react` guards `current` before `removeFirst` (`:397-399`);
  `advanceSeeds`/`currentSeeds` bounds-checked (`:608-619`); `JumpIndex.letterIndex` clamps
  and is tested for `count == 0` and `height == 0` (`LibraryList.swift:320-326`,
  `JumpIndexTests.swift:37-42`); `currentLetter` guards (`:295-297`); shape-bar width
  guards `total > 0` (`LibraryShape.swift:59-63`); streak ring guards `dealt > 0`
  (`StackHeader.swift:104-107`); `RatingPips` clamps (`ShelfDetailView.swift:325`);
  `monthName` clamps (`WrappedShapes.swift:80`). No crash path found.
- **Force-unwraps / `try!` / `as!`** — none in the slice (grep). `Int(Double)` sites all go
  through `Int(wholeOrClamped:)` except `WrappedView.swift:264` (`lift` is finite by
  construction, `ReadingWrapped.swift:54`) and `:326` (clamped progress).
- **Reduce Motion on the stack** — arrival rise (`StackView.swift:108`), throw (`:331-335`),
  save flight (`:380`), symbol bounces (`:425`, `StackSections.swift:266`), settle-back
  (goes through `Motion.run` → `reduced`, `Motion.swift:87-93`), count-up
  (`WrappedShapes.swift:157-161`), `ArrivesModifier` (`MotionModifiers.swift:23`). Haptics
  still fire, which is right — they are not motion.
- **VoiceOver on the drag surface** — Save/Skip exist as custom actions on the card
  (`StackView.swift:181-182`); the visible Skip and Save buttons are labelled (`:405, 431`);
  neighbours, the flight ghost and the ring are hidden (`:246, 224`,
  `StackHeader.swift:127`); toasts announce (`ToastCentre.swift:77`). The one gap is the
  missing button trait (§22).
- **Shape bar and jump index on scroll ticks** — neither observes scroll; the scrim's
  state is modifier-local (§19). The rail is an overlay on the `ScrollViewReader`
  (`LibraryView.swift:52-63`), not on the content.
- **Continuations re-run on search clear** — the row leaves and re-enters the tree when
  the search field is used (`LibraryView.swift:130`), so `.task(id: isComplete)` re-runs,
  but `ContinuationsModel.load` short-circuits on `loadedFor == finishedIDs`
  (`Continuations.swift:127`). No repeat requests.
- **Library `.task` per tab visit** — `fetchAll` guards `entries.isEmpty`
  (`LibraryModel.swift:316`). One walk per session.
- **Rate limit** — the walk is sequential, ≤30 requests, once per session with a 6 h disk
  cache; search is local (`LibraryModel.swift:26-28`); the stack dedupes concurrent refills
  (`StackModel.swift:271-288`) and refills at `queue.count <= 2` in batches of 20/≤50.
  Nothing fires per keystroke, chip or scroll.
- **Privacy** — Wrapped says "None of it is sent anywhere" (`WrappedView.swift:206-210`)
  and nothing in the slice sends reader data anywhere but MangaBaka's own library endpoints.

## `List` versus the hand-built scroll view — what it would cost here, concretely

The library is a `ScrollView { VStack { header, search, chips, shape bar, four cards,
two horizontal strips, LazyVStack(rows) } }` (`LibraryView.swift:66-163`,
`LibraryList.swift:21-55`).

What `List` would give: cell recycling (§5 goes away without touching `CoverImage`),
accurate `scrollTo` on a 942-row list (a `LazyVStack` estimates unrealised row heights, so
a rail jump to "W" can land a row or two off — **unverified**), system swipe actions and
context menus, and no per-row `.id` bookkeeping.

What it would cost, each a real edit: the header/search/chips/bar/cards become
`Section` content or a `safeAreaInset(edge: .top)` (the shape bar and chips must scroll
with the content, so `Section` headers with `.listRowInsets(EdgeInsets())` and
`.listRowSeparator(.hidden)` on every row); `.scrollContentBackground(.hidden)` +
`.listStyle(.plain)` for `Palette.ground`; the horizontal `PickBackUp`/`ContinuationsRow`
strips inside list rows need `.listRowInsets(0)` and lose `.scrollTargetBehavior` tuning;
`.buttonStyle(.press)` on a row inside `List` fights the cell's own highlight; the
`.animation(value: listed.map(\.id))` + `.blurReplace` resettle
(`LibraryList.swift:47, 54`) becomes `List`'s own insert/remove animation, which is not
`Motion.settle`; and `.arrives(index:)` on cells is re-fired on every reuse unless keyed to
identity. Roughly a file of change plus a device pass on the six decorations. What `List`
does *not* give: a section index bar — SwiftUI exposes no `sectionIndexTitles`, so
`JumpIndex` stays hand-rolled either way, and it is the right call (its 44 pt
single-hit-area design, `LibraryList.swift:260-262`, is Contacts' pattern done properly).

Recommendation: not now. Take §5's one-line release in `CoverImage` for the memory
question and keep the scroll view; revisit `List` only if §21 measures a real hitch.

## What the stack does well, specifically

The stack is the one screen with no system equivalent, and hand-rolling it is correct.
What is good about this particular hand-rolling:

- **One reaction path for three triggers** — drag, buttons and VoiceOver actions all go
  through `react(_:)` (`StackView.swift:349-367`), so the confirmation, the haptic and the
  model update cannot diverge by trigger. Fixing §9 is one guard in one place because of
  this.
- **The gesture yields vertical scroll** — `minimumDistance: 12` plus the
  `abs(width) >= abs(height)` claim (`:301-305`) is what lets the page under the card
  scroll at all; the comment records the failure it fixed.
- **A latch, not a level, for the threshold haptic** — `StackGesture.crossedThreshold`
  (`StackGesture.swift:16-20`) is pure, tested for both directions and re-crossing
  (`StackMotionTests.swift:11-40`), and explains why a level would buzz every frame.
- **Physics constants carry their provenance** — 0.012°/pt, 92 pt commit, |dx|/80 badge
  opacity are cited to the mockup's script (`StackView.swift:3-7, 56-61`); the rotation
  cap and the 550 ms hold are labelled guesses (`:58-60, 375-378`), as CLAUDE.md requires.
- **A save is a keep, not a throw** — the card shrinks to the counter via
  `matchedGeometryEffect` with `isSource` set correctly on both ends and the reason written
  down (`:214-220`, `StackHeader.swift:77-86`); the real card hides for the duration so the
  cover is never double-drawn (`:200-203`).
- **The throw is reset when the queue advances, not when the write returns**
  (`:391-399`) — the comment records the slow-POST bug it fixed.
- **The empty state tells failure from exhaustion** (`:436-484`), with the countdown for a
  429 and no auto-retry, per decision 4.
- **The warning belongs to a series id** (`StackModel.swift:46-64, 118-120`), so a
  library-only failure cannot be printed under the next card.
- **Refills dedupe** (`:271-288`) and a failed profile check is not cached as cold-start
  (`:477-505`).
- **`todayProgress` is re-derived from the shelf** rather than incremented (`:194-201`), so
  a reset or a failed write cannot leave the ring wrong — the right design, even though §8
  wants the query cheaper.

## What the library does well

- Every derivation that a body pass would otherwise recompute is stored with the number
  that justified storing it and the test that measured it (`LibraryModel.swift:126-130,
  222-225`; `ReadingInsightsView.swift:28-34`). That is why §10 is a finding at all —
  there is a measurement to compare against.
- The page-by-page walk with generation guarding (`:101-103, 319, 334, 339`) is the right
  shape; §1 is a gap in it, not a flaw of it.
- `partialLoad` distinguishes three states in copy (`LibraryView.swift:233-240`) — §2 is
  that the flag it keys on cannot carry the third.
- The edit sheet sends only touched fields, refuses an unparsable chapter with a sentence,
  parses decimal commas and non-ASCII digits, and caps at a labelled guess
  (`LibraryEditSheet.swift:280-347`). §7 is the one field that pattern was not applied to.
- The rail dedupes diacritics against the comparator it indexes and says why
  (`LibrarySort.swift:81-99`); the tests pin the drag maths at the edges
  (`JumpIndexTests`).
- Entry-less rows say so with a toast rather than a dead tap (`LibraryList.swift:95-103,
  226-245`).
- Insights and Wrapped compute off the main actor, show a loading branch during the gap,
  and name the sample size (`ReadingInsightsView.swift:121-138, 287-296`;
  `WrappedView.swift:168-193, 224-233`).
- Comments in this slice record dates, devices and the bug fixed, consistently. Several
  findings above were only findable because a comment said what a flag was *for*.

## What I could not determine — one measurement each

| Question | Would settle it |
|----------|-----------------|
| §5 — how much memory rows hold after a full scroll | Xcode memory gauge on Library, scroll 513 rows to the bottom and back; compare with `.onDisappear { loaded = nil }` applied. Control: the number before scrolling. |
| §7 — does MangaBaka ever store a rating that is not a multiple of 20 | One `curl -H "Authorization: Bearer …" "/v1/my/library?limit=100"` on the reference account, `jq '.data[].rating' | sort -u`. Needs the token, so not run here. |
| §8 — first-paint cost of `loadIfNeeded` | A `#expect` on wall-clock around `loadIfNeeded()` with 300 fixture saves; control: an empty shelf. |
| §10 — the title sort's real cost | Time `LibraryModel.listed(from:filter:search:sort:)` on 942 fixture entries for `.title` versus `.dateAdded` (the control). |
| §14 — are recommender pages stable across calls | Two `curl`s of `/v1/my/series/discover/recommendations?page=1&limit=20` a minute apart, compare ids. Needs the token. |
| §16 — where ICU places "Øyet" among O titles | A unit test: `["Oyasumi","Øyet","Ozma"].sorted(localizedCaseInsensitiveCompare)`. |
| §21 — whether the row arrival blur drops frames | Instruments Core Animation on a device (not the simulator), flinging the 513-row list; control: the same fling with `.arrives` removed. |
| `List` `scrollTo` accuracy versus the `LazyVStack` | Jump to "W" on the 513-row title sort on a device; note which row lands at the top. |
