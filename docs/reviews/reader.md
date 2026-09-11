# Slice review — Core/Library (minus LibrarySnapshot) + Core/Schedule

Read-only review, 2026-09-11. 2,714 lines across 15 files, all read in full. No
build, no test run, no edits outside this file.

Also read where a claim needed grounding: `Features/Library/WrappedView.swift`,
`Features/Library/ReadingInsightsView.swift`, `Features/Schedule/ScheduleRow.swift`,
`Features/Schedule/ScheduleModel.swift`, `App/RootView+Session.swift`,
`Core/Model/Series.swift`, `Core/Notifications/ReleaseReminders.swift`
(named in the brief; it lives outside `Core/Schedule/`).

25 findings. Nothing here re-reports an item closed in `docs/findings-todo.md`
or `docs/unknowns-2026-09-11.md`.

---

## Tier 1 — the app says something false to the reader

### R1. Both catch-up reminders are pushed into the future on every app launch, so an active reader never receives either

- **What** — `reschedule` removes every pending notification and re-adds the two
  `catchUp` nudges at `now + 24h` and `now + 30 days`, and it runs on every
  foreground. A reader who opens the app at least once a day never reaches
  either fire date.
- **Where** — `MangaBaka/Core/Notifications/ReleaseReminders.swift:81`
  (`await centre.removeAll()`), `:146` (`date: Date().addingTimeInterval(60 * 60 * 24)`),
  `:161` (`60 * 60 * 24 * 30`), driven by
  `MangaBaka/App/RootView+Session.swift:118` inside `startSession()`.
- **Why it matters** — these are the two the file's own doc calls "the ones that
  solve the problem a tracker actually has"
  (`ReleaseReminders.swift:123-127`). The input is not exotic: opening the app
  once a day. The announced and predicted reminders survive because their dates
  are absolute (`work.date`, `cadence.due`); only the two relative ones are
  reset, so the feature looks like it works while the half that was the point of
  it silently never fires. Charter pattern 3 — computed, then discarded, with a
  comment explaining why it matters.
- **Effort** — a function. The dates have to be anchored to something stable
  (first-seen date persisted per id, or a fixed hour-of-day boundary) rather
  than to `Date()` at reschedule time.
- **Confidence** — certain on the mechanism; `ReminderTests.swift` has six
  tests and none of them reschedules twice, which is why it survived.

### R2. The honesty line under the tag verdicts reports a sample the verdicts did not use

- **What** — `verdicts` excludes `planToRead` and `considering` before counting;
  `sampleSize`, which supplies the "from N of your M series" line printed
  beside them, does not.
- **Where** — `MangaBaka/Core/Library/ReadingInsights.swift:183`
  (`guard entry.state != .planToRead, entry.state != .considering`) against
  `:218` (`entries.filter { $0.series?.richTags.isEmpty == false }`).
  Rendered at `MangaBaka/Features/Library/ReadingInsightsView.swift:200-201`.
- **Why it matters** — the line exists specifically because "a verdict drawn
  from 87 of 939 series is a different claim from one drawn from all of them"
  (`ReadingInsights.swift:214-216`). Named input: a library with a large
  plan-to-read shelf — say 300 tagged plan-to-read entries out of 939 — reports
  a sample of 600 for a verdict computed from 300. The one number on the screen
  whose job is to stop the reader over-trusting the verdict is itself inflated.
  Charter pattern 5, in the measurement that was added to prevent pattern 5.
- **Effort** — a line: give `sampleSize` the same state guard, or better, have
  `verdicts` return its own count.
- **Confidence** — certain.

### R3. "That much of your library" is computed over a denominator that is not the library

- **What** — `obscurity` divides by `counts.count`, the number of entries
  carrying a `ratingCount`, and returns that sample alongside. The card prints
  the percentage and drops the sample on the floor, wording it as a share of the
  whole library.
- **Where** — `MangaBaka/Core/Library/ReadingWrapped.swift:175-180`
  (`return (Double(obscure) / Double(counts.count), counts.count)`);
  `MangaBaka/Features/Library/WrappedView.swift:187-193` — the card takes
  `(share: Double, sample: Int)` and never renders `sample`.
- **Why it matters** — named input: a library where 40 of 939 entries carry a
  `ratingCount` and 30 of those are obscure. The card announces "76% barely
  rated. That much of your library has fewer than 500 ratings." The true figure
  over the library is 3%. The file's own opening doctrine is "Every figure
  carries the size of the sample it was drawn from, because a verdict on 9 rated
  series and a verdict on 400 are different claims"
  (`ReadingWrapped.swift:16-18`) — the value is computed and then not shown.
- **Effort** — a line in the view, plus a wording change.
- **Confidence** — certain that the sample is dropped; certain that the wording
  says "your library".

### R4. `obscurity` and `deepestCut` read a field the library endpoint does not return

- **What** — both depend on `series.ratingCount`, which this codebase records as
  present on v2 and absent on v1. The library comes from `/v1/my/library`.
- **Where** — `MangaBaka/Core/Library/ReadingWrapped.swift:176`
  (`entries.compactMap { $0.series?.ratingCount }`) and `:190`;
  `MangaBaka/Core/Model/Series.swift:44-47` — *"How many people rated it. The
  reverse of `year`: present on v2, absent on v1."*;
  `MangaBaka/Core/Library/LibraryService.swift:169` — `"/v1/my/library"`;
  `MangaBaka/Core/Library/TasteLedger.swift:16-17` — *"The library endpoint
  returns the same v1 series objects."*
- **Why it matters** — if that recorded measurement still holds, `counts` is
  empty, the `>= minimumForCriticGap` guard at `:177` fails, `obscurity` returns
  nil, `deepestCut` returns nil, and the whole "Off the beaten track" card has
  never rendered for anybody. It is the same silhouette as the four decode
  bugs in charter pattern 1: an absent section is indistinguishable from a
  reader who happens to have no obscure series. The `decades` slice, by
  contrast, reads `year`, which the same comment says *is* on v1 — so the two
  fields were split deliberately and one side of the split was not carried
  through to this file.
- **Effort** — worth ten minutes against a live library response before deciding;
  the fix is either a merge from a v2 fetch or deleting the card.
- **Confidence** — worth checking. I am asserting the code path, not the payload
  — I have not hit the endpoint. But if `ratingCount` is nil on v1, the
  consequence above is certain, and this is exactly the kind of thing the
  charter says to distrust.

### R5. "From N releases on MangaUpdates" is not the number of releases, nor the number the estimate used

- **What** — `samples` is set to `days.count`, the count of *distinct calendar
  days*, after the estimate has actually been computed from `sessionStarts`.
  The row prints it as a release count.
- **Where** — `MangaBaka/Core/Schedule/Cadence.swift:138` (`samples: days.count`),
  built from `:84` (`Set(dates.map { calendar.startOfDay(for: $0) })`), while the
  gaps come from `:106-108` (`measured = sessionStarts.count >= minimumDates ? sessionStarts : days`).
  Printed at `MangaBaka/Features/Schedule/ScheduleRow.swift:114` —
  `"From \(cadence.samples) releases on MangaUpdates · last \(last)"`.
- **Why it matters** — named input: a series that ships 3 chapters every
  Saturday, 40 releases fetched. `days.count` is about 14; the actual releases
  are 40; the gaps the median came from are about 13. The row says "From 14
  releases", which is wrong in both directions depending on which question the
  reader thought they were asking. This is the schedule's only confidence
  disclosure, and it is the only number on the card that is not derived from
  what it claims to describe. Charter pattern 5.
- **Effort** — a line, plus a decision about which number is meant (I would pass
  both: `releases` and `gaps`).
- **Confidence** — certain.

### R6. The MangaUpdates rate limiter is defeated by exactly the concurrency its doc says the actor prevents

- **What** — `waitForSlot` reads `nextAllowedRequest`, `await`s the sleep, and
  only then writes the new value. The `await` is a suspension point that
  releases the actor, so a second caller entering during the sleep observes the
  same stale deadline, computes the same wait, and fires at the same moment.
- **Where** — `MangaBaka/Core/Schedule/MangaUpdatesClient.swift:141-152`.
  Line 146 is `try await Task.sleep(for: .seconds(wait))`; line 151 is
  `nextAllowedRequest = clock.now.addingTimeInterval(Self.minimumInterval)`.
  Contradicts the type's own doc at `:7-8` — *"An actor so the spacing cannot be
  defeated by concurrent callers."*
- **Why it matters** — named input: the reader opens a series page (which calls
  `cadence(for:)`, `ReleaseSchedule.swift:301`) while a schedule build loop is
  already running (`ReleaseSchedule.swift:263`). Both are separate tasks into
  the same actor. The stated cost of getting this wrong is in the same file:
  *"a ban costs the feature entirely"* (`:13`). Actor isolation protects the
  variable, not the interval — reserving the slot before sleeping does.
- **Effort** — a line: set `nextAllowedRequest` from the computed deadline
  *before* the `await`, then sleep.
- **Confidence** — certain about the reentrancy; likely about how often two
  callers overlap in practice.

### R7. A cached cadence that fails to decode is presented to the reader as a settled "too few releases", and never retried

- **What** — `readCache` decodes the stored payload with `try?`. A failure
  yields `cadence: nil, failure: nil`, and both readers treat "null cadence with
  a timestamp" as a final answer.
- **Where** — `MangaBaka/Core/Schedule/ReleaseSchedule.swift:344` —
  `cadence: payload.flatMap { try? decoder.decode(Cadence.self, from: $0) }`.
  Consumed at `:193-197` (*"A null cadence WITH a timestamp is a settled answer,
  not a gap"* → `reason: .tooFewReleases`) and at `:247`
  (`return row.failure != nil` — so `build()` will not retry it, ever, without
  `refresh: true`).
- **Why it matters** — named input: any change to the `Cadence` struct that
  breaks its stored JSON shipping to an existing install. `season` was added to
  `Cadence` recently (`Cadence.swift:28`, commit "Say which season a series is
  on"); it is `var Int?` so it decodes, but the next required field will not.
  The result is every series on the schedule reading "Too few dated releases to
  estimate from" — a confident, specific, false statement about the series,
  frozen permanently. This is charter pattern 1 in its purest form: a `try?`
  around a decode where the failure and the empty answer are indistinguishable
  to the caller.
- **Effort** — a function. Distinguish "no payload" from "payload that would not
  decode"; the latter should read as `failure != nil` so the next build retries.
- **Confidence** — certain about the code path.

### R8. `worksInScope` uses the error-swallowing library call, so an unreachable network renders as "0 in scope"

- **What** — it calls `library.library(page:limit:)`, which returns `[]` on any
  failure. An empty first page breaks the loop, and the screen shows an empty
  schedule with `inScope = 0`.
- **Where** — `MangaBaka/Core/Schedule/ReleaseSchedule.swift:138` —
  `let batch = await library.library(page: page, limit: 100)`, then `:139`
  `if batch.isEmpty { break }`. The throwing alternative exists and its doc
  names this caller: `MangaBaka/Core/Library/LibraryService.swift:156-157` —
  *"Callers that need to tell 'empty' from 'could not ask' — which is most of
  them — should use `libraryPage` instead"* — and `:164-166` records that
  conflating them *"told a signed-in reader with 937 series that they had no
  account"*.
- **Why it matters** — named input: open the Schedule tab on a bad connection.
  The screen reads "0 ESTIMATED OF 0 IN SCOPE", which is item B5's dead screen
  and is indistinguishable from a reader with nothing to schedule. The same
  swallowed failure also reaches `refreshReminders`
  (`RootView+Session.swift:133`), which then calls `reschedule` with an empty
  snapshot — and `reschedule` starts with `removeAll()`
  (`ReleaseReminders.swift:81`). So one foreground launch with no network
  silently deletes every pending reminder the reader had.
- **Effort** — a function in `ReleaseScheduleService`, plus a state on
  `ScheduleSnapshot` so the screen can say "could not ask" — and a guard in
  `refreshReminders` so an unreadable library does not wipe the pending list.
- **Confidence** — certain for the schedule screen; certain for the reminder
  wipe, having read both call sites.

### R9. "Measured 3 minutes ago" is the newest row's timestamp, presented as the whole schedule's

- **What** — `measuredAt` is the maximum `fetchedAt` across cached rows. The UI
  renders it as a statement about the schedule.
- **Where** — `MangaBaka/Core/Schedule/ReleaseSchedule.swift:185` —
  `newest = max(newest ?? row.fetchedAt, row.fetchedAt)` — and `:207`.
  Rendered at `MangaBaka/Features/Schedule/ScheduleModel.swift:82` —
  `"Measured \(formatter.localizedString(for: measuredAt, relativeTo: Date()))"`,
  and it also drives `remeasureLabel` (`:85`) and `hasNeverMeasured` (`:93`).
- **Why it matters** — named input: measure 55 series, come back six weeks
  later, open one series page (which writes a fresh row via `cadence(for:)`).
  The Schedule header now says "Measured 1 minute ago" over 54 rows that are six
  weeks old. `snapshot.stale` counts them correctly at `:186`, so the honest
  number is computed and the flattering one is the headline. Charter pattern 5 —
  a metric whose denominator nobody stated.
- **Effort** — a line: use the *oldest* row, or show both ends.
- **Confidence** — certain.

### R10. One failed fetch caches an empty release calendar for the rest of the process

- **What** — `upcoming()` assigns `cached` unconditionally after the loop. If
  page 1 fails or decodes to nothing, the loop breaks with `all` empty and `[]`
  is cached with no expiry and no invalidation path.
- **Where** — `MangaBaka/Core/Schedule/ReleaseCalendar.swift:38-40`
  (`guard let batch ... , !batch.isEmpty else { break }`), `:48` (`cached = all.sorted`),
  `:30` (`if let cached { return cached }`). Nothing in the file resets `cached`.
- **Why it matters** — named input: open the app in a lift. Every later call —
  including `refreshReminders`'s `calendar.mine(...)`
  (`RootView+Session.swift:134`) — returns nothing for as long as the app stays
  alive, so the announced releases, the one part of the schedule that is a fact
  rather than an estimate, are absent with no indication. A partial failure is
  worse: pages 1-2 succeed and 3 fails, and 100 works are cached as the complete
  window.
- **Effort** — a function: cache only on a complete, successful walk, and add a
  timestamp so a date-sensitive list expires.
- **Confidence** — certain.

### R11. The calendar fetches 200 works from a documented window of 246

- **What** — 4 pages of 50. The endpoint's own recorded measurement in this
  repo is 246 works in the window. The comment justifying the cap does the
  arithmetic with a page size the code does not use.
- **Where** — `MangaBaka/Core/Schedule/ReleaseCalendar.swift:17-20` —
  *"One page is twenty; the window is a few hundred. Four pages covers the
  month"* — against `private static let perPage = 50` on the next line and
  `pages = 4`. The 246 is recorded at
  `MangaBaka/Core/Schedule/UpcomingWork.swift:12`.
- **Why it matters** — the API returns the window sorted by date ascending
  (`UpcomingWork.swift:12-13`), so the 46 dropped works are the *furthest-out*
  dates. A reader whose volume is number 210 in the window sees nothing, and
  `ReleaseCalendar.mine` reports it as not upcoming. The comment is also an
  underived constant justified by an arithmetic that does not hold — 4 x 20 =
  80, 4 x 50 = 200, and neither is 246.
- **Effort** — a line (`pages = 6`), plus correcting the comment.
- **Confidence** — certain on the arithmetic; likely on the consequence, which
  assumes the 246 measurement still holds.

---

## Tier 2 — a claim about the reader built from data that is not about their reading

### R12. Four Wrapped statistics count series the reader has never opened

- **What** — `signatures`, `formats`, `creators` and `decades` are given the
  entire library with no state filter. `ReadingInsights.verdicts` filters
  `planToRead` and `considering` for exactly this reason; `TasteLedger` scores
  them at zero for exactly this reason. These three do not.
- **Where** — `MangaBaka/Core/Library/ReadingWrapped.swift:67` —
  `let tagged = entries.filter { !($0.series?.richTags.isEmpty ?? true) }`;
  `MangaBaka/Core/Library/ReadingWrappedYear.swift:157` (`formats`), `:162`
  (`decades`), `:175-180` (`creators`). Called with the unfiltered library at
  `MangaBaka/Features/Library/WrappedView.swift:78, 85, 86`.
  The two places that get it right: `ReadingInsights.swift:183` and
  `TasteLedger.swift:57-58, 64` — *"Plan-to-read and considering score zero.
  Nothing has been read, so counting them would measure ambition rather than
  habit."*
- **Why it matters** — named input: a reader with a 400-entry plan-to-read
  shelf. "The people you read most" is a list of authors they have never read;
  "your signature tags" is built from a backlog. `ReadingWrapped`'s own opening
  rule is that a statistic is only interesting if it could have come out
  differently — but the failure here is stronger than uninteresting, it is
  false: the screen's captions say *read*.
- **Effort** — a line each, or better a shared `entries.readAtAll` helper so a
  fifth statistic cannot be added without it.
- **Confidence** — certain.

### R13. `Year.finished` counts anything with a finish date in the year, including dropped series

- **What** — no state filter. The struct field is named `finished`, the card is
  a year in review, and the only test applied is `finishDate`'s calendar year.
- **Where** — `MangaBaka/Core/Library/ReadingWrappedYear.swift:42-45` —
  `let dated = entries.filter { $0.finishDate != nil }` then a year filter and
  nothing else. Contrast `ReadingWrapped.deepestCut`
  (`ReadingWrapped.swift:189`), which does filter state for the same reason and
  says so.
- **Why it matters** — named input: a library where dropping a series sets a
  finish date (which is what "finished with it" means to most trackers, and this
  reader has 429 dropped entries). The card then says "you finished 61 series in
  2026" and lists things they abandoned, and `chapters` at `:49` adds their
  whole progress to the year's total. Whether MangaBaka sets `finishDate` on a
  drop is the one thing that decides this — the code does not care either way,
  which is the defect.
- **Effort** — a line, once that question is answered.
- **Confidence** — likely. The code path is certain; the trigger depends on the
  API's behaviour, which I could not check.

### R14. The binge guard admits an 80-chapter same-day import, and its own minimum is an unlabelled constant

- **What** — `isPlausible` allows any sprint whose implied reading fits in 16
  hours. At the default 11 minutes a chapter, that is up to 87 chapters in one
  day; for a manhwa at 6 minutes, 160.
- **Where** — `MangaBaka/Core/Library/ReadingWrappedYear.swift:130-134`
  (`hoursPerDay = Double(sprint.perDay) * minutes / 60; return hoursPerDay <= plausibleHoursPerDay`),
  `:92` (`plausibleHoursPerDay = 16`), `:113` (`minimumChapters: Int = 20`).
- **Why it matters** — the 700-chapter Naruto case is fixed and documented at
  `:102-109`, and the fix is real. But the same input at a smaller scale walks
  straight through: a bulk import that stamps `startDate == finishDate` on an
  80-chapter manga, or a 150-chapter manhwa, produces "80 chapters in 1 day" —
  still a backfill, still presented as a binge, and now plausible enough that
  nobody will spot it. The specific tell the guard could use and does not is
  `days == 0` combined with a large chapter count: a genuine one-day binge and
  a backfill are distinguishable by nothing else, which is worth saying out loud
  in the comment.
- Separately, `minimumChapters: Int = 20` at `:113` shapes the output and
  carries no derivation and no `guess` label, in a file where four other
  constants are labelled. CLAUDE.md requires the label.
- **Effort** — a function for the guard; a line for the label.
- **Confidence** — certain on the arithmetic (87 = 16 x 60 / 11); certain on the
  missing label.

### R15. `Cadence`'s three output-shaping constants carry no derivation and no guess label

- **What** — `minimumDates = 4`, `minimumGaps = 3`, and the regularity threshold
  `spread <= max(1.0, median * 0.25)`. The last one decides whether the card
  says LIKELY or LOOSE.
- **Where** — `MangaBaka/Core/Schedule/Cadence.swift:68-71` and `:126-128`.
  The comment at `:126-127` explains *what* the number does ("A quarter of the
  median, floored at a day") and never says where 0.25 came from.
- **Why it matters** — CLAUDE.md: an underived constant must be labelled a
  guess. The charter names this file's neighbours as the good example
  (`SeasonReading`'s two are labelled at `SeasonReading.swift:32-39` and
  `:44-48`, and they are exemplary). `0.25` is the one that reaches the reader
  as a confidence claim, and a reader has no way to know the word "likely" is a
  fitted threshold. Note also that it interacts with the session grouping in
  R16: tightening one moves the other, which is the charter's "two constants
  that interact" tell.
- **Effort** — three lines of comment, or a derivation against the release
  histories already cached on the device.
- **Confidence** — certain.

### R16. The session-grouping fallback reinstates the "1 day, likely" pathology it was written to prevent

- **What** — when fewer than 4 sessions are found, the estimate falls back to
  measuring every distinct day. The comment justifies the fallback for a
  *daily* series, which collapses to one session; a series with 2 or 3 sessions
  takes the same branch.
- **Where** — `MangaBaka/Core/Schedule/Cadence.swift:106` —
  `let measured = sessionStarts.count >= minimumDates ? sessionStarts : days`.
  The pathology it guards against is documented at `:90-94`: *"Measuring every
  day as its own tick makes most of the gaps one day, which drags the median to
  1 AND the spread to 0 — the worst possible pairing."*
- **Why it matters** — named input: a series with 12 releases in three
  consecutive-day bursts (4 chapters each, three weeks apart). `sessionStarts`
  has 3 entries, below `minimumDates`, so `measured = days` — 12 days, of which
  9 gaps are 1 day. Median 1, spread 0, `isRegular` true. The card reads "About
  every 1 day, exactly" and then "38 days overdue" a month later. That is worse
  than refusing to estimate, and refusing is what `minimumDates` exists to do.
- **Effort** — a line: fall back only when `sessionStarts.count == 1`, which is
  the case the comment actually describes.
- **Confidence** — certain that the branch is reachable at 3 sessions; certain
  about the resulting median.

### R17. `currentSeason`'s comment describes the opposite of what the code does

- **What** — the code takes the volume of the release with the newest date. The
  comment says this is chosen so that a late-posted straggler from an earlier
  season cannot roll the season back. Taking the newest release's volume is
  precisely how a straggler rolls the season back.
- **Where** — `MangaBaka/Core/Schedule/SeasonReading.swift:80-82` —
  *"The newest release, not the highest volume: a straggler from an earlier
  season posted late should not roll the season back."* followed by
  `return samples.max { $0.date < $1.date }?.volume`.
- **Why it matters** — named input: a series on season 3 where a scanlator
  posts a missed `v.2 c.140` today. The newest release carries volume 2, the
  page says "Season 2 · chapter 140", and the reader on chapter 235 of season 3
  is told they are a season behind. `describe` at `:93` prints it. Taking the
  max volume among the newest N releases, or the max volume outright, is what
  the comment asks for. Whichever is right, the comment and the code currently
  disagree, and CLAUDE.md's rule is that comments record why with the evidence —
  this one records a rationale for a behaviour that is not there.
- **Effort** — a line plus a decision about which behaviour is wanted.
- **Confidence** — certain that the comment and the code disagree; likely that
  the code is the wrong half.

### R18. The Wrapped world-share denominator falls back to a frozen constant the function's own doc forbids

- **What** — `signatures` documents that `catalogueSize` must be whatever the
  pulse endpoint said, "because it moves every week". The call site supplies a
  hard-coded `304_108` when the pulse is unavailable.
- **Where** — `MangaBaka/Core/Library/ReadingWrapped.swift:59-61` — *"pass what
  it said rather than a constant, because it moves every week"* — against
  `MangaBaka/App/RootView+Session.swift:50` —
  `catalogueSize: session.pulse.pulse?.activeSeriesCount ?? 304_108`.
- **Why it matters** — `lift` is `myShare / worldShare`, and `worldShare` is
  `world / catalogueSize`, so the denominator scales every lift linearly and the
  `minimumLift = 2.0` gate is applied against it. A stale, low catalogue size
  inflates every world share, deflates every lift, and silently empties the
  signature card; a stale high one does the reverse and promotes noise to a
  personality. The constant carries no date, no source and no `guess` label —
  charter pattern 4, and the call site is directly disobeying the contract
  written above it.
- **Effort** — a line: return no signatures rather than signatures computed
  against a made-up denominator, or label and date the constant.
- **Confidence** — certain. (The call site is in `App/`, outside this slice;
  flagged because it determines this slice's output.)

### R19. Two Wrapped statistics count a zero rating as a rating

- **What** — `criticGap` and `disagreements` accept any non-nil `entry.rating`.
  `ReadingInsights.verdicts` guards `rating > 0` in the same repo for the same
  field.
- **Where** — `MangaBaka/Core/Library/ReadingWrapped.swift:136` and `:154`
  (`guard let mine = entry.rating, let crowd = entry.series?.rating`) against
  `MangaBaka/Core/Library/ReadingInsights.swift:191` —
  `if let rating = entry.rating, rating > 0 { ... }`.
- **Why it matters** — named input: an importer or an earlier client that writes
  `rating: 0` rather than null for unrated entries. Each such entry contributes
  a gap of `0 - crowd`, i.e. about -75 on the 0-100 scale. Ten of them are
  enough to clear `minimumForCriticGap` on their own and the card announces the
  reader is a savagely harsh critic who has rated nothing. `disagreements(liked: false)`
  then lists ten series they never rated as the ones they alone disliked.
  Whether the API can produce a 0 is the open question — but `verdicts` already
  decided it could, and the two files disagree about the same field.
- **Effort** — a line each.
- **Confidence** — likely. The inconsistency is certain; the trigger depends on
  whether a 0 rating exists, which one file in this repo already assumes it does.

### R20. The TasteLedger diagnostic cannot detect the failure it was built to detect

- **What** — `knownTags` is documented as existing so that "series counted but
  no tags known" is visible in Settings. But a series with no tags is never
  counted: both `absorb` overloads skip it before writing a `TasteSource` row.
  So `countedSeries > 0 && knownTags == 0` is unreachable.
- **Where** — `MangaBaka/Core/Library/TasteLedger.swift:129-134` — *"series
  counted but no tags known means the library's own payload carries no tags, and
  nothing on screen would otherwise say so"* — against `:78`
  (`guard !tags.isEmpty else { continue }`, before the `TasteSource` write at
  `:91`) and `:150` (`guard !tags.isEmpty else { return }`, before `:158`).
- **Why it matters** — the failure the diagnostic targets is a real risk the
  file itself flags at `:142-147` (the library payload has never been checked
  for `tags_v2` against a live authenticated response). When it happens, both
  numbers read 0, which is indistinguishable from a reader who has not paged
  their library yet. Charter pattern 5: the measurement does not measure the
  thing. A separate count of *entries seen* would.
- **Effort** — a line: record the `TasteSource` row regardless of tags, or add
  a third counter.
- **Confidence** — certain.

---

## Tier 3 — cost, reach and dead paths

### R21. Nothing can cancel a schedule build, so the loop's cancellation check is unreachable

- **Where** — `MangaBaka/Core/Schedule/ReleaseSchedule.swift:253`
  (`if Task.isCancelled { return }`) and `:79` (`private var buildTask`).
  `buildTask` is only assigned (`:224`) and cleared (`:231`); grep for
  `.cancel()` against it finds nothing, and no method on the actor exposes one.
- **Why it matters** — a full build is 55 throttled requests, three seconds
  apart: roughly three minutes during which leaving the screen, signing out, or
  changing the token cannot stop it. It looks handled because the check is
  there. Charter pattern 7.
- **Effort** — a function (`func cancelBuild() { buildTask?.cancel() }` plus a
  caller).
- **Confidence** — certain that nothing cancels it.

### R22. Opening the app makes up to twenty library page requests before anything is shown

- **Where** — `refreshReminders` (`MangaBaka/App/RootView+Session.swift:133`)
  calls `schedule.snapshot()`, which calls `worksInScope()`
  (`ReleaseSchedule.swift:156`) — up to ten pages of 100. `build()`'s `run()`
  calls it again independently at `:236`. A measure-then-read from the Schedule
  screen walks the library twice. `refreshReminders` runs on every foreground
  (`:118`).
- **Why it matters** — this is the same class of cost `LibrarySnapshot` was
  introduced to remove, and `TasteProfile.swift:22-24` says so explicitly:
  *"The shared library walk. Without it this walked the library itself, and the
  library is 24.7 MB."* `ReleaseScheduleService` is still walking it itself,
  and `refreshReminders` is holding a `librarySnapshot.all()` at the same time.
  Relevant to F1's cold-launch work.
- **Effort** — a file: take `LibrarySnapshot` as a dependency the way
  `TasteProfile` does.
- **Confidence** — certain about the call graph.

### R23. The schedule's library walk caps at 1,000 entries against a reference library of 937

- **Where** — `MangaBaka/Core/Schedule/ReleaseSchedule.swift:136-142` — ten
  pages of 100 — with the comment *"ten pages covers a very large library"*.
  `TasteProfile.swift:94-96` records the same cap being hit already: *"Ten pages
  was not — Abdi's library is 937 entries against a 1,000 ceiling."*
- **Why it matters** — 94% of the way to a silent truncation. Past it, in-scope
  series vanish from the schedule and `inScope` under-reports with nothing on
  screen saying the list is partial. The comment's confidence is contradicted by
  a measurement written down elsewhere in the same codebase.
- **Effort** — a line (raise the cap and say what the new one is based on), or
  a file if it moves onto `LibrarySnapshot` per R22.
- **Confidence** — certain.

### R24. Notification titles print series names on the lock screen with none of the care taken for tag names

- **Where** — `MangaBaka/Core/Notifications/ReleaseReminders.swift:142`
  (`title: "\(title) has finished"`), `:157`
  (`"\(biggest.waiting) chapters of \(title) are waiting"`), `:101`, `:90`.
  Compare `MangaBaka/Core/Library/LibraryEntry.swift:143-152`, which records a
  device observation — a card captioned with explicit tag names in public — and
  builds a whole `summary(hiding:)` path around it.
- **Why it matters** — a lock-screen notification is a stronger version of the
  same exposure: it fires unprompted, in whatever room the phone is in, and
  `content.title` is shown even when previews are hidden on some configurations.
  The reader's content-rating preference is known
  (`LibraryService.swift:104`) and not consulted here. Not a bug so much as an
  inconsistency in a judgement this project has already made once and made well.
- **Effort** — a function, reusing the hidden-tag / content-rating machinery
  that exists; or a Settings line letting the reader choose generic titles.
- **Confidence** — certain about the code; this is a judgement call, not a
  defect.

### R25. The "out today" reminder for an announced release is dropped the moment UTC midnight passes

- **Where** — `MangaBaka/Core/Notifications/ReleaseReminders.swift:87` —
  `guard let date = work.date, date > Date() else { continue }`.
  `work.date` is parsed as midnight **UTC**
  (`MangaBaka/Core/Schedule/UpcomingWork.swift:112-118`), while
  `LiveNotificationCentre.add` schedules for 09:00 **local**
  (`ReleaseReminders.swift:209-212`).
- **Why it matters** — a release dated today is already in the past by the
  `> Date()` test for every reader once UTC midnight has passed, so the
  notification whose body literally reads "out today" (`:92`) is filtered out on
  the only day it could fire. West of UTC the loss is up to a full day. The UTC
  parsing is correct and well reasoned; the comparison against a wall-clock
  `Date()` is what breaks it.
- **Effort** — a line: compare start-of-day to start-of-day.
- **Confidence** — likely — certain on the mechanism, and the practical effect
  depends on when `refreshReminders` last ran relative to the window.

---

## Question 3 — the `ReleaseScheduleService` fixture, precisely

`docs/findings-todo.md` leaves D2 open with "needs a database fixture and a fake
MangaUpdates client". Both pieces already exist in this repo; what is missing is
one seam.

**What a fixture needs, and what is already there:**

| piece | status |
|---|---|
| in-memory database with the `cadenceEntry` table | exists — `AppDatabase.inMemory()` (`MangaBaka/Core/Persistence/AppDatabase.swift:48`); the table is created in the migration at `:111`; already used by `TasteLedgerTests` and `ScheduleModelTests` |
| a `LibraryProviding` fake returning paged entries | exists — conformances in `MangaBakaTests/ScheduleModelTests.swift`, `TasteProfileTests.swift` and six others |
| a controllable clock | exists — `ReleaseScheduleService.init(clock:)` (`ReleaseSchedule.swift:85`) and `MangaUpdatesClient.init(clock:)` (`MangaUpdatesClient.swift:27`) |
| a fake MangaUpdates | **missing as a type, but reachable**: `MangaUpdatesClient.init(session:)` (`:26`) takes a `URLSession`, and `URLProtocolStub.makeSession()` already exists (`MangaBakaTests/APIClientTests.swift:16`). So a real `MangaUpdatesClient` can be handed a stubbed session today with **no production change**. |

So the fixture is: `AppDatabase.inMemory()` + a paging `LibraryProviding` fake +
`MangaUpdatesClient(session: URLProtocolStub.makeSession(), clock: fixed)` +
`ReleaseScheduleService(clock: fixed)`. Note the rate limiter is real in that
setup — 3 seconds per request (`MangaUpdatesClient.swift:14`), so a fixed clock
that never advances is required, or a 55-series build test takes three minutes.
That is the one thing to get right first.

**What such a fixture would then reach**, which is most of D2's genuine gap:
`worksInScope`'s pagination and scope filter; `snapshot`'s five branches
(hiatus, no MangaUpdates id, pending, dated, settled-null) and both sorts;
`run`'s todo selection including `refresh: true`; the write/read round-trip
through `cadenceEntry`; the failure-recorded-then-retried path; and
`cadence(for:)`'s cache hit, miss and error branches. It would catch R7, R8 and
R9 directly.

**What stays unreachable even with it:**

1. **Cancellation — `ReleaseSchedule.swift:253`.** `buildTask` is never
   cancelled by anything (R21). A test can only reach this branch by cancelling
   its own enclosing task and hoping the child inherits, which is not what the
   line is there for. Until a `cancelBuild()` exists, this is untestable because
   it is unreachable, not because it is hard.
2. **The stale window before `run` sets `isRunning` — `:221-250`.**
   `build()` returns immediately and `progress.isRunning` stays false until
   `run` has finished `await worksInScope()`. Observing that window requires
   controlling when the library fake's `await` resumes; Swift Concurrency gives
   no supported way to pin an actor between two suspension points. Testable only
   by restructuring `build()` to set `progress` synchronously before spawning —
   which is also the fix.
3. **The rate limiter's reentrancy — `MangaUpdatesClient.swift:141-152` (R6).**
   Proving the double-fire needs two tasks to interleave at a specific
   suspension point. With an injected clock you can *assert the reserved
   deadline* after two concurrent calls, which is a real test of the fix; you
   cannot deterministically reproduce the race itself. Write the assertion, not
   the race.
4. **The cache decode-failure path — `:344` (R7).** Reachable, but only by
   writing invalid JSON straight into `cadenceEntry` with raw SQL; no helper
   does this and none of the model types can produce it. Worth building — it is
   the test that would have caught R7 — but note that it is a test of the
   *storage*, not of any API the service exposes, so it is brittle by
   construction and should say so in a comment.
5. **The 1,000-entry ceiling — `:136-142` (R23).** A fake can return 1,001
   entries, so it is reachable; nothing today asserts what happens at the
   boundary, and the honest test is "the caller is told the list was truncated",
   which requires a production change first because there is currently nothing
   to tell it with.

One caution, since the charter's pattern 2 is fixtures with no provenance: the
MangaUpdates release payload should come from a recorded response, not from
`Release`'s own shape. `MangaUpdatesClient.swift:38-41` already records one
field the reference handoff got wrong (`released` vs `release_date`) — that is
exactly the kind of thing a model-derived fixture would agree with and a real
one would not.

---

## What this slice does well

With the same evidence standard. This is not filler — several of the findings
above were only findable because of the habits below.

1. **Comments record measurements with their dates and methods.**
   `TasteLedger.swift:177-185` — *"Measured at 517ms for 200 series of 40 tags"*
   — states the before-number, the workload, and why the fix went into SQLite
   rather than Swift. `Cadence.swift:96-100` names two real series by title and
   gives the before and after of the session-grouping change. `LibraryService.swift:288-292`
   records that passing `limit` returns zero rows, verified on two values, so
   the omission reads as deliberate rather than forgotten. This is the practice
   CLAUDE.md asks for and it is unusually consistent here.

2. **Negative results are written down instead of deleted.**
   `SeasonReading.swift:32-39` keeps the *rejected* rule and the exact input
   that killed it ("a print volume ending at chapter 20 followed by one starting
   at 9"), then says the replacement is also a guess and names the dataset that
   would be needed to derive it. `UpcomingWork.swift:26-33` keeps the whole
   story of the `String` price, including that the fixture agreed with the bug.
   Nobody will re-propose either idea by accident.

3. **Several types are shaped so a caller cannot forget the uncertainty.**
   `Cadence` splits `confidence` (spread-derived) from `state` (clock-derived)
   and `:45-49` says why the single-field version shipped a green "LIKELY"
   pill on a late chapter. `ReleaseScheduleService.SeriesCadence`
   (`ReleaseSchedule.swift:286-290`) distinguishes `none` from `unavailable`,
   which is the distinction charter pattern 1 is entirely about.
   `ScheduledWork.Reason` (`:13-26`) makes "no estimate" carry its cause to the
   screen.

4. **`MangaUpdatesID` is a whole type for a two-line conversion, and the
   justification at `:8-17` is the strongest piece of writing in the slice** —
   a wrong id returns HTTP 200 with somebody else's releases, so the failure is
   confidently wrong rather than absent. Checking the all-digit case *before*
   base-36 (`:31`) is the kind of ordering bug that would never have been found
   by testing the happy path.

5. **Privacy is handled as a design constraint, not a checkbox.** Spoiler tags
   are excluded from Wrapped with the reason given
   (`ReadingWrapped.swift:76-79` — someone looking over the reader's shoulder).
   `PersonalRecommendation.Reason.summary(hiding:)`
   (`LibraryEntry.swift:143-160`) was built from an actual device observation
   and drops withheld tags rather than substituting. `ReleaseReminders.swift:10-12`
   states that nothing is registered with a server. R24 is a gap in this, and it
   is a gap in an otherwise deliberate pattern.

6. **`LibraryChange`'s double-optional (`LibraryService.swift:63-65`) is the
   right call, made for the right reason and explained in two lines** — `nil`
   means leave alone, `.some(nil)` means clear, and collapsing them would make
   a note uneraseable. Easy to get wrong against a `PATCH` that merges.

7. **`Cadence.estimate` uses a median and says why**
   (`:120-122`) — "a series that ran weekly for a year and then paused for eight
   months has a mean describing neither state". That is the correct statistic
   for the data, chosen with the failure mode of the alternative stated.

---

## Denominator

All 15 files in the slice read end to end. Nine findings are certain from the
code alone; five depend on an API behaviour I could not check (marked "likely"
or "worth checking" and the assumption named in each). No build, no test run.
Three findings (R18, R22, and the reminder-wipe half of R8) point at call sites
in `App/`, outside this slice — flagged because they determine this slice's
output, not reviewed otherwise.
