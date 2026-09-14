# Slice 3 — what the app says about the reader, and when it says it

Read-only review, 2026-09-13/14, against HEAD `99a1124`. Scope: `Core/Library/**`,
`Core/Schedule/**`, `Core/Notifications/**`. Nothing built, run, or edited; one
live GET spent (listed at the end).

**Fraction read:** every line of `Core/Notifications` (611/611) and `Core/Library`
(3,500/3,500). `Core/Schedule`: `ReleaseSchedule`, `Cadence`, `SeasonReading`,
`ReleaseCalendar`, `UpcomingWork`, `ReleaseFeedService`, `MangaUpdatesClient`,
`MangaUpdatesID`, `WebtoonsFeed`, `WebtoonsFeedClient`, `ReleaseFeedProvider`,
`TranslationGap`, `ReleaseSummary`, `NaverFeedClient` in full; `GigaViewerFeedClient`
and `WebtoonsEpisode` only at the lines cited; `MangaUpdatesCategories` and
`ReleaseSource` not read. About 6,750 of 7,227 lines (93%). Read outside the
slice to state impact: `App/RootView+Session.swift`, `Features/Settings/
LibraryTransferSection.swift`, `Features/Library/LibraryModel.swift:297-380`,
`Features/Schedule/ScheduleRow.swift:134`, `Core/Persistence/AppDatabase.swift:
193-202`, `SeriesRepository+Cache.swift:24-33`, and the tests named below.

**Not re-filed.** `docs/reviews/reader.md` (2026-09-13) findings 1–6, 9–12 are
visibly fixed in the code read here (oldest-first guard `ReleaseSummary.swift:40`,
English-variant feed `WebtoonsFeedClient.swift:183`, `latestEpisodeNumber ??
totalCount` `ReleaseFeedService.swift:163`, `originalComplete` `TranslationGap.swift:
29`, UTC calendar `ReadingWrappedYear.swift:10`, one rate table `ReadingInsights.swift:
142-149`, R9 retract `TasteLedger.swift:108-120`, R10 `ReleaseSchedule.swift:108-115`,
anchored `marksFinale` `WebtoonsEpisode.swift:146-149`, Naver guards
`NaverFeedClient.swift:125-131,163`). R24 (titles on the lock screen) and the
`staleAfter` label (now labelled, `ReleaseSchedule.swift:95-100`) are recorded and
not repeated.

## Ranked top ten

| # | Finding | Where | Effort | Confidence |
|---|---|---|---|---|
| 1 | The 3/day cap is per call, not per day: `sentToday` starts at 0 every pass, and the overflow all lands at tomorrow 09:00 uncapped | `ReleaseReminders.swift:258,267-277` | function | certain |
| 2 | Reminders are recomputed only at launch and on the switch; the "on foreground" the comment promises does not exist | `RootView+Session.swift:170,88,244-246`; no `scenePhase` anywhere in `App/` or `Features/` | function | certain |
| 3 | Naver's `finished` fires "X has finished" about a translation that has not, years after the fact, and can fire the day after "X has finished" already went out | `NotificationPolicy.swift:168-182`, `:148-149` | function | certain |
| 4 | MangaUpdates release days are UTC; the cadence is measured in the device calendar, so every "last release", "due" and "late" is a day early west of UTC | `ReleaseSchedule.swift:109-110`, `Cadence.swift:102-105,164`, `ScheduleRow.swift:134` | function + 2 lines | certain (arithmetic); unmeasured on a device |
| 5 | The library walk never dedupes across pages; a mid-walk write can repeat a series, and two `Dictionary(uniqueKeysWithValues:)` then trap | `LibrarySnapshot.swift:100`, `LibraryImport.swift:384`, `LibraryTransferSection.swift:100` | 3 lines | likely |
| 6 | Settings opens a second, unshared, uncached library walk (10 requests, ~25 MB) and rebuilds the export bytes inside `body` on every render | `LibraryTransferSection.swift:148-161,190,207,57-70`; `SettingsView.swift:134` | file | certain |
| 7 | `LibrarySnapshot.load` commits a walk that `invalidate()` already discarded and nils the newer walk's `inFlight`/`onPage` | `LibrarySnapshot.swift:116-128,232-243` | function | likely |
| 8 | Every series page open re-absorbs the whole library into the taste ledger (`note` clears `cachedIDs`; the next `favouredTagIDs` re-runs `absorb` over 939 rows) | `TasteProfile.swift:129-136,104-106`; `SeriesDetailView.swift:521-523` | function | likely (unmeasured) |
| 9 | Confirmed releases (1a) and feed episodes (1b) are not limited to reading/paused — a dropped series' new volume says "out now" | `NotificationPolicy.swift:94-108,116-128`; `ReleaseCalendar.swift:106-111` | function | likely (product call) |
| 10 | A MangaUpdates id that will not decode is counted `done` by the build and `pending` by the snapshot, forever | `ReleaseSchedule.swift:335-341,216-225` | function | certain |

## Notifications — the owner's constraint, checked

The rule: only (1) a confirmed release that has just come out, and (2) a
reading/paused series that completed or ended a season; 3/day; 24h per series.

**What holds.** `NotificationPolicy.decide` (`NotificationPolicy.swift:75-90`) is
the only producer of `PlannedNotification`; `ReleaseReminders.notify` (`:113-116`)
is called from exactly one place, `reschedule` (`:201`), and nothing else in
`MangaBaka/` calls `.notify(` (grep). `PublisherFollows.check` is invoked with no
`notify` closure (`RootView+Session.swift:259`). There is no cadence, nudge or
follow path into a notification — charter-clean. The first-seen baseline rule
(`:118`, `:143-144`, `:158`) plus `seedFirstSeenBaselines` (`ReleaseReminders.swift:
318-337`) stops the day-one burst, and it is only seeded while the feature is on
(`:172-189`), so enabling later still baselines first. `fired` and
`seriesLastNotified` are in `UserDefaults` (`:214-215`), so dedup and the 24h
cooldown survive a relaunch. The two guards are tested (`ReminderTests.swift:
138-184`).

**What does not hold — the four findings below.**

### N1. The daily cap does not survive a second pass, let alone a relaunch

- **What** — `applyFatigueGuard` counts `sentToday` from zero on every call and
  never consults `fired` for what already went out today; the 4th+ candidates
  are all moved to tomorrow 09:00 with no cap on that day either.
- **Where** — `ReleaseReminders.swift:258` (`var sentToday = 0`), `:267-277`
  (the else branch re-dates every overflow candidate to `tomorrowNine`), `:191-193`
  (only `fired` and `seriesLastNotified` are passed in).
- **Why it matters** — launch fires 3; the reader opens Settings and toggles the
  switch (`onRemindersChanged` → `refreshReminders`, `RootView+Session.swift:88`)
  or relaunches: 3 more the same day. Ten candidates on one pass: 3 now, 7
  simultaneously at 09:00 tomorrow. The test at `ReminderTests.swift:138-156` runs
  one pass, so it cannot see either. This is the exact fatigue the owner named.
- **Fix** — seed `sentToday` from `fired.values.filter { calendar.isDate($0, inSameDayAs: now) }.count`
  (that dictionary is already persisted); for overflow, walk forward day by day
  and place at most `dailyLimit` per day, counting `fired` dates on each day.
  Add the two-pass test: 3 then 1 on a second call an hour later → the 4th must
  defer. Also serialise `refreshReminders` (one in-flight task) so launch and
  toggle cannot run two passes over the same ledger.
- **Effort** — a function. **Confidence** — certain. **Lens** — bugs.

### N2. Nothing recomputes on foreground

- **What** — `refreshReminders()` runs from `startSession()` and from the Settings
  switch only. The doc comment says "and when the app comes back to the
  foreground"; no `scenePhase`/`willEnterForeground` handler exists.
- **Where** — `RootView+Session.swift:170`, `:88`, comment `:244-246`; grep of
  `MangaBaka/App` and `MangaBaka/Features` for `scenePhase` returns nothing.
- **Why it matters** — iOS keeps a used app resident for days. A reader who does
  not cold-launch gets no confirmed release and no completion until they do, and
  then gets them late (1a is gated `date <= today`, so a release from three days
  ago arrives "out now"). With N6 the announced list is also frozen at launch.
- **Fix** — `.onChange(of: scenePhase)` on `RootView` → `.active` → the same
  `refreshReminders()`, guarded by a single `Task` handle so overlapping calls
  coalesce. Correct the comment.
- **Effort** — a function. **Confidence** — certain. **Lens** — bugs / bad practice
  (comment describes code that does not exist).

### N3. Condition (2c) says the wrong thing, at the wrong time, and can say it twice

- **What** — `feed.finished == true` (Naver's flag for the Korean original) plans
  `"\(title) has finished"` on first sight, with no baseline, dated `now`, worded
  identically to the catalogue completion in (2a).
- **Where** — `NotificationPolicy.swift:168-182` (2c); `:142-152` (2a, same
  body); the feed selection that decides whether Naver is even consulted:
  `ReleaseFeedService.swift:124-133` (first provider with a cache wins — Webtoons
  before Naver, per `:109-111`).
- **Why it matters** — (i) the reader reads the *translation*; the original
  finishing is `TranslationGap.originalComplete`'s "the translation will catch
  up and stop", not "it has finished". (ii) First-seen firing means a webtoon
  that ended in 2019 notifies the day its Naver feed is first cached — not "just
  finished". (iii) Sequence: catalogue flips to completed and the Naver cache is
  the only one on disk → 2a fires `finished-<id>`, 2c `original-finished-<id>` is
  dropped by the 24h cooldown (`ReleaseReminders.swift:262-264`, `continue`, not
  defer) → next pass, a day later, 2c is still a candidate (no baseline for it)
  and fires: "X has finished" two days running. (iv) Whether 2c fires at all
  depends on which provider's file is on disk, since `cachedFeeds` stops at the
  first hit — the same series notifies or not by cache accident.
- **Fix** — either delete 2c (the owner's condition (2) is about the series the
  reader is reading; the catalogue status covers it), or: baseline it like 2a
  (`lastKnownFinished: [Int: Bool]`, first-seen records only), skip it when
  `finished-<id>` is in `fired`, and word it as `TranslationGap` does. Update the
  test at `NotificationPolicyTests.swift:154-162`, which pins the first-seen
  behaviour.
- **Effort** — a function. **Confidence** — certain that the mechanism is as
  described; the wording harm is a judgement. **Lens** — bugs.

### N9. (1a)/(1b) ignore the reader's state

- **What** — `confirmedReleases` filters by date only; `mine(seriesIDs:)` is fed
  every library id; `confirmedEpisodes` iterates every cached feed. Only (2) is
  limited to reading/paused (`trackedForCompletion`, `:41`).
- **Where** — `NotificationPolicy.swift:94-108`, `:116-128`;
  `ReleaseCalendar.swift:106-111`; `RootView+Session.swift:253`.
- **Why it matters** — a dropped or completed series' next print volume produces
  "Vol. 12 · out now". The class comment (`ReleaseReminders.swift:4`) says "something
  they are waiting for"; a dropped series is not that, by this file's own
  argument at `NotificationPolicy.swift:37-40`.
- **Fix** — pass a `Set<Int>` of ids whose state is in `[.reading, .rereading,
  .paused, .planToRead]` (plan-to-read is a defensible "waiting"; ask the owner)
  and filter 1a/1b by it. One test per condition.
- **Effort** — a function. **Confidence** — likely (product call on plan-to-read).
  **Lens** — bugs.

### N5. Condition (1b) can only ever tell the reader what they just looked at

- **What** — a provider's `cachedFeed` reads only what `feed(for:)` wrote, and
  `feed(for:)` is called from the series page. So a feed is refreshed exactly
  when the reader opens that series; the next launch then notifies about the
  episode they saw yesterday, dated `feed.lastEpisodeAt` (possibly days old) and
  therefore fired "a minute from now".
- **Where** — `WebtoonsFeedClient.swift:42-45` (`cachedFeed`), `:52-63` (`feed`
  is the only writer, via `writeCache` `:75`); `NotificationPolicy.swift:126`;
  `ReleaseReminders.swift:373-374`.
- **Why it matters** — charter 5: the condition measures "did the reader visit
  the page", not "did an episode come out". It is not wrong, it is inert, and
  the doc at `NotificationPolicy.swift:49-57` still says feeds are always `[:]`
  (stale since `d8a77d5`/`0fb8457`; so is `docs/todo-next-week.md:238-240`).
- **Fix** — either say so in the caption (`RemindersSection.swift:109-113` promises
  "a confirmed release the day it's out") or add a `BGAppRefreshTask` that refreshes
  the Webtoons feed for reading/paused series only. Cost, stated: at the client's
  3.5 s spacing (`WebtoonsFeedClient.swift:13`) 55 in-scope series is ~3 minutes
  of a background slot, one request each per week, to a third party the app
  otherwise contacts only on a page visit — the privacy comment at `:5-8`
  would need revisiting. Correct the two stale comments either way.
- **Effort** — a redesign for the refresh; a line for the honest caption.
  **Confidence** — certain. **Lens** — measurement of the wrong thing.

### N6. The announced list is fetched once per process and never expires

- **What** — `upcoming()` returns `cached` whenever it is set; nothing clears it.
- **Where** — `ReleaseCalendar.swift:27-28`, `:53-55`, `:100-101`.
- **Why it matters** — with N2 fixed, a foreground refresh would still test today's
  date against the list fetched at launch. Live on 2026-09-13 23:24 UTC the window's
  first date was 2026-09-15 (`/v1/works/upcoming?limit=3&page=1`), i.e. it did not
  contain today or tomorrow, so (1a) may only ever fire when a process survives
  a midnight — which after N2 is exactly when it recomputes. Whether the window
  ever includes today is the open question below.
- **Fix** — a `freshness` like `LibrarySnapshot`'s (6 h) and re-fetch past it.
- **Effort** — lines. **Confidence** — likely. **Lens** — bugs / optimisation.

### N28. A pass never asks iOS whether it may deliver

- **What** — `reschedule` guards on `effectiveEnabled`, which reads `systemStatus`,
  but `systemStatus` is `.notDetermined` until `refreshStatus()` runs, and the
  only caller is the Settings section's `.task`.
- **Where** — `ReleaseReminders.swift:42,50,173`; `RemindersSection.swift:70`.
- **Why it matters** — a reader who revoked permission in iOS Settings: launch runs
  the pass, iOS drops every `add`, and `fired` records the ids (`:202`) — they will
  never be told, even after re-granting. Fix: `await refreshStatus()` first thing
  in `reschedule`. **Effort** — a line. **Confidence** — likely. **Lens** — errors.

Minor, notifications: `ReleaseReminders.swift:248-254` builds "tomorrow" by
`day + 1` in components rather than `date(byAdding: .day, value: 1)` — Foundation
normalises the overflow, so it works, but it is the hand-rolled form (lens 4).

## Schedule

### N4. Cadence arithmetic in the wrong calendar

- **What** — `MangaUpdatesClient.Release.date` parses `yyyy-MM-dd` at UTC midnight
  (`MangaUpdatesClient.swift:86-93`), the right reading of a calendar day. Then
  `measuredCadence` calls `Cadence.estimate(from:)` with the default
  `calendar: .current` (`ReleaseSchedule.swift:109-110`, `Cadence.swift:100-105`),
  whose `startOfDay` moves every instant to the previous local day anywhere
  west of UTC. `lastRelease` and `due` (`:152,164,170-171`) are then local
  midnights of the wrong day; `ScheduleRow.swift:134` prints `lastRelease` in the
  local zone; `overdueDays` (`Cadence.swift:66-68`) and `WidgetSnapshot.swift:136`
  compare local days.
- **Why it matters** — a reader in the Americas sees "last release 4 Sep" for a
  5 Sep release, "due Wednesday" for Thursday, and "late" a day early — every
  row, every time. East of UTC (Seoul, Tokyo) nothing moves, which is why it was
  not seen on the reference device if that was the zone. Gaps are unaffected
  (both ends shift), so the median is right and the tests pass — `CadenceTests`
  pin a GMT calendar (`CadenceTests.swift:9-11`) and so agree with the bug's
  absence. The project convention for calendar-day fields is
  `Date.FormatStyle(timeZone: .gmt)` (`VolumesSection.swift:192,196`) and a UTC
  calendar (`ReadingWrappedYear.swift:10-14`).
- **Fix** — `measuredCadence` passes `ReadingWrapped.utcCalendar` (move it to a
  shared `Calendar.utc`) to `Cadence.estimate`, and `ScheduleRow`/widget format
  `lastRelease`/`due` with `.gmt`. Leave the feed path (`ReleaseFeedService.swift:
  170`, real instants) on `.current`. `overdueDays` should take the same UTC
  calendar so "late" flips at UTC midnight, consistently with the day the
  source means. One test with a `TimeZone(identifier: "America/Los_Angeles")`
  calendar that fails today.
- **Effort** — a function plus two lines. **Confidence** — certain on arithmetic;
  not measured on a western-zone device. **Lens** — bugs.

### N10. Undecodable MangaUpdates id: `done` to the build, `pending` to the snapshot

- **Where** — `ReleaseSchedule.swift:335-341` (no row written), `:216-225`
  (`guard let row … else pending += 1`), `:308-316` (re-listed in `todo` on every
  build).
- **Why it matters** — a series whose `source.manga_updates.id` fails
  `MangaUpdatesID.number(from:)` (`MangaUpdatesID.swift:24-38`: any character
  outside `[0-9a-z]`) shows "1 still to do" forever and is re-walked each build.
  How often the API sends such an id is unknown — one grep over a cached library
  would tell.
- **Fix** — write a settled row (`cadence: nil, failure: nil`) or add
  `Reason.badMangaUpdatesID`. **Effort** — a function. **Confidence** — certain by
  reading. **Lens** — errors.

### N14. `cancelBuild` can clear the *next* build

- **Where** — `ReleaseSchedule.swift:277-281` (the task ends with
  `finishBuild()`), `:287-289` (`cancelBuild` also calls it synchronously).
- **Sequence** — sign out → `cancelBuild()` → sign in → `build()` sets
  `buildTask = B`, `isRunning = true` → task A's `measureOne` returns → A's
  continuation runs `finishBuild()` → `buildTask = nil`, `isRunning = false` while
  B is still measuring; the screen stops following and a third `build()` is now
  allowed to start alongside B.
- **Fix** — give each build an id; `finishBuild(id:)` only clears if it matches.
  **Effort** — lines. **Confidence** — likely. **Lens** — bugs (race).

### N15. Every series page reads and decodes the whole cadence table

- **Where** — `ReleaseSchedule.swift:401` (`cadence(for:)` → `readCache()`),
  `:426-447` (`SELECT … FROM cadenceEntry`, decode every payload). Rows for
  series that left the library are never deleted.
- **Fix** — `WHERE seriesId = ?` for the single-series path; prune rows not in
  scope at the end of `run`. **Effort** — a function. **Confidence** — likely
  (55 rows today; grows with every series ever opened). **Lens** — optimisation.

### N12. `SeasonReading.describe` contradicts `currentSeason`, and nothing calls it

- **Where** — `SeasonReading.swift:96` prints `newest.volume`; `:80-85` says the
  newest release "is exactly what a straggler is" and returns the max. No
  production caller (grep: only `SeasonReadingTests.swift:100,110,119`).
- **Fix** — delete it and its three tests, or use `currentSeason`. **Effort** — a
  line. **Confidence** — certain. **Lens** — charter 7.

### The `ReleaseScheduleService` fixture — what exists and what is missing

The brief called this the largest untested surface. It is partly tested:
`ScheduleServiceTests.swift` already constructs the actor with
`LibrarySnapshot(library: OneEntryLibrary(...))`, `AppDatabase.inMemory()` and a
`MangaUpdatesClient` over `URLProtocolStub` (`:12-13`, `:80-87`, `:141-148`), and
covers a failed walk, an unreadable row, follow-on-return, `cadence(for:)`'s season
and failure, and the offline stop. **Not covered, and reachable with that same
fixture plus a `TestClock` passed as `clock:`:**

1. A successful `build()` writing rows that `snapshot()` then reports as `dated`
   (with `measuredAt`/`oldestMeasuredAt` set) and `undated(.tooFewReleases)` — the
   `write` upsert (`:450-465`) and the happy path of `readCache` (`:433-445`) have
   no test.
2. `stale` counting past `staleAfter` (`:229-230`) — advance the clock 15 days.
3. `build(refresh: true)` re-measuring a settled row (`:313`).
4. A recorded failure being retried by the next build and a settled null not
   (`:314-316`).
5. `cancelBuild()` mid-loop with a slow stub (N14's race).
6. N10 (an id like `"abc-1"`).

The fixture needs nothing new: the release JSON shape at `:125-133` is the
provenance-bearing one already used.

## Library

### N5. Duplicate series across pages → trap

- **Where** — `LibrarySnapshot.swift:94-113` appends each page with no dedupe;
  `LibraryImport.swift:384` and `LibraryTransferSection.swift:100` build
  `Dictionary(uniqueKeysWithValues:)` over `existing`, which traps on a repeated
  key. The walk sends no `sort_by`; the schema's default order is undocumented
  (`mangabaka_openapi.json`, `/v1/my/library` `sort_by` enum includes
  `updated_at_desc`).
- **Sequence** — the import section's own walk (N6) is in flight; the reader (or
  their other device, or the website) updates an entry; if the default order is
  by `updated_at`, that entry moves to page 1 and the page-2 boundary shifts by
  one, so one entry appears on two pages. `LibraryModelPagingTests.swift:99`
  checks two *walks* do not duplicate, not one walk.
- **Fix** — dedupe in `load()` (`Set<Int>` of seen ids, keep first) and
  `uniquingKeysWith: { first, _ in first }` at both sites. Consider sending
  `sort_by=created_at_desc` so the order cannot move under the walk. One curl
  (page 1 with and without `sort_by`) settles what "default" is.
- **Effort** — three lines. **Confidence** — likely. **Lens** — crash risk.

### N6. Settings pays for a second library walk and re-encodes the export per render

- **Where** — `LibraryTransferSection.swift:148-154` (default `loadExisting` is
  `LibrarySnapshot(library:).all()` on a fresh, database-less snapshot),
  `:156-161` (a second `APIClient`/`LibraryService`), `:190` (`.task` runs it
  on appear), `SettingsView.swift:134` (`LibraryTransferSection()`); `:207`
  calls `model.jsonExportItem()` from `body`, which runs `LibraryExport.json(entries)`
  (`:57-63`) on every render, and `:65-70` the same for CSV.
- **Why it matters** — 10 requests and ~25 MB (`LibrarySnapshot.swift:6-8`) every
  time Settings opens, from the 180/min window, duplicating the cached walk the
  app already holds; the comment at `:140-147` knows. The encode is 939 small
  structs — cheap per call, but it is on the main actor inside `body`.
- **Fix** — thread `AppServices.library` and `librarySnapshot.all` through
  `SettingsView` into the section; compute the two `Data`s once in
  `loadEntriesIfNeeded` and store them. **Effort** — a file. **Confidence** —
  certain. **Lens** — load balancing / speed.

### N7. A discarded walk can still commit, and can drop the live walk's observer

- **Where** — `LibrarySnapshot.swift:116-128` (after `await task.value`: `cached =
  result`, `writeCache`, `inFlight = nil`, `onPage = nil` unconditionally),
  `:232-243` (`invalidate` cancels and nils `inFlight`).
- **Sequence** — walk A awaiting its last page; `LibraryModel.reload()` →
  `invalidate()` → `load()` starts walk B and `observePages` for B; A's last page
  returns without error (cancellation lands between pages, so no throw) → A's
  continuation caches the pre-write library, then sets `inFlight = nil` and
  `onPage = nil` — B's page observer is gone, so the Library screen stops
  drawing pages until B completes; a third caller now starts walk C in parallel
  with B. If A did throw `.cancelled`, the cache is spared but the nil-outs
  still happen.
- **Fix** — a `generation` captured before the task and checked after the await
  (`LibraryModel` already does this for its own state, `:319,326`); also check
  `Task.isCancelled` between pages.
- **Effort** — a function. **Confidence** — likely. **Lens** — bugs / load balancing.

### N8. Every series page re-absorbs the whole library

- **Where** — `SeriesDetailView.swift:521-523` (`taste.note(...)` then
  `favouredTagIDs()`), `TasteProfile.swift:129-136` (`note` sets `cachedIDs = nil`),
  `:77-90,99-106` (`favouredTagIDs` with no cache → `buildIDs` → `ledger.absorb(
  await snapshot.all())`), `TasteLedger.swift:80-123` (per entry: `TasteSeen.save`,
  `TasteSource.fetchOne`, then the `NOT IN` scan).
- **Why it matters** — the per-entry no-op path is still ~939 selects and 939
  upserts in one transaction plus a scan, on the ledger actor, on every page
  open. The 517 ms figure at `:215` was the old, heavier path; this one is not
  measured. Not on the main actor, so no hitch — but the page's tag ordering
  waits on it.
- **Fix** — `absorb(_ series:as:)` returns whether anything changed; `note` only
  clears `cachedIDs` when it did. Or have `note` update `cachedIDs` incrementally.
  Measure first: `Signposts.measure` around `buildIDs` on the reference account.
- **Effort** — a function. **Confidence** — likely. **Lens** — optimisation.

### N16. The two binge ceilings disagree by 5–6×

- **Where** — `ReadingWrappedYear.swift:128` (same day: 60 chapters), `:112` and
  `:173-179` (multi-day: 16 h ÷ `minutesPerChapter`, now 2.83 min for manga via
  `ReadingInsights.swift:148` → ~340 chapters/day).
- **Why it matters** — R14's own scenario, "a stamped 80-chapter import", is
  rejected only when start and finish are the *same* day. An importer that
  stamps start = yesterday, finish = today passes as "80 chapters a day"; 600
  chapters over two days passes at 300/day. No test sits at either boundary
  (grep `isPlausible`/`plausible*` in `MangaBakaTests`: none). Charter 4: two
  constants that interact, one of them moved by R8.
- **Fix** — one ceiling in chapters per day for any span (`plausibleChaptersPerDay
  = 60`, a guess, labelled) and the two-day test that fails today.
- **Effort** — a function. **Confidence** — certain (arithmetic). **Lens** — bugs.

### N17. Two unlabelled thresholds

- `ReadingInsights.swift:58` `within: 12` ("nearly finished") and `:240`
  `started.count >= 10` (the dropped line). Both shape what the screen says and
  neither says "guess". `minimum: 2` (`:33-36`) and `minimum: 3` (`:188-190`)
  give a reason and are fine. **Effort** — two lines. **Confidence** — certain.
  **Lens** — bad practice (CLAUDE.md).

### N18. An unrecognised server state is exported as `considering`

- **Where** — `LibraryEntry.swift:59-62` (decode fallback), `LibraryExport.swift:51`
  and `:143` (writes `state`/`rawValue`), `LibraryImport.swift:406-407` (a new
  entry is `add`ed with that state).
- **Why it matters** — the backup is lossy for a state this build does not know,
  and restoring it into an empty account writes `considering`. Round-tripping
  into the *same* account is safe: `changeSet` compares two coerced values
  (`:449-451`). **Fix** — keep the raw string (`rawState`) on `LibraryEntry` and
  export it; import passes it through when the enum does not know it.
- **Effort** — a function. **Confidence** — likely (needs a new server state).
  **Lens** — bugs.

### N22. CSV formula injection

- `LibraryExport.swift:165-170` quotes for RFC 4180 only; a note beginning `=`,
  `+`, `-` or `@` is executed by Excel/Numbers when the reader opens their own
  export. The note is theirs, but pasted text is real input. **Fix** — prefix
  such fields with a single quote or a space. **Effort** — a line. **Confidence** —
  worth checking (severity is a judgement). **Lens** — crash risk / bad practice.

### Also noted, one line each

- `NotificationPolicy.swift:49-57` and `docs/todo-next-week.md:238-240` still say
  feeds are always `[:]`; `ReleaseFeedCachedFeedsWiringTests.swift` proves they
  are not. Comment drift.
- `ReleaseReminders.swift:290-291` `fired` grows without bound (one entry per
  event ever). Slow, but prune entries older than, say, 90 days.
- `refreshReminders` reads `cachedExtras` for every entry, one GRDB read and one
  full `SeriesExtras` decode per hit, 942 actor hops (`RootView+Session.swift:
  268-271`, `SeriesRepository+Cache.swift:24-33`). One `WHERE seriesId IN (…)`
  query returning only `links` would do. Optimisation, unmeasured.
- `Cadence.swift:133-140`: a daily series that skipped two days in its 40-release
  history has 2–3 sessions and gets no estimate, while a perfectly daily one gets
  one. Deliberate per the comment; worth a sentence in the "too few releases"
  explanation.
- `PublisherFollows.check` runs every launch from `refreshReminders` with nothing
  to notify (`RootView+Session.swift:255-259`). Deliberate and cheap (one
  background search per follow per day); fine.

## What the slice does well

- `NotificationPolicy` is a pure function with the owner's words at the top
  (`NotificationPolicy.swift:5-13`) and one producer/one consumer, so the
  constraint is checkable by grep — which is how the four gaps above were
  findable in an hour.
- `ReleaseReminders.swift:52-65` labels both pacing constants guesses and says
  why there was nothing to measure them against.
- `LibrarySnapshot.swift:6-15` records the 24.7 MB / 13-request measurement with
  the date, and `:155-162` (gap 116) turns one undecodable cached row into a
  refetch rather than a permanently shorter library.
- `Cadence.swift:117-121,126-132` names the two series each rule was measured on
  and the before/after numbers; `:84-92` says the tolerance interacts with the
  session grouping.
- `SeasonReading.swift:30-49` records the previous wrong constant and the input
  that killed it.
- `ReleaseSummary.swift:35-40` and `ReleaseFeedService.swift:143-163` carry the
  2026-09-13 measurements (True Beauty 3%, 화산귀환 185/174, Lookism 624/617)
  beside the code they changed.
- `ReadingWrappedYear.swift:4-9,114-127` and `ReadingInsights.swift:134-141`
  each explain the bug the current shape replaced, with the numbers.
- `SpotlightIndex.swift:41-44` measured the reindex (84 ms, 941 entries) before
  deciding to do it every launch, off the main actor.
- `LibraryImport.swift:366-371,433-444` never downgrades progress and never
  spends a write on an unchanged row; `:48-53` labels the 500 ms spacing a guess
  with the arithmetic (120/min of 180).
- `ScheduleServiceTests` builds the actor over an in-memory database and a
  stubbed session — the fixture the brief asked for already exists.

## What I could not determine

1. **Does `/v1/works/upcoming` ever include today's date?** Measured once
   (2026-09-13 23:24 UTC): first entry 2026-09-15. If the window starts at
   tomorrow, (1a) can only fire from a cached list across midnight (N6). One GET
   at ~09:00 UTC on a weekday with known releases, `limit=3`, comparing the first
   `release_date` to the date.
2. **What is the library's default sort?** Decides whether N5's duplicate is
   reachable. Two GETs of `/v1/my/library?limit=5` with and without
   `sort_by=created_at_desc`, compared.
3. **N8's cost.** `Signposts.measure("taste absorb")` around
   `TasteProfile.buildIDs` on the 939-entry account, second call.
4. **N4 on a device** — set the simulator to `America/Los_Angeles`, open the
   schedule for a series with a known MangaUpdates date, read the row.
5. **How often a `manga_updates.id` fails to decode** (N10) — grep the cached
   `libraryEntry` payloads for ids with characters outside `[0-9a-z]`.
6. **`readCache` time on 24.7 MB** — `Signposts.measure` around
   `LibrarySnapshot.readCache` at second launch; it gates first paint of Library.

## Live requests spent (1 of 1)

1. `GET https://api.mangabaka.org/v1/works/upcoming?limit=3&page=1` — 200;
   `status/data/pagination` envelope; first three `release_date` values all
   `2026-09-15`, `count_type` `main`, at 2026-09-13 23:24 UTC (N6, open
   question 1). A first attempt against `api.mangabaka.dev` returned a 500 with
   "deprecated and no longer serves traffic — switch to api.mangabaka.org"; the
   app already uses `.org` (`LibraryTransferSection.swift:167`).
