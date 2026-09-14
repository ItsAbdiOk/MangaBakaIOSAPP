# Second pass — synthesis and work list

2026-09-14, HEAD `fee95b0`. Synthesised from the five slice reports in this directory
against `docs/reviews/full/SUMMARY.md` §2. Read-only: this file is the only thing written.
Nothing was built, run, or measured for this synthesis.

---

## 1. Counts

| Report | Filed |
|---|---|
| persistence | 15 (F1–F15) |
| wire | 16 (W1–W16) |
| reader | 12 (F1–F12) |
| screens | 29 (F1–F29) |
| shell-and-tests | 18 (S1–S18) |
| **Raw** | **90** |

One cross-report duplicate: persistence F13 and reader F6 are the same defect
(`LibrarySnapshot.load()`'s `inFlight` branch skips `replayPending`). reader F12 and
shell S1 are two *different* defects in `TokenStore.swift` and are counted separately.
**Deduped: 89.** Of those, 72 are in the work list, 7 are product decisions, and 10 are
notes, negative results or items the reports closed themselves.

By kind — this is the story of the pass:

| Kind | Count | Share |
|---|---|---|
| **inert** — the mechanism cannot fire | 16 | 18% |
| **half-landed** — right at some call sites, missed at others | 19 | 21% |
| **collision** — two fixes each right alone, wrong together | 6 | 7% |
| **new defect** — introduced 2026-09-13/14 | 5 | 6% |
| **pre-existing** — there before yesterday | 43 | 48% |

**46% of this pass's findings are about yesterday's ~200 changes rather than about the
code they were applied to.** Pass 1's taxonomy had no category for "inert"; it is now the
second-largest kind, and it and "half-landed" together outnumber the new defects nine to one.
Agents produced the *shape* of a fix reliably and its *reachability* unreliably.

---

## 2. The three that must be fixed before anyone else installs this app

I agree with two of your three and want to swap the third.

**1. `TokenStore`'s per-instance memo — S1, `TokenStore.swift:66`.** Agreed, and it is
first by a wide margin. The app builds three `TokenStore()`s (`AppServices.swift:87`,
`TokenProvider.swift:31`, `SettingsView.swift:97`), each with its own `private let cache`.
On a fresh Release install: onboarding's `feed(.rising)` caches "no token" in instance 2 →
reader pastes a token into instance 3 → `verifiedProfile()` reads instance 2 → sends the
request unauthenticated → 401 → `SettingsView.swift:358-366` **deletes the token it was
just given** and tells the reader it was rejected. No new install can connect an account
without relaunching, and the app blames the reader's token. "Remove token" is equally
cosmetic: instances 1 and 2 keep sending the removed token and re-cache the previous
account's library to disk. It is hidden from every walk because `Secrets.xcconfig` defines
`MB_PAT`, so Debug authenticates through `buildTimeToken` whatever the Keychain says —
the one failure the whole review could not have seen from Abdi's machine.

**2. The deep-link task cancelling itself — S2, `RootView.swift:299-303`.** This replaces
your third. `.task(id: bridge.pendingSeriesID)` writes nil to the id it is keyed on, which
restarts the task; gap 76's `Task.isCancelled` guards at `RootView+Session.swift:307, 318`
then return before navigating. Library series still open (that branch has no guard) —
**so the failure is invisible on a stocked library and total on an empty one.** A new
installer's library is empty, so every Siri "Open X", every widget tap, every mangabaka.org
link is a dead tap that spends a request first. The reports support this over the taste
ledger: two features shipped separately (item 65's URL routing, gap 76's guards), each
correct alone, and nobody ran the pair.

**3. The import after a failed library walk — persistence F1,
`RootView+Session.swift:101` → `LibraryTransferSection.swift:66, 150`.** Agreed. `all()`
answers `[]` for *any* failure — offline, 429, a 500 — so `LibraryImport.apply` gets
`existing: []`, its "never downgrades progress" guard at `LibraryImport.swift:430-434`
cannot fire, and every row is sent as a fresh `add`. A reader who is briefly offline when
they open Settings and restores an old export **walks their real MangaBaka progress
backwards on the server**, one request per row. The preview at `:105` reports every row as
"new", so the number on screen agrees with the bug. It is the only finding in the pass that
writes wrong data to the account and cannot be undone by relaunching.

**Why the taste ledger (persistence F2) is fourth, not third.** `absorb([])` does empty the
whole ledger on one failed walk — certain, and the fix is one line. But the report says
plainly it rebuilds on the next successful walk: the cost is degraded ranking, a wrong
"Nothing counted yet" in Settings, and one expensive re-absorb, all for the rest of one
session. Recoverable ≠ install-blocking. It shares a seam with F1 and F3, so it lands in
the same diff anyway.

**The other close call is W1** (the widget's `URLSession` sends no User-Agent to a host
measured on 2026-09-08 as answering 403 without one — every cover in both widgets, failing
permanently and silently). I left it out of the three only because the impact is cosmetic
and the 403 is inferred for the CDN rather than measured. One `curl -sI` promotes it.

---

## 3. THE WORK LIST

Ordered by value ÷ effort. Lane letters are defined in section 4. Every test edit belongs
to the lane that owns the production file it asserts on.

1. [new defect] TokenStore.swift:66 — the memo is `private let cache` so each of the app's three `TokenStore()`s memoises separately; a written token is invisible to the reader and to the API client. FIX: `private static let cache = Cache()` (service/account are constants at `:14-15`, so one memo is the truth); delete the wrong sentence at `:24-28` and `AppServices.swift:71-74`; drop the defaults at `SettingsView.swift:97` and `TokenProvider.swift:31` and pass `services.tokenStore`. EFFORT: line. CONFIDENCE: certain. TEST: `let a = TokenStore(); let b = TokenStore(); _ = a.read(); b.write("mb-two-instances-token"); #expect(a.read() == "mb-two-instances-token")` — returns nil today. LANE: A.
2. [collision] RootView.swift:299-303 — `.task(id: bridge.pendingSeriesID)` nils the id inside its own body, cancelling itself; gap 76's guards then return before navigating, so every deep link to a non-library series is a dead tap after a spent request. FIX: `struct Open: Equatable { let id: Int; let token = UUID() }` on `IntentBridge`, key on `pending?.token`, clear only after the `selection`/path writes in `openSeries`. EFFORT: function. CONFIDENCE: likely. TEST: assert `AppIntents.swift:19` and `RootView.swift:318` both construct an `Open`; `print(Task.isCancelled)` at `RootView+Session.swift:307` settles the mechanism. LANE: A.
3. [collision] LibrarySnapshot.swift:252,255 — `all()`/`seriesIDs()` discard `Result.failure`, so the refusal the snapshot was rebuilt to carry reaches only three of twelve callers. FIX: deprecate both; move each caller to `load()`; where a caller genuinely cannot act, spell `let result = await snapshot.load()` so the discard is visible. EFFORT: function + 9 call sites. CONFIDENCE: certain. TEST: a stub snapshot with `failure: .noAccount` — `AppIntents.swift:46` must not answer "nothing coming up". LANE: B (API), A+D+E (call sites, round 2).
4. [collision] LibraryTransferSection.swift:66,150 — an import run after a failed walk gets `existing: []`, so the progress guard cannot fire and every row is re-added; the reader's server-side progress walks backwards. FIX: `loadExisting` hands over the `Result`; refuse to build a preview when `failure != nil || !isComplete` and say why. EFFORT: function + 1 call site. CONFIDENCE: certain. TEST: `apply` with a failed-walk `existing` and an imported chapter behind the current one asserts zero `add` calls — fails today. LANE: A (needs 3).
5. [collision] TasteLedger.swift:116-121 — `absorb([])` matches every `tasteSource` row and retracts the whole ledger; `TasteProfile.swift:106` feeds it `all()`, which is `[]` on any failure. FIX: pass the `Result` and skip the stale sweep unless `failure == nil && isComplete`; `guard !entries.isEmpty` is the one-line patch. EFFORT: line (patch) / function (fix). CONFIDENCE: certain. TEST: seed two `tasteSource` rows, `absorb([])`, `#expect(countedSeries() == 2)` — fails today. LANE: B.
6. [half-landed] MangaBakaWidgets/CoverLoader.swift:31-37 — the widget's own `URLSession` sets no `httpAdditionalHeaders`, so every cover request goes out agentless to a host measured as 403-ing agentless clients. FIX: add `AppUserAgent.swift` to the widget target's `sources` in `project.yml` (as `:150` already does for `WidgetSnapshotData.swift`) and set the header. EFFORT: line + project.yml. CONFIDENCE: certain the header is absent; likely it costs covers. TEST: `curl -sI` one cover URL with and without `-A`. LANE: C.
7. [half-landed] Core/Volumes/GoogleBooksClient.swift:106-109 — the one 429 branch of ten that never reached the shared `Retry-After` function, in the client documented as 429-ing most. FIX: `_ = spacing.backOff(retryAfterHeader: http.value(forHTTPHeaderField: "Retry-After"), now: clock.now)`; `unstatedBackOff` is already 60, so the old behaviour is preserved exactly. EFFORT: 3 lines. CONFIDENCE: certain. TEST: a stub 429 with `Retry-After: 3600` asserts `nextAllowed >= now + maxHonouredRetryAfter`. LANE: C.
8. [inert] RootView+Session.swift:381 — `ReleaseReminders.reschedule(isComplete:)` is never passed by its only caller, so the guard at `:200` that refuses to schedule off a page-capped walk is dead. FIX: `isComplete: walk.isComplete` (it is read one line above at `:353`). EFFORT: line. CONFIDENCE: certain. TEST: a stub snapshot with `isComplete: false` and a confirmed release for a `.reading` series asserts zero `centre.add` calls. LANE: A.
9. [inert] Core/Model/CommunityPulseService.swift:32-40 — the `failedAt` backoff pass 1 recorded as folded into Lane D was never written; `load()` is still `guard pulse == nil` and `DiscoverView.swift:148` runs it per appearance. FIX: `private var failedAt: Date?`; `guard pulse == nil, failedAt.map { Date().timeIntervalSince($0) > 60 } ?? true else { return }`; label the 60 a guess. EFFORT: few lines. CONFIDENCE: certain. TEST: two appearances with a throwing stub assert one request. LANE: C.
10. [half-landed] Core/Schedule/ReleaseCalendar.swift:75 — `/v1/works/upcoming` is still decoded strictly in the file whose own comment records that exact failure emptying the Schedule screen; and `:78-81` `break`s the paging loop, discarding pages that already succeeded. FIX: `client.getLossy(...)`; return `.loaded(sorted, isPartial: true)` when ≥1 page succeeded. EFFORT: line + few. CONFIDENCE: certain. TEST: a two-page stub whose page 2 has one bad row asserts page 1's works survive. LANE: C.
11. [half-landed] Core/Model/CatalogueService.swift:51 — `genres()` decodes `[Genre]` strictly while its two siblings in the same file use `getLossy`; one bad row empties the genre vocabulary on several browse surfaces at once. FIX: `client.getLossy("/v1/genres")`. EFFORT: line. CONFIDENCE: certain. TEST: a payload with one malformed genre asserts the rest decode. LANE: C.
12. [half-landed] TasteLedger.swift:213-219 — `clear()` deletes three of the four ledger tables and leaves `tasteSeen`, so after sign-out Settings reads "945 series seen, and none of them carried tags" — the previous account's count dressed as this feature's one diagnosable failure. FIX: add `DELETE FROM tasteSeen`; derive the table list once (v11, `clear`, `salvage` are three hand-maintained copies that already disagree). EFFORT: line. CONFIDENCE: certain. TEST: absorb one tagless series, `clear()`, `#expect(seenSeries() == 0)`. LANE: B.
13. [half-landed] AppServices.swift:151,191 — `hasCredentials` reads the Keychain only; `TokenProvider.swift:40` also honours `MB_PAT`, so every Debug build says "No account" in the Library tab while Discover, the stack and Settings all authenticate. FIX: `ResolvingTokenProvider.hasCredentials { store.read() != nil || buildTimeToken != nil }`, built once and passed to both. EFFORT: lines. CONFIDENCE: certain. TEST: a provider with `MB_PAT` and an empty store reports `true`. LANE: A.
14. [half-landed] RootView+Session.swift:133-187 vs SettingsView.swift:357 — sign-out clears ten surfaces; a successful sign-in rebuilds none, so a reader who connects an account has no Spotlight, a blank widget, no reminders and an unweighted stack until relaunch. FIX: factor `startSession`'s post-guard half into `rebuildAccountSurfaces()`; call it from `startSession` and from `.accepted`. EFFORT: function. CONFIDENCE: certain. TEST: a recording double asserts `spotlight.reindex` is called after `.accepted`. LANE: A (needs 1).
15. [pre-existing] AppServices.swift:358-362 — `applyStoredExclusion` asks `/v1/my/profile` on every signed-out cold launch, and `RootView+Session.swift:169` asks again after "Remove token"; both are guaranteed 401s against the shared 180/min budget. FIX: guard both on `hasCredentials()`. EFFORT: 2 lines. CONFIDENCE: certain. TEST: a counting client asserts zero profile requests with an empty store. LANE: A (needs 13).
16. [collision] PublisherBrowser.swift:98-103,115-116 — the B-1 cancellation guard returns with `isSearching` still true, and the replacement task's short-text branch returns without resetting it: type "se", wait 350 ms, delete to "s", spinner forever. FIX: set `isSearching = false` in the short-text branch and move the reset above the cancellation guard. EFFORT: line. CONFIDENCE: certain. TEST: schedule("se"), let the request start, schedule("s"), assert `isSearching == false`. LANE: D.
17. [half-landed] SeedPickerSheet.swift:172-176 — reads `isSearching` and ignores `isPending`, so "Nothing called “x”." shows for 300 ms after every keystroke. This is E F4, fixed on `SearchView` and not carried here. FIX: `if (search.isSearching || search.isPending) && search.results.isEmpty`. EFFORT: line. CONFIDENCE: certain. TEST: `emptyCopy` with `isPending: true` returns nil. LANE: D.
18. [inert] Countdown.swift:31-35 — `.onChange(of: hasReached(remaining))` has no `initial:`, so a `Countdown` mounted after its deadline (a 429 that lapsed while backgrounded) reads "Retrying now…" forever and never retries. FIX: `initial: true`. EFFORT: line. CONFIDENCE: likely. TEST: a `Countdown` given `deadline: .now - 1` calls `onReachZero` once. LANE: E.
19. [inert] SeriesRepository.swift:314-324 — the `.mix` feed is not asked for `schema=full`, so every dealt card arrives with no `tags_v2`, `TasteRanker` scores every one 0, and the ranker, its reason lines and the ledger behind it reorder nothing. FIX: add `schema=full` to `.mix` as `.surprise` already does, and move the explaining comment up to cover both; **measure the payload delta first** (see NEEDS ABDI). If the cost is refused, delete the `ranker.rank` call rather than leave it looking alive. EFFORT: line + measurement. CONFIDENCE: certain on the mechanism. TEST: log the spread of `score()` over one dealt batch; all-zero today. LANE: B + E.
20. [inert] Core/Telemetry/NetworkLedger.swift:35,61 — `droppedRows` is written by 14 `getLossy` sites and read by nothing, so `LossyArray`'s own justification ("is the app quietly showing nineteen of twenty?") is inert and the app can show 29 of 30 results forever undetected. FIX: one conditional in `DataUseSection.endpointRow`'s caption — `· N rows dropped` when `> 0`. EFFORT: function. CONFIDENCE: certain. TEST: an entry with `droppedRows: 3` renders the suffix. LANE: A.
21. [inert] RootView+Session.swift:441-458 — `onOpenTag` sets `selection = .search` but never pops `searchPath`, so a tag tapped on a series page reached *from* Search changes the results underneath a page that stays on top: nothing visibly happens. FIX: `searchPath.removeAll()` before `selection = .search`. EFFORT: line. CONFIDENCE: likely. TEST: assert the closure clears the path (source pin), or drive it on device. LANE: A.
22. [half-landed] PublisherView.swift:365-366,377-382 — a separate `count(query)` request for a number `FeedResult.total` already carries; this is E F1, fixed on Search a day ago. Worse, `PublisherPageTests.swift:123` pins the duplicate as source text. FIX: `total = result.total`, fall back to `count` only when nil; rewrite the test to assert one search call per load. EFFORT: line + test. CONFIDENCE: certain. TEST: a counting stub sees one request per load. LANE: D.
23. [pre-existing] SearchModel.swift:216-223 — `cancelSearch` never clears `sort`/`randomSeed`, so after any Browse pick or series-page tag every title typed afterwards goes out `sort_by=popularity_asc` instead of by relevance. FIX: clear both in `cancelSearch`. EFFORT: line. CONFIDENCE: certain. TEST: `openTag` then `cancelSearch` then `search("one piece")` asserts `query.sort == nil`. LANE: D.
24. [pre-existing] SearchModel.swift:236-240 — removing the last token of a token-only search runs `filtersDidChange`, whose only guard is `hasAsked`; `query.isEmpty` counts `sort`, so a sort-only request for the whole catalogue goes out under an empty field. FIX: treat "no text and no tokens" as idle in `filtersDidChange`, the rule `queryDidChange` already applies to text. EFFORT: few lines. CONFIDENCE: likely. TEST: `openTag` then remove the token asserts no request. LANE: D.
25. [pre-existing] LibrarySnapshot.swift:218 — `walk` checks cancellation at the top of the page, then awaits, then publishes; a cancellation landing during the await still delivers that page to the previous account's observer. Contained today only by `LibraryModel`'s own generation counter. FIX: `guard !Task.isCancelled else { break }` immediately before `onPage?`. EFFORT: line. CONFIDENCE: certain. TEST: cancel mid-page against a stub and assert `onPage` is not called again. LANE: B.
26. [pre-existing] LibrarySnapshot.swift:145 — the second concurrent `load()` caller returns `await inFlight.value`, the raw walk, with `pendingChanges` un-replayed; three callers arrive at once on launch, so who sees the reader's mid-walk edit is a race. FIX: minimally `return replayPending(onto: await inFlight.value)`; properly, route both branches through one `finish(_:)`. EFFORT: line / function. CONFIDENCE: certain. TEST: stash a change mid-walk and assert both callers see it. LANE: B.
27. [new defect] AppDatabase+Schema.swift:139-140,232 — `v12_shelfOrderIndex` creates an index on `shelfEntry`, breaking the rule stated in bold 25 lines below; it survives only because v12 and the split shipped in the same build. The next migration that does the same makes every launch fall back to an in-memory DB, silently and forever. FIX: `if try db.tableExists("shelfEntry")` inside v12; a comment at `:139` saying why v12 is safe; and the test below. EFFORT: line + test. CONFIDENCE: certain. TEST: migrate a cache file, run `splitReaderTables`, run `AppDatabase.migrator` again, assert no throw. LANE: B.
28. [pre-existing] LibraryImport.swift:141 — `LibraryExport.defused` prefixes a note starting `=+-@` with an apostrophe and `parseCSV` never strips it, so a round trip spends a real PATCH writing the corrupted text into the reader's account. FIX: in `parseCSV`, strip exactly one leading `'` on `title`/`note` when the next character is one of the four; name `defused` in the comment. EFFORT: function. CONFIDENCE: certain. TEST: round-trip a note starting with each of the four — fails today. LANE: B.
29. [new defect] TokenStore.swift:74,78 — `keychainQueryCountForTesting` is a `nonisolated(unsafe) static var` incremented in production, outside the cache's lock, reachable from two isolation domains at once. FIX: move it inside `Cache` behind the existing `NSLock` and wrap in `#if DEBUG`. EFFORT: line. CONFIDENCE: certain. TEST: none needed beyond the existing counter tests. LANE: A (same diff as 1).
30. [half-landed] +Categories.swift:25-26, +Releases.swift:57, +Store.swift:76-78 — C2 was fixed for cadence, Mix and Discover but not for categories, cast or the volumes shelf, so a cancelled ask leaves "Cancelled" with a Retry on a page the reader is looking at. FIX: `if case .cancelled = error { return }` before each write — the three lines cadence uses. EFFORT: line ×3. CONFIDENCE: likely. TEST: `onwardRowState` / `DetailCategories` given `.cancelled` renders loading, not failure. LANE: E.
31. [inert] LibraryControl.swift:35,70-72 — `needsAccount` is computed and read nowhere, and the control renders *nothing at all* for a reader with no token: no button, no explanation. FIX: render a muted "Add a MangaBaka token in Settings to track this" where the button would be, as the Library tab already does for `.noAccount`. EFFORT: few lines. CONFIDENCE: certain. TEST: the state function returns a `.noAccount` case. LANE: E.
32. [pre-existing] SeriesDetailView.swift:344,489-495 — `.task(id: series.id)` re-runs the whole page load on every pop-back and every cover-gallery dismissal: `filled = nil` resets the page to skeletons, then seven onward legs are re-asked including two behind MangaUpdates' 3 s spacer and up to 36 s of Open Library HEADs. The "Detail readable" signpost now measures cache hits. FIX: `@State loadedID: Int?`; `guard loadedID != series.id else { return }` before `loadCore`; set after a non-failing return. EFFORT: function. CONFIDENCE: likely. TEST: `print("load", series.id)` at the top; one related-cover tap and back — expect one line, not two. LANE: E.
33. [half-landed] PublisherView.swift:141,359-364 — `.task(id: order)` has no already-loaded guard, so a pop-back resets to page 1 and spends two (with 22, three) search-window requests, losing the reader's place. D-1, fixed on Discover, not here. FIX: `@State loadedOrder: Order?` with the same guard; pull-to-refresh keeps calling `load()` directly. EFFORT: few lines. CONFIDENCE: likely. TEST: same print. LANE: D.
34. [half-landed] ScheduleView.swift:100 — `.task { await model.load() }` re-reads and re-decodes the whole library on every pop-back, and flickers `scopeCard` over `firstRunCard` for a frame. FIX: guard on `hasLoadedOnce` as Discover does, keeping `followBuild()` resumption unconditional. EFFORT: few lines. CONFIDENCE: likely. TEST: same print. LANE: D.
35. [pre-existing] ReleaseReminders.swift:239,313 — the same-series 24-hour cooldown is stamped at queue time, not at the placed date, so two notifications about one series can land on the same lock screen seconds apart — the exact fatigue the guard exists to stop. FIX: record and compare against `placed.date`, not `now`, in both `applyFatigueGuard` and `performReschedule`. EFFORT: function. CONFIDENCE: certain. TEST: fixed clock, two passes a day apart, assert one delivery date per series. LANE: E.
36. [pre-existing] ReleaseReminders.swift:249,361-363 — `reminders.fired` is an append-only `UserDefaults` dictionary, decoded twice and rewritten on every launch/foreground/toggle on the main actor, and one non-`Date` value silently yields `[:]`, making every past notification eligible again. FIX: prune on write to 60 days (label it a guess; `maxDeferralDays` is 14); read `fired` once into a `let`. EFFORT: function. CONFIDENCE: certain. TEST: seed a 90-day-old entry, reschedule, assert it is gone. LANE: E.
37. [pre-existing] LibraryImport.swift:67-72,417-440 — `requestSpacing` is documented as one request per row landing at 120/min; `apply` sends up to three per row, so a 939-row restore runs at ~240/min against a 180/min shared ceiling, and a mid-restore 429 has no retry and no resume point. FIX: sleep per network call, not per row, and rewrite the comment with the real worst case and the real restore time. EFFORT: function. CONFIDENCE: certain. TEST: a counting client over 10 new rows asserts ≥10 sleeps. LANE: B.
38. [half-landed] DiscoverView.swift:228-230 — a single row's `InlineFailure` retry calls `model.load(forceRefresh: true)`, re-paying all four rows including two from the 30/min family. FIX: `DiscoverModel.retryRow(_:)` refreshing one row; factor `:150-170` into `apply(result, to: index)`. EFFORT: function. CONFIDENCE: certain. TEST: a counting repository sees one feed call per row retry. LANE: D.
39. [half-landed] DiscoverView.swift:76-89 — `StaleBar` is mounted without `deadline:` and a hand-rolled `Countdown` sits under it that never retries; the recorded reason (a frozen `staleDetail` string) is true of the detail line and is not a reason to withhold the deadline. FIX: pass `deadline: model.staleFailure?.rateLimitDeadline`, delete `:84-89`. Separately, write the *real* reason at `ScheduleView.swift:65` for the site that correctly withholds it (its retry is the 13-request walk). EFFORT: few lines. CONFIDENCE: certain the line is redundant; the auto-retry is a decision (see NEEDS ABDI). LANE: D.
40. [pre-existing] DiscoverModel.swift:211-214 — `staleFailure` returns the screen-wide first failure, not the stale row's, so an offline row and a rate-limited row together produce "Offline" with no countdown. FIX: `rows.first { $0.failure != nil && !$0.series.isEmpty }?.failure`. EFFORT: line. CONFIDENCE: likely. TEST: two rows, two failures, assert the bar names the one with content. LANE: D.
41. [pre-existing] PublisherView.swift:403,424 — `page += 1` runs before the request, so a failed page's retry skips it and fetches N+2. `SearchModel.loadMore` got this right. FIX: advance `page` only when `result.blockingError == nil`. EFFORT: line. CONFIDENCE: likely. TEST: fail page 2, retry, assert page 2 is requested again. LANE: D.
42. [pre-existing] MixFilterStrip.swift:59,159-174 — every toggle in the tag-picker sheet fires a `/v1/series/mix` request 350 ms later while the sheet still covers the grid; five tags in six seconds is five invisible blends. FIX: `guard !isPickingTags else { return }` in `requestBlend`, and blend once from `onDismiss`. EFFORT: few lines. CONFIDENCE: likely. TEST: three toggles with the sheet up assert zero requests, one on dismiss. LANE: D.
43. [pre-existing] FilterPanel.swift:148-152,328-355 — the "Show N results" count is a `limit=1` search-window request debounced 350 ms, and the year fields write per digit, so "2020" is up to four requests. Priced when the count was on the general window; it is now on the 30/min one. FIX: count on commit for the year fields; hold the count while a picker sheet is up; consider 800 ms, labelled a guess. EFFORT: few lines. CONFIDENCE: likely. TEST: type four digits, assert one count request. LANE: D.
44. [half-landed] MixView.swift:93-99 — Mix drops `lenses?.save(...)`'s `Bool`, so "saved" is indistinguishable from "the tap missed"; gap 55 fixed this on Search only. FIX: the same toast pair; `ToastCentre` is already in the environment. EFFORT: few lines. CONFIDENCE: certain. TEST: a failing save surfaces a toast. LANE: D.
45. [pre-existing] MixView.swift:54-56 — `.task { suggestedSeeds = await model.suggestedSeeds() }` decodes the shelf on every appearance for a row shown only when `seeds.isEmpty`. FIX: `guard model.seeds.isEmpty else { return }`. EFFORT: line. CONFIDENCE: certain. TEST: appear with seeds, assert no shelf read. LANE: D.
46. [pre-existing] ScheduleModel.swift:148-149 — a `RelativeDateTimeFormatter` allocated per body read; `DiscoverModel` was made static this week. FIX: `private static let ageFormatter`. EFFORT: line. CONFIDENCE: certain. TEST: none (mechanical). LANE: D.
47. [inert] CoverImage.swift:141-143,155 — item 33's release is half inert: the assignment after the await has no cancellation check and `CoverStore` is deliberately uncancellable, so a fast fling gives hundreds of off-screen rows their decoded bitmap back. FIX: `guard !Task.isCancelled else { return }` before both writes. EFFORT: line. CONFIDENCE: likely. TEST: memory graph after a 513-row fling, with and without. LANE: E.
48. [pre-existing] StackModel.swift:304-312,412-413 — `refill()` nils `refillTask` unconditionally, clobbering a newer refill's registration, and neither `performRefill` nor `append` checks cancellation, so a cancelled refill appends to a stack `resetStack` just emptied and two concurrent feed requests follow. FIX: `if refillTask == task { refillTask = nil }`; check `Task.isCancelled` at the top of `append` and after each await in `performRefill`. EFFORT: function. CONFIDENCE: likely. TEST: a synchronously-returning repository, cancel the refill, assert `queue.isEmpty` after `resetStack`. LANE: E.
49. [pre-existing] TasteRanker.swift:74-83 — `score()` is called on both sides of every comparison, ~560 calls for a 50-item batch instead of 50, on the main actor on the deal path. Cheap only because item 19 makes every score an early return. FIX: decorate–sort–undecorate on `(score desc, offset asc)`. EFFORT: function. CONFIDENCE: certain. TEST: a counting scorer sees n calls. LANE: B (land with 19).
50. [pre-existing] CoverStore.swift:31-37 vs :149-153 — two comments in one file contradict each other about the same number: the cost function charges decoded bytes, so 96 MB holds ~28 covers, not the 300 the header claims. That is less than one Discover screen plus the page behind it, and `NSCache` eviction is silent. FIX: decide which the limit means — charge encoded size and keep 96 MB (matches intent), or rewrite `:31-37` to say ~28. EFFORT: line / function. CONFIDENCE: certain the two disagree. TEST: log `NSCacheDelegate` evictions over one 60-cover fling. LANE: B.
51. [pre-existing] CoverStore.swift:92-97 — `prefetch` starts one unstructured default-priority `Task` per URL with no cap; a grid handing it 40–60 URLs starts 40–60 concurrent fetches and decodes competing with the scroll that asked for them. FIX: a `TaskGroup` of fixed width at `.utility`, or `urls.prefix(12)`. EFFORT: function. CONFIDENCE: certain about the code. TEST: `grep -n "prefetch(" MangaBaka/Features` for the largest caller. LANE: B.
52. [pre-existing] EmbeddingIndex.swift:191-200 — `count` and `dims` come from the file header and are multiplied before any bound check, so a truncated `OfflineEmbeddings.bin` traps instead of throwing `LoadError`, and a plausible-but-wrong `count` allocates first. `Gunzip` learned this lesson on 2026-09-14; this file did not. FIX: bound both before multiplying (real file is 19,203 × 384 — say so, with the headroom). EFFORT: 4 lines. CONFIDENCE: likely. TEST: a truncated fixture throws rather than traps. LANE: B.
53. [pre-existing] OfflineCatalogue.swift:376 — `Int(rating.rounded())` on a `Double` decoded from the bundled index, against this project's own rule and `Int(wholeOrClamped:)`. FIX: `Int(wholeOrClamped: rating.rounded())`. EFFORT: line. CONFIDENCE: certain the rule is broken. TEST: a NaN rating does not trap. LANE: B.
54. [pre-existing] SeriesRepository.swift:463,469 — `cachedImages` and `cachedRelationships` are per-series dictionaries held for the process lifetime; the second is cleared by nothing at all. FIX: an `NSCache` with a count limit or a small LRU; label the number a guess. EFFORT: function. CONFIDENCE: certain neither is bounded. TEST: 500 series pages, assert the dictionary is capped. LANE: B.
55. [pre-existing] AppDatabase.swift:381-395 — `salvage` copies `readerTables` and deliberately not `librarySplit`, so a reader's file reset while the cache still holds the reader tables loses the marker and re-runs the copy, resurrecting rows the reader deleted. FIX: salvage the marker through a second, salvage-only list, or re-`mark` after checking `salvage.librarySplit`. EFFORT: 1-2 lines. CONFIDENCE: likely (narrow reachability). TEST: reset a reader's file with cache tables present, assert no re-copy. LANE: B.
56. [inert] AppDatabase+Split.swift:103-118 — the whole-row `EXCEPT` cannot catch any column reorder that keeps the arity, which is exactly the drift its comment says it catches; the real protection is `LibrarySplitTests.schemasMatch`, and nothing says so. FIX: minimum — correct both comments (`:103-107` and `LibrarySplitTests.swift:216-219`). Better — compare `PRAGMA table_info` name lists and throw `SplitError.schemaDrift` before copying, with an explicit column list instead of `SELECT *`. EFFORT: comment / function. CONFIDENCE: certain (reasoned, not run). TEST: reorder one table's columns, assert the split refuses. LANE: B.
57. [inert] WidgetSnapshotTests.swift:64,100-115 — the contract test asserts the encoded item has **no `due` key**, and `due` is the entire point of the 2026-09-14 change; the fixture's subtitle is a string the app no longer produces. Rename `due` and every widget silently reverts while all four tests pass — T2's failure mode, in the test written to prevent it. FIX: give the `dueThisWeek` fixture a real `due` and the subtitle the app writes; add `due` to the key set; assert the decoded date; keep one `pickBackUp` item without `due`. EFFORT: function. CONFIDENCE: certain. TEST: the new key-set assertion fails today. LANE: C.
58. [pre-existing] APIClientCacheAndPrivacyTests.swift:194,227 — both identity-cache tests use `/v1/my/profile`, the easy half; neither exercises the `exclude_user_library` clause that puts a 32-character account id in a *public* path's URL, which is the cache key. FIX: a third test on `/v1/series/mix?exclude_user_library=<id>` with the parameterless call as its control. EFFORT: function. CONFIDENCE: certain. TEST: narrow `identifyingParameters` and the new test must fail. LANE: C.
59. [inert] AppShellRoundThreeTests.swift:64-66 — the stated kill criterion ("delete any one line from `AppServices.wire` and exactly one expectation fails") is false for two of five lines: `updateContentRatings` and `updateFormats` are never asserted, and those are the ones that filter the reader's own recommendations by rating. FIX: `wire` takes a two-method `LibraryFiltering` protocol; the test passes a recording double and asserts both halves. EFFORT: function + lines. CONFIDENCE: certain. TEST: delete `updateContentRatings` and the suite must go red. LANE: A.
60. [inert] SourceTree.swift:21-23 + 91 gate sites — ~165 of ~1,958 tests never run on Xcode Cloud and the difference is printed nowhere, so "1,954 green" is two numbers and the smaller one is the release gate. FIX (better way): ship the source to the test bundle — `- path: MangaBaka` with `buildPhase: resources, type: folder` under `MangaBakaTests.sources`, and `SourceTree.root` falling back to the bundle; then every source test runs everywhere. Fallback: a `Scripts/run-unit-tests.sh` that prints the skipped count, called by the hook and CI. EFFORT: file / script. CONFIDENCE: certain about the gates; the 165 is a regex ±5. TEST: the printed skip count is 0. LANE: C (owns project.yml).
61. [pre-existing] .githooks/pre-push:96 — the archive memo's stamp omits the toolchain (and the SIL-verifier crash it exists to catch is compiler-specific), omits `Package.resolved` (inside the excluded `.xcodeproj`), records HEAD's hash for an archive that compiled the working tree, and dies silently under `set -eu` if a stamped path is renamed. FIX: fold `xcodebuild -version` into the stamp; add the `Package.resolved` path; refuse to write the memo on a dirty tree; `|| true` on `:96`. EFFORT: lines. CONFIDENCE: certain for the omissions. TEST: bump Xcode with an unchanged tree, assert the archive runs. LANE: A.
62. [pre-existing] Configs/Info.plist:22-23,36-37 — the bundle ships literal `1.0 (1)`; `MARKETING_VERSION 0.1.0` and CI's `CURRENT_PROJECT_VERSION` sed never reach it, and the plists are XcodeGen defaults regenerated on every `generate`, so a hand edit will not stick. FIX: add `CFBundleShortVersionString: $(MARKETING_VERSION)` and `CFBundleVersion: $(CURRENT_PROJECT_VERSION)` to both targets' `info.properties` in `project.yml`, regenerate, commit both plists. EFFORT: 2 lines. CONFIDENCE: certain for the strings. TEST: measurement first — read build 64's build string in App Store Connect (see NEEDS ABDI). LANE: C.
63. [half-landed] CharacterProfileView.swift:23,25 — both clients default to fresh actors and `CharacterRow.swift:95` passes neither, so every profile open gets its own `RequestSpacing`, its own `Retry-After` backoff and its own outage memory, unknown to the `CharacterService` that just fetched the cast. C4's shape, a third time. FIX: thread the shared clients from `AppServices` through `CharacterRow`. EFFORT: function. CONFIDENCE: likely. TEST: assert the sheet is constructed with injected clients. LANE: E.
64. [pre-existing] CoverGallery.swift:44,153-158 — `progress` is `@State` on the gallery root and written per scroll sample, so the whole body — a `LazyHStack` of `ZoomableCover`s and two 1000 pt backdrops — re-evaluates per frame. FIX: reuse `ScrollTracker` and move `backdrop` into a child that alone reads it. EFFORT: function. CONFIDENCE: likely. TEST: Instruments (U7). LANE: E.
65. [pre-existing] ScrollTracker.swift:32-40 and DetailBackdrop.swift:100-166 — `update` wraps a continuous 0…1 value in `withAnimation` on every frame (a new animation per frame toward a one-frame-old target), and the backdrop reads the offset at the bottom of a body that also builds the `AsyncImage`, blur and gradient. FIX: assign `crossfade` directly and animate only `showsBarTitle`'s mount; split the offset read into a `ParallaxOffset` child. EFFORT: line + function. CONFIDENCE: likely. TEST: Instruments (U7). LANE: E.
66. [pre-existing] DetailHero.swift:49-53,189-191 — `MeasureKey` retires the three measurers before `extras`, the status, the byline and the cadence arrive, so the column form is chosen against heights measured on a different column and the gap under the cover comes back. FIX: add the shaping inputs to the key (kicker, byline, chapter count, title count, schedule shape), or `.onChange(of: series/schedule) { measuredFor = nil }`. EFFORT: function. CONFIDENCE: likely. TEST: screenshot a Discover-opened series at t=0 and t=2 s. LANE: E.
67. [pre-existing] SearchModel.swift:368-372,412-434,302 — a blocking 429 with nothing on screen falls back to the offline index and clears `failure`, so there is no countdown, no auto-retry, and Return is refused as a byte-identical re-ask; the reader is stranded on stale offline results. `SearchView.swift:333-337`'s comment says a retry "happens on its own" — nothing schedules one. FIX: keep `failure` alongside `origin = .offlineIndex`, and add `origin == .network` to the re-ask condition at `:302`. EFFORT: function. CONFIDENCE: likely. TEST: a rate-limited empty search then Return issues a request. LANE: D.
68. [pre-existing] TasteProfile.swift:132-133 — `note` reads the whole library through `all()` to find one entry, on the series page, on every open (and with item 32 unfixed, every re-appearance). FIX: `LibrarySnapshot.entry(for:)` returning one row; use it in `note`. EFFORT: function. CONFIDENCE: certain. TEST: a counting snapshot sees one row read. LANE: B (E calls it).
69. [pre-existing] InlineFailure.swift:16,33-41 — hand-rolls `RetryGate`'s rule and resets `isRetrying` on the main actor from an unstructured `Task` the view may have left. FIX: `@State private var gate = RetryGate()`. EFFORT: lines. CONFIDENCE: certain. TEST: none (mechanical). LANE: E.
70. [half-landed] Comments that now lie — one line each, all certain, all LANE per file: `RateLimitGate.swift:177-183` and `:209-211` (describe a pre-item-31 world with a `searchTimestamps` that no longer exists, and tell the reader general requests are uncounted — C); `APIClientCacheAndPrivacyTests.swift:178-179` (credits the *inert* `willCacheResponse` fix as shipped, in the file proving it did not — C); `ThirdPartySession.swift:5-6` (names nine clients including the deleted Naver — C); `OfflineCatalogue.swift:157-162` (`builtDate()`'s doc sits above `titles(for:)` — B); `AppleBooksClient.swift:147` (hard-codes 60 where `RequestSpacing.unstatedBackOff` is the named constant — C); `RemindersSection.swift:13-14`, `RootView.swift:141`, `LibraryModel.swift:125-126`, `RootView+Session.swift:302-303` (A); `SessionTests.swift:105` test title now asserts the opposite of its name (A). FIX: rewrite each to what the code does. EFFORT: line each.
71. [pre-existing] ReleaseSchedule.swift:124 and RequestSpacing.swift:71 — two loaded guns: `mangaUpdates:` still defaults to building a second client (reintroducing the two-spacing 429 bug silently at any future call site), and `backOff`'s `cap:` parameter has no caller. FIX: delete both defaults — all six test call sites already pass `mangaUpdates:` explicitly; say in `cap:`'s doc that it exists for tests, or remove it. EFFORT: line each. CONFIDENCE: certain. TEST: the build fails at any omitting call site. LANE: C.
72. [pre-existing] Misc, one line each: `ScheduleModel.swift:337` `Dictionary(uniqueKeysWithValues:)` over library entries — safe only because the walk dedupes, one refactor from a trap, use `uniquingKeysWith:` (D); `ReleaseReminders.swift:191` `rescheduleTask` never cleared, retaining the last task for the app's life (E); `Clock.swift:8` shadows the standard library's `Clock` in a module that uses `Task.sleep` three files away — rename to `CacheClock` (B); `check-credentials.sh:33` requires 16 alphanumerics while `TokenStore.swift:143` accepts 12, so a 13–18 character token passes the scanner (A); `WidgetSnapshotTests.swift:117-123` `roundTrips()` reads as a contract test eleven lines below a comment saying it is not — rename or delete (C); `LibraryControl.swift:102-106` and `SearchEmptyState.swift:113-124` write through `library` and never tell `LibraryModel`, so the Library tab is stale until its next walk (E).

Work-list tally by kind: 12 inert, 17 half-landed, 5 collision, 3 new defect, 35 pre-existing
(72). The remaining 17 of the 89 are the seven decisions in section 6, the eight
could-not-determines in section 7, and two notes the reports closed themselves
(`RootView+Tabs.swift:155-161`'s ranker task, which costs one cached read today and is
recorded only so nobody adds a walk to it; and `AppServices.tokenStore`, which stops being
dead the moment item 1 lands).

---

## 4. Lanes

Five lanes, disjoint by directory. No two lanes touch a file.

**Lane A — shell, auth, settings.** `MangaBaka/App/**` (`MangaBakaApp`, `RootView`,
`RootView+Session`, `RootView+Tabs`, `RootView+Failures`, `AppServices`, `IntentBridge`),
`MangaBaka/Core/Auth/**` (`TokenStore`, `TokenProvider`), `MangaBaka/Features/Settings/**`
(`SettingsView`, `DataUseSection`, `LibraryTransferSection`, `RemindersSection`,
`TranslationSection`), `.githooks/pre-push`, `Scripts/check-credentials.sh`. Tests:
`SessionTests`, `AppShellRoundThreeTests`, `TokenStoreCacheTests`, `TokenStatusTests`,
`LaunchPathDeferralTests`, `RepositoryWiringTests`.
Items: 1, 2, 4, 8, 13, 14, 15, 20, 21, 29, 59, 61, 70 (its A files), 72 (its A bullet).

**Lane B — persistence, library core, caches.** `Core/Persistence/**`, `Core/Library/**`,
`Core/Images/**`, `Core/Offline/**`. Tests: `LibrarySplitTests`, `AppDatabaseResetTests`,
`DatabaseCorruptionScopeTests`, the import/export suites.
Items: 3 (the API half), 5, 12, 19 (the `feedQuery` half), 25, 26, 27, 28, 37, 49, 50, 51,
52, 53, 54, 55, 56, 68, 70 (`OfflineCatalogue`), 72 (`Clock`).

**Lane C — wire, third parties, widgets, project config.** `Core/Networking/**`,
`Core/Model/**`, `Core/Volumes/**`, `Core/Characters/**` (clients only), `Core/Schedule/**`,
`Core/Telemetry/**`, `MangaBakaWidgets/**`, `project.yml`, `Configs/**`, `ci_scripts/**`.
Tests: `WidgetSnapshotTests`, `APIClientCacheAndPrivacyTests`, `GeneralRateLimitWindowTests`,
`ReleaseFeedServiceTests`, `ScheduleServiceTests`.
Items: 6, 7, 9, 10, 11, 57, 58, 60, 62, 70 (its C files), 71, 72 (`roundTrips`).

**Lane D — the screens that fetch.** `Features/Search/**`, `Features/Discovery/**`,
`Features/Mix/**`, `Features/Browse/**`, `Features/Schedule/**`.
Items: 16, 17, 22, 23, 24, 33, 34, 38, 39, 40, 41, 42, 43, 44, 45, 46, 67, 72 (`ScheduleModel`).

**Lane E — detail, shared controls, stack, notifications.** `Features/Detail/**`,
`Features/Shared/**`, `Features/Stack/**`, `Features/Library/**`, `DesignSystem/**`,
`Core/Notifications/**`, `Core/Characters/CharacterRow`-side views.
Items: 18, 19 (the `StackModel` measurement), 30, 31, 32, 35, 36, 47, 48, 63, 64, 65, 66,
69, 72 (its E bullets).

### Round order

**Round 1 — independent; all five lanes in parallel.**
A: 1, 29, 13, 8, 20, 21, 59, 61, 72(A). B: 5, 12, 25, 26, 27, 28, 50–56, 72(B), and the
`load()`-returning API that item 3 needs. C: 6, 7, 9, 10, 11, 57, 58, 62, 70(C), 71, 72(C).
D: 16, 17, 22, 23, 24, 33, 34, 38–46, 67. E: 18, 30, 31, 32, 35, 36, 47, 48, 63–66, 69.

**Round 2 — preconditions from round 1.**
- Item 3's call sites (A, D, E) need B's round-1 `Result` API. **This is the only hard
  cross-lane dependency and it gates the three blockers' seam.**
- Item 4 (import guard) needs item 3.
- Item 14 (`rebuildAccountSurfaces`) needs item 1 — until the memo is shared there is
  nothing coherent to rebuild from.
- Item 15 needs item 13.
- Item 19's two halves (B's `schema=full`, E's before/after score spread) must land together
  or the measurement is meaningless; item 49 lands with them.
- Item 68 is written in B and called from E.

**Round 3 — after a decision or a measurement (section 6).**
C: item 60 (project.yml test bundle — keep it out of round 1 so item 62's `project.yml`
edit lands alone and is reviewable), and W6's `TranslationGap` delete once Abdi decides.
D: item 39's automatic-retry half. B/E: item 19 if the payload measurement allows it.

**Rule for the whole run:** no lane builds. Agents write code and tests; compile once per
round. `project.yml` is Lane C's alone in every round — a second writer means
`xcodegen generate` silently reverts someone.

---

## 5. What the second pass says about the first

Blunt, because this is the section that changes how we work.

**C1 — "the wiring half of a two-half change is nobody's file" is not gone. It is now the
dominant failure mode, and it has a name: inert.** Pass 1 filed C1 as a cluster of
*omissions*. Pass 2 found the same shape in the *fixes written to close it*:
`reschedule(isComplete:)` has the parameter, the guard and a doc comment promising the
behaviour, and one caller that never passes it (item 8). `TasteRanker` has a scorer, a
ledger, a reason line and a `forgetPreviousAccount` clear, over a feed that carries no tags
(item 19). `LossyArray` has a counter, and a comment explaining why a counter beats a log
line, and no screen (item 20). `CommunityPulseService`'s backoff was *recorded as folded in*
and never written (item 9). Twelve of 72 work items are of this kind. An agent that cannot
run the app writes the mechanism and asserts the reachability.

**C2 — "one flag carries three states" moved rather than died.** It is genuinely fixed
where pass 1 named it: cadence, Mix and Discover all drop `.cancelled` correctly, and
Discover's cancelled-load accounting is the one combination that avoids both the permanent
skeleton and the four-request re-ask. It is alive on every screen pass 1 did not name —
categories, cast and the volumes shelf (item 30), the seed picker (17), the publisher
browser (16), `staleFailure` (40). The fix was applied per-site from a list, and the list
was the list of findings.

**C3 — moved, and two reports independently caught it moving.** The account-change list was
fixed at source (the snapshot refuses without a credential), which is the right shape. But
persistence found the *same pattern one layer down*: the ledger's own forget list now exists
three times (`v11`'s DELETE, `clear()`, `salvage`'s `readerTables`) and they already
disagree (item 12). And shell found it had moved *sideways*: sign-out clears ten things,
sign-in rebuilds none (item 14). One hand-maintained list became three.

**C4 — the only cause genuinely improved.** `ThirdPartySession`, one `RequestSpacing`, one
`backOff(retryAfterHeader:)`: eight clients, one rule, with the measurement attached. That
is real. What remains is that *membership in the layer is still checked by hand*: one of ten
429 sites missed (item 7), the widget extension outside the seam entirely (item 6),
`CharacterProfileView` building its own actors (item 63), `ReleaseScheduleService` still
defaulting to a second client (item 71). The abstraction exists; nothing enumerates its
members.

**C5 — half gone, half reproduced one screen deeper.** `WidgetSnapshot`'s reload gating,
`SeriesPager`'s `init` seeding and `ScrollTracker`'s extraction are correct and well argued.
Then `CoverGallery` reinvented the per-frame `@State` at the root of a body containing two
1000 pt backdrops (item 64), `ScrollTracker` itself animates a continuous value per frame
(65), `ScheduleModel` allocates the per-body formatter `DiscoverModel` was just told to hoist
(46), and `TasteProfile.note` still reads the whole library to find one row (68).

**What this says about fixes written by agents that cannot run the app.**

1. **Reachability is the thing they cannot check, and it is the thing that matters.** Every
   inert finding has a correct mechanism. Not one was a coding error.
2. **The `#if DEBUG`-shaped blind spot is the most dangerous class.** `MB_PAT` in
   `Secrets.xcconfig` authenticated every walk, every screenshot and every agent's mental
   model, and hid a defect (item 1) that makes a real install unable to accept a token *and*
   blame the reader for it. Nine slices in pass 1 and five in pass 2 all missed it until
   someone traced three constructor call sites. **Anything that differs between Debug and
   Release must be verified in Release at least once per batch.**
3. **A fix that adds a parameter, a counter or a field must land its consumer in the same
   diff, or be rejected.** Items 8, 9, 19, 20, 31 are all "the producer shipped, the consumer
   did not". This is mechanically checkable: grep the new symbol; if it has one write site
   and no read site, it is not done.
4. **A comment promising behaviour is now evidence *against* the behaviour existing.** Items
   8, 19, 20, 50, 56 and 70 are all cases where the comment was the only reason anyone
   believed the mechanism worked — and the comment was written by the agent that wrote the
   mechanism. The reports found these *because* the comments were precise enough to check,
   which is an argument for keeping the standard, not relaxing it.
5. **Fixes applied per-site from a findings list will always be n−1 complete.** Items 7, 11,
   16, 17, 22, 30, 33, 34, 39, 44 are all "the same rule, applied where it was filed and
   nowhere else". The fix for this is not more diligence; it is to make the site
   enumerable — one function all nine call, one component all screens mount.
6. **Tests written alongside a fix assert the fix's shape, not its effect.**
   `TokenStoreCacheTests` uses one instance and is green over item 1. `WidgetSnapshotTests`
   asserts `due` is *absent*. `AppShellRoundThreeTests` claims a kill criterion that is false
   for two of five lines. `PublisherPageTests` pins a duplicate request as source text. Three
   of those tests were *written yesterday, to guard yesterday's fix*.
7. **Two correct fixes composed by two agents who never met produce a third bug.** Items 2,
   3+4+5, 16. Nobody owns the composition. That is what the round order in section 4 is for.

---

## 6. Needs Abdi — product calls, each with a recommendation

1. **Distribution.** Is this going to the App Store, or is it personal like the last project?
   It decides whether item 62 is urgent, whether licences and privacy manifests are real, and
   whether "no reader can add an account" (item 1) is a P0 or an inconvenience.
   *Recommendation:* answer this first; everything below inherits it.
2. **The translation gap (wire W6).** Naver's adapter is gone, so `ReleaseFeedService`'s
   `naver` branch is unreachable, `TranslationGap` is permanently `.none`, 80 lines plus UI
   are maintained for nothing, and ~12 green tests assert a provider configuration production
   does not have. Is the gap coming back from a permitted source (MangaBaka's own
   `/v1/series/{id}` carries the original's chapter count), or is it gone?
   *Recommendation:* gone. Delete the branch, `TranslationGap`, `ReleaseSource.naverWebtoon`,
   `ReleaseFeed.totalCount`/`.finished` and the twelve tests. Either way, fix
   `ReleaseFeedProvider.swift:32-35` today — a protocol doc naming a deleted conformer is
   free to correct.
3. **Version string (item 62).** Before the fix: read build 64's build string in App Store
   Connect → TestFlight. If it reads `1`, the next upload is refused as a duplicate and this
   is urgent; if it reads `64`, something outside this tree is setting it and the fix is right
   but not urgent. *Recommendation:* fix `project.yml` either way; it costs two lines.
4. **`schema=full` on the mix feed (item 19).** A working taste ranker costs a larger payload
   on the app's most frequent feed call. *Recommendation:* measure first — one `curl` to
   `/v2/series/mix?...&limit=50` with and without `&schema=full`, compare `Content-Length`.
   If the delta is under ~2×, enable it; if not, delete the `ranker.rank` call and say so in
   a comment, rather than leaving a feature that looks alive.
5. **Discover's automatic retry (item 39).** `StaleBar(deadline:)` fires `retry` at zero.
   Discover's retry is four requests, two from the 30/min family. Search took the automatic
   retry; Discover has not. *Recommendation:* yes — the bar's own manual Retry already does
   the same four, so the only change is who taps it. (`ScheduleView` correctly withholds it:
   its retry is the 13-request, ~25 MB library walk. That reason is right and is written
   nowhere; write it at `ScheduleView.swift:65`.)
6. **Deferred notifications with a shelf life (reader F5).** `place` walks up to 14 days
   forward and nothing revisits the decision, so "Ep. 12 is out" can arrive when the reader
   can see episode 15 — and because the baseline moves at scheduling time, 13, 14 and 15 each
   get their own slot, dripping stale announcements. *Recommendation:* defer only condition 2
   (a completed series is a fact that does not move) and never condition 1b; it is the
   smaller change and the honest one. State the choice in the comment either way.
7. **The 180/min general cap (wire W8).** The app now refuses its own 181st general request
   in a rolling minute, `.userInitiated` included, against a number nobody has measured
   against real traffic (U9). A legitimate cold launch crossing it gives the reader
   "Too many requests" on a screen they just opened, indistinguishable from MangaBaka being
   down. *Recommendation:* make a `.userInitiated` general request that would be the 181st
   *wait* for the oldest timestamp's expiry rather than throw — the wait is bounded under
   60 s by definition and the deadline is already computed at `RateLimitGate.swift:201`.
   Record the decision; this will be re-proposed otherwise.

---

## 7. Could not determine

### Needs a device or a simulator run

| Question | The one measurement |
|---|---|
| **Does item 1 actually reject a pasted token on a real install?** The single most valuable measurement in this pass. | One Release run (or Debug with `Secrets.xcconfig` moved aside) on a fresh simulator: finish onboarding, paste a valid token, read the card. Expect "Token rejected" and an empty Keychain. |
| Does the deep-link task really cancel itself (item 2)? | `print(Task.isCancelled)` at `RootView+Session.swift:307`, then Siri "Open &lt;a series not in the library&gt;". Expect `true`. |
| Does `.task(id:)` re-fire on pop-back and on `fullScreenCover` dismissal in this stack? (Items 32, 33, 34, and the severity of 30.) | `print("load", series.id)` at the top of `SeriesDetailView.load()`; one related-cover tap, one back. Expect two lines. One line withdraws 32/33/34. |
| Does `didFinishCollecting` precede `data(for:delegate:)` returning? (The cache-refund fix's own unsure.) | One `print` in each, one request, read the console order. |
| Does the hero's form visibly change after `extras` lands (item 66)? | One Discover-opened series with a two-line title and a known chapter count; screenshot at t=0 and t=2 s. |
| Does a `Countdown` past its deadline retry (item 18)? | A `StaleBar` given `deadline: .now - 1` in a preview. Expect no retry today. |
| How long does the one-time split take on a real pre-split install? It runs synchronously in `AppServices.init` over 945 + 939 rows and ~25 MB. | `Signposts.measure` around `splitReaderTables`, one launch on a restored pre-split `mangabaka.sqlite`. >200 ms is a visible launch hang. |
| Does `.localCache` cover a URLCache *revalidation* (wire W9)? If it does, the refund hands back slots for requests the server counted. | Two `CachingStubProtocol` loads to one URL, `max-age=1`, 2 s apart, the second answered 304; print `resourceFetchType` and `requestStartDate`. No live request; the fixture already has everything. |
| The exact cloud/local test-count gap (item 60). | `xcodebuild test -resultBundlePath`, then `xcrun xcresulttool get test-results tests` filtered for Skipped, under `TZ=UTC` with the source tree renamed aside. The 165 is a regex. |

### Needs a curl

| Question | The one request |
|---|---|
| Does MangaBaka's cover CDN 403 an agentless client (item 6)? | `curl -sI` one `cdn.mangabaka.dev` cover URL with and without `-A`. Compare status. |
| What does `schema=full` cost on `/v2/series/mix` (item 19, decision 4)? | The same query with and without `&schema=full`; compare `Content-Length`. Two requests. |
| Can MangaBaka's write API set `startDate`, `finishDate` or `numberOfRereads`? `LibraryExport` writes all three and `LibraryImport` restores none, so every restore is silently partial. | One PATCH to `/v1/my/library/&lt;id&gt;` with `{"start_date": "2026-01-01"}` on a throwaway entry; read the response back. |
| Is 180/min ever approached on a real cold launch (U9, decision 7)? | `NetworkLedger.shared.byPath` totals bucketed per minute across one cold launch on the 937-series reference account. One launch and a `print`. |
| Does the `OfflineIndex` generator emit a null/NaN rating, and does `OfflineEmbeddings.bin`'s header ever disagree with its size? (Items 52, 53.) | Not a curl — read `Scripts/`, or `zcat OfflineIndex.json.gz \| jq '[.series[].r] \| map(select(. == null)) \| length'`. |

### Needs Instruments

| Question | The one measurement |
|---|---|
| Does `CoverStore` actually evict mid-scroll, i.e. is item 50 costing refetches? | `NSCacheDelegate.cache(_:willEvictObject:)` logged during one 60-cover Discover fling. Evictions > 0 on a single screen confirms it. |
| What do the per-frame body re-evaluations cost (items 64, 65)? U7, still open. | One Instruments trace of a `CoverGallery` swipe and a detail-page scroll, before and after the child-view split. |
| How much memory does item 47 actually hold? | Memory graph after a 513-row fling, with and without the cancellation guard. Item 33's ~70 MB is the ceiling, not a measurement. |
| Does `repository.feed` ever return without suspending (decides whether item 48's second half is live)? | A test stubbing the repository to return synchronously, cancelling the refill, asserting `queue.isEmpty` after `resetStack`. |
