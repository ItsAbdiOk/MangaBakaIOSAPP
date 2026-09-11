# Deep review — synthesis

2026-09-11. Six read-only slice reviews, 104 findings, ~18,400 lines of Swift read in
full across the six. This pass read all six reports, the charter, `findings-todo.md`
and `unknowns-2026-09-11.md`. Nothing was built, run or edited.

Slice prefixes used throughout, because two reports both numbered their findings `F`:

| prefix | slice | file | findings |
|---|---|---|---|
| `W` | wire — `Core/Networking`, `Core/Model` | `wire.md` | 17 |
| `P` | persistence, `LibrarySnapshot`, Settings stores | `persistence.md` | 12 |
| `R` | reader — `Core/Library`, `Core/Schedule`, reminders | `reader.md` | 25 |
| `L` | library UI — `Features/Library` | `library-ui.md` | 14 |
| `D` | discovery UI — Discovery, Search, Mix, Stack | `discovery-ui.md` | 13 |
| `S` | surface — Detail, Settings, Shared, DesignSystem, App | `surface.md` | 23 |

---

# 1. The three highest-value changes

Value here is reach × wrongness ÷ effort. All three are certain from code that two
or more people have now read, and none needs a decision first.

## 1. `SeriesDetailView.swift:77` and `:87` pass `series` where every sibling passes `shown`

**Surface F1.** Two words.

`shown` is `series.filling(gapsFrom: fetched)` — it exists because a v2 feed payload
carries no `description`, no chapter count, no status and no `source`
(`SeriesDetailView.swift:44-46`). Five children take `shown`; `DetailCredits`
(`:77`) and `TrackerScores` (`:87`) take `series`. Those two views read exactly the
six fields `filling(gapsFrom:)` repairs — `authors`, `artists`, `publishers`,
`contentRating`, `anime`, `source` (`Series.swift:200-215`) — and both render nothing
when their input is empty (`TrackerScores.swift:21`, `DetailCredits.rows`).

**Reach:** every series opened from Discover, the Stack, Mix or a related-series row
— which is most opens. The credits table and "Scores elsewhere" are silently absent.
Open the same series from Search and both appear.

**Why it is first:** it is the largest reach in the review, it is the exact bug
`shown` was written to fix reintroduced in two lines, and the fix is changing two
identifiers. There is no argument to have.

## 2. `SeriesRepository.swift:545-551` discards the whole feed cache on every launch

**Persistence F1.** One line.

`updateLibraryExclusion` is the fourth filter-update function and the only one that
does not call `shouldDiscard` first. At launch `libraryExclusionUserID` is `nil`, so
for any reader with a token `nil != id` and `DELETE FROM feedEntry; DELETE FROM
feedMetadata` runs before the first screen draws.

The comment twenty lines above it (`SeriesRepository.swift:492-504`) describes this
exact bug in the past tense: *"every one of them differed from the empty starting
state, so every launch discarded the entire feed cache before the first screen drew.
Offline support was documented, tested, and silently dead."* It is live again, in the
one sibling the fix did not reach.

**Reach:** every signed-in reader, every cold launch. Offline support is dead for
precisely the readers with the most data. Unauthenticated readers are unaffected,
which is why it survives testing on a signed-out build. It is probably also paying
for a second `.rising` fetch per launch (the discard awaits a network call and can
land after `startSession` has already cached the row) — that half is likely, not
certain.

**Why it is second:** one line, the mechanism it needs already exists and needs no
change, and it is a regression of a bug this project has already paid for once.

## 3. A reader with 937 tracked series, offline, is told their library is empty

**Library-UI L1** (with **L14** as its test). A function.

`LibrarySnapshot` gets this right and says so — *"The failure is carried rather than
swallowed"* (`LibrarySnapshot.swift:27`) — setting `result.failure` and
`isComplete = false`. `LibraryModel.swift:218` stores it. **No view in the app reads
`LibraryModel.failure`.** `apply` then computes
`hasAccount = !rows.isEmpty || !complete` (`:235`) → `false || true` → true, and
`LibraryView.swift:60-66` falls through to `emptyLibrary` at `:139`: *"Nothing saved
yet — Swipe through the stack and anything you keep lands here"*, with an "Open the
stack" button.

**Reach:** anyone on a bad connection, an expired token, or mid-walk. **Wrongness:**
maximal — the app invites a reader with 937 series to start a library.

**Why it is third:** every layer below the view did its job. `DiscoverView.swift:268`
already has the failure branch to copy. The catch is that its test
(`LibraryModelTests.swift:109-115`) exercises `isComplete: true`, the branch a real
reader almost never hits; per CLAUDE.md the sibling test must be shown failing before
the fix lands, and L14 says exactly how.

**Two that nearly made this list, both one or two lines:** persistence **F2** (a token
change leaves the previous account's id in the recommender — and, worse, a first
sign-in never switches exclusion on at all until a relaunch) and surface **F2**
(`grep -rn "UIAccessibility.post\|announcement" MangaBaka/` returns zero hits, so the
toast — the app's only confirmation for every write — is silent to VoiceOver).

---

# 2. Cross-cutting findings

This is the point of the exercise, so each claim below is stated as a count with its
instances named, and each was tested against the reports rather than asserted.

## X1. The characteristic defect is a correct rule applied n−1 times out of n

This is the strongest pattern in the review and no single agent could see it, because
each instance looks local from inside one slice. Twelve findings, spread across all
six slices, have one shape: **a rule this project derived, wrote down, and then
applied everywhere but one place.**

| the rule, where it is written | where it was not applied |
|---|---|
| `shouldDiscard` on a filter change (`SeriesRepository.swift:492-509`) | the fourth filter path — **P-F1** |
| `forgetProfile()` clears account-scoped state | the fifth account-scoped value — **P-F2** |
| a derivation read from a body is stored, not recomputed (`LibraryModel.swift:57-63`, with 3/4/6ms measured) | `shape` in the wrong phase (**L4**), `inProgress` and `subtitle` never moved (**L5**) |
| `shown` is what a detail child takes | two of seven children — **S-F1** |
| `Motion` gates every animating surface (`Motion.swift:7-9` lists the gallery by name) | the gallery's `scrollTransition` — **S-F3** |
| *"'no tags match' and 'the network is down' must not look the same on screen"* (`CatalogueService.swift:85-87`) | `searchPublishers`, eight lines below it — **W10** |
| `allowsFormat` backstops a server that ignores a filter (`SeriesRepository.swift:580-584`) | no `allowsBlockedTags` — **P-F10** |
| `rating > 0` guards a rating (`ReadingInsights.swift:191`) | `criticGap`, `disagreements` — **R19** |
| `verdicts` excludes `planToRead`/`considering`; `TasteLedger` scores them zero | four Wrapped statistics (**R12**), `sampleSize` (**R2**) |
| `.tapTarget()` / `Metrics.tapTarget = 44`, applied at 13 sites | the jump index at 20×13pt (**L7**), `SearchClearButton` at 30pt (**S-F8**) |
| `decodeIfPresent` throughout `Series.init(from:)` | `id`, `state`, `cover` — **P-F9** |
| `guard !isLoading` on `loadIfNeeded` (`StackModel.swift:117`) | `refill`, the entry point that actually fires — **D-A1** |

**Why it happens, and what it implies.** In every one of those rows the rule lives in
a comment or in a call-site convention — never in a type, a signature, or a single
function the next call site is forced through. That is precisely the thing CLAUDE.md
forbids ("never fix a duplication by copying a value into a second place and
documenting the hazard — expose it at its source"), and persistence **F12** names the
mechanism directly: the three filter-update functions are three copies of one idea,
*which is how `updateLibraryExclusion` came to be written twenty lines below them
without the guard.*

**This is an actionable prediction, not an observation.** It says where to look next:
any rule in this codebase that is enforced by convention has an unapplied instance,
and the cheapest way to find it is to grep for the rule's *sites* rather than for its
*statement*. It also says what "fixed" means for eight of the top thirty findings —
not patching the missing site, but moving the rule somewhere it cannot be missed.

## X2. "A model that disagrees with the payload" — HOLDS, and it is really two patterns stacked

The candidate was: does it explain findings in reader and library-UI, not only wire
and persistence? **Yes, in both, and in discovery too.** But testing it showed the
pattern is a compound, and separating the halves is what makes it useful.

**Half A — a field type chosen with no recorded payload beside it.** Wire's evidence
table is the proof: every type with dated evidence is series-shaped; every type with
none is a satellite endpoint added on 2026-09-10/11; and all four mismatches (**W1**
`Price.value`, **W2** `NewsItem.id`, **W3** `SeriesImage.id`, **W4**
`PublisherRecord.id`) are in the second group. Outside wire: **R4** (`ratingCount` is
recorded as absent on v1 and the library is `/v1/my/library`, so the whole "Off the
beaten track" card may never have rendered for anybody), **R13** (`finishDate` on a
drop), **R19** (`rating: 0` vs null — two files in the repo already disagree about
the same field), **L8** (`progressChapter` is `Double` everywhere and the edit sheet
reads it through `Int`, with no recorded payload showing a fractional value in either
direction). Wire's own diagnosis of the cause is right and is the fix: **W13** — the
sweep that claims to cover "every endpoint the app decodes" checks a hardcoded seven
of about seventeen, and the ten it misses are exactly where W1–W4 sit.

**Half B — a failure and an emptiness are the same value.** This is the amplifier,
and it is bigger than Half A. It is what makes Half A invisible, and it causes damage
on its own with no decode involved at all. Instances, by slice:

- wire — twelve of fifteen swallowed-decode sites are indistinguishable from empty
  (`wire.md` §C); **W9** caches a failed genre/tag fetch as an empty success for the
  whole app run; **W10**.
- persistence — **P-F9**, one bad row silently shortens a cached feed and `feed()`
  accepts it as a hit because it checks only `!fresh.isEmpty`.
- reader — **R7** (a cadence that will not decode is presented as a settled "Too few
  dated releases to estimate from", and never retried), **R8** (an unreachable
  network renders as "0 IN SCOPE" *and* silently deletes every pending reminder),
  **R10** (one failed fetch caches an empty release calendar for the process).
- library-UI — **L1**, the top-three item above.
- discovery — **D-B3**, `LensCounts` marks every lens `asked` before counting any, so
  a reader who types one character permanently loses lenses 3–6 for the session.

**The single cause under both halves: the app has no vocabulary for "I could not
ask."** And it is not ignorance — the codebase draws the distinction correctly and
deliberately in five places, each with the reason written next to it
(`CatalogueService.swift:85-87`, `LibrarySnapshot.Result.failure`,
`SeriesRepository+Count.swift:14-16`, `FeedResult.origin`/`blockingError`,
`ReleaseScheduleService.SeriesCadence.none` vs `.unavailable`). What is missing is a
*type* that makes the distinction unavoidable. Every layer re-decides it by hand and
most decide wrong. That is X1 again, in its most expensive instance.

## X3. "Computed, documented as load-bearing, read by nobody" — one pattern, not three coincidences

The candidate named three: `LibraryModel.failure` (L1), `lastSaveWentToLibrary` and
`source` (D-C1, D-C2), and `series` vs `shown` (S-F1). It is one pattern and the
count is nearer eleven: add **S-F9** (`popToRoot`, whose comment states a behaviour
the app does not have), **P-F8** (`CachedSeries.cachedAt` written on every row, read
by nobody, while `AppDatabase`'s doc claims a one-day lifetime that does not exist),
**R20** (`knownTags` cannot detect the failure it was built to detect, because a
series with no tags is never counted), **L3** (`shelves` and everything built on it,
recomputed thirteen times per load for output nothing draws), **W5**
(`volumes(from:)` drops exactly the works its comment promises to keep), **R17**
(`currentSeason`'s comment describes the opposite of the code), **S-F3** (the gallery
glide, documented as fixed), **L6** (a *capability* — per-row edit — that survived
only on the screen nothing presents).

**What makes it one pattern rather than a list: the producer side was written, the
consumer side was not, and the doc comment was written on the producer describing the
consumer.** That ordering is what a design-then-build split produces.

**And there is a second-order cost specific to this codebase.** The comments here are
unusually good — they record measurements with dates and methods, and six of the
seven charter bugs were findable only because of that. The consequence is that a
comment is *trusted evidence* in this repo in a way it is not elsewhere. So a comment
describing an absent consumer does more damage here than in an ordinary project: it
reads as proof the feature works. Every agent independently praised the comment
culture and every agent independently found instances of it misleading them. That is
the trade-off of the practice, and it is worth naming rather than treating the
practice as unambiguously good.

**The mechanical sub-case — comment drift.** Six findings are a comment that has come
unstuck from the thing it documents: **P-F11** (two doc comments in `LibrarySnapshot`
merged into the following declaration — one of them records a real shipped bug),
**D-C3** (an orphaned doc comment marking where a property was half-removed, directly
above D-C1, which looks like the other half of the same unfinished edit), **S-F22**
(three comments describing a 126pt hero cover that is 150pt, one of which *reasons
from* the stale number), **S-F23** (`Metrics`' "one CTA height" comment detached,
welded to `shapeBar`'s, and false as written — `ctaSecondary` has eleven call sites),
**W16** (`subType`'s comment names an enum the schema does not have), **R11** (the
calendar's page-count comment does its arithmetic with a page size the code does not
use). These are cheap individually and they matter collectively for the reason above:
in this repo, a wrong comment is a wrong measurement.

## X4. Throttling is per-call-site, so every new call site starts un-throttled — and the one measurement of request volume cannot see the worst paths

Eight findings, four slices, one cause. No single agent could see it: wire saw the
gate, discovery saw the call sites, reader saw MangaUpdates, persistence saw the
cache that stops the requests happening at all.

- **W6** — `send()`, the one path behind `post`/`patch`/`delete`, never consults the
  gate and never arms it. Ten chapters marked read during a 429 window fire ten real
  requests into it, and a write's 429 does not protect the reads. The limit is per IP
  and shared with strangers; the gate's own comment says so.
- **W8** — writes are invisible to `NetworkLedger`. **So any "N requests per session"
  number is computed with a denominator that omits the burstiest traffic in the app.**
  That is charter pattern 5 sitting under the measurement that would be used to
  justify a budget.
- **R6** — `MangaUpdatesClient.waitForSlot` reads the deadline, sleeps, *then* writes
  it. The `await` releases the actor, so two callers observe the same stale deadline
  and fire together — defeating the spacing the type's own doc says an actor
  guarantees, where the stated cost of getting it wrong is *"a ban costs the feature
  entirely"*.
- **D-A1** — `refill()` has no in-flight guard; three quick swipes issue three
  concurrent refills, each bypassing the cache.
- **D-A2** — every DNA chip tap is a `/v1/series/mix` request with no debounce and no
  serialisation; six strands switched off is six blends, landing out of order.
- **D-A4** — a lens or recent term may search twice, on the 30 req/min budget.
- **R22 / R23** — `refreshReminders` walks up to twenty library pages on every
  foreground, `build()` walks it again independently, and the walk caps at 1,000
  against a reference library of 937.
- **P-F1** — and then the cache that would have absorbed the reads is deleted at
  launch anyway.

**The fix direction is one thing, not eight:** the gate belongs at the client, not at
the call site, and the ledger has to see every request or its numbers are not numbers.
Note the codebase already has both good patterns to copy — `SearchModel.queryDidChange`
(`SearchModel.swift:49-53`) is a cancel-and-replace debounce proven by a *behavioural*
test (`SearchModelTests.swift:57-70`), and `rawData` does the gate handling correctly.
Every finding above is "do what the neighbour already does." X1 again.

## X5. No cache declares what invalidates it, so nine caches have drifted apart

Persistence enumerated eleven SQLite tables and five in-memory caches and found the
four invalidation paths agree on nothing: rating and blocked-tag clear strictly less
than the data their filter governs; format is saved only by a read-side filter the
others do not have; a token change clears a fourth, disjoint set. Two caches added
since (`seriesDetail` in v6, `cachedImages`) are wired into no path at all.

That is P-F2/F3/F4/F5, and the same shape reaches into three other slices: **W9**
(`CatalogueService` caches a failed fetch as an empty success for the session),
**R10** (`ReleaseCalendar` caches `[]` with no expiry and no invalidation path),
**D-B3** (`LensCounts.asked` is an in-memory cache of a failure that is never rolled
back). Nine instances.

**Cause, stated by persistence and confirmed here:** nothing anywhere declares what a
filter or a token *owns*, so each cache is invalidated by whoever remembered, and the
invariant lives in three copied functions instead of one (**P-F12**). The worst
single instance is **P-F4**: change a content rating with the cover gallery open and
the gallery keeps serving the pre-change covers — with the comment five lines above it
saying *"the filter failing on exactly the thing it exists to hide is a bug this app
has already shipped once."*

## X6. Work repeated per body pass, in the one codebase that measured why not to

**L4** (the shape bar rebuilt on every keystroke — 3ms of the file's own measured
number, thrown away, eight times in a typed word), **L5** (`inProgress` and
`subtitle` walk 939 entries on every body pass, one with a sort), **L3** (`shelves`
groups and sorts the whole library once per arriving page, thirteen times per load,
on the main actor, for output nothing draws), **D-D1** (`TagBreadth.step` sorts 500
tag counts once per row per body pass — 40 rows while the reader types), **S-F17**
(two 1000pt blurred backdrops, live, cross-fading under a continuously-updating
scroll position, against the project's own written rule that *"nothing that scrolls
is glass"*).

Five findings, three slices, one habit: SwiftUI's body treated as cheap. This one is
listed with a caveat the reports were careful about and I am repeating: **only L4's
3ms is a measured number.** The rest are structural arguments. Per CLAUDE.md, measure
before fixing — and S-F11's signpost work (below) is the cheap way to get all of them
at once.

---

# 3. Everything, ranked by value to effort

104 findings. "Value" is reach × wrongness ÷ effort, as above. Effort uses the
reports' own vocabulary: *line* / *lines* / *function* / *file* / *decision*.

**Read the bands, not the exact ranks.** Within a band the ordering is a judgement
call and I would not defend rank 41 against rank 44. Across bands I would.

**Band A (1–14) — do now.** Certain, broad reach, line-to-function.
**Band B (15–38) — cheap and certain, narrower reach or a smaller lie.**
**Band C (39–58) — settled by one measurement first.** Do the measurement (§6), then
most of these become Band A or disappear.
**Band D (59–78) — real, but a decision or a design call comes first.**
**Band E (79–92) — refactors. Value is in what they prevent, not what they fix.**
**Band F (93–104) — small, cosmetic, or comment drift.** Cheap; do them in one pass.

| # | id | slice | what | effort | conf |
|---|---|---|---|---|---|
| 1 | S-F1 | surface | `SeriesDetailView.swift:77,87` pass `series` not `shown`; credits + tracker scores absent for most opens | two words | certain |
| 2 | P-F1 | persist | every signed-in launch deletes the whole feed cache (`SeriesRepository.swift:545`) | line | certain |
| 3 | P-F2 | persist | previous account's id left in the recommender; first sign-in never enables exclusion | lines | certain |
| 4 | S-F2 | surface | toast is the only write confirmation and VoiceOver never hears it | line | certain |
| 5 | L1 | lib-ui | offline library renders as "Nothing saved yet" to a 937-series reader | function | certain |
| 6 | D-A1 | disc-ui | `refill()` has no in-flight guard; fast swiping fires concurrent uncached refills | line | certain |
| 7 | P-F4 | persist | rating change does not clear the rating-filtered image cache | line | certain |
| 8 | R8 | reader | offline foreground shows "0 IN SCOPE" **and** deletes every pending reminder | function | certain |
| 9 | W9 | wire | one dropped packet empties genre chips + the whole tag tree until relaunch | function | certain |
| 10 | R1 | reader | both catch-up reminders are pushed forward on every launch, so neither ever fires | function | certain |
| 11 | W6 | wire | every write bypasses the rate-limit gate, in both directions | function | certain |
| 12 | R10 | reader | one failed fetch caches an empty release calendar for the process | function | certain |
| 13 | R6 | reader | MangaUpdates spacing defeated by reentrancy; stated cost is a ban | line | certain |
| 14 | P-F5 | persist | `seriesDetail` is invalidated by nothing, ever, and is rating/tag-filtered | function | certain |
| 15 | D-B3 | disc-ui | typing one character permanently loses saved-lens counts 3–6 for the session | line | certain |
| 16 | W10 | wire | publisher-search failure renders as "no results", eight lines under the rule forbidding it | line | certain |
| 17 | P-F3 | persist | a token change serves the previous account's blends for an hour | line | certain |
| 18 | D-B1 | disc-ui | `loadMore` has no query generation; a stale page is appended to a new search | function | certain |
| 19 | R2 | reader | the honesty line under the tag verdicts reports a sample the verdicts did not use | line | certain |
| 20 | R3 | reader | "that much of your library" divided by the rated subset, not the library | line | certain |
| 21 | R9 | reader | "Measured 3 minutes ago" is the newest row's time, printed over six-week-old rows | line | certain |
| 22 | R5 | reader | "From N releases on MangaUpdates" is a count of calendar days | line | certain |
| 23 | D-A2 | disc-ui | every DNA chip tap is a blend; no debounce, out-of-order writes, spinner lies | function | certain |
| 24 | R12 | reader | four Wrapped statistics count series the reader has never opened | line ×4 | certain |
| 25 | S-F3 | surface | the cover gallery's 3D glide ignores Reduce Motion, and is named as fixed | function | certain |
| 26 | L9 | lib-ui | "Nearly half of your library is dropped" is a hardcoded sentence | line | certain |
| 27 | S-F15 | surface | Settings tells the reader the field stays usable while disabling it | line | certain |
| 28 | S-F8 | surface | `SearchClearButton` is the 2.52:1 colour at 30pt, across four fields | lines | certain |
| 29 | P-F9 | persist | one bad cached row silently shortens a feed; caller reads it as a hit | line | certain |
| 30 | L2 | lib-ui | the "All" pill counts 937 over a list of ~500 | line + decision | certain |
| 31 | R16 | reader | the session fallback reinstates the "every 1 day, exactly" pathology at 3 sessions | line | certain |
| 32 | R20 | reader | the TasteLedger diagnostic cannot detect the failure it exists to detect | line | certain |
| 33 | W14 | wire | one bad tag drops all 146 — and the flat fallback hides that it is the degraded list | line | certain |
| 34 | W5 | wire | `volumes(from:)` drops exactly the works its comment promises to keep | function | certain |
| 35 | R18 | reader | the Wrapped world-share denominator falls back to a frozen `304_108` its own doc forbids | line | certain |
| 36 | S-F18 | surface | nothing is `accessibilityIgnoresInvertColors`; Smart Invert makes every cover a negative | lines | likely |
| 37 | S-F19 | surface | Bold Text does nothing anywhere — every style sets an explicit weight | function | certain |
| 38 | L7 | lib-ui | the A–Z jump index is 20×13pt per letter | redesign | certain |
| 39 | W1 | wire | `SeriesWork.Price.value` non-optional vs a nullable-and-required schema; kills the volumes section | line | certain/likely |
| 40 | R4 | reader | `obscurity`/`deepestCut` read `ratingCount`, recorded as absent on v1; card may never have rendered | check first | worth checking |
| 41 | W3 | wire | `SeriesImage.id` non-optional; one bad id loses all 24 covers | line | certain |
| 42 | W2 | wire | `NewsItem.id` non-optional; one null id empties the news rail | function | certain |
| 43 | W4 | wire | `PublisherRecord.id` non-optional; one imprint empties the browse screen | line | certain |
| 44 | P-F10 | persist | `tag_not` is verified only for the endpoint that uses `blocked_tag`, with no client backstop | request + function | worth checking |
| 45 | S-F11 | surface | the 0.08 ms launch number excludes `AppServices.init`, incl. the only synchronous disk I/O | line to measure | certain |
| 46 | L8 | lib-ui | the edit sheet truncates a fractional chapter and writes it back unasked | line + check | likely |
| 47 | R13 | reader | `Year.finished` counts dropped series if the API sets a finish date on a drop | line + check | likely |
| 48 | R19 | reader | two Wrapped statistics count a rating of 0 as a rating | line ×2 | likely |
| 49 | R11 | reader | the calendar fetches 200 of a documented 246, dropping the furthest-out dates | line | certain/likely |
| 50 | D-A4 | disc-ui | a lens or recent term may fire two identical searches on a 30/min budget | line | worth checking |
| 51 | S-F4 | surface | `ScrollEdge` asks the process for a key window, not this view for its scene | function | certain/likely |
| 52 | S-F5 | surface | `heroTitleTravel = 150` is fitted to one text size; B2 returns at AX1+ | function | certain/likely |
| 53 | W17 | wire | `CommunityPulse` counts are `Int` where a measured sibling arrives fractional | lines | worth checking |
| 54 | L5 | lib-ui | `inProgress` + `subtitle` walk 939 entries on every body pass | function | certain/check |
| 55 | S-F17 | surface | two live 1000pt blurs under a dragging finger, against the project's own rule | function | likely |
| 56 | D-D1 | disc-ui | `TagBreadth.step` sorts 500 counts per row per body pass while typing | line | certain |
| 57 | L4 | lib-ui | the shape bar is rebuilt on every keystroke — 3ms, by the file's own number | line | certain |
| 58 | S-F7 | surface | `tapTarget()` grows height only; the 44pt rule is two-dimensional | line + audit | certain/check |
| 59 | R7 | reader | a cadence that will not decode reads as a settled "too few releases", forever | function | certain |
| 60 | W13 | wire | the "every endpoint" contract test checks a hardcoded 7 of ~17 — the cause of 39–43 | file | certain |
| 61 | S-F9 | surface | `popToRoot` has no callers and its comment states behaviour the app lacks | line or delete | certain |
| 62 | D-C2 | disc-ui | `StackModel.source` exists so the screen can stop implying personalisation; no screen reads it | line | certain |
| 63 | D-C1 | disc-ui | `lastSaveWentToLibrary` written twice, read nowhere | line + decision | certain |
| 64 | R21 | reader | nothing can cancel a three-minute schedule build; the cancellation check is unreachable | function | certain |
| 65 | R23 | reader | the schedule's library walk caps at 1,000 against a measured 937 | line | certain |
| 66 | D-B4 / S-F10 | both | `.id(titleRevision)` destroys `DiscoverModel` + `StackModel`; changing a title preference resets the stack | line / function | certain/likely |
| 67 | R17 | reader | `currentSeason`'s comment describes the opposite of the code; a straggler rolls the season back | line + decision | certain |
| 68 | R14 | reader | the binge guard admits an 80-chapter same-day import; `minimumChapters` unlabelled | function + line | certain |
| 69 | R15 | reader | `Cadence`'s three output-shaping constants carry no derivation and no guess label | lines | certain |
| 70 | L10 | lib-ui | 0.6 / 0.3 finish-and-abandon thresholds, underived, in a view file | lines | certain |
| 71 | L6 | lib-ui | the live library row has no edit affordance; the only copy is on the unreachable screen | function | certain |
| 72 | W15 | wire | `preferredCover` has no final fallback and falls back to a language usually nil | line | likely |
| 73 | S-F21 | surface | `SwitchIndicator` is a hand-drawn `UISwitch`; the root cause is offered and is testable | function | likely |
| 74 | S-F14 | surface | `ScaledFont` computes leading from the unscaled size; leading tightens as type grows | function | certain/likely |
| 75 | S-F6 | surface | `Motion` cannot invalidate a view, so two declarative sites keep a stale answer | line ×2 | likely |
| 76 | R24 | reader | lock-screen notifications print series titles with none of the care taken for tag names | function | judgement |
| 77 | R25 | reader | "out today" is filtered out on the only day it could fire (UTC vs wall clock) | line | likely |
| 78 | D-A3 | disc-ui | tag chips re-blend, type chips and the tag sheet do not — same strip, two rules | decision + line | certain |
| 79 | L3 | lib-ui | `shelves` + 5 derived values recomputed 13× per load, read by nothing | file + decision | certain |
| 80 | P-F12 | persist | three filter-update functions are three copies of one idea — the cause of 2, 7, 14 | function | certain |
| 81 | R22 | reader | up to twenty library page requests per foreground; the walk is done twice | file | certain |
| 82 | S-F12 | surface | `AppServices` bundles 19 values and `MangaBakaApp` unbundles them into 19 arguments | file | certain |
| 83 | P-F7 | persist | `series` and `seriesDetail` grow without bound, and the reader is shown the orphan count | function | certain |
| 84 | P-F8 | persist | `cachedAt` written, never read; the doc claims a one-day lifetime that does not exist | line | certain |
| 85 | W11 | wire | `total()` decodes the whole series payload to read one integer from `pagination` | line | certain |
| 86 | W12 | wire | `getBare` and `getRoot` are one function under two names; one has a dead `catch` | line | certain |
| 87 | L14 | lib-ui | the `hasAccount` test covers the branch that cannot happen, not L1's | function | certain |
| 88 | D-B2 | disc-ui | the same append-after-refresh race in `DiscoverModel`, narrower | line | likely |
| 89 | D-E1 | disc-ui | the thrown card's offset is not reset until the library POST returns | line | certain/likely |
| 90 | S-F20 | surface | Settings is the only pushed scrolling screen with no title and no scroll-edge style | lines | certain/likely |
| 91 | L11 | lib-ui | a hand-built switch where `Toggle` would do — **see §5, this is contested** | function | likely |
| 92 | L12 | lib-ui | two rating scales in one app (out of 5 in Library, out of 10 in Wrapped) | decision | certain |
| 93 | S-F22 | surface | three comments describe a 126pt hero cover that is 150pt; one reasons from it | lines | certain |
| 94 | P-F11 | persist | two `LibrarySnapshot` doc comments merged into the wrong declaration | lines | certain |
| 95 | S-F23a | surface | `Metrics`' "one CTA height" comment detached, and false — `ctaSecondary` has 11 sites | line | certain |
| 96 | D-C3 | disc-ui | an orphaned doc comment marking a half-removed property, directly above D-C1 | line | certain |
| 97 | W16 | wire | `subType`'s comment names three values the schema's enum does not contain | line | certain |
| 98 | S-F13 | surface | `MangaBakaApp` carries a dead duplicate of `unsafelyUnwrappedFallback`; its comment is false | delete | certain |
| 99 | S-F16 | surface | `validateToken` takes a token it never uses, hiding load-bearing call ordering | line | certain |
| 100 | S-F23b | surface | `CoverGallery.selection` is set once; a nil moment shows the caption for the page you opened at | line | likely |
| 101 | W7 | wire | the write path's offline detection is narrower, so a dropped signal reads as "something went wrong" | line | certain |
| 102 | W8 | wire | writes are invisible to `NetworkLedger`, so every request-budget number omits them | line | certain |
| 103 | L13 | lib-ui | `monthName` builds a `DateFormatter` per call | line | certain |
| 104 | D-D2 | disc-ui | a lens whose count request fails once never retries (same `asked` bug as 15) | line | certain |

*Note on 101–102: both are one line and both are certain. They sit at the bottom
because their cost is future rather than present — W7 is a wrong headline, W8 is a
wrong denominator in a number nobody has quoted yet. If anyone is about to quote a
request-budget figure, W8 moves to Band A immediately.*

---

# 4. Verdict per slice

Default is fix in place. A rewrite needs an argument, because the comments in this
codebase encode measurements the tests do not capture — and every one of the six
agents independently reported that several of its findings were *only* findable
because of a comment. Deleting a file here deletes evidence.

## wire — **fix in place**, with one targeted replacement

Seventeen findings and none of them is structural. The error taxonomy
(`staleContentRemainsUseful`), the cache-policy rule derived from the threat rather
than the path, `SafeLink`, `Series.filling(gapsFrom:)`'s id guard and
`APIClientTests`' nineteen behavioural tests with a named control are the strongest
engineering in the review. W1–W4 are one line each.

**The one replacement: `APIShapeContractTests.sweepCoversEveryEndpoint` (W13).** Its
endpoint list is a literal retyped inside the test, so an endpoint added to the app is
never added to it and nothing is caught. Derive the list from the source — the grep
wire used (`client\.(get|getBare|getRoot|getResults|total)\(`) is the derivation. This
is the single change that would have prevented W1–W4 and all four bugs the charter
records, because **every decode bug this project has paid for was in a series-shaped
payload, which is the only shape it has ever fixtured.**

## persistence — **fix in place, with one refactor that is not optional**

Eleven of twelve are one line or one function. The slice's own audit (Part 4) proves
no read/write key-strategy mismatch remains anywhere in the app, which is a real
result and closes a whole class.

**The refactor: P-F12.** Collapse the three filter-update functions into one
`apply(key:discards:)`. This is not tidying — it converts F1, F4 and F5 from three
independent omissions into three arguments at one call site, and it is the direct
application of CLAUDE.md's "expose it at its source". Doing F1/F4/F5 as three separate
patches leaves the fifth filter to repeat the mistake.

## reader — **fix in place. Explicitly do not rewrite.**

Twenty-five findings, the highest count in the review, and the verdict is still fix
in place — because this slice also has the best comments in the repo.
`SeasonReading.swift:32-39` keeps a *rejected* rule with the exact input that killed
it and then says the replacement is also a guess and names the dataset needed to
derive it. `UpcomingWork.swift:26-33` keeps the whole story of the `String` price
including that the fixture agreed with the bug. `Cadence.swift:96-100` names two real
series with before and after. A rewrite loses all of it, and re-proposing a dead idea
is precisely what those comments prevent.

**One structural change, not a rewrite: R22/R23.** `ReleaseScheduleService` should
take `LibrarySnapshot` as a dependency the way `TasteProfile` already does — with
`TasteProfile.swift:22-24` stating why in the past tense. That is one file and it
closes the double library walk, the 1,000-entry ceiling, and part of the cold-launch
cost at once.

**And build the fixture.** Reader answered `findings-todo.md`'s open D2 completely:
every piece exists (`AppDatabase.inMemory()`, eight `LibraryProviding` fakes, injected
clocks on both types, and `URLProtocolStub.makeSession()` feeding a real
`MangaUpdatesClient` with **no production change**). It would catch R7, R8 and R9
directly. The one thing to get right first is a fixed clock, or the real 3-second
limiter makes a 55-series test take three minutes.

## library-UI — **fix in place**, plus one product decision that is already open

L1 and L2 are the reader-facing lies and both are cheap. L4/L5 are the derivation
refactor. The slice's `LibraryModelTests.swift:20-27` decodes real JSON *including*
the capitalised `"Series"` key the charter names as a live hazard — the opposite of
the fixture problem — and should be the model for the wire fixtures.

**The decision is the one `unknowns-2026-09-11.md` already raised** (delete
`ShelfDetailView` or wire it up), and this review adds the argument that was missing
from it: **L6.** The per-row edit affordance did not survive the redesign and its only
implementation is on the unreachable screen, so deleting the screen deletes a
capability nobody has noticed is gone. Lift the `contextMenu` +
`accessibilityAction` onto `LibraryList.row` **first**, then the delete-or-wire
question is about a screen rather than about a feature.

**One "use `List`" recommendation to reject, on the slice's own evidence:** moving
`LibraryList` to `List` costs eight elements their `listRowInsets` /
`listRowSeparator` / `listRowBackground`, and the prize (swipe actions) is available
without it — `ShelfDetailView:210` already chose `contextMenu` for exactly this and
wrote down why. Take the `contextMenu`, keep the `LazyVStack`.

## discovery-UI — **fix in place**, and every fix is "copy the neighbour"

Thirteen findings, and the two structural ones both have their correct implementation
already in the same slice: `MixModel` needs the cancel-and-replace task that
`SearchModel.queryDidChange` has (A2/A3), and `SearchModel.loadMore` needs a
generation counter (B1). E3 is worth recording as a *negative* result: rapid swiping
cannot lose or double-count a card, checked and clean — `react` mutates everything
before its first `await` on `@MainActor`. The thing most worth breaking does not
break; only the refill it triggers is unguarded.

## surface — **fix in place, with the review's one genuine replace**

Twenty-three findings, most of them lines. `StateAction`, the `CoverImage` /
`CoverGallery` pair of opposite-but-justified aspect-ratio decisions, `SessionModels`'
recorded bug, and `Typography.swift:61-81`'s reproducible `UIFontMetrics` table are
all worth protecting.

**Replace `ScrollEdge.swift`.** Take real navigation bars on the four tab roots plus
`.scrollEdgeEffectStyle`, which this project already uses on four pushed screens. It
deletes 91 lines, makes S-F4 cease to exist rather than be fixed, and buys
status-bar-tap-to-scroll-to-top, a VoiceOver screen name on four screens that have
none, and automatic adaptation on the next OS. **Keep the comment at
`ScrollEdge.swift:57-62` even though the file goes** — a `GeometryReader` inside a
scroll view's overlay reporting `top == 0` is a measured negative result, and it will
be re-derived by somebody in six months if it is deleted with the code.

That change also unlocks library-UI's `.searchable` conclusion: `.searchable` needs a
bar to attach to, and `LibraryView.swift:106-108` records *why* the screen has none.
**These are the same change**, which neither agent could state alone — library-UI got
close, and this is the confirmation from the other side.

---

# 5. Contradictions between reports

## The one to adjudicate: does a real navigation bar cost the mockup's type ramp?

**Sources.** `docs/apple-experiment/README.md` — which is **not on `main`**; it is on
the `apple-idiomatic` branch (commit `59188b9`), which is worth stating because
anyone following the surface report's citation from `main` will not find it. Against
`surface.md` Q1.

**What surface says.** That the README "frames the choice as 'real navigation bars on
the four tab roots, and you lose a title that moves', presenting `.navigationTitle(.large)`
as the only door", and that this is wrong: a `ToolbarItem(placement: .principal)` or
iOS 26's `.safeAreaBar(edge: .top)` hosts arbitrary content in the bar's own space and
participates in the scroll edge effect, so the mockup's 36pt title at −1.2 tracking
and 1.05 line height can go in there verbatim.

**Adjudication: surface is right about the mechanism and wrong about the disagreement.
They agree on the conclusion, and surface has mildly strawmanned the README.**

Read directly, the README's closing section says: *"the free upgrades come from the
containers … and almost none of them come from the colours and type. **You could take
a real navigation bar on each tab root and keep every other thing about the design.**
That would have made four of tonight's fixes unnecessary and would cost you a title
that moves when you scroll, which the mockup does not draw either way."* That is the
same recommendation surface arrives at, with the same stated cost, and it explicitly
does **not** claim the type ramp is lost.

So the substantive residue — and it is real — is narrower than surface presents:

1. **The README omits the mechanism.** Its "what the system gives" list leads with
   "a title that collapses as you scroll", and it never mentions `.principal` or
   `.safeAreaBar`. A reader could reasonably infer the large title is the only route.
   Surface supplying the mechanism is a genuine addition.
2. **Surface's cost accounting is better.** "One number, nine files"
   (`Metrics.scrollTopInset = 24` plus nine flat `.padding(.top)` call sites) is a
   concrete estimate the README does not give.
3. **Surface's claim carries an untested caveat it does not state.** A `.principal`
   toolbar item is laid out in a standard bar whose height is ~44pt. A 36pt title at
   1.05 line height is ~38pt — it fits, but only barely, and iOS may shrink or clip it
   rather than growing the bar. `.safeAreaBar(edge: .top)` does host arbitrary content
   without that constraint, and it is the newer API of the two. **Neither agent ran
   it.** This is settleable in about twenty minutes on the `apple-idiomatic` branch,
   which already has the screens built — see §6.

**Practical upshot: take the navigation bars.** Both documents recommend it, the type
ramp is very probably safe, and the mechanism to verify is one build on a branch that
already exists. Do not treat the type ramp as at risk until that build says so.

## Library-UI L11 vs surface F21 — the real contradiction, and library-UI loses

**L11** says the hand-built `SwitchIndicator` should be replaced with `Toggle`, calls
it *"the cheapest pattern-6 win in the slice"*, and estimates
`Toggle(isOn:).tint(Palette.accent).labelsHidden()` "renders the same control".

**S-F21** read the note at `SettingsView.swift:76-83` that library-UI did not:
a real `Toggle` was already tried, and it *"only ever responded to a drag across the
switch, never to an ordinary tap"*, ending *"worth revisiting if anyone finds the root
cause."*

**Surface is better evidenced, and it also supplies the root cause library-UI would
have needed:** at `SettingsView.swift:114-128` the row is a `Button` whose *label*
contains the control, and a `Button`'s label is not an interactive region — the
button's own tap gesture wins every tap inside it, while a drag is not the button's
gesture and falls through to the `Toggle`. That matches the reported symptom exactly.

**Resolution:** L11 is not wrong about the goal, it is wrong about the cost. The fix is
not "swap in `Toggle`" — that was tried and failed — it is "stop nesting the control
inside a `Button`", after which `Toggle` works. Anyone acting on L11 alone will
reproduce a failure this project already paid for and recorded. Rank 91 reflects that.

## Agreements worth recording as such (independent confirmation, not duplication)

- **D-B4 and S-F10 are the same finding, found from opposite ends.** Discovery noticed
  `DiscoverModel`/`StackModel` are constructed inline while three sibling models are
  `@State`-held; surface noticed `.id(titleRevision)` at `RootView.swift:72` replaces
  the whole tab tree. Same bug — changing a title preference silently resets the swipe
  stack and re-runs the Discover feed — reached by two independent routes. Treat as
  strengthened, not as two items.
- **Library-UI Q2 and surface Q1 converge on navigation bars first**, from
  `.searchable` and from the scroll edge respectively. Neither knew the other was
  arguing it.
- **No report contradicts another on a factual claim about shared code.** Wire and
  persistence both read `Series.swift` and `APIClient`'s coder config; wire's evidence
  table is silent on `source`, persistence raised F6 about it. That disagreement is now
  settled — see the negative result below — and wire's silence was correct.

---

# 6. What the review could not determine

Every "likely" and "worth checking" in the six reports, with the one measurement that
settles it. These are cheap experiments, and several of them decide whether a Band-A
fix is needed at all.

## The highest-value block: one authenticated API session settles eleven findings

All of these are a `curl` or two against the live API with a token. **W1–W4 alone cost
one `curl` each and wire says settling them is worth more than any other item in that
slice.** Do them in one sitting, and record each payload as a fixture with a
provenance comment — which also starts closing W13.

| finding | the one measurement |
|---|---|
| W1 | `GET /v1/series/{id}/works` on a series with a free or unpriced edition — does `price[].value` ever arrive `null`? |
| W2 | `GET /v1/series/{id}/news` on a series with ANN items — is any `id` null? |
| W3 | `GET /v1/series/{id}/images` on Solo Leveling (24 images) — is any `id` null? |
| W4 | `GET /v1/publishers/search` on a broad query — is any `id` null? |
| W17 | `GET /v0/frontpage/community-pulse` — is any count other than `chapters_read_count` fractional? |
| R4 | `GET /v1/my/library` — is `ratingCount` present on any entry? **If it is absent, the "Off the beaten track" card has never rendered for anybody.** |
| R13 | set one library entry to `dropped` and read it back — does MangaBaka write a `finishDate`? |
| R19 | scan a real library payload — does any entry carry `rating: 0` rather than null? |
| L8 | scan the same payload — does `progress_chapter` ever arrive fractional? If never, the fix is an `Int` and a comment, not a formatter. |
| P-F10 | `GET /v2/series/discover/rising?tag_not=<a common tag>` with and without — is `tag_not` honoured, or ignored the way `type` was measured to be on 2026-09-10? |
| R11 | `GET /v1/works/upcoming` — is the window still 246? |

## The second block: two lines of signpost, and one open item stops being a guess

**S-F11 is the cheapest high-value measurement in the whole review.** `findings-todo.md`
F1 ("cold launch ~900 ms, 598–634 ms of it before our code, which took 0.08 ms") is
reasoning from a number that does not include `AppServices.init` — where the app opens
SQLite, runs any pending GRDB migration, allocates a 32 MB/256 MB `URLCache`, and
constructs seventeen objects of which at least seven read `UserDefaults`.
`Signposts.measure` already exists (`SeriesDetailView.swift:240-241`). Wrap
`AppServices.init` and `AppDatabase.onDisk()`.

If the database open is 40 ms, that is 10% of Apple's 400 ms budget and far cheaper to
fix than unlinking a framework. **Doing the deferral work against the current
unmeasured guess would be charter pattern 5 for the second time on the same finding.**

## The third block: things only a device or a run can answer

| finding | the measurement |
|---|---|
| §5 above | build the `apple-idiomatic` branch with the mockup's 36pt title in a `.principal` toolbar item and again in `.safeAreaBar(edge: .top)` — does it render at size, and does it get the scroll edge effect? ~20 min, and it settles the only adjudicated disagreement in this review |
| D-A4 | drive `onRunTerm`'s two statements through the existing `RecordingRepository` and assert `searchCount == 1` after 600 ms. **The test must fail without the fix or it is not a bug** — that is the whole check |
| S-F18 | turn Smart Invert on, on a device, and open the cover gallery |
| S-F21 | move the `Toggle` out of the `Button` label and tap it — confirms or kills the root cause in one build |
| S-F4 | iPad with Stage Manager and two scenes — does the scrim degenerate to 14pt? |
| S-F5 | series page at AX1 — at what scroll offset do both titles appear? |
| S-F7 | measure the 13 `.tapTarget()` call sites for width; is any current site narrow, or is this future-only? |
| S-F17 | one Instruments capture while swiping the gallery — GPU time for two live 1000pt blurs |
| S-F20 | screenshot Settings beside a sibling pushed screen — how different is the top edge? |
| L5 | signpost `inProgress` and `subtitle`; they are *structurally identical* to three properties measured at 3/4/6 ms, which is an argument, not a number |
| D-D1 | same, for `TagBreadth.step` while typing |
| P-F7 | `SELECT COUNT(*) FROM series` on a device that has been in use a week — how fast does it actually grow? |
| S-Q3 | audit the colour-coded surfaces for Differentiate Without Color: the account dot, the library state colours, and `Palette.stale` vs `Palette.accent`, where the distinction between two similar oranges *is* the meaning |
| R6 | you cannot deterministically reproduce the race. Write the assertion instead: after two concurrent calls, assert the reserved deadline. Reader is right about this |

## One decision that no measurement settles

**`ShelfDetailView`, still open from `unknowns-2026-09-11.md`** — delete or wire up.
This review does not resolve it, but it changes the inputs: L3 adds a cost the
original write-up did not have (`shelves` and five derived values recomputed thirteen
times per load for output nothing draws), and L6 adds an argument the original did not
have (the per-row edit capability exists only there). Deal with L6 first — lift the
`contextMenu` onto `LibraryList.row` — and the remaining question is about a screen
rather than about a feature.

---

# 7. Recorded negative result — persistence F6 is a FALSE POSITIVE

**Do not re-raise this.**

**The claim.** `APIClient` decodes with `.convertFromSnakeCase`
(`APIClient.swift:29-31`), and Foundation applies `keyDecodingStrategy` to dictionary
keys as well as struct keys. `Series.source` is `[String: TrackerEntry]`
(`Series.swift:40`), so the wire's `"manga_updates"` would become `"mangaUpdates"` in
memory while three call sites look it up in snake_case. If true, `mangaUpdatesID` is
nil for every series, which gates **the entire release-schedule feature** —
`ReleaseSchedule.swift:173, 242, 255, 303` and `SeriesDetailView.swift:329`. It was
the largest single finding in the review, and persistence was careful to mark it
**likely, not certain**, and to supply the two-line control that would settle it.

**The control was run, against the real captured `rising.json` fixture, and it
PASSES.** The keys survive. `mangaUpdatesID` resolves. The release schedule is not
gated off. Persistence's second assertion —
`s.source?.keys.contains("mangaUpdates") == true`, predicted to pass — is the one that
does not hold.

**F6 is withdrawn.** So is everything downstream of it: `TrackerScores`'
`case "anime_planet"` / `case "manga_updates"` (`TrackerScores.swift:59-60`) are fine,
and `SeriesMergeTests.swift:29`'s `source: ["manga_updates": …]` fixture is **not** an
instance of charter pattern 2 — it agrees with the wire, not with the bug.

**Three notes, so this stays settled:**

1. **Persistence's corroboration caveat was correct and should be preserved.** The
   report explicitly said finding B5's "0 ESTIMATED OF 0 IN SCOPE" does **not**
   confirm F6, because `inScope` is counted at `ReleaseSchedule.swift:161`, *before*
   the `mangaUpdatesID` gate at `:173`. That reasoning stands on its own and it
   correctly predicted that B5 has a different cause. **R8 is that cause** — the
   schedule's library walk uses the error-swallowing `library(page:limit:)`, so an
   unreachable network renders as "0 in scope". Two agents converged on the right
   answer from opposite directions.
2. **The result is settled; the mechanism is not.** Foundation applying
   `convertFromSnakeCase` to `[String: T]` keys is documented behaviour and a
   well-known gotcha, so *why* the keys survive here was not established by the
   control — only *that* they do. Per CLAUDE.md, a negative result is worth more with
   its reason attached. **Keep the control test in the suite and add one line of
   comment naming the mechanism once someone establishes it**, or the next reader
   re-derives the same alarming and wrong conclusion from the same correct general
   knowledge. The test itself is the cheapest possible guard: if the behaviour ever
   changes, it fails.
3. **This is the review's best argument for its own method.** The largest finding
   produced by six careful agents was wrong, and it was wrong in the direction of
   alarm. It was caught because the agent that raised it wrote down the control that
   would kill it instead of writing down a fix. Every "likely" in §6 deserves the same
   treatment before anyone edits anything.

---

# 8. What this codebase does well

Stated with the same evidence standard, because an all-negative summary of 104
findings would be a false picture, and because several of the findings above were
findable **only** because of the habits below.

- **Comments record measurements with their dates and methods.** All six agents
  independently said so, and all six said it was why they found what they found.
  `SeriesRepository.swift:566-575` does not say "we also filter client-side" — it says
  *"Measured against the live API on 2026-09-10: `/v2/series/discover/rising?type=manga`
  answered with fourteen manhwa out of twenty."* That one comment is the entire reason
  P-F10 was a question worth asking.
- **Negative results are written down where the code is.** `SeasonReading.swift:32-39`
  keeps the rejected rule *and* the input that killed it *and* says the replacement is
  also a guess. `SeriesRepository.swift:219-223` records a comment that asserted the
  opposite and held up for months "because a single seed has no comma in it."
  `LibrarySnapshot.swift:162-170` names the wrong behaviour, the exact key, the
  symptom (939 rows of "Untitled series"), the date and the rule.
- **Failure is distinguished from emptiness — deliberately, five times, each with the
  reason.** X2 is about the places it was not; it is worth noting the app invented the
  distinction before anyone told it to.
- **Defences written before the bug.** `identifyingParameters` (`APIClient.swift:343-347`)
  pre-lists `blend_user_id`, a parameter the app does not yet send, specifically so
  adding it cannot be the change that quietly starts caching an account id in a 256 MB
  on-disk cache.
- **`StateAction` fixes a duplication at its source** by reading
  `@Environment(\.isEnabled)` inside the component, so every caller gets the disabled
  treatment right by default — which is exactly the thing CLAUDE.md records two agents
  getting wrong.
- **`APIClientTests` opens with a test literally named "Control — a well-formed
  response decodes."** That is CLAUDE.md's control rule honoured rather than cited.
- **Privacy is a design constraint, not a checkbox.** Spoiler tags excluded from
  Wrapped because of someone looking over the reader's shoulder;
  `summary(hiding:)` built from an actual device observation; nothing registered with
  any server. (R24 is a gap *in* this pattern, which is why it is worth fixing.)
- **No force-unwraps reachable from real input.** The charter asked for this to be
  re-verified rather than assumed. **Four agents verified it independently across
  their slices** — wire (25 files), persistence (2,015 lines), library-UI (13 files),
  surface (34 files) — and it holds in all four. `AppServices.makeDatabase` even falls
  back to an in-memory database rather than crashing on a corrupt cache.
