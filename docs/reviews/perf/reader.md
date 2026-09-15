# Reader slice — perf review, 2026-09-15, HEAD 1f5e632

Read-only. Slice: `Core/Library/**` (minus `LibrarySnapshot.swift`), `Core/Schedule/**`, `Core/Notifications/**`. Read outside the slice only to state a trigger or an impact (`App/RootView+Session.swift`, `App/RootView+Tabs.swift`, `Features/Library/ReadingInsightsView.swift`, `Features/Library/WrappedView.swift`, `Features/Detail/SeriesDetailView+Releases.swift`, `Features/Detail/SeriesDetailView.swift:699-715`, `Features/Library/LibraryView.swift:120-133`, `Core/Persistence/SeriesRepository.swift:877-884`, `Core/Networking/APIClient.swift:392-410`, the four captured fixtures under `MangaBakaTests/Fixtures/`).

**Summary**
- Files: 24 of 41 read in full, 6 skimmed (`LibraryService`, `LibraryImport`, `LibraryExport`, `WidgetSnapshot`, `WebtoonsFeed`, `WebtoonsEpisode`), 7 not read (`OriginalRun`, `UpcomingWork`, `MangaUpdatesCategories`, `MangaUpdatesID`, `ReleaseSource`, `OwnedSummary`, `LibrarySnapshotResult`).
- Findings: 21 — 13 certain, 5 likely, 3 worth checking.
- Highest-value change: **P1** — today's "back from hiatus" notification cannot fire for any series that *enters* hiatus after the reader first ran the feature, because the status baseline only ever advances when a `finished-` notification is sent (`ReleaseReminders.swift:263-265`). One function fixes it and P2 with it.
- Second: **P4/P5** — `refreshReminders` spends up to 6 MangaBaka requests and one search request per followed publisher, at launch, on results `NotificationPolicy.decide` throws away.
- Third: **P7** — a settled cadence row is never re-measured from the series page, so "N days late" on the hero grows forever for a reader who does not use the Schedule tab's refresh.

## Findings

### P1. The status baseline never records a non-notifying transition, so "back from hiatus" is inert for the common case
- **What** — `performReschedule` only advances `seriesStatus` for a series whose `finished-` notification was just sent. A series that goes `releasing → hiatus` produces no candidate, so its baseline stays `releasing`; when it later returns, 2d needs `previous == "hiatus"` and never sees it.
- **Where** — `ReleaseReminders.swift:263-265` (the only status write), `:444-449` (`seedFirstSeenBaselines` refuses to overwrite an existing baseline), `NotificationPolicy.swift:157-158` (the check). The design comment at `ReleaseReminders.swift:225-232` explains why an existing baseline is left alone for a *blocked* candidate; it does not consider a transition that produces no candidate at all.
- **Why it matters** — the rule Abdi wrote today only works for series already on hiatus the first time the feature ran. Every hiatus that begins afterwards returns silently. Trace: launch 1 status `releasing` → baseline `releasing`; launch 2 `hiatus` → no candidate, baseline untouched; launch 3 `releasing` → `previous` is `releasing`, 2d false. Every test in `ReminderPacingTests.swift:33-35,106-109` and `NotificationPolicyTests.swift:100-128` starts the series on hiatus at first sighting — charter §2, the tests agree with the bug.
- **Effort** — a function: after `applyFatigueGuard`, set `updatedStatus[id] = status` for every library series with **no** candidate this pass (a transition nobody will be told about is safe to record immediately); keep the existing "advance only on send" rule for series with a held-back candidate. Plus one test: `releasing → hiatus → releasing` across three passes expects one `back-`.
- **Confidence** — certain.

### P2. A sent "back" notification never advances the baseline, so it repeats on day 61
- **What** — the send loop updates status only for ids prefixed `finished-`; a `back-<id>` send leaves the baseline at `hiatus`. Every later pass re-plans `back-<id>`, blocked only by `fired[id]`, which `pruned` drops after 60 days.
- **Where** — `ReleaseReminders.swift:263` (`hasPrefix("finished-")`), `:361-367` (60-day prune), `NotificationPolicy.swift:157-166`.
- **Why it matters** — "X is back" arrives twice, two months apart, for a series whose status did not change in between. Also the `release-feed-` branch at `:266-267` is dead since 1b was deleted today.
- **Effort** — a line: `if item.id.hasPrefix("finished-") || item.id.hasPrefix("back-")`. Subsumed by P1's fix.
- **Confidence** — certain.

### P3. Dead parameters and a dead baseline left by today's rewrite
- **What** — `announced` and `lastKnownEpisode` are still threaded through `decide`, `reschedule`, `performReschedule` and discarded at `NotificationPolicy.swift:111`; `notifiable` is computed over the whole library at `:106-108` and discarded; `title(for:in:fallback:)` at `:205-208` has no caller; the episode baseline (`knownEpisode`, `episodeKey`, seeding at `ReleaseReminders.swift:451-456`, the `release-feed-` branch at `:266`) is written every pass and read by nothing. `UpcomingWork.localDay` keeps one live caller (`AppIntents.swift:165`) so it stays.
- **Where** — as listed; also `RootView+Session.swift:396` still awaits `calendar.mine` to fill the dead parameter (see P4).
- **Why it matters** — a reader of `decide`'s signature is told two facts feed it that do not; the `_ = (…)` line is the tell. The comment at `:109-110` ("so the callers and their tests read unchanged") is a reason to keep test churn down, not a reason to keep a launch-path request (P4).
- **Effort** — a function: drop both parameters, the episode baseline and its key (leave a one-line tombstone naming the `UserDefaults` key so a future restore knows old installs carry it), fix the 23 test call sites mechanically.
- **Confidence** — certain.

### P4. Launch fetches up to six pages of `/v1/works/upcoming` for a value nothing reads
- **What** — `refreshReminders` awaits `calendar.mine(seriesIDs:)` → `upcoming()` → up to `pages = 6` `.userInitiated` requests (246 works ≈ 5 pages at 50), cached in memory for 6 h only, then passes the result as `announced`, which `decide` discards.
- **Where** — `RootView+Session.swift:396`, `ReleaseCalendar.swift:24-25,69-92`, `NotificationPolicy.swift:111`.
- **Why it matters** — 5–6 general-window requests on every cold launch (reminders on), serialised *ahead of* Spotlight, the widget write and `session.library.load()` (`RootView+Session.swift:250-320`), and again on the first foreground after 6 h. They compete with Discover's first paint for the same 180/min window. The Schedule tab fetches the same list itself when opened (`ScheduleModel.swift:376`), which is the right moment.
- **Effort** — a line: delete `:396` and the `announced:` argument (P3).
- **Confidence** — certain.

### P5. Launch spends one *search* request per followed publisher for a notification that does not exist
- **What** — `publisherFollows.check(using:)` runs inside `refreshReminders`, one `SearchQuery` per follow due today, `.background`, and its `updates` are discarded; no `notify` closure is passed.
- **Where** — `RootView+Session.swift:400`, `PublisherFollows.swift:101-150` (`let result = await repository.search(query, priority: .background)`), `:44` (the daily throttle comment says each spends the 30/min search budget).
- **Why it matters** — search is the 30/min family. `.background` *waits* for a slot, so with N follows due, `startSession` is held for N search slots before the widget and Spotlight are rebuilt — and if the reader is typing in Search at the same moment, the follow checks and the keystrokes drain one window. `lastSeenSeriesID` is maintained for a feature deleted on 2026-09-13 (`ReleaseReminders.swift:20-25`). Charter §3.
- **Effort** — a line to remove the call; or, if the follow list is to notify one day, move the check off the launch path to the Settings section that shows it.
- **Confidence** — certain that it runs and is discarded; the contention with typing is by reading `RateLimitGate`'s documented behaviour, not measured.

### P6. `favouredTagIDs` caches a failed `top-genres` answer for the whole session, and the endpoint is asked twice
- **What** — `buildIDs` unions the ledger ids with `library.topGenres()`, which is `try?` → `nil` → `[]` on any failure (`LibraryService.swift:436-441`), and the union is cached unconditionally at `TasteProfile.swift:88`. `favouredTagNames` asks the same endpoint separately at `:53` and, correctly, does not cache nil.
- **Where** — `TasteProfile.swift:83-90,112-113`; `LibraryService.swift:437`. Trigger: `RootView+Tabs.swift:164` (`taste.ranker()` at launch) and `SeriesDetailView.swift:703,713` (first page open).
- **Why it matters** — a 429 or offline moment at launch drops the genre half of the profile for the rest of the session with nothing logged; and the same endpoint is requested twice per session where one would do. `APIClient.getResults` has no cache (`APIClient.swift:392-410`).
- **Effort** — a function: fetch `topGenres` once, share it between the two entry points, and cache `cachedIDs` only when the fetch succeeded (mirror `:60`).
- **Confidence** — certain.

### P7. A settled cadence is never re-measured from the series page
- **What** — `cadence(for:)` returns any cached row with `failure == nil` regardless of `fetchedAt`; only `build(refresh: true)` (the Schedule tab's refresh button, `ScheduleView.swift:151`) re-measures. `staleAfter` (14 days) is consulted only to *count* stale rows for the Schedule header.
- **Where** — `ReleaseSchedule.swift:439-441` (no age check), `:102` (`staleAfter`), `:244` (count only), `Cadence.swift:73-76` (`overdueDays` grows from a stored `due`).
- **Why it matters** — the hero reads "next chapter — 47 days late, likely" for a weekly series that shipped yesterday, to any reader who does not open the Schedule tab and tap refresh. The claim is wrong in the direction the doc comment at `Cadence.swift:41-54` says is worst.
- **Effort** — a function: `if now - row.fetchedAt > staleAfter` treat as pending and re-ask (one 3 s-spaced MangaUpdates request per stale series, at most once a fortnight), and show the stale row meanwhile.
- **Confidence** — certain by reading; not reproduced on a device.

### P8. A finale without a season number is discarded, and the section then says "overdue"
- **What** — `ReleaseFeed.endedSeason` returns `finale.season`, which is nil when the title carries no "Season N". `summarise` and `NotificationPolicy` both `guard let` it, so a detected finale with no season number is treated as no finale.
- **Where** — `WebtoonsFeed.swift:107-112`, `ReleaseSummary.swift:78-80`, `NotificationPolicy.swift:171-172`. `ReleaseSummary.seasonEnded(season: Int?, …)` and `ReleaseSection.seasonEndedLine(season: Int?)` (`ReleaseSection.swift:167`) already accept nil — the type was designed for it and the producer never supplies it.
- **Why it matters** — "Ep. 120 (Final Episode)" falls through to `Cadence.estimate` and renders as a rhythm that is now late — the exact opposite claim `ReleaseSummary.swift:24-27` says must not be made — and the "season ended" notification (Abdi's condition 2) cannot fire for it. Charter §3.
- **Effort** — a function: return an `(season: Int?, on: Date)?` (or a `finaleAt: Date?` beside `endedSeason`), and let 2b key its id on the date when there is no number.
- **Confidence** — likely (no live title without a season number captured; `docs/reviews/reader.md` §11 recorded finale wording without one on 2026-09-13).

### P9. `on_hiatus` is a hiatus everywhere except the notification
- **What** — 2d requires `previous == "hiatus"`; `ReleaseScheduleService.isPaused` accepts `["hiatus", "on_hiatus"]` and `SeriesStatus.names` carries `on_hiatus` because the series page once printed "On_hiatus".
- **Where** — `NotificationPolicy.swift:158`; `ReleaseSchedule.swift:174-176`; `SeriesStatus.swift:13`.
- **Why it matters** — a series the API reports as `on_hiatus` never triggers "is back". Also 2a compares `== "completed"` case-sensitively while `isBack` lowercases (`:139,202`).
- **Effort** — a line: reuse `ReleaseScheduleService.isPaused(status:)` and lowercase both.
- **Confidence** — likely (that the API sends `on_hiatus` today is inferred from the comment, not from a fixture; the four captured fixtures all say `releasing`/`completed`).

### P10. `hasAnythingToSay` re-runs three full library passes inside `body`
- **What** — `ReadingInsights.hasAnythingToSay` calls `waiting`, `nearlyFinished` and `verdicts` (each a filter + sort over 945 entries; `verdicts` builds a per-tag dictionary over every tag of every read series), and `ReadingInsightsView` calls it in `body`, after `recompute()` has already produced the same three results off the main actor.
- **Where** — `ReadingInsights.swift:89-95`; `ReadingInsightsView.swift:87` (in `body`), `:130-143` (the detached compute the view already has).
- **Why it matters** — the comment at `:129` says the work is "tens of milliseconds on a real library" and puts it off-main on purpose; `body` then does it again on the main actor on every re-evaluation (scroll-driven `StaleBar` changes, `revision` bumps). A frame is 16.7 ms.
- **Effort** — a line: `derived.waiting.isEmpty && derived.nearly.isEmpty && derived.verdicts.isEmpty && derived.chapters == 0`.
- **Confidence** — certain that it runs in `body`; the ms cost is the file's own number, not re-measured.

### P11. Continuations fire up to eight `.userInitiated` requests on the Library tab, ignoring the disk cache the detail page already fills
- **What** — `SeriesRepository.relationships(for:)` uses an in-memory `BoundedCache` and the client's default `.userInitiated` priority; the same endpoint is one of the six `extras` legs cached to disk for 6 h, which this path never reads.
- **Where** — `Continuations.swift:135-149` (sequential loop), `SeriesRepository.swift:877-884`, trigger `LibraryView.swift:129-131`.
- **Why it matters** — up to 8 foreground-priority requests when the Library tab first settles, for a row below the list; a series whose page was opened an hour ago is asked again. A tap on a library row during that second competes with them for the 60-slot reserve.
- **Effort** — a function: read `readDetailCache(seriesId)?.relationships` first; pass `.background` (the row already has `hasFailure`/Retry, so waiting costs nothing visible).
- **Confidence** — certain for the priority (per `detail-page-budget.md` §1, nothing overrides the default); likely for the cache miss (not traced into `readDetailCache`).

### P12. `WebtoonsFeedClient.cachedFeed` probes the disk for any linked series, not Webtoons ones
- **What** — `cachedFeed` guards on `links.contains { $0.safeURL != nil }` and then reads `v4-<id>.json`; `feed(for:)` filters with `WebtoonsFeedParser.isWebtoons` first.
- **Where** — `WebtoonsFeedClient.swift:42-45` vs `:60`.
- **Why it matters** — in `cachedFeeds` (launch, per library entry with cached links) every non-Webtoons series with any link costs a failed `Data(contentsOf:)` on the actor, serially (`ReleaseFeedService.swift:148-157`). Bounded by the 6 h extras cache (≤200 rows), so small — but it is the same guard written two ways.
- **Effort** — a line.
- **Confidence** — certain.

### P13. `GigaViewerFeedClient.cachedFeed` decodes the whole magazine file once per series
- **Where** — `GigaViewerFeedClient.swift:60-64,194-197`; called per entry from `ReleaseFeedService.swift:151-152`.
- **Why it matters** — ten Jump+ series in the library is ten decodes of the same 100-item JSON at launch. Small today; it scales with the reader's Japanese shelf, not with the cache.
- **Effort** — a function: memoise by host for the duration of one `cachedFeeds` pass.
- **Confidence** — certain; cost unmeasured.

### P14. `ReleaseReminders` rewrites eight `UserDefaults` dictionaries every pass, three of them before knowing whether anything changed
- **Where** — `ReleaseReminders.swift:449,461-462` (seed writes, unconditional), `:272-276` (five more). `encodeIntKeys` builds a 945-entry `[String: String]` for the status map each time.
- **Why it matters** — on the launch path, on the main actor. Milliseconds, not frames — flagged because the file's own comment (`:235-238`) already paid for reading `fired` once and then writes it back plus seven siblings.
- **Effort** — a function: write only the maps that changed.
- **Confidence** — certain that it writes; cost is a guess (not measured).

### P15. `seriesLastNotified` still uses the all-or-nothing cast that item 36 fixed for `fired`
- **Where** — `ReleaseReminders.swift:421` (`as? [String: Date]`) vs `:417` (`compactMapValues`).
- **Why it matters** — one non-`Date` value reads the cooldown ledger as empty, and the same-series guard is off for every series. Only this file writes the key, so unlikely in practice; it is the sibling of a bug that did ship.
- **Effort** — a line.
- **Confidence** — likely.

### P16. `LibraryExport.json` writes an empty backup on an encode failure
- **Where** — `LibraryExport.swift:122` (`(try? dateEncoder.encode(envelope)) ?? Data()`).
- **Why it matters** — the reader shares a 0-byte file and finds out on restore. Synthesized `Codable` over these types has no realistic failure today, which is why it is P16 and not P1 — but a silent empty backup is the worst shape a failure can take.
- **Effort** — a line: throw, and let the share sheet's caller show the failure it already handles for CSV.
- **Confidence** — worth checking (whether the caller has a failure path).

### P17. `ReadingWrapped.decades` is tested and never presented
- **Where** — `ReadingWrappedYear.swift:226-232`; callers: `ReadingWrappedTests.swift:177,201` only; `WrappedView.swift:180-190` builds every other slice.
- **Why it matters** — charter §7. Either a card was planned and dropped, or the function is dead; the tests keep it looking alive.
- **Effort** — a line to delete, or a card.
- **Confidence** — certain.

### P18. `OwnedVolumes.rowIdentity(of:)` has no caller after today's `ndl:` change
- **Where** — `OwnedVolumes+Reconcile.swift:50-52`; `orphanIdentities` at `:58-63` builds the key itself. No test references it.
- **Effort** — a line.
- **Confidence** — certain.

### P19. Thresholds not labelled as guesses
- `ReadingInsights.swift:58` `within: 12` ("how close to the end still counts as nearly") — no derivation, no label. `:191` `minimum: 3` and `:240` `>= 10` have a sentence of reasoning but not the word. `:36` `minimum: 2` is reasoned ("a weekly series is one behind six days out of seven") — fine.
- `TasteLedger.swift:41-48,61-68` weights 4/3/2/1 and 3/2/1 — the API's own importance ranking justifies the *order*, nothing justifies the *ratio*; `TasteRanker.swift:8,53` says its 0.7 is "taken as-is", which is honest.
- `TasteLedger.swift:171` `seriesCount >= 2` and `:162` `limit = 30`, `TasteProfile.swift:119-123` `60` — reasoned, unlabelled.
- Everything in `Cadence`, `SeasonReading`, `ReleaseSummary`, `WebtoonsFeed`, `ReadingWrapped`, `ReadingTime`, `WidgetSnapshot+NextVolume`, `ReleaseReminders`, `ReleaseCalendar`, `MangaUpdatesCategories` is labelled. That is most of the slice.
- **Effort** — a line each. **Confidence** — certain.

### P20. Silent `try?` where one line would make the failure findable
- `WebtoonsFeedClient.swift:128` — `session.data(from:)` failure becomes `"Webtoons request failed."`; the `URLError` (offline vs DNS vs timeout) is dropped, unlike `MangaUpdatesClient.swift:132-140`, which keeps it and maps offline. `:206-209` — a HEAD that fails for any reason is reported as `"No usable Webtoons feed URL."`, which is a different diagnosis.
- `GigaViewerFeedClient.swift:138` — same shape.
- `ReleaseSchedule.swift:385,397,446,465` — a cadence write that throws is invisible, and every open re-asks MangaUpdates (3 s spaced). Already in `open-items-2026-09-15.md` as "throwing-database test"; still true at these lines, no log either.
- `TasteProfile.swift:109,112,146` — an `absorb` that throws makes the profile silently "likes nothing"; the only logger in this slice is `:200-202` and it covers `clear()` alone.
- `LiveNotificationCentre.add`, `ReleaseReminders.swift:538` — iOS refusing a request (past trigger, >64 pending) is swallowed and `fired` records it as sent (`:251`). The doc at `:488-493` describes this exact failure having happened.
- `SpotlightIndex.swift:48,50`, `WidgetSnapshot.swift:200-201,227-228`, `PublisherFollows.swift:151-162` — index/file writes.
- **Effort** — a `Logger` per file (five files have none) and one `.error` line at each site; a function total.
- **Confidence** — certain.

### P21. `LibraryImport` still sends two requests per new row behind one sleep
- **Where** — `LibraryImport.swift:459-466` (`add` then `update`), `:481` (one sleep per row), `:472-474` (a `.rateLimited` throw counts as a failure and the loop continues at 2/s).
- **Why it matters** — item 37, still true at these lines: a 939-row restore of a fresh account runs at up to ~240/min against 180, and once the window is full every remaining row is recorded as failed in seconds with no resume point.
- **Effort** — a function. **Confidence** — certain.

## Requests in flight (this slice)

| Call | Trigger | Priority | Awaited before draw? | Could be |
|---|---|---|---|---|
| `/v1/works/upcoming` ×≤6 (`ReleaseCalendar.swift:83`) | launch + every foreground after 6 h, via `refreshReminders` | `.userInitiated` | No screen waits, but Spotlight/widget/`session.library.load` queue behind it | **Dropped** from launch (P4); Schedule tab already fetches it |
| `/v1/series/search` ×N follows (`PublisherFollows.swift:126`) | same | `.background` (search family, 30/min) | same | **Dropped** (P5) or moved to Settings |
| `/v1/my/series/discover/top-genres` ×2 (`LibraryService.swift:437`) | launch (`RootView+Tabs.swift:164`) and first series page (`SeriesDetailView.swift:703`) | `.userInitiated` | Stack ranker waits; page tags render unsorted meanwhile | **Merged** to one (P6) |
| `/v1/series/{id}/relationships` ×≤8 (`Continuations.swift:143`) | Library tab, once the walk settles | `.userInitiated` | No (row fills later) | `.background` + read detail cache (P11) |
| MangaUpdates `releases/search` (`MangaUpdatesClient.swift:112`) | series page (`loadCadence`), 3 s spaced; Schedule build ×55 | n/a (own spacer) | No — hero spinner | Later: never re-asked when stale (P7 is the opposite problem) |
| MangaUpdates `series/{n}` (`:192`) | series page categories, 7-day disk cache | n/a | No | fine |
| Webtoons HEAD + GET (`WebtoonsFeedClient.swift:206,128`) | series page, after `extras`, 7-day cache; 3.5 s spacer each, so a placeholder link is ≥3.5 s + ≥3.5 s | n/a | No — section skeleton | fine; repeats per open only on cache miss. Item 32 (`.task(id:)` re-run on pop-back) not re-checked here |
| GigaViewer `/rss` (`GigaViewerFeedClient.swift:138`) | series page, 24 h per-host cache | n/a | No | fine |
| `/v1/tags` ×≤3 (`LibraryService.swift:382`) | Stack (`StackModel.swift:607`), cached per rating set | `.userInitiated` | not traced | not reviewed |
| `/v1/my/library` pages | shared walk (`LibrarySnapshot`, excluded) | — | — | — |

Nothing in this slice fires per keystroke. Nothing sends reader data anywhere (all three feed clients read; `PublisherFollows` sends a publisher name to MangaBaka's own search).

## Main thread & rendering
- `ReadingInsightsView.swift:87` — three library passes in `body` (P10).
- `ReleaseReminders.performReschedule` — `@MainActor`; per pass: five `UserDefaults` dictionary decodes, `decide` over 945 entries (cheap), eight dictionary writes (P14). `applyFatigueGuard` sorts candidates — a handful.
- `SpotlightIndex.reindex` — detached, `.utility`, measured 84 ms (`:42-44`). Good.
- `ReadingInsightsView.recompute` / `WrappedView.compute` — detached. Good.
- `WidgetSnapshot.write` — on the caller's actor (main, from `startSession`): read file, encode, write, compare three arrays. Small.
- `TasteLedger.absorb(_ entries:)` — 945 `TasteSeen` saves + 945 `TasteSource` selects per call (`:110,114`), on the ledger actor, once per launch via `ranker()`. Off main; ~tens of ms by the file's own 517 ms/200-series figure for the *old* path.

## Rate-limit invisibility
What exists: `ReleaseSection` shows `InlineFailure` per failed source and keeps the cadence estimate as fallback (`ReleaseFeedProvider.swift:50-53`); `DetailScheduleBlock` separates `.failed` from `.none` (`ReleaseSchedule.swift:412-421`); `ReadingInsightsView` has a `StaleBar` for a partial walk; `ScheduleSnapshot` returns whatever is measured and never blocks (`:197-200`).

What is missing, specific to this slice:
- **The cadence row has no "here is what we had".** `cadence(for:)` returns `.failed(error)` on a MangaUpdates 429 even when a stale settled row exists (`ReleaseSchedule.swift:439-441` skips rows with `failure != nil`, and a 429 *writes* a failure row at `:465`, overwriting the last good cadence). Keep the payload on a failure write (`payload = excluded.payload` only when non-nil) and return `.measured(stale)` with an age; the hero then reads "about every 7 days · measured 3 weeks ago" instead of a red line.
- **The Releases section is loaded after `extras`** (`SeriesDetailView+Releases.swift:12-19`), and `extras` is the leg most likely to be the 429 (`detail-page-budget.md` §3). When `extras` fails, Releases never asks — so the section's absence is silent. Show the section's skeleton with "waiting for links" rather than nothing, or read links from the 6 h cache when `extras` is throttled.
- **Reminders are silent on a throttled walk** by design (`ReleaseReminders.swift:209`) — correct, nothing to show.
- **Continuations** already have `hasFailure` + Retry; at `.background` (P11) a throttle would simply delay the row, which is the invisible outcome wanted.
- **Taste profile**: on a throttled `top-genres` the page's tags render in API order with no hint (P6). Acceptable — but do not cache the miss.

## Debuggability
- **A wrong "fastest finish" cannot be traced.** `fastestFinish` is pure and unlogged (`ReadingWrappedYear.swift:169-188`); the card shows the winner only. One `Logger.debug` line listing the top three candidates with `(seriesId, chapters, days, perDay, rejected: Bool)` would let a screenshot be matched to its inputs. Same for `signatures` (which tag, `mine`, `world`, `catalogueSize` — the denominator that is a dated constant at `ReadingWrapped.swift:78` when the pulse has not arrived, and nothing says which was used).
- **A wrong or missing notification cannot be traced.** No log at any of: candidate planned, dropped by `fired`, dropped by cooldown, deferred by cap, `add` refused by iOS. One line per decision in `applyFatigueGuard` and one in `LiveNotificationCentre.add` (`ReleaseReminders.swift:326,343,338,538`).
- **A wrong cadence** can be traced only as far as the row: `fetchedAt` is stored but not shown on the hero (P7); the releases the median was taken over are not kept. Store `samples`/`gaps` (already on `Cadence`) beside `fetchedAt` in the hero's accessibility label, at least in debug.
- Signposts in the slice: `"Reminder links"` (`RootView+Session.swift:413`), `"Spotlight index"`. None around `reschedule`, `cachedFeeds`, `absorb`, `buildIDs`, `snapshot()`.
- Loggers in the slice: `TasteProfile` (one site). None in `ReleaseReminders`, `ReleaseSchedule`, the three feed clients, `PublisherFollows`, `WidgetSnapshot`, `SpotlightIndex`.

## Size
- Delete: `ReadingWrapped.decades` + two tests (P17); `OwnedVolumes.rowIdentity` (P18); `NotificationPolicy.title(for:in:fallback:)`, the `announced`/`lastKnownEpisode` parameters and the episode baseline (P3); `ReadingWrapped.utcCalendar` alias (`ReadingWrappedYear.swift:28`, used only as a default-argument spelling of `.utc`).
- Duplicated logic: the `isWebtoons` guard written two ways (P12); "is this status a hiatus" in `ReleaseSchedule.swift:174-176` and `NotificationPolicy.swift:158` (P9); the three feed clients' `readCache`/`readCacheIgnoringAge`/`writeCache` triplets (`WebtoonsFeedClient.swift:224-248`, `GigaViewerFeedClient.swift:181-204`, `MangaUpdatesClient.swift:241-258`) are the "seven file-cache implementations" item, still seven.
- `PublisherFollows` (164 lines) exists to maintain a number nothing reads (P5); if the follow list is only ever a Settings list, `check` and `Update` can go.

## Good news
- `MangaUpdatesClient.Release.releaseDate` (`:50-53`), `perpage` (`:116-118`), the 0-100 rating scale (`Series.swift:27`, `LibraryEntry.swift:70`) — each states what the API sends and when it was checked. I checked the ratings against four captured fixtures: `series-2060-record`, `library`, `search-solo-leveling`, `rising` all carry top-level ratings on 0-100 (86.8, 70.5, 86.17); the OpenAPI schema's own example (`mangabaka_openapi.json:1412`, `8.38275`) is the wrong one. The code is right and the doc is wrong — worth a line in `Series.swift` so the next reader does not "fix" it.
- `Cadence.swift:126-131` records the session-grouping measurement with series names and before/after numbers; `SeasonReading.swift:30-49` and `ReadingWrappedYear.swift:120-146` record what the previous constant got wrong and why the new one is still a guess. That is exactly the standard.
- `SpotlightIndex.swift:42-44` — measured, dated, off main.
- `WidgetSnapshot.write` (`:174-211`) merges lists so two writers do not blank each other and rations `reloadAllTimelines` to real changes.
- `ReleaseReminders.reschedule` (`:172-196`) serialises overlapping passes and releases its handle — the review-item-72 fix landed cleanly.
- `WebtoonsFeedClient.resolveFeedURLs` (`:196-203`) — HEAD not GET, with the measurement.
- `ReleaseSummary.swift:36-41,49-56` — the oldest-first guard against True Beauty, measured live.
- `TasteLedger.contribute` (`:280-288`) — 517 ms measured, moved into SQL.
- `LibrarySnapshot.load` dedupes concurrent walks (`:64,159`), so the launch's two walkers (`refreshReminders` and `taste.ranker()`) share one — checked because P4/P5 made me look.

## Could not determine
- Whether the API sends `on_hiatus` today (P9) — a captured `/v1/my/library` page with one such series would settle it.
- Whether a Webtoons finale title ever lacks a season number (P8) — one live feed of a series that ended without seasons.
- The ms cost of P10 and P14 on a device — an `os_signpost` around `hasAnythingToSay` and `performReschedule`, one launch, Instruments.
- Whether `Continuations`' standalone `relationships` misses the detail cache (P11) — read `SeriesRepository+Cache.readDetailCache` and `cachedRelationships`'s population.
- Whether the `.task(id: series.id)` re-run (full2 item 32) still re-fires `loadReleases` on pop-back — not re-checked; if it does, the Webtoons spacer is paid twice per visit.
- Tests for `NotificationPolicy`/`ReminderPacing` were grepped for the P1 shape, not reviewed.
