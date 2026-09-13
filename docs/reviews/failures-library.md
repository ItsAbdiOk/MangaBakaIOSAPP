# Failure audit — the reader's own data (Library, Schedule, Shelf, Insights, Wrapped, reminders, Spotlight, intents)

Read-only audit, 2026-09-13. Nothing built, nothing run; every claim below is from reading the branch named.

## Scope

Read in full (28 files, ~7,400 lines):

- `MangaBaka/Features/Library/` — LibraryView, LibraryModel, LibraryList, LibraryEditSheet, LibrarySort, LibraryShape, LibraryRouteCards, PickBackUp, ContinuationsRow, ReadingInsightsView, WrappedView, WrappedShapes, ShelfCard, ShelfDetailView
- `MangaBaka/Features/Schedule/` — ScheduleView, ScheduleModel, ScheduleRow, AnnouncedSection
- `MangaBaka/Features/Shelf/ShelfStore.swift`
- `MangaBaka/Core/Library/` — LibraryService, LibrarySnapshot, LibraryEntry, Continuations, ReadingInsights, ReadingWrappedYear, SpotlightIndex
- `MangaBaka/Core/Schedule/` — ReleaseSchedule, ReleaseCalendar, MangaUpdatesClient
- `MangaBaka/Core/Notifications/ReleaseReminders.swift`
- `MangaBaka/Core/Intents/` — AppIntents, IntentBridge, LibrarySeriesEntity
- The kit: FailureState, EmptyState, Skeleton, Toast, StateAction, APIError

Read in part, for wiring only: `App/RootView+Session.swift` (the Library tab's construction, `saveLibraryChange`, `refreshReminders`, `openSeries`), `Core/Networking/APIClient.swift` lines 120–300 (401/403/429 handling), `Features/Settings/RemindersSection.swift` lines 20–75, `Core/Library/TasteProfile.swift` and `TasteLedger.swift` (grepped for failure paths only — their surfaces are the stack and Settings, not this slice), `Core/Schedule/UpcomingWork.swift` (`publisherLink` only), `MangaBakaTests/LibraryModelTests.swift` lines 135–160.

Not read: `Core/Library/ReadingWrapped.swift` beyond the `catalogueSize > 0` guard, `Core/Model/Series.swift`, the rest of Settings, `docs/designs/*` (grepped for Library failure states; nothing there names one).

## The table

Confidence: **H** = the branch is quoted and the trigger is ordinary; **M** = the branch is quoted but the trigger needs a specific sequence or an unverified server behaviour; **L** = inferred from SwiftUI semantics I did not run.

| Screen / section | Trigger | What the reader sees today | What they should see | Effort | Conf |
|---|---|---|---|---|---|
| Library tab, list | Walk fails on page 12 of 13 (offline, 429, 5xx, decode) | 1,100 rows and `partialLoad` (`LibraryView.swift:97-99, 228-247`): a **`ProgressView` that spins forever** over "1,100 loaded so far — Counts and search cover what has arrived." `failure` is set (`LibraryModel.swift:255`) but no view reads it when `entries` is non-empty (`screenState` only returns `.failed` on an empty list, `LibraryModel.swift:58-60`). No retry; `fetchAll` is guarded on `entries.isEmpty` (`:238`) so a second `load()` is a no-op and the failure is not cached (`LibrarySnapshot.swift:119`) so nothing retries it either. | **StaleBar** in place of `partialLoad` once `failure != nil`: "Some of your library didn't load — 1,100 so far. <error.userFacingMessage>" with Retry → `reload()`. The countdown for 429. Keep `partialLoad` (spinner) only while `isLoading || (!isComplete && failure == nil)`. | function | H |
| Library tab, list | Walk hits the 30-page cap (3,000+ entries) | Same `partialLoad` spinner, forever; `isComplete=false`, `failure=nil` (`LibrarySnapshot.swift:106`). | Inline note, no spinner: "Showing the first 3,000." | line | H |
| Library tab | Signed in, library genuinely empty (200, `[]`) | `hasAccount = !rows.isEmpty \|\| !complete` (`LibraryModel.swift:272`) → **"No library yet — Add a MangaBaka token in Settings"** (`LibraryView.swift:286-294`) to a reader who has one. `.empty` ("Nothing saved yet / Open the stack", `:209-220`) is **unreachable**: it needs `entries.isEmpty && hasAccount`, which needs `!complete`, which needs a failure. `LibraryModelTests.swift:143-148` pins this. | **EmptyState** "Nothing saved yet / Open the stack" (already written). `hasAccount` must come from the token, not from emptiness: the 401 path already yields `.failed(.server(401))` → FailureState "This part needs an account" + Open Settings, so `noAccount` can simply be deleted and the test inverted. | function | H |
| Library tab | No token stored | A request goes out with no header (`APIClient.swift:131`) → 401 → `.failed(.server(401))` → FailureState "This part needs an account" + Open Settings. Correct. Costs one request per visit, and **offline with no token** shows "You're offline — Showing what was downloaded" (nothing was). | Acceptable. Optional: short-circuit on no token before the request so offline-and-signed-out says "needs an account". | line | M |
| Library tab | 401/403 mid-session (token revoked) with the disk cache still fresh (< 6 h) | `readCache()` wins before any request (`LibrarySnapshot.swift:86-90`): the old library shows as complete and current for up to six hours; nothing checks the token. Edits then fail per-sheet ("MangaBaka would not accept that change. Check your token in Settings.", `APIClient.swift:277`). | Acceptable for reads. For writes: see edit-sheet row. Optional StaleBar after a 401 on any write: "Your token stopped working — Settings". | function | M |
| Library tab | 401 after the cache expired | `.failed(.server(401))` → FailureState + Open Settings. Correct. | — (done well) | — | H |
| Library tab, header/subtitle | During the walk | `subtitle` is "Nothing here yet" until page 1 lands (`LibraryModel.swift:184-190`) while the skeleton shows. Reads as a verdict for ~300 ms. | "Loading…" or blank while `screenState == .loading`. | line | M |
| Library tab, search | Search matches nothing / filter + search match nothing | `LibraryList` renders header "All series" and **no rows, no message** (`LibraryList.swift:20-28`). `matchCount`/`isSearching` exist on the model (`LibraryModel.swift:294-298`) and nothing reads them. | **EmptyState** (no mark) "Nothing matches" with "Clear search" (`.aside`) when `listed.isEmpty && (isSearching \|\| filter != nil)`. | function | H |
| Library tab, `partialLoad` copy | Any partial | Says "Counts and search cover what has arrived" — true. But `LibraryFilterRow` counts and `LibraryShapeBar` proportions are drawn from the partial as if final. The copy covers it. | Fine once the spinner-forever row is fixed. | — | — |
| Library tab, edit sheet Save | Success | `onSave` → `library.update` → `session.library.reload()` (`RootView+Session.swift:211-220`) which does `entries = []` then re-walks **every page** (13 requests, 24.7 MB on the reference account, `LibrarySnapshot.swift:6-8`) and deletes the disk cache (`:190-201`). The sheet's spinner runs the whole time (`LibraryEditSheet.swift:245-255`); behind it the tab flips to the loading skeleton, the search field disappears (`LibraryView.swift:70`), the continuations walk re-fires (`:145-148`). A one-star rating costs ~4 s and 25 MB. No toast. | Patch the one entry locally (LibrarySnapshot gains `apply(seriesId:change:)`; write the same row to the disk cache) and dismiss immediately; **Toast** "Saved". Keep the full reload for the failure-to-patch case only. | file | H |
| Library tab, edit sheet Save | Failure (offline, 5xx, 401) | Inline accent text with `error.userFacingMessage` (`LibraryEditSheet.swift:50-55`), sheet stays open, fields keep the typed values. No optimistic change was made, so nothing to revert. Correct. | Done well. Accent colour reads as "tap me" — `Palette.stale` or textPrimary would match the kit. | line | H |
| Library tab, edit sheet Save | Failure after the PATCH actually landed (timeout on the response) | Sheet says it failed; the server has the change; the screen keeps the old value until the next reload. | Reload on transport failure too, or say "It may have saved — pull to check". | line | M |
| Library tab, edit sheet | Save tapped, then Cancel while saving | Cancel dismisses (`:66`), the PATCH continues, `reload()` runs. Fine, but no toast says whether it landed. | Toast on completion regardless of sheet state. | line | M |
| Library tab, edit sheet, chapter field | `.numberPad` keyboard (`:111`) | Cannot type "." — a reader at 12.5 who taps +1 gets 13 (`:122-123`, floors first); cannot enter a half chapter at all from the pad. Decimal only via paste/hardware keyboard, which L3 handles. | `.decimalPad`. | line | H |
| Library tab, edit sheet, chapter field | Twenty digits typed | Parses as 1e20 (`:309-315`), Save sends it; `JSONSerialization` accepts finite doubles (`APIClient.swift:264`). If the server stores it, see Traps: three `Int(Double)` sites crash on the next launch. | Cap in `changes`: refuse `> 100_000` with the existing "Couldn't read that as a chapter number" line. | line | M (server acceptance unverified) |
| Library tab, row | Entry whose `series` is nil | Row renders "Untitled series" with a blank cover (`LibraryList.swift:81-90`); tap does nothing (`:68`), no feedback; edit sheet does not open (`LibraryView.swift:168`, `if let series`), so the context-menu "Edit" is a dead control. | Hide Edit for such rows; on tap, Toast "This series couldn't be loaded." | line | M |
| Library tab, jump index | — | Guarded (`LibraryList.swift:237, 245, 258-262`). | Done well. | — | — |
| Library tab, "Open the <state> shelf" | Tapped while the walk is still running | `openShelf = shelves.first{...}` (`RootView+Session.swift:28`) is a copy of the partial shelf; `ShelfDetailView` never updates as pages land (`shelf` is a `let`, `Shelf ==` is id-only, `LibraryModel.swift:16`). Header count and rows are the partial. | Pass the state and read `model.shelves` live, or block the button while `!isComplete`. | function | M |
| Pick back up | Nothing in progress | Row hides (`PickBackUp.swift:12`). Correct — it is a bonus row. | Done well. | — | — |
| Pick back up | `series.totalChapters` nil or 0 | No bar, just "ch N" (`:86-91`). Correct. | Done well. | — | — |
| Continuations row | Every `/relationships` request fails (offline, 429) | `repository.relationships(for:)` returns nil → `continue` (`Continuations.swift:118-120`); `items` ends empty, `loadedFor` is set (`:128`) so **it never retries this session**; the row hides (`ContinuationsRow.swift:25`). Failure is indistinguishable from "no sequels". | Track `failed` count in the model; when `items.isEmpty && failed == finished.count`, do not set `loadedFor`, and show a one-line inline note with Retry (or simply hide but leave retry possible). Minimum: do not cache the failure. | function | H |
| Continuations row | Library tab left mid-walk | `.task(id:)` cancels; the loop keeps calling `repository.relationships` (no `Task.isCancelled` check, `:117-125`). Up to 8 requests continue against the shared rate limit. | `guard !Task.isCancelled` in the loop. | line | H |
| Continuations row | Loading | `CoverSkeletonRow` while `isLoading && items.isEmpty` (`ContinuationsRow.swift:18-24`). | Done well. | — | — |
| Shelf detail | The shelf becomes empty after an edit (last entry moved) | `openShelf = shelves.first{ $0.state == openShelf?.state }` → nil (`RootView+Session.swift:218`) → `navigationDestination(item:)` **pops the reader off the screen** with no message, right after Save. | Toast "Moved to Completed — this shelf is now empty" before the pop, or keep the shelf open with EmptyState "Nothing left on this shelf". | line | M (pop-on-nil is SwiftUI behaviour I did not run) |
| Shelf detail | Edit on the shelf changes one row | After reload, `openShelf` is reassigned a `Shelf` that is `==` the old one (id-only equality, `LibraryModel.swift:16`). Whether SwiftUI re-renders the destination with the new entries depends on `@State` invalidation semantics for Equatable values. | Verify on device: edit a rating from the shelf, does the pip row change? If not, key the destination on the state and read entries from the model. | function | L |
| Shelf detail | Search matches nothing | "Nothing on this shelf matches" (`ShelfDetailView.swift:74-79`). | Done well (could be EmptyState for consistency). | — | — |
| Shelf detail | Dropped filter selected, then all matching entries edited away | `availableFilters` drops the chip (`:126-130`) but `filter` state keeps the value; `visible` is empty with **no message** (the message needs `!searchText.isEmpty`, `:74`). | Reset `filter = .all` when it leaves `availableFilters`; extend the empty message to `visible.isEmpty`. | line | M |
| Shelf detail | Entry with nil `series` | Row skipped silently (`:81`); header count includes it. | Acceptable; count is off by the skipped rows. | — | L |
| ShelfCard | — | **Not presented anywhere** (grep: no callers outside its own file). Dead view. | Delete or leave; not a reader-facing failure. | — | H |
| Your reading (Insights) | Empty library, or all `planToRead` | "0 chapters — About 0 hours" and nothing else (`ReadingInsightsView.swift:42-49, 85-103`). No empty branch. | **EmptyState** "Nothing to read into yet — this fills in as you track what you read." when `entries.isEmpty` or every section is empty. | function | H |
| Your reading (Insights) | First ~20 ms after push | `derived` starts at zero (`:30-40`) so the headline reads **"0 chapters"** then jumps (rubric 9: a count that says 0 while loading). | Hold a `isComputing` flag; skeleton or blank headline until `recompute()` lands. | line | M |
| Your reading (Insights) | Library only partially loaded (walk failed at page 12) | Built from `session.library.entries` as passed (`RootView+Session.swift:63-66`); nothing tells the screen `isComplete == false`. "From the 87 of your 1,100 series" — the 1,100 is a floor presented as the total. | Pass `isComplete`; **StaleBar** at the top: "Built from the 1,100 series that loaded." | line | H |
| Your reading (Insights) | Library reloads (after an edit) while the screen is up | `entries` becomes `[]` for the walk's duration (`LibraryModel.swift:229`), `.task` (no id) does not recompute (`:62`), so the screen keeps the old numbers — fine — but when the walk lands it still does not recompute until the next visit. | `.task(id: entries.count)` or a revision counter. | line | M |
| Your year (Wrapped) | Empty or sparse library | Header, then `provenance` ("Hours are an estimate…"), and **nothing between** (`WrappedView.swift:45-60`: every card is conditional). No loading state either; `facts` starts empty. | **EmptyState** "Not enough of a year yet" when no card qualifies; blank (not the provenance line) while computing. | function | H |
| Your year (Wrapped) | Partial library | Same as Insights: built on `session.library.entries`, no `isComplete`. | StaleBar as above. | line | H |
| Your year (Wrapped) | `catalogueSize` 0 from the pulse | Guarded (`ReadingWrapped.swift:91`). | Done well. | — | — |
| Schedule | First ~0.3–3.5 s while `service.snapshot()` waits on the library walk (`ReleaseSchedule.swift:172`) | `isLoading` is true but the `else` branch runs (`ScheduleView.swift:39-54`): `hasNeverMeasured` is false while loading (`ScheduleModel.swift:119`), so the reader sees **controls "Not measured yet" + an enabled Measure button + scopeCard "0 estimated of 0 in scope"** — the exact screen the device review rejected, now shown during every cold load. | Skeleton/blank while `isLoading`; the branch order needs `if model.isLoading` first. | line | H |
| Schedule | Library walk failed, no announced works | FailureState with retry (`ScheduleView.swift:30-32`). | Done well. | — | — |
| Schedule | Library walk failed, announced works present | Announced section, then `EmptyView()` (`:33-34`). **Nothing says the estimates half failed.** | **StaleBar** under the announced section: "Estimates unavailable — <error.userFacingMessage>", Retry. | line | H |
| Schedule | `/v1/works/upcoming` fails (any page) | `try?` → `complete=false` → whatever pages arrived, uncached (`ReleaseCalendar.swift:44-49, 69`); `AnnouncedSection` hides when empty (`AnnouncedSection.swift:16`). Failure reads as "nothing announced". | Return a failure alongside; inline note "Announced dates couldn't load" (StaleBar if estimates exist). | function | H |
| Schedule | Announced row | Not tappable to the series; only the publisher arrow (`AnnouncedSection.swift:38-71`). Estimated rows open the series (`ScheduleRow.swift:16-24`). Inconsistent. | Button on the row → `path.append` when `seriesId` resolves in the library. | line | M |
| Schedule | Announced row `publisherLink` | `URL(string: raw)` with any scheme/host (`UpcomingWork.swift:119-122`), opened via `Link` (`AnnouncedSection.swift:55-63`). An `http://` or off-allowlist host from the API opens as-is (rubric 8/10). | Route through the same host allowlist `ReadingPlatforms`/`SeriesExtras` use; drop non-https. | line | M |
| Schedule | MangaUpdates down for **every** series on the first measurement | Each row written with `failure` (`ReleaseSchedule.swift:326-331`), `measuredAt` stays nil (`:213-217, 242`), so `hasNeverMeasured` is true again → **firstRunCard "Nothing measured yet / Measure now"** (`ScheduleView.swift:47-48`). `measurementFailureLine` lives only in `scopeCard` (`:209-215`), which is not shown. Three minutes of "Reading 12 of 55", then the screen returns to where it started with no explanation. | Show `measurementFailureLine` in `firstRunCard` too, or promote it to a **StaleBar** above whichever card is showing. | line | H |
| Schedule | MangaUpdates down mid-build (offline) | The loop keeps going through all 55 at 3 s each (`ReleaseSchedule.swift:312-333`); no early exit on `.offline`. Reader watches "Reading 12 of 55" tick for two minutes of guaranteed failures. | Break on `.offline`/`.rateLimited`, keep `progress.failure`. | line | H |
| Schedule | Measurement failure line wording | "55 not measured. MangaUpdates returned 503." (`MangaUpdatesClient.swift:135-138` → `APIError.server.userFacingMessage` returns the message verbatim). Jargon for App Review taste. | "MangaUpdates isn't answering right now." | line | M |
| Schedule | Reader leaves during a build | `stop()` cancels the poll only (`ScheduleModel.swift:298-301`); build continues; `load()` re-follows (`:238`). | Done well. | — | — |
| Schedule | Stale estimates | `staleCard` (`ScheduleView.swift:146-163`). | Done well. | — | — |
| Reminders (Settings) | Permission denied at first enable | `enable()` returns false, switch stays off (`ReleaseReminders.swift:57-68`); "Notifications are switched off… Open Settings" appears (`RemindersSection.swift:38-50`). | Done well. | — | — |
| Reminders | Permission revoked later in iOS Settings | `isEnabled` stays true → switch reads **On**; every `add` is `try?` (`ReleaseReminders.swift:328`) and silently fails. The denied line under it is the only tell, and only after `.task { refreshStatus() }` runs. | Show the switch as off-with-reason when `systemStatus == .denied` (`SwitchIndicator(isOn: isEnabled && systemStatus != .denied)`). | line | H |
| Reminders | Library walk failed on foreground | `reschedule` returns early, keeps yesterday's (`:119`). | Done well. | — | — |
| Reminders | Walk succeeded but partial (page cap) | `walk.failure == nil` → reschedule runs on a truncated library; series past the cap lose their reminders. | Treat `!isComplete` like a failure for the purpose of *removing* reminders. | line | M |
| Spotlight | Library empty / walk failed at launch | `reindex([])` deletes the domain and indexes nothing (`SpotlightIndex.swift:48-49`) — after a failed walk this **wipes the index** built yesterday. `startSession` passes `librarySnapshot.all()` (`RootView+Session.swift:147`), which drops the failure. | Skip `reindex` when `load().failure != nil`. | line | H |
| Spotlight | Tapped result whose series left the library | `openFromSpotlight` finds nothing and returns (`RootView+Session.swift:171-176`). App comes to the front on the current tab, nothing happens, no message. Index is only rebuilt next launch. | Toast "That series is no longer in your library", and fall through to `openSeries(id:)` which already handles the catalogue case. | line | H |
| Siri "What's due this week" | Library walk fails (offline, 401, no token) | `snapshot.libraryFailure` is ignored by `DueThisWeek.sentence` (`AppIntents.swift:36-44, 82-86`); Siri says **"The schedule hasn't been measured yet. Open MangaBaka to build it."** or "Nothing due in the next 7 days." | Pass `snapshot.libraryFailure`; dialog "I couldn't read your library — <headline>." | line | H |
| Siri "What's due this week" | Never opened this process | `services == nil` → "Open MangaBaka first, then ask again." (`:33-35`). `services` is set at app construction so this is a guard, not a path. | Done well. | — | — |
| Siri "Open a series" | Library empty or walk failed | `entities(matching:)` returns `[]` (`LibrarySeriesEntity.swift:43-47`); Siri's generic "no Series matches". Failure indistinguishable from empty. | Throw a `LocalizedStringResource` error when `load().failure != nil`. | line | M |
| Siri "Open a series" | Stale entity id (series removed) | `perform` sets `pendingSeriesID` (`AppIntents.swift:18-20`); root runs `openSeries(id:)` → not in library → `extras(for:)` — if that also fails, `guard … else { return }` (`RootView+Session.swift:166`) and **nothing happens**. | Toast "Couldn't open that series." on the nil path. | line | M |
| ShelfStore (local saves) | Any GRDB error | Throws; callers are in the stack slice (not reviewed here). `entries()` drops rows whose payload no longer decodes (`ShelfStore.swift:46`) — silent shrinkage after a `Series` shape change. | Count the drops and log; out of slice for the UI. | — | M |
| LibrarySnapshot disk cache | Rows that no longer decode | `compactMap { try? decode }` (`LibrarySnapshot.swift:151-153`): a `Series` shape change silently shrinks the cached library (939 → fewer) and reports it as complete for six hours. | If `entries.count != rows.count`, treat the cache as absent. | line | M |
| LibrarySnapshot | One entry with a `state` the app does not know | `State: String, Codable` with no fallback (`LibraryEntry.swift:13-20`) → the whole page throws → `.decoding` → walk stops there; rows so far + spinner forever (row 1). The decoding message says "Cached copies were cleared" (`APIError.swift:111-115`) but this slice never clears them (`staleContentRemainsUseful` is read by nothing here). | Decode unknown states to a `.other(String)` or drop the entry; and either clear the cache on `.decoding` or change the copy. | function | M |
| LibrarySnapshot | `reload()` while a walk is in flight | `invalidate()` cancels `inFlight` (`:199`); the cancelled walk returns `failure: .transport("cancelled")` to the *first* caller, whose `fetchAll` applies it after the new walk has started (`LibraryModel.swift:249-255`). Two `apply` streams interleave on `entries`; last writer wins. Observed order not verified. | Tag each walk with a generation and ignore results from an older one. | function | L |

## Traps (crash-reachable)

Grepped the slice for `!` (excluding `!=`/prefix), `try!`, `as!`, `fatalError`, `precondition`, `Int(`, `[0]`/`[1]`, `.first!`, `URL(string:`. Every hit read in context.

- **`Int(Double)` on server-supplied numbers** — traps outside ±9.2e18. `progress_chapter`, `progress_volume`, `total_chapters`, `final_volume` all decode as `Double?` (`LibraryEntry.swift:47-48`, Series). The reader's own sheet will send 1e20 (twenty digits on the pad, `LibraryEditSheet.swift:266-272` documents it and fixes only `chapterText`). Whether MangaBaka stores a value that large is **unverified**; if it does, the next launch crashes in `startSession` and keeps crashing until the value is fixed on the website:
  - `MangaBaka/Core/Library/SpotlightIndex.swift:93-94` — `Int($0)`, `Int(chapter)`; runs on every launch via `spotlight.reindex`.
  - `MangaBaka/Core/Library/ReadingInsights.swift:78` — `Int(total - read)` (negative 1e20 traps too); `:90` — `Int(chaptersCounted)`. Reached by Insights, Wrapped (`ReadingWrappedYear.swift:64, 156`) and reminders (`ReleaseReminders.swift:195, 219` → `nearlyFinished`/`waiting`) — so a bad progress value also crashes the foreground refresh.
  - `MangaBaka/Features/Library/LibraryList.swift:145, 148, 149, 155` — `Int(volume)`, `Int($0)` on `finalVolume`/`totalChapters`.
  - `MangaBaka/Features/Library/LibraryEditSheet.swift:152` — `Int(total)`.
  - `MangaBaka/Features/Library/ShelfDetailView.swift:240` — `Int(total)` (guarded by `read <= total`, so `total` is at least `read`; still unbounded).
  - `MangaBaka/Features/Library/ReadingInsightsView.swift:96` — `Int(hours.rounded())`; `:179` — `Int(totalChapters ?? 0)`.
  - Fix: one `Int(clamping:)`-style helper (`Int(exactly: value.rounded()) ?? Int.max`) and use it at all ten sites; refuse `> 100_000` in `LibraryEditSheet.changes`.
- Safe by inspection: `LibraryList.swift:171, 175`, `ShelfDetailView.swift:252`, `LibraryEditSheet.swift:35` (rating ≤ 100 → ≤ 5), `LibraryList.swift:261` (fraction ≤ 1), `ReadingInsights.swift:226` (percent), `ReadingWrappedYear.swift:100` (bounded), `ScheduleModel.swift:132` (`inScope × 3 / 60`), `ReadingWrappedYear.swift:86` (`ranked[1]` guarded by `ranked.count == 1 ||`).
- `MangaBaka/Core/Schedule/MangaUpdatesClient.swift:167` — `preconditionFailure` on a compile-time literal URL. Not reachable from input.
- Force unwraps, `try!`, `as!`, `fatalError`, `.first!`: **none found** in the slice.
- Division: every `/` on a Double is guarded by `total > 0` / `catalogueSize > 0` / `max(days, 1)` (`PickBackUp.swift:87-90`, `ShelfDetailView.swift:231`, `ReadingInsights.swift:158, 211, 226`, `ReadingWrappedYear.swift:46, 100`, `ReadingWrapped.swift:91`, `LibraryShape.swift:60`). None found unguarded.

## Done well (do not touch)

- `LibraryModel.screenState` decides loading/failed/list in one place (`LibraryModel.swift:55-63`); `.failed` renders `FailureState` with retry and Open Settings (`LibraryView.swift:76-82`).
- 401/403 → "This part needs an account" + accent Open Settings (`APIError.swift:52-54, 65`; `FailureState.swift:65-66`).
- First page drawn as it lands, spinner stops on page one (`LibraryModel.swift:249-251, 277`); skeleton rows in the list's own shape (`LibraryView.swift:262-284`).
- A failed walk is never cached (`LibrarySnapshot.swift:119-122`); disk cache ignores a clock that went backwards (`:146-147`); the cache is dropped on every write (`:190-201`).
- Edit sheet: nothing sent until Save, only touched fields, invalid chapter blocks Save with a sentence (`LibraryEditSheet.swift:137-144, 217-220`), failure shown inline and the sheet stays (`:250-254`), Save disabled and spinning while in flight (`:226-242`), decimal comma / Arabic digits parsed (`:309-315`), 1e20 does not crash the formatter (`:273-279`).
- `NaN`/`inf` refused before `JSONSerialization` can raise (`APIClient.swift:255-268`).
- Pick back up hides when empty; progress bar only with a real denominator (`PickBackUp.swift:12, 86-91`).
- Continuations row shows a skeleton while loading (`ContinuationsRow.swift:18-24`) and is keyed on `isComplete` so it runs once (`LibraryView.swift:145-148`).
- Schedule: library failure → FailureState with retry (`ScheduleView.swift:30-32`); empty is distinguished from failure (`ScheduleModel.swift:61-63`); build survives leaving the screen and is re-followed on return (`:229-240`); Measure button spins and disables during a build (`ScheduleView.swift:96-109`); stale estimates named with a count (`:146-163`); "0 of 0" replaced by a first-run card once loaded (`:47-48`); a recorded MangaUpdates failure is retried next build, a settled null is not (`ReleaseSchedule.swift:305-307`); undecodable cadence rows are treated as failures (`:404-406`); `ScheduledWork.Reason.explanation` says why there is no date (`:19-25`).
- Reminders: asked for on toggle, never at launch (`ReleaseReminders.swift:14-17`); refusal leaves the switch off (`:57-68`); denied state gets an Open Settings line (`RemindersSection.swift:38-50`); library failure keeps yesterday's reminders (`ReleaseReminders.swift:119`); trigger never in the past (`:284-291`); capped at 40 under iOS's 64 (`:31`).
- Spotlight: cleared on sign-out (`RootView+Session.swift:129`); thumbnails from URLCache only, never a fetch (`SpotlightIndex.swift:100-103`).
- Intents: `services == nil` guard with a sentence (`AppIntents.swift:33-35`); "hasn't been measured yet" is distinguished from "nothing due" (`:82-86`).
- MangaUpdates 429 backs the spacer off (`MangaUpdatesClient.swift:129-133`); sleep cancellation becomes an error, not a hang (`:154-162`).
- Sign-out forgets profile id, ledger, snapshot, exclusion, reminders, build, index in one place (`RootView+Session.swift:112-130`).

## Proposed fixes, grouped by file

Each with the test that proves it; the test must fail before the change.

**`MangaBaka/Features/Library/LibraryModel.swift`**
1. Delete `hasAccount` and `.noAccount`; `screenState` returns `.empty` for `entries.isEmpty && isComplete && failure == nil`. Test (`LibraryModelTests`): stub returning `[]` → `screenState == .empty`; invert `noAccount()` at `:143-148`. Stub throwing `.server(401)` → `.failed(.server(401))` (already true; keep as the control).
2. Add `partialFailure: APIError?` = `failure` when `!entries.isEmpty`. Test: `PagedLibrary` that throws on page 3 → `entries.count == 200`, `isComplete == false`, `partialFailure == .offline`, `screenState == .list`.
3. Add `isFiltering: Bool` (`isSearching || filter != nil`) and `listedIsEmptyByFilter`. Test: 10 entries, `searchText = "zzz"` → `listed.isEmpty && isFiltering`.
4. Generation counter around `fetchAll` so a cancelled walk's result is ignored. Test: start `load()`, call `reload()` before page 2, assert final `failure == nil` and `entries.count` equals the second walk's.

**`MangaBaka/Features/Library/LibraryView.swift`**
5. `partialLoad` → three branches: spinner while `!isComplete && failure == nil && isLoading`; **StaleBar** (headline "Some of your library didn't load", detail `error.userFacingMessage`, Retry → `reload()`) when `partialFailure != nil`; inline note "Showing the first 3,000" when capped. Test: a `ViewInspector`-free check is to unit-test the pure state (2 above); the render is verified by a screenshot on Haiku.
6. `EmptyState("Nothing matches", secondary "Clear search")` under `LibraryList` when `listedIsEmptyByFilter`.
7. Subtitle blank while `screenState == .loading`.

**`MangaBaka/App/RootView+Session.swift`** (wiring only; the model change is in `LibrarySnapshot`)
8. `saveLibraryChange`: on success patch the entry in `LibrarySnapshot` and `LibraryModel` (new `apply(seriesId:change:)`), write the row to disk, `ToastCentre.show("Saved")`; full `reload()` only when the patch cannot be applied. Test (`LibraryWriteTests`): after a rating save, `library.libraryPage` call count is **0** and `model.entries.first{…}.rating == 80`. Control: today's code makes 13 calls.
9. When `openShelf` would become nil after a save, toast "This shelf is now empty" first.
10. `startSession`: skip `spotlight.reindex` when `librarySnapshot.load().failure != nil`. Test (`SpotlightIndexTests` with a recording index): failed walk → `deleteSearchableItems` **not** called.
11. `openFromSpotlight` / `openSeries` nil path → toast.

**`MangaBaka/Core/Library/LibrarySnapshot.swift`**
12. `apply(seriesId:change:)` mutating `cached` and the disk row. Test: cached 3 entries, apply state change → `load().entries` reflects it, no network.
13. `readCache`: if `entries.count != rows.count` return nil. Test: write 3 rows, corrupt one payload → `load()` goes to network.

**`MangaBaka/Core/Library/Continuations.swift`**
14. `guard !Task.isCancelled` in the loop; count nil results; do not set `loadedFor` when every fetch failed. Test (`ContinuationsTests`): repository returning nil for all → `items.isEmpty`, second `load` with same entries **does** call the repository again (today: 0 calls).

**`MangaBaka/Features/Library/ReadingInsightsView.swift`, `WrappedView.swift`**
15. Take `isComplete`; render **StaleBar** "Built from the N series that loaded" when false. EmptyState when nothing qualifies. Hide the headline until computed. Test: the pure predicate `ReadingInsights.hasAnythingToSay(entries)` — `[]` → false; one reading entry with progress → true.

**`MangaBaka/Features/Schedule/ScheduleView.swift`, `ScheduleModel.swift`**
16. `if model.isLoading { skeleton }` as the first branch. Test (`ScheduleModelTests`): fresh model before `load()` → a new `screenState` enum returns `.loading`, not `.measured`.
17. `else if model.libraryFailure != nil` → StaleBar under the announced section with Retry.
18. `measurementFailureLine` shown in `firstRunCard` too; model: `measurementFailureLine` must not require `measuredAt != nil`. Test: `applyForTesting(ScheduleProgress(failure: "x"))` + snapshot with `pending: 55, measuredAt: nil` → `measurementFailureLine != nil` **and** `hasNeverMeasured == true` (both must be true; today the line is unreachable in that state).

**`MangaBaka/Core/Schedule/ReleaseSchedule.swift`**
19. Break the build loop on `.offline` / `.rateLimited`. Test (`ScheduleServiceTests`): stub throwing `.offline` → `progress.done == 1`, `progress.total == 55`, `progress.failure` set, elapsed well under 3 s × 55.

**`MangaBaka/Core/Schedule/ReleaseCalendar.swift`**
20. `upcoming()` returns `(works, failure)`; `mine` passes it up; `ScheduleModel.announcedFailure`. Test: first page throws → `failure != nil`, `works.isEmpty`; second call retries (already true, keep as control).

**`MangaBaka/Core/Schedule/MangaUpdatesClient.swift`**
21. `server` message → "MangaUpdates isn't answering right now." Test: 503 stub → `userFacingMessage` has no digits.

**`MangaBaka/Core/Intents/AppIntents.swift`**
22. `DueThisWeek.sentence(… libraryFailure:)` → "I couldn't read your library — <headline>." Test: `libraryFailure: .offline` → sentence starts "I couldn't read your library".

**`MangaBaka/Core/Notifications/ReleaseReminders.swift`, `Features/Settings/RemindersSection.swift`**
23. Switch shows off when `systemStatus == .denied`. Test: `isEnabled == true`, stub status `.denied` → a new `effectiveEnabled == false`.
24. `reschedule`: treat `isComplete == false` like a failure for removals. Test: partial walk → `removeAll` not called.

**Traps — one helper, ten sites**
25. `Int(wholeOrMax: Double)` in a shared file; replace the sites listed under Traps. Test: `Int(wholeOrMax: 1e20) == Int.max`, `Int(wholeOrMax: -1e20) == Int.min`, `Int(wholeOrMax: 12.5) == 12`. Then `SpotlightIndex.description(for: entry(progress: 1e20))` returns a string instead of trapping — the test process would crash today, which is the proof.
26. `LibraryEditSheet.changes`: reject `> 100_000` via `chapterIsInvalid`. Test: `isInvalidChapter("99999999999999999999") == true`.

**`MangaBaka/Features/Library/LibraryEditSheet.swift`**
27. `.decimalPad`. No test; visible.

## Unsure

- Whether `navigationDestination(item:)` re-renders `ShelfDetailView` when `openShelf` is reassigned an `==`-equal `Shelf` (id-only equality). If it does not, every edit from the shelf screen shows stale rows until the reader backs out. Needs a device check, not a guess.
- Whether MangaBaka's API accepts `progress_chapter: 1e+20`. If it rejects it the ten `Int(Double)` sites are only reachable by the server sending an absurd `total_chapters`, which is a lower-probability path. The fix is cheap either way.
- The `reload()`-during-walk interleave (row "LibrarySnapshot / reload while in flight") is reasoned from the code, not observed.
