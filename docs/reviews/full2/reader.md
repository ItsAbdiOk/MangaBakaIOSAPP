# Slice 3 — the reader's own data, and what the app says to them

Second-pass review. `Core/Library/**`, `Core/Notifications/**`, `Features/Library/**`,
`Features/Stack/**`, `Features/Shelf/**`. Read-only; nothing built, run or edited.

**Coverage: about half the slice, by line, chosen worst-first.**
Read in full: `NotificationPolicy.swift`, `ReleaseReminders.swift`, `LibraryService.swift`,
`LibraryModel.swift`, `LibraryImport.swift`, `LibraryExport.swift`, `TasteRanker.swift`,
`ShelfStore.swift`, and — because the brief asks about them even though slice 1 owns the
file — `LibrarySnapshot.swift`'s walk, pending-changes map and generation guard.
Read in part: `StackModel.swift` (~60%: `loadIfNeeded`/`refill`/`performRefill`/`append`/
`resetStack`/`react`/`fetchBatch`), `LibraryEntry.swift`, `Continuations.swift`,
`PickBackUp.swift`, plus `SeriesRepository.feedQuery`, `Series.richTags`,
`RootView+Session.swift` and `AppServices.swift` where they cross into the slice.
**Not reviewed:** `ReadingTime`, `ReadingInsights`, `ReadingWrapped`, `ReadingWrappedYear`,
`SpotlightIndex`, `WidgetSnapshot`, `TasteLedger`, `TasteProfile`, `PublisherFollows`,
`LibrarySort`, `LibraryShape`, and every `Features/*` view except the two named above.

---

## Ranked top ten

| # | Finding | Lens | Effort | Confidence |
|---|---|---|---|---|
| 1 | The taste ranker cannot fire on the stack's main path — mix feeds carry no `tags_v2` | Bugs / inert fix | a line | certain |
| 2 | `reschedule(isComplete:)` is never passed by its only caller — the guard is dead | Errors / inert fix | a line | certain |
| 3 | The same-series 24-hour cooldown is measured from queue time, not delivery time | Bugs | a function | certain |
| 4 | The `reminders.fired` ledger grows without bound and is never pruned | Crash risk / speed | a function | certain |
| 5 | A notification deferred up to 14 days is delivered saying something no longer true | Bugs | a function | likely |
| 6 | A concurrent `LibrarySnapshot.load()` caller gets un-replayed, pre-edit rows | Bugs | a line | certain |
| 7 | The library walk publishes one page *after* cancellation | Bugs | a line | certain |
| 8 | `LibraryImport` paces for one request per row but sends up to three | Load balancing | a function | certain |
| 9 | `TasteRanker.rank` recomputes every score inside the sort comparator | Optimisation | a function | certain |
| 10 | `StackModel.refill`'s task bookkeeping clobbers a newer refill, and `resetStack`'s cancel does not stop an append | Bugs | a function | likely |

Also worth doing, below the ten: the CSV round trip corrupts a note that starts with `=`
(F11), and `TokenStore.read()` races an unsynchronised static counter in production (F12).

---

## Findings

### F1 — The taste ranker is inert on the stack's main path

**What.** `TasteRanker` scores a series from `Series.richTags`, but the series the stack
actually deals come from the `.mix` feed, which is not asked for `schema=full` and
therefore arrives with no `tags_v2` at all. Every card scores 0, the rank is a no-op, and
the "Shares X, Y with what you read" caption can never be produced.

**Where.**
- `MangaBaka/Core/Persistence/SeriesRepository.swift:314-324` — `case let .mix(seeds)` returns
  only `series` + `strict`. Only `.surprise` (line 325-333) adds
  `URLQueryItem(name: "schema", value: "full")`, and its own comment says why: *"The lean v2
  schema omits tags entirely."*
- `MangaBaka/Core/Model/Series.swift:206` — `var richTags: [SeriesTag] { tagsV2 ?? [] }`.
- `MangaBaka/Core/Library/TasteRanker.swift:45-46` — `let tags = series.richTags;
  guard !isEmpty, tags.count >= Self.minimumTags else { return 0 }` with `minimumTags = 3`.
- `MangaBaka/Features/Stack/StackModel.swift:375-386` — `fresh = ranker.rank(fresh) { $0 }`
  and the `reasons` loop, both gated on `source != .yourProfile`, i.e. exactly the mix and
  surprise paths.
- `MangaBaka/Features/Stack/StackModel.swift:679-685` — `fetchBatch` picks `.mix(seeds:)`
  whenever the seed pool is non-empty, which it is for any reader with saves or a library.

**Why it matters.** `RootView+Tabs.swift:160` builds a ranker from the taste ledger on every
visit to the Stack tab; `forgetPreviousAccount` is careful to clear it
(`RootView+Session.swift:156`). All of that machinery reorders nothing. `rank` is stable on
ties and every score is 0, so the queue comes out in exactly the order the feed returned it.
The reader never sees the reason line either. The only path where the ranker works is the
seedless `.surprise` fallback — the one path where the reader has the *least* taste data.

**Fix.** Add `URLQueryItem(name: "schema", value: "full")` to the `.mix` case in
`SeriesRepository.feedQuery`, as `.surprise` already does, and move the comment that
explains why up to cover both. Then measure: log the spread of `score()` over one dealt
batch before and after, because a stable sort over all-zero scores and a stable sort over
real scores are indistinguishable from the outside. Note the cost honestly — `schema=full`
is a larger response on the app's most frequent feed call, so the before/after payload size
belongs in the comment. If the payload cost is judged too high, the honest alternative is to
delete the ranker call from `append` rather than leave it looking alive.

**Effort.** A line, plus a measurement. **Confidence.** Certain on the mechanism; the
payload-cost trade-off is the judgement call. **Lens.** 1 (bugs), and the charter's
"unreachable code that still looks alive".

---

### F2 — `reschedule(isComplete:)` is never passed, so the guard it was added for is dead

**What.** `ReleaseReminders.reschedule` takes `isComplete: Bool = true` and
`performReschedule` refuses to schedule anything when it is false — *"A walk cut short at
the page cap is not a fresh answer either"*. The only production caller never passes it.

**Where.**
- `MangaBaka/Core/Notifications/ReleaseReminders.swift:170` (parameter), `:200`
  (`guard libraryFailure == nil, isComplete else { return }`), `:162-164` (the doc comment
  that promises the behaviour).
- `MangaBaka/App/RootView+Session.swift:377-382` — passes `announced`, `library`, `feeds`
  and `libraryFailure`, and stops. `walk.isComplete` is available on the very line above
  (`let walk = await librarySnapshot.load()`, `:353`) and is not read.

**Why it matters.** This is the "`deadline:` that three of four call sites never passed"
shape, exactly. A reader whose library walk stops at the 30-page cap, or is cut short by
cancellation without an error, gets a partial library treated as the whole one: series that
did not make it into `walk.entries` are absent from `notifiable`, so a confirmed release for
something they are actively reading is silently not scheduled, and — worse — the
first-seen baselines in `seedFirstSeenBaselines` are still written for whatever *did*
arrive, so the pass is not even a harmless no-op.

**Fix.** `RootView+Session.swift:381` → add `isComplete: walk.isComplete`. Then write the
test that fails without it: a stub snapshot returning `isComplete: false` with a confirmed
release for a `.reading` series, asserting zero calls to `centre.add`.

**Effort.** A line. **Confidence.** Certain. **Lens.** 2 (errors), inert fix.

---

### F3 — The same-series cooldown starts when a notification is queued, not when it arrives

**What.** `updatedSeriesLastNotified[seriesID] = now` is written for every scheduled
candidate, including one the placement walk pushed days into the future. The 24-hour guard
is therefore measured against the moment the app decided, not the moment the reader is
told — so two notifications about one series can land on the same lock screen on the same
day, which is the exact thing the guard exists to prevent.

**Where.** `MangaBaka/Core/Notifications/ReleaseReminders.swift:239`
(`updatedSeriesLastNotified[seriesID] = now`) and `:313`
(`seriesSeenThisPass[seriesID] = now` inside `applyFatigueGuard`), against the placement at
`:331-353` which can return a candidate re-dated to `day+N` at 09:00.

**Why it matters, with the sequence.** Day 0: three candidates already fill day 0, so a
season-ending for series 7 is placed on day 2 at 09:00; `seriesLastNotified[7] = day 0`.
Day 1: a confirmed chapter for series 7 arrives. `now - seriesLastNotified[7]` is 24 hours,
so the cooldown does not bite; there is room on day 2, and it is placed there too. Day 2 at
09:00 the reader gets two notifications about the same series within a second of each
other. Abdi's stated complaint is notification fatigue, and this is the specific failure
the cooldown was written for.

**Fix.** Record the cooldown against the *placed* date, not `now`. In `applyFatigueGuard`,
after `place` returns, use `placed.date` for `seriesSeenThisPass[seriesID]`, and compare
`candidate`'s prospective placement against it rather than comparing `now`. In
`performReschedule`, write `updatedSeriesLastNotified[seriesID] = item.date` for the same
reason. The cooldown then means "24 hours between two things arriving about one series",
which is what the doc comment at `:62-65` already claims.

**Effort.** A function. **Confidence.** Certain from reading; a test with a fixed clock and
two passes a day apart proves it. **Lens.** 1 (bugs).

---

### F4 — The dedup ledger grows without bound

**What.** `reminders.fired` is an id → date dictionary in `UserDefaults` that is only ever
added to. Nothing prunes it. The only removal in the codebase is `forget()`
(`ReleaseReminders.swift:140`), which runs on an account change.

**Where.** `MangaBaka/Core/Notifications/ReleaseReminders.swift:249`
(`defaults.set(updatedFired, forKey: Self.firedKey)`), `:361-363` (the read), `:294-297`
(the per-pass scan over `fired.values`). `seriesLastNotified`, `seriesStatus`,
`knownEpisode` and `knownSeason` are all bounded by library size; `fired` is not.

**Why it matters.** Ids are per-event: `release-feed-<seriesId>-<episode>` and
`release-work-<workId>`. A reader following a few dozen weekly webtoons accrues a few
thousand keys a year, forever. Every `reschedule` — launch, every foreground, every
Settings toggle — decodes the whole dictionary twice (`fired` is a computed property and
`performReschedule` reads it at `:227` and again at `:230`), scans it, re-encodes it and
writes it back, on the main actor, on the launch path. It is also the single point of
failure for the whole fatigue system: `defaults.dictionary(forKey:) as? [String: Date]`
(`:362`) is all-or-nothing, so one non-`Date` value silently yields `[:]` and every past
notification becomes eligible again at once.

**Fix.** Prune on write: keep only entries whose date is within, say, 60 days of `now`
(comfortably past `maxDeferralDays` = 14, so nothing still pending is dropped), and label
the 60 as a guess in the comment the way `dailyLimit` and `maxDeferralDays` already are.
Separately, read `fired` once into a `let` at the top of `performReschedule` rather than
twice through the computed property. Consider moving the ledger out of `UserDefaults` into
the `libraryWriter` database with the rest of the reader's own data, where a per-row read
does not cost a whole-dictionary decode — but that is a redesign, and the prune is the fix.

**Effort.** A function for the prune. **Confidence.** Certain. **Lens.** 8 (unbounded
memory), 7 (speed on the launch path).

---

### F5 — A deferred notification can be delivered after it stops being true

**What.** `place` walks forward up to 14 days looking for a free slot and re-dates the
candidate to 09:00 on the day it finds. Nothing revisits that decision, and `removeAll()`
is deliberately never called from `reschedule`, so the notification stands and fires with
its original wording.

**Where.** `MangaBaka/Core/Notifications/ReleaseReminders.swift:323`
(`maxDeferralDays = 14`), `:331-353` (`place`), `:147-156` (the doc comment explaining why
nothing is rebuilt: *"a confirmed release or a completed series is a fact that does not
move once it is true"*).

**Why it matters.** That comment is true of condition 2a — a series that completed stays
completed. It is not true of condition 1b. `"Ep. 12 of <title> is out"` deferred twelve days
arrives when the reader can already see episode 15 on the page. Worse, the baseline moves at
*scheduling* time (`updatedEpisode[seriesID] = episode`, `:243-244`), so episodes 13, 14 and
15 each generate their own candidate and each gets its own slot — the reader receives a
drip of stale episode announcements over the following days rather than one current one.
The 14 is honestly labelled a guess; the problem is not the number, it is that the
deferral is applied to a fact with a shelf life.

**Fix.** Give `PlannedNotification` a `staleAfter: Date?` — for 1b, the feed's own cadence
or a flat 48 hours; nil for 2a, which genuinely does not expire — and have `place` stop
walking at `min(today + maxDeferralDays, staleAfter)`, dropping the candidate rather than
scheduling it late. Because a dropped candidate is deliberately not written to `fired`
(`:320-322`), a later pass with room can still place a *newer* episode, which is the right
answer. Alternatively, and more simply: defer only condition 2 and never condition 1b —
state the choice in the comment either way.

**Effort.** A function. **Confidence.** Likely — the mechanism is certain, the right
staleness window is a product call. **Lens.** 1 (bugs).

---

### F6 — Concurrent `LibrarySnapshot.load()` callers get rows without the pending edits replayed

**What.** `load()` replays `pendingChanges` onto the walk's rows before caching. A second
caller that arrives while the walk is in flight returns `await inFlight.value` — the raw
task result, before any replay.

**Where.** `MangaBaka/Core/Library/LibrarySnapshot.swift:145`
(`if let inFlight { return await inFlight.value }`) against `:173`
(`result.entries = replayPending(onto: result.entries)`), which runs only in the branch
that owns the task.

**Why it matters.** On launch, `LibraryModel.load`, `refreshReminders` and the widget/
Spotlight builders all ask the snapshot at once — the doc comment at `:128-130` says so in
as many words. If the reader edits a row mid-walk, one of those callers sees the edited
library and the others see the pre-edit one. Concretely: the reader marks a series
Completed while the walk is running; `refreshReminders` receives the row still reading
`.reading`, and condition 2a can then notify *"<title> has finished"* about a series the
reader just finished by hand. Whether you get the right or wrong answer depends on which
caller happened to own the task, which is a race.

**Fix.** Route both branches through one place. Make the `Task` produce the raw walk and
have a single `finish(_:)` actor method do the generation check, the replay and the caching;
the `inFlight` branch then calls `finish` on the awaited value too (it is idempotent once
`pendingChanges` is cleared and `cached` is set — return `cached ?? replayed` there). Or,
minimally, change `:145` to `return replayPending(onto: await inFlight.value)`, which is one
line and correct for the entries even though it does not share the caching.

**Effort.** A line for the minimal fix, a function for the clean one. **Confidence.**
Certain. **Lens.** 1 (bugs). *(Slice 1 owns this file — flagged here because the brief
asked for it; worth a cross-check with that report.)*

---

### F7 — The walk publishes one page after it has been cancelled

**What.** `walk` checks `Task.isCancelled` at the top of each page, then awaits the request,
then calls `onPage?`. A cancellation that lands during the await is not noticed until the
*next* iteration, so the page that was in flight is published to the previous account's
observer.

**Where.** `MangaBaka/Core/Library/LibrarySnapshot.swift:211` (the check), `:213` (the
await), `:218` (`onPage?(result.entries)`) — no second check between the two.

**Why it matters.** The generation guard at `:168` was added precisely so *"a walk abandoned
at sign-out"* cannot commit, and it correctly stops the walk caching and writing to disk.
It does not stop the page observer, which is a different channel: `LibraryModel`'s observer
(`LibraryModel.swift:415-426`) hops to the main actor and calls `apply(partial,
isComplete: false)`, which assigns `entries` outright. Its own `generation` check saves it
here — `forget()` bumps `generation` (`LibraryModel.swift:466`) — so today the damage is
contained one layer up, by a second guard rather than by this one. That makes it a latent
bug rather than a live one: any future observer that does not happen to carry its own
generation counter inherits the previous account's rows.

**Fix.** `LibrarySnapshot.swift:218` → `guard !Task.isCancelled else { break }` immediately
before `onPage?(result.entries)`. One line, and it makes the guarantee local to the walk
instead of dependent on every observer re-deriving it.

**Effort.** A line. **Confidence.** Certain on the mechanism; "latent, not live" is the
honest severity. **Lens.** 1 (bugs), 9 (the charter's shotgun-surgery pattern — the same
invariant enforced in two places).

---

### F8 — The import's request spacing assumes one request per row; it sends up to three

**What.** `requestSpacing = .milliseconds(500)` is documented as *"One request per entry, so
a large import stays comfortably under MangaBaka's general 180-requests-per-minute limit …
chosen to land at 120/min"*. `apply` issues a POST, then a PATCH inside `add` when the POST
answers 409, then a second PATCH from `update` — up to three requests per 500 ms, i.e.
360/min against a documented 180/min ceiling shared per IP with strangers.

**Where.**
- `MangaBaka/Core/Library/LibraryImport.swift:67-72` (the constant and its comment).
- `MangaBaka/Core/Library/LibraryImport.swift:417-424` — `library.add(...)` then
  `if !change.isEmpty { library.update(...) }`, with the single `Task.sleep` at `:440`
  covering both.
- `MangaBaka/Core/Library/LibraryService.swift:401-416` — `add` is POST, and PATCHes again
  when `created == false`.

**Why it matters.** Restoring a 939-entry backup is the case this feature exists for, and
in that case *every* row is new, so it is two requests per row throughout — 240/min,
sustained for eight minutes. A 429 mid-restore surfaces as `report.failures` with no retry
and no resume point; the reader is told "N failed" and has no way to finish the job except
re-running the whole file. The comment's arithmetic is the thing that is wrong, not the
intent.

**Fix.** Count requests rather than rows: sleep after each network call rather than once per
iteration, or pass a shared throttle. Simplest honest version — move the
`try? await Task.sleep(for: requestSpacing)` to just after `add` as well as after `update`,
and rewrite the comment to say "one sleep per request, up to three per row". Then say the
real worst case in the comment: 120 requests/min, and a 939-row restore takes about sixteen
minutes. If that is too long, the constant is the thing to revisit, with the 180/min figure
and the date beside it.

**Effort.** A function. **Confidence.** Certain. **Lens.** 6 (load balancing); also "a
comment that now lies".

---

### F9 — `TasteRanker.rank` recomputes every score inside the comparator

**What.** The sort comparator calls `score()` on both sides of every comparison, so a list
of *n* items costs roughly 2·n·log n score computations instead of n.

**Where.** `MangaBaka/Core/Library/TasteRanker.swift:74-83` — `score(series(lhs.element))`
and `score(series(rhs.element))` inside `sorted(by:)`.

**Why it matters.** `score` is not free: it reads `series.richTags` (an array), reduces over
it with a dictionary lookup per tag, and calls `pow`. For a 50-item mix batch that is ~560
score calls rather than 50, on the main actor, on the path that deals the next cards. It is
small today only because F1 makes every score an early return; fixing F1 makes this the
cost it was always meant to be.

**Fix.** Decorate–sort–undecorate:
`items.enumerated().map { ($0.offset, $0.element, score(series($0.element))) }` then sort on
`(score desc, offset asc)` then `map`. Same result, same tie-break, n score calls.

**Effort.** A function. **Confidence.** Certain. **Lens.** 3 (optimisation — work done more
than once), and the charter's "computed and discarded".

---

### F10 — `refill`'s task bookkeeping clobbers a newer refill; `resetStack`'s cancel does not stop the append

**What.** Two related problems in the same three lines.

(a) `refill()` sets `refillTask = nil` unconditionally after its own task finishes, without
checking that the task it is clearing is still the current one. (b) `resetStack` cancels
`refillTask`, but neither `performRefill` nor `append` checks `Task.isCancelled`, so the
cancelled refill can still append to the queue `resetStack` has just emptied — which is the
exact failure the cancel was added for (work-list 84).

**Where.** `MangaBaka/Features/Stack/StackModel.swift:304-312` (`refill`), `:412-413`
(`refillTask?.cancel(); refillTask = nil`), `:319-363` (`performRefill`, no cancellation
check), `:372-386` (`append`, no cancellation check), `:429` (`await loadIfNeeded()`, which
starts a second refill).

**Why it matters, with the sequence.** The reader taps Reset while a refill is in flight.
`resetStack` cancels task A and nils the handle, clears the shelf, empties `queue`, then
`loadIfNeeded` → `refill` sees a nil handle and starts task B. Task A's network call is
already past its suspension point, so it returns, calls `append(fresh)` — and the freshly
reset stack is dealt cards drawn from the seeds that were just thrown away. Then task A's
original `await task.value` in the first `refill()` resumes and runs `refillTask = nil`,
clearing *B's* registration, so the next `react()` that drops the queue to two cards starts
task C alongside B: two concurrent feed requests against the shared rate limit, which is
the thing `refill`'s dedup was written to prevent (`:296-303`).

**Fix.** (a) `refill()` → `if refillTask == task { refillTask = nil }` (`Task` is
`Equatable`). (b) Give `performRefill` a generation counter bumped by `resetStack`, or check
`Task.isCancelled` at the top of `append` and immediately after each network await in
`performRefill`, and return without appending. Do not rely on `URLSession` honouring
cancellation — `repository.feed` may serve a cached answer with no suspension at all.

**Effort.** A function. **Confidence.** Likely — (a) is certain from reading; (b) depends on
whether `repository.feed` ever returns without an await, and a cached feed does exactly
that. The measurement that settles it: a test that cancels a refill whose provider returns
synchronously and asserts `queue.isEmpty` after `resetStack`. **Lens.** 1 (bugs), 6 (load
balancing).

---

### F11 — The CSV round trip corrupts a note that starts with `=`, `+`, `-` or `@`

**What.** `LibraryExport.defused` prefixes such a field with an apostrophe so a spreadsheet
does not execute it as a formula. `LibraryImport.parseCSV` does not strip it, so a
re-imported note comes back one character longer than it went out.

**Where.** `MangaBaka/Core/Library/LibraryExport.swift:193-196` (`defused`), applied to the
note at `:156`; `MangaBaka/Core/Library/LibraryImport.swift:141`
(`note: field(row, "note")`) — no inverse.

**Why it matters.** The brief asks whether the round trip is faithful. For raw states it now
is (verified — see "What this slice does well"). For notes it is not: a note reading
`-dropped after vol 3` restores as `'-dropped after vol 3`, and because `changeSet` compares
the imported note against the current one (`LibraryImport.swift:501-503`), the import spends
a real PATCH to write the corrupted value into the reader's account. It is not idempotent in
the reader's favour — it silently edits their own text.

**Fix.** In `parseCSV`, undo it: for the `title` and `note` columns only, strip exactly one
leading `'` when the character after it is one of `=+-@`. Keep the rule narrow and put the
`LibraryExport.defused` reference in the comment so the two halves stay visibly paired.
Prove it with a round-trip test over a note starting with each of the four characters —
that test fails today.

**Effort.** A function. **Confidence.** Certain. **Lens.** 1 (bugs).

---

### F12 — `TokenStore.read()` mutates an unsynchronised static on every call

**What.** `keychainQueryCountForTesting` is a `nonisolated(unsafe) static var` incremented
inside `read()` in production, not behind `#if DEBUG` and not behind the cache's lock.

**Where.** `MangaBaka/Core/Auth/TokenStore.swift:74` (declaration) and `:78` (the
increment, immediately before `SecItemCopyMatching`).

**Why it matters here.** It is not my slice's file, but this slice is now one of its
heaviest callers: `LibrarySnapshot.hasCredentials` runs on the snapshot actor
(`AppServices.swift:151`) and `LibraryModel.hasCredentials` runs on the main actor
(`AppServices.swift:191`), both closing over the same `TokenStore`. On a cold launch, or any
time after `invalidate()`, both can reach the un-cached branch from different isolation
domains at once — an unsynchronised read-modify-write on a shared `Int`, which is undefined
behaviour the compiler was explicitly told to stop checking.

**Fix.** Move the counter inside `Cache` behind the existing `NSLock`, and wrap it in
`#if DEBUG` so production pays nothing for a test-only observation.

**Effort.** A line. **Confidence.** Certain that it is a race; the practical consequence is
a wrong test count rather than a crash. **Lens.** 8 (data races the compiler cannot see).

---

## The brief's specific questions, answered

**Does the notification day cap hold?** Mostly yes, and better than I expected — I tried to
break it and could not on the main path. Traced: a candidate whose own date is in the past
(the common case — condition 1a requires `date <= today`, and 1b/2b use a feed timestamp) is
re-dated by `place` to today at 09:00 (`ReleaseReminders.swift:342-350`, the
`guard day > startOfDay(candidate.date)` branch falls *through* for a past date), so it is
recorded in `fired` with a date `>= today` and is correctly counted by the next pass's
seeding at `:294-297`. **The cap therefore holds across a relaunch**, which was the original
leak. It also holds across two overlapping passes, because `reschedule` serialises them
through `rescheduleTask` (`:179-188`) on the main actor, with no await between the read and
the assignment.

Two ways it still bends, neither the original bug:
- **Clock moved backwards.** Set the device back a day and `today` moves back with it;
  `allocated` for the new "today" seeds from nothing, so three fresh slots open while the
  real day's three are still spoken for. `fired[id]` still blocks repeats of the *same*
  event, so this needs genuinely new candidates to exploit. Low severity; worth one line in
  the comment rather than a fix.
- **Timezone change** is self-correcting: `fired` holds absolute dates and `startOfDay` is
  recomputed, so a westward move can fold a "tomorrow 09:00" into today's count. Harmless.

**Can anything else reach `notify`?** No. `notify(id:title:body:at:)` is public on the type,
but grep across the app finds no caller outside `ReleaseReminders` itself
(`performReschedule:236`). `PublisherFollows.check` takes a `notify:` closure
(`PublisherFollows.swift:103`) and `RootView+Session.swift:355-357` deliberately passes
none, with the reason written down. `NotificationPolicy.decide`'s three producers all filter
by `notifiableStates` — 1a at `:129`, 1b at `:151`, 2a/2b through `trackedForCompletion` at
`:172` — and 2c is deleted with its epitaph at `:203-213`. Nothing schedules before the
policy is consulted. **This part is sound.**

**Does the pending-changes replay happen on every path, and do two edits merge?** Merging is
correct: `LibraryChange.merging` (`LibraryService.swift:129-141`) is field-by-field, the
`??` on the double optionals preserves an explicit "clear it", and `rawState` correctly
follows `state`. Both stashes use it (`LibrarySnapshot.swift:337`,
`LibraryModel.swift:453`). The replay happens on the path that caches
(`LibrarySnapshot.swift:173`, before `writeCache` at `:179`). The one path it does **not**
happen on is the concurrent `inFlight` branch — that is F6.

One near-miss I checked and cleared: `LibraryModel.apply(_:to:)` returns early when the row
is not yet loaded (`LibraryModel.swift:456`), which skips the `await snapshot.apply(...)` on
the next line — so I expected the snapshot's own stash to be unreachable. It is not: a row
the reader can edit is a row already on screen, which means the page carrying it has
already landed, which means `snapshot.cached` is still nil and `inFlight` is not. The stash
branch is reachable and correct. And a row that has *not* landed will be fetched from a
server that already holds the write, because `saveLibraryChange` PATCHes before it patches
locally (`RootView+Session.swift:400-405`).

**Can a late page still write, and does the guard leak a task?** A late page can still reach
the observer — F7. The guard does not leak a task: `inFlight` is nil'd by `invalidate()` on
the abandoned path and by `load()` on the committed one. The early `return` at
`LibrarySnapshot.swift:168` correctly does *not* nil `onPage`, because doing so would steal
the replacement walk's observer — that is the subtle bit and it is right. `ReleaseReminders`
does leak one: `rescheduleTask` (`:191`) is never cleared, so the last chained task is
retained for the life of the app. One line, trivial.

**`LibraryExport`/`LibraryImport` raw states.** Faithful now, on both paths — see below.
The remaining round-trip infidelity is notes, not states (F11).

**Is there a second notion of "signed in" that could disagree with `hasCredentials`?** No.
Both closures read `keychain.read() != nil` off the *same* `TokenStore` instance
(`AppServices.swift:87-88`, `:151`, `:191`), and `TokenStore` is a struct wrapping a shared
reference-type cache, so the two cannot diverge. `LibraryModel.hasAccount` is now derived
from `screenState` rather than from a row count (`LibraryModel.swift:100`), and
`headerSubtitle` (`:303`) is derived from the same `screenState` as the body — which is the
real fix, because it removes the possibility of disagreement rather than adding a check.
The only duplication left is that the closure is spelled out twice; if you want it once,
expose `var hasToken: Bool { read() != nil }` on `TokenStore` and pass
`tokenStore.hasToken`. Cosmetic.

---

## What this slice does well

- **The raw-state round trip is genuinely fixed, on both formats.** JSON carries `rawState`
  only when it disagrees with `state` (`LibraryExport.swift:58`); the CSV `state` column is
  `exportedState`, the raw spelling (`:152`), and `parseCSV` reconstructs the pair
  (`LibraryImport.swift:133-142`) instead of dropping the row. Critically,
  `changeSet` compares on the **raw** spellings, not the enums
  (`LibraryImport.swift:494-497`) — without that, two different unknown states both coerce
  to `.considering` and compare equal, and the fix would have been inert. Someone thought
  that through.
- **The comments carry their evidence, with dates and methods.** `LibrarySnapshot.swift:6-15`
  (939 entries, 24.7 MB, 13 requests, three walks a launch, 2026-09-10),
  `LibraryModel.swift:236-240` (43 ms vs 17 µs over fifty reads, 2026-09-11),
  `LibraryModel.swift:288-302` (a simulator walk with the exact header string that
  contradicted the body). Several of these findings were only findable because the comment
  said what the code was supposed to do precisely enough to check.
- **Guesses are labelled as guesses.** `dailyLimit` (`ReleaseReminders.swift:53-60`),
  `sameSeriesCooldown` (`:61-65`), `maxDeferralDays` (`:318-322`),
  `requestSpacing` (`LibraryImport.swift:67-72`), the MAL status mapping
  (`LibraryImport.swift:325-327`), and the 0.7 exponent
  (`TasteRanker.swift:38-43`) all say they are underived. That is the standard in CLAUDE.md
  and it is actually being met.
- **Deleted rather than disabled.** Condition 2c is gone with a nine-line epitaph explaining
  what it did wrong and why the page already says the useful version
  (`NotificationPolicy.swift:203-213`). This is the right treatment of the charter's
  "unreachable code that still looks alive".
- **`Dictionary(uniquingKeysWith:)` over `uniqueKeysWithValues`** in
  `LibraryImport.apply` (`:405-407`), with the reason written down: a trap inside an import
  is the worst place to rely on a caller's invariant. The walk's own dedupe
  (`LibrarySnapshot.swift:207`, `:215`) and the pinned `sort_by=created_at_desc`
  (`LibraryService.swift:283`) are belt and braces on the same hazard, and both are
  explained.
- **No force-unwraps anywhere in the slice.** Grepped `Core/Library`,
  `Core/Notifications`, `Features/{Library,Stack,Shelf}` for `!` on a value and for `try!`:
  nothing. `LibraryList.swift:315` uses `indices.contains` before subscripting. The MAL
  score path (`LibraryImport.swift:303-307`) explicitly declines a force-unwrap it could
  have justified, and says why.
- **`ShelfStore.reactionCount` and `recentlyReactedIDs` count in SQL** rather than fetching
  every timestamp the reader ever produced (`ShelfStore.swift:88-126`), and the second one
  records the real bug it fixed: `reactedIDs().sorted().suffix(60)` was ordering by
  catalogue time, not swipe time.

---

## What I could not determine

- **Whether `repository.feed` can return without suspending** (a warm cache hit). This
  decides whether F10(b) is live or theoretical. *The measurement:* a test that stubs the
  repository to return synchronously, cancels the refill, and asserts `queue.isEmpty` after
  `resetStack`.
- **What `schema=full` costs on the `.mix` endpoint** — the payload delta that F1's fix
  would add to the app's most frequent feed call. *The measurement:* one `curl` against
  `/v2/series/mix?series=<id>&strict=false&limit=50` with and without `&schema=full`,
  comparing `Content-Length`. One request per variant, well inside the 180/min window.
- **Whether MangaBaka's write API can set `startDate`, `finishDate` or `numberOfRereads`.**
  `LibraryImport`'s own doc comment flags this as unsure (`:57-63`) and it is still open —
  the export writes all three and the import can restore none of them, so a restore is
  silently partial. *The measurement:* one PATCH to `/v1/my/library/<id>` with
  `{"start_date": "2026-01-01"}` against a throwaway entry, reading the response back.
- **The 1,954-test suite's coverage of F2, F3 and F6.** I did not read the test files (the
  brief's read-only scope and my token budget went to source). Each of the three should have
  a test that fails before the fix; if one already has a test that *passes* today, that test
  is asserting the bug and is worth reading before the fix lands.

---

## Not re-reported

Nothing here duplicates `docs/reviews/full/SUMMARY.md`'s do-not-fix list as far as I read
it. F1, F2 and F8 are new — each is a change that landed on 2026-09-13/14 whose mechanism
cannot do what its comment says it does, which is the shape the second pass was asked to
look for.
