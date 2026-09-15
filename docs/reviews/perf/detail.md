# Perf review — the series page (`MangaBaka/Features/Detail/**`)

Run "perf", 2026-09-15, HEAD 1f5e632. Read-only; nothing built, nothing run.

**Summary**
- Reviewed 31 of 39 files in the slice in full (8,716 lines total), plus the four Core files the page's requests go through (`SeriesRepository.swift`, `+Works.swift`, `RateLimitGate.swift`, `APIClient.swift`). Skimmed by grep only: `AppleVolumesRow`, `LibraryControl` (past the model), `DetailCredits`, `DetailTagSections`, `CharacterRow`, `TrackerScores`, `DetailCategories`, `PublisherView`, `CharacterProfileView`, `ReadRow`, `SeriesSiblingsSection`, `ReleaseSection`.
- 19 findings: 9 certain, 7 likely, 3 worth checking.
- **Highest-value change (P1):** today's `.background` move made the hero wait. `loadCore` writes `filled`/`isLoading = false` only after *all* four legs return, and five of the eight now *wait at the gate* from 120 held requests where yesterday they succeeded up to 180 — so between 120 and 180 the synopsis, stats and tags now stall until the window drains, on a page that used to render. Fix is a split of `extras` into the two foreground legs and the tail, ~a function each side.
- Second: `LoadingLine` runs a `TimelineView(.animation)` at display rate for the whole life of every series page, active or not (P4).
- Two of today's additions regress fixed items: `originalRun` reshapes the hero column without re-measuring it (item 66 back, P7), and a cancelled `.background` feed writes "Cancelled" into the similar/also rows (item 30 back, P6).

---

## Requests in flight — one cold open, in order

Priorities read from the call sites; "awaited before hero" means `filled`, `synopsis`, `tagGroups` and `isLoading = false` (`SeriesDetailView.swift:628-630`) are not written until it returns. MangaBaka gate: `.userInitiated` throws at 180 held, `.background` waits at 120 (`RateLimitGate.swift:70-75, 194-215, 289-315`). Third parties have their own spacers; none share MangaBaka's window.

**`loadCore` — `SeriesDetailView.swift:593-631`, fired by `.task(id: series.id)` at `:423`, four legs concurrent, awaited in the order listed.**

| # | Leg | Party | Priority | Awaited before hero? | Cache | Could move |
|---|---|---|---|---|---|---|
| 1 | `feed(.similar)` `:606` | MangaBaka | `.background` (waits) | **yes** | 24h | after first paint — it draws at the foot of the page |
| 2 | `feed(.readersAlsoLike)` `:609` | MangaBaka | `.background` (waits) | **yes** | 24h | same |
| 3a | `extras` → `/v1/series/{id}` `SeriesRepository.swift:941` | MangaBaka | `.userInitiated` | yes — the one leg that should be | 6h bundle | no |
| 3b | `extras` → `/works` p1 `+Works.swift:33` | MangaBaka | `.userInitiated` | yes | 6h | below the fold on a long series; above on a short one |
| 3c | `extras` → `/works` last page `+Works.swift:39-41` (only `count > 50`) | MangaBaka | `.background` (waits) | **yes** — awaited *sequentially* inside 3b, and its failure is `try?`-swallowed | 6h | after first paint; it feeds the widget and the badge |
| 3d | `extras` → `/news` `:928` | MangaBaka | `.background` (waits) | **yes** | 6h | after first paint; last section on the page |
| 3e | `extras` → `/relationships` `:936` | MangaBaka | `.background` (waits) | **yes** | 6h | after first paint |
| 3f | `extras` → `/collections` `:945` | MangaBaka | `.background` (waits) | **yes** | 6h | after first paint |
| 4 | `/images` `SeriesRepository.swift:806` via `loadCovers` `+Covers.swift:39` | MangaBaka | `.userInitiated` | yes (awaited at `:627`, after 1–3) | in-memory until relaunch | it already retries itself; could write the fan before the hero settles |

Cold total: 8 MangaBaka requests (9 on a long series). Warm: 0. Matches `detail-page-budget.md`; the ORDER is what that doc did not have, and it is the problem (P1).

**Not in the budget doc, MangaBaka family, first series page per launch only:**

| Leg | Where | Priority | Notes |
|---|---|---|---|
| `LibraryModel.load()` — the whole library walk | `LibraryControl.swift:269-270` → `LibraryModel.swift:379-384` → `LibraryService.swift:255-266` (`getLossy`, no priority argument) | `.userInitiated`, up to 13 pages | Only if the Library tab has not been opened this launch. Then the *first series page* pays 13 foreground general requests alongside its own three, all competing for the same 60-slot reserve. Not throttled, not counted anywhere. |
| `taste.favouredTagNames()` / `favouredTagIDs()` | `SeriesDetailView.swift:703, 713` | default | session-cached, the budget doc's "10th" |

**`loadOnward` — `SeriesDetailView.swift:650-675`, after the hero, ten legs concurrent, never awaited before draw.** Each shows its own skeleton (`isCastLoading`, `isCadenceLoading`, `isLoadingVolumes`, `isLoadingEditions`, `isReleasesLoading`, `isCategoriesLoading`) and all feed `LoadingLine` (`+Covers.swift:130-133`).

| Leg | Party / spacer | Requests | Trigger guard | Could move |
|---|---|---|---|---|
| `loadCast` `+Releases.swift:45` | AniList 0.7 s / Shikimori 0.25 s | 1–2 | a tracker id | behind a tap? The row is the third section; no |
| `loadCadence` `+Releases.swift:89` | MangaUpdates 3 s (shared instance, `AppServices.swift:135,212`) | 1 | MU id + `canPredict` | in the hero — first |
| `loadCategories` `+Categories.swift:14` | MangaUpdates, **same 3 s spacer** → lands ≥3 s after cadence | 1 | MU id | second-to-last section; could wait for scroll |
| `loadAppleVolumes` `+Store.swift:65` | Apple Books 3.5 s | 1–2 (JP fallback) | always | keep — short series show it above the fold |
| → Google | 3.5 s | 0–1 | gaps only | keep |
| → `loadOpenLibraryCovers` `+Store.swift:153` | Open Library 4 s (`HostRateGate.openLibrary`, shared with editions) | 0–12, serial, up to 48 s | coverless ISBNs | **behind scroll** — the pass runs for a shelf nobody may reach |
| `loadEditions` `+Editions.swift:41` → ANN | 1.2 s | 0–1 | ANN id | below the fold; on scroll |
| → Open Library editions | 4 s, same gate as the cover pass | 0–2 | ISBN anchor | on scroll |
| → NDL | 2 s | 0–1 | ja title + ja shelf | on scroll |
| `loadReleases` `+Releases.swift:15` | Webtoons/GigaViewer 3.5 s each, concurrent | 0–N providers | `extras.links` | keep — the "Releases" section is mid-page |
| `loadTaste`, `loadOwned`, `loadSimilarByDescription`, `loadSiblings` | on-device | 0 | — | — |

Worst case per open: 8–9 MangaBaka + up to ~22 third-party (the OL cover pass is 12 of them). The three comments that count this — `+Editions.swift:12-13` ("nine MangaBaka"), `SeriesPager.swift:32` ("nine-request"), `DesignSystem/LoadingLine.swift:6` ("nine requests") — are all stale against the budget doc's 8; the number lives in four places (charter "duplicated constants").

**What competes with a tap.** `RootView+Session.swift:519-527` — tapping a tag fires one search request (30/min family) and pops the stack; `SeriesPager` (see P10) can fire a whole cold open for a page the reader only dragged towards. `CoverStore` prefetch (full2 item 51, still open) is the other tap competitor and is outside this slice.

---

## Findings

### P1 — The hero now waits for the bottom of the page
- **What** — `loadCore` writes the hero's data (`filled`, `synopsis`, `tagGroups`, `isLoading = false`) only after all four legs return, and five of the eight requests behind those legs are now `.background`, which *waits* at the gate from 120 held requests where `.userInitiated` still succeeds until 180.
- **Where** — `SeriesDetailView.swift:606-630` (sequential awaits; hero written at `:628-630`); `SeriesRepository.swift:928-959` (`let results = await (news, related, full, editions, works)` — the struct is assembled only when all five are in); `SeriesRepository+Works.swift:39-41` (the last-page `.background` leg is awaited *inside* the foreground `works` leg, sequentially); `RateLimitGate.swift:302` (`held.count < family.limit - family.reserve` = 120).
- **Why it matters** — Yesterday, with 120–179 general requests held (Discover prefetch + a library walk + Spotlight reindex can put the window there), every leg went through and the page rendered whole. Today the same page shows the feed copy's title and cover with a synopsis skeleton, no stats beyond rating, no tags, and the `LoadingLine` running — until the window drains below 120, which is up to 60 s. The reader sees exactly the throttle Abdi asked to hide, on the part of the page he is looking at, caused by legs he cannot see. `DetailOnwardRows` stays on skeletons the whole time too (`isLoading` is the page's, `DetailOnwardRows.swift:169`). It also widens the P6 window: the fan is tappable as soon as covers land (`:627` is after the feeds), and a gallery opened while the core is still out cancels the core, so the return runs `filled = nil` — the flash item 32 fixed.
- **Effort** — a function on each side: `fetchExtras` returns `full` + `works` p1 as one struct the instant they land and the tail (`news`, `relationships`, `collections`, works last page) as a second `async let` the view awaits after `isLoading = false`; `loadCore` writes `filled` from the first and the tail sections from the second. `SeriesExtras.failure` splits the same way. The 6h cache bundle can stay one row written when both halves are in.
- **Confidence** — certain on the mechanism (read at the lines above); the 120-vs-180 band is arithmetic from `Family.reserve`. Not measured on a device — a `print` of `Date()` at `:612` and `:628` under a saturated gate would show it.

### P2 — `LoadingLine` says "done" while a throttled covers retry is pending
- **What** — A throttled `/images` sets `isCoversLoading = false` (the `defer`), schedules a retry, and `isAnyLegLoading` does not know about the retry — so the line fades out, then the fan pops in seconds later, which is the glitch the line was added today to prevent.
- **Where** — `SeriesDetailView+Covers.swift:40-41` (`defer { isCoversLoading = false }`), `:57-67` (`scheduleCoversRetry` sets no flag), `:130-133` (`isAnyLegLoading` reads eight flags, not `coversRetry`).
- **Why it matters** — On exactly the throttled open the line exists for, it is off during the wait.
- **Effort** — a line: `|| coversRetry != nil`, and nil it out at the end of the retry task.
- **Confidence** — certain.

### P3 — `StaleBar` is the wrong control on a cold page, and it hides itself while retrying
- **What** — On a cold open where `full` throws `.rateLimited`, the page has nothing stale — it has the feed copy and skeletons — yet it mounts `StaleBar`, whose own doc says it is for "good content, failed refresh" (`FailureState.swift:122-125`). And its retry calls `loadCore()`, which sets `isLoading = true`, which un-mounts the bar (`if !isLoading, let pageFailure`), so the countdown card vanishes on retry and reappears on a second failure.
- **Where** — `SeriesDetailView.swift:287-313`; `:594` (`isLoading = true`).
- **Why it matters** — This is the card the walk saw three times. It reads as an error over a page that has not loaded, and it flickers. See "Rate-limit invisibility" for the replacement.
- **Effort** — a function (see below).
- **Confidence** — certain on the flicker; the wording point is design.

### P4 — `LoadingLine` animates at display rate for the life of every series page
- **What** — `TimelineView(.animation)` is in the tree whether or not `isActive`; opacity 0 does not pause a timeline schedule. Every mounted series page (and every page the pager keeps alive, P10) redraws a gradient every frame until popped.
- **Where** — `DesignSystem/LoadingLine.swift:29-49` (kept in tree "so the fade out is a fade"; `opacity(isActive ? 1 : 0)` at `:49`).
- **Why it matters** — A 2 pt band is cheap per frame, but a per-frame commit keeps the display out of its idle refresh (ProMotion drops to 10 Hz on a still screen) for as long as the reader is reading. Battery and thermal, not frame drops.
- **Effort** — a line: `TimelineView(.animation(paused: !isActive))`, or `if isActive` with a `.transition(.opacity)` for the fade.
- **Confidence** — likely. Settle it with Instruments' Core Animation FPS on a settled page: expect 0, get 60/120.

### P5 — Every `EditionShelvesSection` is re-evaluated on every parent pass, for ~160 eager rows
- **What** — `var now: Date = .init()` is a stored property defaulted at construction; the section is constructed inside `volumesShelf` on every `SeriesDetailView` body pass, so `now` differs every time and SwiftUI can never skip it. Its rows are a plain `VStack`/`ForEach` (not lazy), so on One Piece that is ~113 ANN rows + 50 NDL rows (`NDLClient.pageSize = 50`, `NDLClient.swift:45`), each running `dateLine` → `wording` → `Date.FormatStyle` construction and formatting, per pass; and on first mount each row carries its own `ArrivesModifier` with a `.blur(radius: 6)` layer animating to 0 — ~160 simultaneous blur layers.
- **Where** — `EditionShelvesSection.swift:46` (`now`), `:73-75` and `:256-259` (eager `ForEach`), `:329` → `:360-372` → `:166-170` (`dateLine` and `wording` per row), `VolumesSection.swift:244-250` (`utcMonthYear`/`utcDayMonthYear` are computed `static var`s, rebuilt per call), `DesignSystem/MotionModifiers.swift:22-37` (blur per row).
- **Why it matters** — ~25 root body passes happen during a load (one per `@State` write); each re-formats every row. The blur burst on mount is the likelier visible cost: blur is an offscreen pass per view, and 160 of them in one frame on a long series is a plausible hitch exactly when the shelf lands.
- **Effort** — a few lines: `static let` for the two format styles; pass `now` from the page once per load rather than defaulting it; make the shelf rows a `LazyVStack` or cap the blur to the first screenful (index < ~8).
- **Confidence** — likely for the re-evaluation (read); worth checking for the hitch (Instruments, One Piece open, watch the shelf land).

### P6 — A cancelled `.background` feed writes "Cancelled" into the similar/also rows (item 30 back)
- **What** — `blockingError` does not drop `.cancelled` (`SeriesRepository.swift:445-448`), and `loadCore` writes it straight to `similarFailure`/`alsoLikeFailure` and `similarOrigin`/`alsoOrigin` with no `presentableFailure` — unlike every onward leg. A `.background` feed is cancelled by `waitForBackgroundSlot` the moment the task is (`RateLimitGate.swift:295`), which is exactly a gallery opened while the feeds are still queued.
- **Where** — `SeriesDetailView.swift:614-623`; `+Covers.swift:167-177` (`pageFailure` walks the origins without dropping `.cancelled` either).
- **Why it matters** — On return the row shows "Cancelled" with a Retry until the re-run's feed answers — under a full gate, the whole wait. The `StaleBar` can name "Cancelled" too once `isLoading` clears.
- **Effort** — two lines: `similarFailure = similarAnswer.blockingError.flatMap(Self.presentableFailure)`, same for also; and skip `.staleAfter(.cancelled)` in `pageFailure`.
- **Confidence** — likely (the write is certain; whether the row is visible before the re-run overwrites it depends on the gate wait, which P1 makes long).

### P7 — `originalRun` reshapes the hero column and the measurers do not re-run (item 66 back, today)
- **What** — `column(_:fill:)` mounts `DetailScheduleBlock` when `originalRun != nil` (`DetailHero.swift:275`), and the block renders a text line for `.approximated` (`DetailScheduleBlock.swift:60-63, 90-99`); but `MeasureKey.scheduleShape` is computed from `schedule`, `isScheduleLoading` and `scheduleFailure` only (`DetailHero.swift:81-85, 234-240`). `originalRun` arrives last of all — it rides the categories leg, ≥3 s behind cadence on the MangaUpdates spacer (`+Categories.swift:28`).
- **Where** — `DetailHero.swift:81-85` (no `originalRun` input), `:275` (the block's mount condition includes it).
- **Why it matters** — On a Korean webtoon (the case `originalRun` exists for) the form is chosen against a column without the line; when the line lands the column grows ~25 pt past the cover and the gap under the artwork comes back — or the `.chapters` form is kept when it no longer fits.
- **Effort** — a line: add `originalRun != nil` to `scheduleShape` (a fifth value), and its test in `DetailHeroFormTests`.
- **Confidence** — certain on the key omission; likely on the visible gap (needs a webtoon screenshot at t=0 and t=6 s).

### P8 — "Started" is now a range in a column sized for a year (today)
- **What** — `DetailStatsStrip` puts `published.rangeLine` ("c. 2018 – c. 2023", up to 17 characters) in the same equal-width segment that held "2018", with `lineLimit(1)` and `minimumScaleFactor(0.7)`.
- **Where** — `DetailStatsStrip.swift:67-71` (the value), `:156-160, 171` (`lineLimit(1)`, `.frame(maxWidth: .infinity)` — six equal columns on a 361 pt strip is ~60 pt each), `Series+Popularity.swift:89-97` (the strings).
- **Why it matters** — At 0.7 scale the range is still ~70 pt wide; it truncates to "2018 – …" on any five- or six-stat series, which loses the one fact (ended or ongoing) the range was added to show.
- **Effort** — a few lines: give "Started" the year and put the range on the footer line beside the popularity sentence, or let that segment take `layoutPriority(1)`.
- **Confidence** — likely; one screenshot of a completed series with a rating count settles it.

### P9 — `CoverGallery` pages use `AsyncImage` in a horizontal `LazyHStack`, the failure `PortraitImage` documents
- **What** — `ZoomableCover` loads with `AsyncImage`; `PortraitImage.swift:5-12` records why that is a bug in a scrolled row: it cancels on scroll-out and remembers `.failure` per identity, so a cover that loses the race stays the "photo" glyph for the life of the screen. The gallery also bypasses `CoverStore`, so the front cover is fetched a third time at a third size (hero via `CoverImage`, wash via `AsyncImage`, gallery via `AsyncImage`).
- **Where** — `CoverGallery.swift:323-339`; `DetailBackdrop.swift:142-151` (the second `AsyncImage`; not in a scroll row, so only the duplicate fetch applies there).
- **Why it matters** — A fast swipe through a 50-cover gallery on a slow link leaves dead pages; the fix already exists in the same folder.
- **Effort** — a function: `PortraitImage`'s `.task(id:)` + `CoverStore` pattern with a non-square frame.
- **Confidence** — likely (the mechanism is the one already measured for portraits, item 121; not re-reproduced here).

### P10 — The pager's neighbour pays a cold open the moment it is dragged into view
- **What** — `SeriesPager` is a `LazyHStack` of full `SeriesDetailView`s, each with `.task(id:)`. A lazy child is built when it enters the viewport, so any drag past the first pixel builds the neighbour and starts its `loadCore` — 3 foreground + 5 background MangaBaka requests plus the onward legs — and a snap-back cancels the task after the foreground requests have already left. `APIClient` refunds a cancelled request's slot (`APIClient.swift:166-174`, "never reached the network") but a cancelled in-flight request usually did reach it, so the local window under-counts against the server by up to three per aborted drag.
- **Where** — `SeriesPager.swift:73-86`, `SeriesDetailView.swift:423`.
- **Why it matters** — Under Abdi's ask 2 this is a request the reader never asked for, at foreground priority, competing with the page under their thumb. Memory: pages the reader has swiped through stay alive in the lazy stack, ~40 `@State` values, up to 50 `SeriesImage`s, up to 200 edition rows and a `LoadingLine` timeline (P4) each; unmeasured.
- **Effort** — a few lines: gate `load()` on a "settled" flag the pager sets in `onChange(of: position)`, so a page loads only once it is the page; or defer `loadCore` by ~150 ms and let the cancellation land first.
- **Confidence** — worth checking: whether `LazyHStack` builds the neighbour on a partial drag or only past the halfway point is the unknown. `print("load", series.id)` at `SeriesDetailView.swift:556` and one drag-and-release settles it.

### P11 — The works last page: `try?`, no log, awaited in the foreground
- **What** — `+Works.swift:39-41` swallows the last-page failure with `try?`, so a long series whose last page 429s gets a shelf badge that says "113" (from `worksTotal`) and a "Showing the first and latest volumes" line (`VolumesSection.swift:117-122`) over a list that only has the first page — and the Next-volume widget silently loses volume 113, the case the second page was added today to fix. Nothing logs it.
- **Where** — `SeriesRepository+Works.swift:39-41` (outside the slice, but it is the page's leg); `VolumesSection.swift:74-83, 117`.
- **Why it matters** — Charter 1/3: a failure indistinguishable from "there is nothing there". Also P1: the sequential `await` holds `works` — and so the hero — on a `.background` wait.
- **Effort** — a function: return the last page as its own `Result` alongside `first`, log the failure, and let the badge say "first 50 of 267" when the tail did not land.
- **Confidence** — certain.

### P12 — "Publisher page" in `DetailEditions` has no tap target (today)
- **What** — A footnote-sized `Text` in a `Button` with no `minHeight`. Every other new control in the slice today got `Metrics.tapTarget` (`VolumeSheet.swift:188, 207`; `EditionShelvesSection.swift:104, 338`).
- **Where** — `DetailEditions.swift:77-86`.
- **Why it matters** — ~14 pt tall; the charter's "nine controls that needed 44pt added by hand", plus one.
- **Effort** — a line.
- **Confidence** — certain.

### P13 — `DetailPagePriorityTests` asserts source text for a behaviour a stub can already observe
- **What** — The test reads `SeriesRepository.swift` and greps for `priority: .background` between two comment strings (`DetailPagePriorityTests.swift:20-41`), while `PriorityRecordingRepository.swift` sits in the same test target. And nothing tests what the *page* does while a `.background` leg waits — which is how P1 shipped with the tests green.
- **Where** — `MangaBakaTests/DetailPagePriorityTests.swift:16-61`; 71 source-reading assertions across the slice's test files (`grep -c "Features/Detail" MangaBakaTests/*.swift`), all under the open F19 item.
- **Why it matters** — Charter 2. The test would pass against a `fetchExtras` that awaits the background legs before the foreground ones — it does.
- **Effort** — an hour: a `PriorityRecordingRepository` whose `.background` legs suspend on a continuation; assert `filled != nil` before they resume.
- **Confidence** — certain.

### P14 — `NewsSection` builds a relative-date formatter per item per pass; `DetailStatsStrip` computes `stats` four times per pass
- **Where** — `LinksSection.swift:164` (`.relative(presentation: .named)` per item, ×4 items — the pattern full2 item 46 fixed in `ScheduleModel`); `DetailStatsStrip.swift:91, 93, 112, 154` (`stats` is a computed array read four times); `VolumesSection.swift:92, 117` (`badge` twice).
- **Why it matters** — Small each; they sit on the ~25 passes a load produces. Mechanical.
- **Effort** — lines: `let stats = stats` at the top of `body`; a `static let` `RelativeDateTimeFormatter`.
- **Confidence** — certain about the code; the cost is unmeasured and probably sub-millisecond.

### P15 — `AlternativeTitlesButton.others` runs four times per hero pass while the measurers are mounted
- **Where** — `AlternativeTitles.swift:34-42, 88` (merge + lowercase over 25+ titles per `column(...)`), `DetailHero.swift:243-257` (three hidden columns) + `:221` (the visible one).
- **Why it matters** — Only while `measuredFor != key`, which since item 66 is every time a shaping input lands — five or six times per load. Sub-millisecond each; recorded because the measurers were retired precisely to stop this class of cost (`DetailHero.swift:41-47`).
- **Effort** — a line: compute `others` once in `DetailHero` and pass the rows down.
- **Confidence** — certain about the code; cost unmeasured.

### P16 — Three unlabelled constants shaping output
- `VolumesSection.swift:81` — `top < 10_000` decides whether the badge shows the highest volume number or the fetched count; no derivation.
- `LinksSection.swift:186` — `shown.prefix(4)` news items; `DetailEditions.collapsedLimit = 4` is explained at `:12-15`, this one is not.
- `CoverGallery.swift:128-133` — 0.35 / 0.10 / −14° glide; design constants, but the file labels nothing.
- **Effort** — comments. **Confidence** — certain.

### P17 — `CoverGallery.selection` is written once and never changes
- **Where** — `CoverGallery.swift:10, 21, 187` — set in `init`, read only as a fallback when `scrolledIndex` is nil, which `init` also seeds. Dead state.
- **Effort** — a line. **Confidence** — certain.

### P18 — `DetailHero` derives the native title from `titles` while the record now carries `native_title`
- **What** — `DetailHero+Copy.swift:51-56` (`nativeTitle(of:)`, trait-based) and `Series.nativeTitle` (the API field, passed at `DetailHero.swift:319`) are two answers to one question; the byline uses the first, the "Also known as" sheet merges the second. Same-series divergence is possible where the API's `native_title` is not trait-tagged `native`.
- **Effort** — a function; decide which is authoritative and delete the other. **Confidence** — worth checking against a few records.

### P19 — `loadCore` parses the synopsis and groups tags before the answer is in
- **Where** — `SeriesDetailView.swift:598-600`: `filled = nil` then `refreshDerived()` runs the Markdown parse on the feed copy's description (nil for v2, so usually nothing) and `TagGrouping.groups` on the *previous* `extras.richTags` — which are not reset until `:624`. Harmless on a fresh page; on the pager's per-page identity it is one wasted grouping of up to 146 tags per open.
- **Effort** — a line (`extras = SeriesExtras()` beside `filled = nil`, or drop the first call). **Confidence** — certain about the code; cost trivial.

---

## Main thread & rendering

- **Root body passes.** ~40 `@State` values on `SeriesDetailView` (`:68-211`); a cold load writes ~25 of them, one pass each. Per pass the root computes `otherCovers` twice (`:275`, `:420` — `Self.gallery` filters ≤50 covers and sorts ≤115 Apple volumes) and `preferred` three times (`:276, 549, +Covers.swift:78`). Read: cheap, tens of microseconds; not a finding. What is not cheap per pass is P5 (the eager shelf) and P14/P15.
- **Per-frame isolation holds.** No root body reads a per-frame value: `ScrollTracker` (`ScrollTracker.swift:19-35`) is read only by `ParallaxOffset` (`DetailBackdrop.swift:192-200`) and `DetailBarTitle` (`:34`); `CoverGallery`'s `tracker.pageProgress` is read only by `GalleryBackdrop` (`CoverGallery.swift:241-264`). New views today (`CoverFilmstrip`, `LoadingLine`, `VolumeSheet`) read none. `LoadingLine` is the one per-frame *producer* (P4).
- **`DetailBarTitle`** re-diffs the toolbar per frame during the crossfade zone (`DetailBarTitle.swift:34, 90-100`); confined to the hero's height of scroll. Not worth touching.
- **Main-actor work that need not be:** `Self.prose` Markdown parse (`SeriesDetailView.swift:530-541, 639`) and `TagGrouping.groups` (`:643-647`) run on the main actor inside `refreshDerived`; both are pure and could be `nonisolated` off-main. Unmeasured; a 40-line description is likely ~1 ms.
- **`DetailSynopsis`** lays out a hidden full copy of the text (`DetailSynopsis.swift:91-110`) — 40 lines of attributed text, once per text/width change. Fine.
- **`DetailHero` measurers** — three extra columns while `measuredFor != key` (`DetailHero.swift:232-268`); keyed correctly since item 66 except P7.

## Rate-limit invisibility — the structure for this page

What exists: `StaleBar` with a countdown and auto-retry (`SeriesDetailView.swift:287-313`), five `InlineFailure` sites (cast `:326`, releases `:345`, volumes `+Store.swift:39`, similar/also `DetailOnwardRows.swift:190-195`, categories `:374`, schedule `DetailScheduleBlock.swift:78`), skeletons on every onward leg, `LoadingLine` (`:400-402`), and the covers auto-retry (`+Covers.swift:54-67`). Five `.background` legs already queue silently. That is most of the machinery; the gaps are in what is shown *while* something waits and *which* control says so.

Proposed, concretely:

1. **Render from cache or skeleton, retry silently, never a card:** `/images` (already), `/news`, `/relationships`, `/collections`, works last page, `.similar`, `.readersAlsoLike`. These are `.background` and never throw locally; they throw only on a server 429 (`RateLimitGate.swift:298`). On `.rateLimited` specifically they should keep their skeleton and schedule one retry at `error.rateLimitDeadline`, the pattern `scheduleCoversRetry` already implements — lift it to a `RetryAfterThrottle` helper the four state-writing sites call. `InlineFailure` stays for offline/5xx/decode, where "here is why" is honest.
2. **The one leg that must say so:** `/v1/series/{id}` on a cold page. Not `StaleBar` (P3): the honest form is the synopsis skeleton staying up, with one line under the `LoadingLine` — "Still loading · MangaBaka is busy · 12 s" — and the same auto-retry. `LoadingLine` already sits in the `safeAreaInset`; give it an optional caption and a deadline and it is the single affordance. When the 6h cache *does* have the record, `extras(for:)` returns it before any request (`SeriesRepository.swift:855-856`) and there is nothing to show at all — that path is already invisible.
3. **Third-party throttles are not MangaBaka's.** The volumes shelf, cast, cadence and categories carry a `party` other than `.mangaBaka` (`APIError.swift`, per the budget doc §3); their wording should never say "MangaBaka is throttling". Read: `InlineFailure` renders whatever `userFacingMessage` says, so this is presumably already right; not re-verified in `APIError.swift`.
4. **Make waiting count as loading** (P2): `isAnyLegLoading` should include a scheduled retry, and — after the P1 split — should *not* include the tail legs' wait once the hero is up, or the line never goes out on a throttled window.
5. **Order the writes so the reader never sees the wait** (P1): hero from `full` first; feeds and tail sections whenever they come.

## Debuggability

- **Swallowed:** `+Works.swift:39-41` (`try?`, no log — P11); `SeriesRepository.swift:807-810` returns the images failure but nothing logs a scheduled covers retry (`+Covers.swift:57-67`) — in production a fan of one and a throttled fan are indistinguishable in any log. One `Logger.notice("covers retry in \(wait)s for \(series.id)")` makes it findable.
- **No per-open request counter.** Still true from the budget doc §4: `NetworkLedger` is per-host, nothing sums one page open. A `Signposts` interval already brackets "Detail readable"/"Detail complete" (`SeriesDetailView.swift:567, 572`); adding `.event` signposts at each leg's start (`os_signpost` with the path) would give the whole timeline above in one Instruments trace instead of by reading.
- **The gate wait is invisible.** `waitForBackgroundSlot` (`RateLimitGate.swift:289-315`) sleeps in 200 ms polls with no log and no signpost; P1 would have been visible in a trace with one `os_signpost(.begin/.end, "gate wait", family)`.
- **Logged well:** the owned-volumes store logs every read/write/reconcile failure with the error (`+Editions.swift:80, 110, 126`).

## Size

- Largest types: `SeriesDetailView` 717 + 8 extensions (1,800 lines for one screen's state machine); `CharacterProfileView` 547; `PublisherView` 469; `CoverGallery` 464 (holds `CoverStack`, `ZoomableCover`, `GalleryBackdrop`, `GalleryStart`, a `Collection` extension). `CoverStack` (`CoverGallery.swift:375-445`) is the hero's fan and belongs beside `DetailHero`; the `Collection[safe:]` extension (`:447-454`) belongs in Core.
- **Duplicated:** the request count in four comments (above); `nativeTitle` two ways (P18); three image loaders in one folder (`CoverImage`/`CoverStore`, `PortraitImage`, `AsyncImage` ×2 — P9); `VolumeSheet`/`ReleaseSection`/`EditionShelvesSection` each build their own `Date.FormatStyle` per call (`VolumesSection.swift:244-250`, `ReleaseSection.swift:184-194`, `EditionShelvesSection.swift:168-169`).
- **Dead:** `CoverGallery.selection` (P17). `EditionShelvesSection+Owned.swift` (16 lines) is a struct and an `@Entry`; fine as is.
- **Not dead, checked:** `SeriesPager.allowsPaging(width:)` unused parameter is explained (`SeriesPager.swift:117-122`); every callback on `SeriesDetailView` (`onOpenSchedule`, `onOpenTag`, `onUseAsSeed`, `onOpenPublisher`, `onOpenAuthor`) is wired at `RootView+Session.swift:492-527` and invoked (`DetailScheduleBlock.swift:72`, `SeriesDetailView.swift:691, 695, 472`, `DetailCredits`). Charter 7: nothing unreachable found in this slice.

## Charter hits, in order

1. Model vs payload — none new in this slice's files (the models live in Core). P11 is the `try?`-around-a-fetch shape.
2. Tests agreeing with the bug — P13.
3. Computed and discarded — P19 (grouping the previous page's tags); `available_languages`/`available_types` from `/images` are read and unused, recorded in the budget doc already.
4. Constants — P16; `coversRetryCeiling` (`+Covers.swift:69-72`), `openLibraryPassLimit` (`+Store.swift:210-217`), `LoadingLine.loop` (`:14-15`) are labelled guesses, good.
5. Measuring the wrong thing — the "Detail readable" signpost measures first opens only and says so (`:565`); after P1 it will measure the gate wait, which is the right thing to see.
6. Hand-rolling the platform — `DetailSynopsis` measures its own truncation with two probes (`:83-110`) where `ViewThatFits` cannot help (explained at `DetailHero.swift:161-164` for the hero); `SeriesPager` approximates the edge-back exclusion with a `DragGesture` (`SeriesPager.swift:56-68`, flagged unverified in its own comment). Neither is new.
7. Unreachable — none (above).
- Force-unwraps reachable from input: none found in the slice (`grep -nE "\w!\.|\w!\)|as! |try! "` over the folder, 0 hits).
- Privacy: nothing here sends reader data anywhere; the owned-volumes ticks stay on the reader's file.

## Good news

- `ScrollTracker.swift:3-18` records the 8.3 ms/120 Hz budget and what the root body used to redo per frame; the isolation holds in every file read, including today's.
- `SeriesDetailView.swift:175-188` — `coreLoadedID`/`onwardLoadedID` with the reasoning for two ids (item 32); `:588-591` `presentableFailure` and its use in every onward leg (item 30).
- `DetailHero.swift:52-75` — `MeasureKey` carries the shaping inputs with the date and item number of the bug (66).
- `DetailBackdrop.swift:100-118, 178-184` — `.compositingGroup()` before the parallax, `ParallaxOffset` as the only tracker reader (55/65).
- `CoverGallery.swift:41-58, 236-240` — pages built in `init`, backdrop split (64).
- `SeriesRepository.swift:855-870` — a partial `extras` is never cached (gap 9), with the six-hour reasoning.
- `+Covers.swift:15-20` re-measures its own "four alternates" claim against 931 covers and corrects it in place, dated.
- `+Editions.swift:229-248` — `isJapaneseScript` with the 935-wrong-records measurement that justifies it.
- `+Store.swift:145-152` — the Open Library pass records what it used to cost (40 × 3 s, nothing committed on pop) and why it commits per answer.
- `SeriesPager.swift:31-35` — the pager seeds in `init` and says which item that closed (56).

## Could not determine

| Question | What settles it |
|---|---|
| How long the hero actually waits under P1 on a real window | `print(Date())` at `SeriesDetailView.swift:612` and `:628` after a Discover fling that fills the window; or one `os_signpost` around `waitForBackgroundSlot`. |
| Whether `TimelineView(.animation)` at opacity 0 commits every frame (P4) | Instruments → Core Animation FPS on a settled series page; expect 0. |
| Whether ~160 `.blur` layers on shelf mount drop frames (P5) | Instruments → Animation Hitches, open ONE PIECE (377), watch "Volumes on record" land. |
| Whether `LazyHStack` builds the neighbour page on a partial drag (P10), and what a swiped-through page costs in memory | `print("load", series.id)` at `:556`, one drag-and-release; memory graph after swiping ten pages of a publisher row. |
| Whether `AsyncImage` in the gallery actually strands pages (P9) | Network Link Conditioner 3G, open a 50-cover gallery, swipe to the end and back; count photo glyphs. |
| Whether "Started" truncates at default type (P8) | One screenshot of a completed, rated, volumed series at default size. |
| Whether `originalRun` visibly re-opens the hero gap (P7) | A Korean webtoon at t=0 and t=6 s (the categories leg lands after the 3 s spacer). |
| Cost of `refreshDerived`'s Markdown parse on the main actor | `ContinuousClock` around `Self.prose` on the longest description in the fixtures. |
