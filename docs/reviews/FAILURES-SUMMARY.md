# Failures — summary of the five audits (2026-09-13)

Merged from `failures-detail.md`, `failures-discovery.md`, `failures-library.md`,
`failures-shell.md`, `failures-services.md`. Line numbers are as of `1f118cd`.
Where two reports cited the same line I read it before merging; the three places
they disagreed are noted inline. Nothing here was run.

The ask: every failure gets a loading state and an honest explanation; nothing
crashes; nothing confuses.

Counts: **123 distinct gaps** after de-dup (six of them traps, six more the
reports marked acceptable-but-noted: 72, 74, 75, 103, 116, 123), **13 systemic
causes** (nine of the ten candidates confirmed as written, one — (e) — confirmed
in inverted form, three the candidate list missed).

---

## 1. The reader's five worst afternoons

**1. Typing in Search, then everything else stops.** They typed a title fast.
The 300 ms debounce fires ~3 searches a second and the search bucket is 30/min,
so ten seconds in MangaBaka answered 429. The grid went blank behind one grey
sentence — "MangaBaka is throttling this connection…" — with no countdown, no
button, re-shown identically on every further keystroke; the last good results
were thrown away (`SearchView.swift:275-285`; `SearchModel.swift:104,112` keeps
only a `String`). Because there is one `RateLimitGate` for the process
(`APIClient.swift:22,126`) every other tab now refuses locally too: Discover rows
say "Nothing here right now." (`DiscoverView.swift:194`), the series page loses
tags and synopsis (§2 below), the Library walk stops on whatever page it reached.
Should have seen: `FailureState` with a live countdown, the last results kept
under a `StaleBar`, and the other tabs unaffected because the 30/min bucket is
search's alone (`RateLimitGate.swift:53-64` knows nothing about buckets).

**2. Opening a series on the train.** Offline or throttled, they opened a series
from Library. Nine requests fan out and every one is `try?`. Title and cover
render; then Similar/Readers-also-like show skeletons and vanish
(`DetailOnwardRows.swift:63`), cast placeholders appear and vanish
(`CharacterService.swift:94-95`, `CharacterRow.swift:30`), "Estimating" spins and
the line disappears (`ReleaseSchedule.swift:377`, `DetailHero.swift:189`); no
synopsis, tags, links or volumes (`SeriesRepository.swift:699-716`). Nothing on
the page says offline (`SeriesDetailView.swift:274-285` reads `.series` and drops
`origin`). Worse: five of six legs succeeded and one 429'd, so the struct was
cached as complete for six hours (`SeriesRepository.swift:679`) — the missing
section stays missing all afternoon, tunnel or no tunnel. Should have seen: a
`StaleBar` under the hero ("You're offline — showing what was downloaded ·
Retry"), each failed section as a one-line "Couldn't load · Retry" in its own
slot, and nothing cached until all six answered.

**3. The signed-in reader's library.** Page 12 of 13 failed. 1,100 rows and a
spinner that never stops over "1,100 loaded so far" (`LibraryView.swift:228-247`;
`failure` is set at `LibraryModel.swift:255` and read by nothing once rows
exist; `fetchAll` at `:238` returns early so nothing retries). Opening a series
offers "Add to library" for one they saved (`LibraryControl.swift:46`). Rating
it one star costs 13 requests and 25 MB (`RootView+Session.swift:211-220`,
`LibrarySnapshot.swift:6-8`) and, when that reload 429s, the control flips from
"Reading · ch 68" to "Add to library" although the write landed
(`LibraryControl.swift:75-78`, `LibraryModel.swift:229`). Insights and Wrapped
present the 1,100 as the total (`RootView+Session.swift:63-66`), the Spotlight
index built yesterday is wiped (`SpotlightIndex.swift:48-49`), Siri says "The
schedule hasn't been measured yet" (`AppIntents.swift:36-44`). And a *new*
signed-in reader with zero entries is told "No library yet — Add a MangaBaka
token in Settings" (`LibraryModel.swift:272`, pinned by
`LibraryModelTests.swift:143-148`). Should have seen: `StaleBar` "Some of your
library didn't load — 1,100 so far · Retry"; the library control hidden until
the walk is complete; a one-star rating patched locally with a "Saved" toast;
`EmptyState` "Nothing saved yet" for the empty account.

**4. Blending in Mix while offline or throttled.** Three seeds, tap Blend.
`mix` returned `.empty` for the error (`SeriesRepository.swift:463-465`), so the
screen said "Nothing matched. Try loosening the filters." (`MixModel.swift:101`)
and the DNA strands they were editing vanished with the "Start over" button
(`MixView.swift:232`, `dna = .empty`). They loosened the filters and blended
again: same sentence. Should have seen: `FailureState` with the real cause and
Retry/countdown; DNA and moves untouched.

**5. Exhausting the stack.** Swiped to "That's today's stack — a new one is
dealt tomorrow morning" (nothing is scheduled for the morning,
`StackView.swift:312-315`), tapped "Deal another now", and every local save and
skip was erased with no confirmation and no toast (`StackView.swift:319-320` →
`StackModel.swift:247-256`), two lines under "N saved" — while the header's own
reset asks first and names the consequence (`StackResetMenu.swift:32-46`). Had
the fetch failed instead, the same slot shows "Can't load the stack" dressed as
`EmptyState`, no countdown (`StackView.swift:301-308`). Should have seen: the
header's confirmation dialog, then "The stack has been reset"; `FailureState`
for a failed fetch; the promise dropped.

---

## 2. Systemic causes

Tested each candidate against all five reports. "Fix" is the one change that
closes the family; the batches in §6 apply it.

### (a) Services return `[]` / `nil` / `.empty`, so callers cannot tell failure from emptiness — **confirmed, largest family**

Sites: `SeriesRepository.swift:463-465` (`mix`), `:653-660` (`images`),
`:699-716` (six `extras` legs), `+Count.swift:26`; `CharacterService.swift:94-95`;
`ReleaseSchedule.swift:372-377` (`cadence` → `.none`); `ReleaseFeedProvider`
with `WebtoonsFeedClient.swift:63-66`, `NaverFeedClient.swift:45-54`,
`GigaViewerFeedClient.swift:106-114`; `CatalogueService.swift:59,91` (flags
`genresFetchFailed`/`tagsFetchFailed` read by no caller), `:152`
(`findPublisher`); `LibraryService.swift:140,161,183,211-215`;
`APIClient.swift:339` (`profile`); `ReleaseCalendar.swift:44-49`;
`Continuations.swift:118-128`. View-side consequences: `DiscoverView.swift:194`,
`DiscoverModel.swift:97-122`, `StackModel.swift:429`, `BrowseModel.swift:27`,
`BlockedTagsSection.swift:120-166`, `TagPickerSheet.swift:72-86`, every hidden
section in §1 afternoon 2.
Done right already, copy it: `FeedResult` (`SeriesRepository.swift:285-323`,
`origin`/`cachedAt`/`blockingError`) and `AppleBooksClient` nil-vs-`[]`
(`:34-36`).
**Fix:** one `Fetched<T> { value: T; failure: APIError?; isPartial: Bool;
fetchedAt: Date? }` in `Core/Model`, returned by every repository/service read
that today swallows; plus one kit view `InlineFailure(error:retry:)` (header +
muted line + `StateAction(.aside, "Retry")`) for section slots, so a section
that *asked and failed* shows one line and a section that *asked and got
nothing* hides.

### (b) `APIError` speaks only for MangaBaka — **confirmed**

`APIError.swift:52` (`needsAccount` on any 401/403), `:130` (headline "MangaBaka
had a problem"), `:104` (raw "AniList returned 403." shown verbatim);
`AniListClient.swift:122,161` and `SeriesCharacter.swift:156` (offline →
`.transport`, empty cast → `.server`); `MangaUpdatesClient.swift:120` (one
offline code where `APIClient.swift:142-144` has three), `:135-138`
("MangaUpdates returned 503." reaches `ReleaseSchedule.swift:330` as a string);
`CharacterProfileView.swift:92-93` (AniList 403 → "This part needs an account"
+ the MangaBaka-token paragraph); `SettingsView.swift:215-229` (feed wording on
the account card).
**Fix:** `APIError.party: Party` (`.mangaBaka` default, `.aniList`,
`.shikimori`, `.mangaUpdates`, `.appleBooks`) on `.server`/`.rateLimited`/
`.transport`; `headline` names the party; `needsAccount` true only for
`.mangaBaka`; `userFacingMessage` never echoes a status code for a non-MangaBaka
party; add `case cancelled` (see (d)). Every third-party client maps the same
three offline `URLError` codes.

### (c) Partial results cached or rendered as complete — **confirmed**

`SeriesRepository.swift:679` (five-of-six `extras` cached 6 h);
`LibrarySnapshot.swift:151-153` and `ShelfStore.swift:46` (undecodable rows
dropped, rest reported complete); `WebtoonsFeedClient.swift:51` (`v3-` unbumped
after `5bb36b8` changed the parser — empty feeds cached in the window hide the
series for a week), `NaverFeedClient.swift:37`; the five file caches drop
`storedAt` on read (`AppleBooksClient.swift:126`, Google, Webtoons, Naver, Giga)
so 7-day-old data has no age. Rendered-as-complete: `LibrarySnapshot.swift:106`
(page cap), `RootView+Session.swift:63-66` (Insights/Wrapped), `:28` (ShelfDetail
copy), `:147` (Spotlight reindex on a failed walk), `ReleaseReminders.swift:119`
(reschedule on a capped walk), `AppIntents.swift:36-44`,
`LibrarySeriesEntity.swift:43-47`.
**Fix:** the same `Fetched<T>` — `isPartial` and `fetchedAt` travel with the
value, the cache layer refuses to write when `isPartial`, and `readCache`
returns `nil` when `decoded.count != rows.count`. Bump Webtoons to `v4-`, Naver
to `v2-naver-` now.

### (d) No timeout; cancellation is a failure; sleeps ignore cancellation — **confirmed**

Zero `timeoutInterval` hits in the tree (`APIClient.swift:377` + six clients);
`URLError.cancelled` → `.transport` at `APIClient.swift:146`,
`AniListClient.swift:121,302`, `SeriesCharacter.swift:155`,
`MangaUpdatesClient.swift:122` — and `staleContentRemainsUseful` is false for
`.transport` (`APIError.swift:47`), so leaving a screen mid-load tells the kit to
hide the cached copy; `LibraryService.update` cancel → "The request didn't
complete." for a write that may have landed. Swallowed `Task.sleep`
cancellations that then fire the request anyway: `AppleBooksClient.swift:85`,
`GoogleBooksClient.swift:76`, `WebtoonsFeedClient.swift:59,103`,
`NaverFeedClient.swift:43`, `GigaViewerFeedClient.swift:104`. Loops without a
cancel check: `Continuations.swift:117-125`; no early exit on offline:
`ReleaseSchedule.swift:312-333`; `AniListClient.healthCheck` at launch
(`RootView.swift:107`) can hold 60 s; `RootView.swift:111-115` intent task race.
`MangaUpdatesClient.swift:154-162`, `AniListClient.swift:194`,
`ShikimoriClient:182` and `CoverStore.swift:128` do it right.
**Fix:** `APIError.cancelled` (dropped silently by every caller; `origin` stays
`.cache`), one shared `URLSessionConfiguration` with `timeoutIntervalForRequest
= 20` (15 for third parties), and one `Task.sleepOrBail(for:)` helper used at
the six sites.

### (e) Optimistic UI never reverted on write failure — **not confirmed as phrased; confirmed inverted**

No write in the app is optimistic. The family is *displayed outcome ≠ real
outcome*, in both directions: a **successful** write shown as failed/undone
(`LibraryControl.swift:75-78` + `LibraryModel.swift:229` flips to "Add to
library" when the post-write reload fails; `LibraryEditSheet.swift:66` Cancel
mid-save; `LibraryService.update` cancel wording) and a **failed** local write
confirmed anyway (`StackModel.swift:267` toast "Saved here" after
`shelf.record` threw; `:248` "The stack has been reset" after `shelf.clear`
threw; `HistorySection.swift:49-54` clear swallowed). Plus writes with no
feedback at all: `LibraryControl.swift:171,236` (no spinner while `isWorking`),
`:130-135` (failure in muted 12 pt, never cleared), `RootView+Session.swift:211`
(edit-sheet save, no toast), `SearchLens` save (S13), `Toast.swift:22` (failure
toasts last 2 s and are replaced by the next success).
**Fix:** apply the change locally *after* the write succeeds (`LibraryEntry`
patched in `LibrarySnapshot.apply(seriesId:change:)`), confirm only on success
(`ToastCentre.show(_:kind:)` with `.failure` = 4 s, not replaced), and never
`try?` a write whose caller then confirms.

### (f) Account state collapsed into one message — **confirmed**

`LibraryModel.swift:272` (`hasAccount = !rows.isEmpty || !complete` — signed-in
and empty reads as "no token"; `.empty` unreachable; `LibraryModelTests.swift:
143-148` pins the bug); `LibraryModel.screenState` + `APIClient.swift:131` (no
token offline → "You're offline"); `LibraryControl.swift:46` (walk failed or no
token → "Add to library" live); `RootView+Session.swift:112-130`
(`forgetPreviousAccount` clears seven stores but not `session.library.entries`
— the previous account's library stays on screen until relaunch; the Library
audit's "done well" for this function is about the stores, the shell's finding
stands); `APIClient.swift:339` + `LibraryService.swift:140` (offline = "no
account" for the blend exclusion); `StackModel.swift:312-323` (`canUseProfile =
false` cached for the session on a failed status call);
`SettingsView.swift:193-196` (Keychain refusal shown as "Token rejected");
`AccountCard.swift:164-187` ("Replace" does nothing), `:206-212` (Save greyed,
no reason); `AppServices.swift:203` (`/v1/my/profile` sent with no token every
launch); `TokenProvider.swift:40` (Debug PAT shows "No account").
**Fix:** `hasCredentials` on `LibraryProviding` (from `TokenStore` + build PAT),
checked *before* any walk; `LibraryModel.screenState` decides `.noAccount` from
it and `.empty` from `entries.isEmpty && isComplete && failure == nil`; delete
the row-count heuristic; `forgetPreviousAccount` calls `session.library.forget()`.

### (g) `Int(Double)` on server numbers — **confirmed, 27 sites, one crash loop**

Traps outside ±9.2×10¹⁸. `LibraryEditSheet.swift:309-315` accepts twenty digits
(1e20) and `APIClient.swift:264` sends it; whether MangaBaka stores it is
**unverified** (all four reports say so). If it does, `ReadingInsights.swift:78,90`
runs on Discover at launch (`RootView.swift:164`) and `SpotlightIndex.swift:93-94`
in `startSession` — a crash before the first screen, every launch, until the
value is fixed on the website. Sites: `SpotlightIndex.swift:93-94`;
`ReadingInsights.swift:78,90`; `ReadingWrappedYear.swift:64,156`;
`ReadingInsightsView.swift:96,179`; `LibraryList.swift:145,148,149,155,171,175`;
`LibraryEditSheet.swift:35,152`; `ShelfDetailView.swift:239,240,252`;
`LibraryControl.swift:180,191,195`; `DetailHero.swift:313`;
`DetailStatsStrip.swift:58,61`; `SeriesDetailView+Store.swift:24,53`;
`TrackerScores.swift:54-55`; `BlendDNAView.swift:92` (mix `weight`);
`CommunityPulse.swift:73`; `SeasonReading.swift:93` (found by grep, in no
report). `Series.swift:136` already does it right for `ratingCount`.
Not a trap but adjacent: `APIClient.swift:464` `Retry-After: nan` → `max(NaN,0)`
is NaN in Swift → `RateLimitGate.secondsUntilAllowed` (`:24-32`) returns NaN
forever and every request is refused until relaunch (shell and services agree;
`countdown` guards `> 0` so no crash).
**Fix:** `Int(wholeOrClamped: Double)` in `Core/Model` (`Int(exactly:
rounded) ?? (value < 0 ? .min : .max)`), used at all 27 sites; `parseChapter`
refuses `> 100_000`; `parseRetryAfter` guards `isFinite`.

### (h) Destructive actions without confirmation — **confirmed**

`StackView.swift:319-320` ("Deal another now" clears every save; the header's
identical action confirms at `StackResetMenu.swift:32-46`);
`SettingsView.swift:92-103` ("Remove token" forgets seven stores at once,
`role: .destructive` one tap below a dead "Replace"); `SearchIdleView.swift:
99-102` (delete lens, no undo/toast), `:157` (clear recents, low stakes);
`BlockedTagsSection.swift:47-70` (unblock discards every cached feed, no note;
`FormatSection.swift:31-37` has the note). Done right: `HistorySection.swift:
44-60`, `StackResetMenu`, `FilterSheet.swift:85-102` (undoable clear).
**Fix:** extract `StackResetMenu`'s dialog into `ConfirmDestructive(title:
consequence:)` in `Features/Shared` and use it at the three sites; toast the
lens delete.

### (i) Static "Retrying in N s" with no timer — **confirmed**

`APIError.swift:140-145` + `FailureState.swift:38-44` (bold static string;
"Retry now" button stays live, `:63-75` double-fires and shows nothing while
retrying); `SearchView.swift:275-285` (no countdown at all, nothing re-searches
when the window opens); `DiscoverModel.swift:126-133` (`staleDetail` drops the
countdown); `CharacterProfileView.swift:119` (retry never sets `.loading`);
`LibraryView.swift:228-247` (the opposite: a spinner with no end).
**Fix:** `.rateLimited(until: Date)` instead of `retryAfter: TimeInterval?`;
one `Countdown(until:)` view on `TimelineView(.periodic(by: 1))`; `FailureState`
gains `@State isRetrying` (button disabled + linear bar) and an optional
`autoRetry: Bool` that fires `retry` once when `until` passes.

### (j) Whole-library re-walk after every write — **confirmed**

`RootView+Session.swift:211-220` (`saveLibraryChange` → `reload()` → `entries
= []` → 13 pages, 24.7 MB, disk cache deleted at `LibrarySnapshot.swift:
190-201`; sheet spinner the whole time, tab flips to skeleton, search field
disappears `LibraryView.swift:70`, continuations re-fire `:145-148`);
`LibraryControl.swift:75-78` (`refresh()` re-pages after every +1);
`LibraryModel.swift:229` (entries empty during the walk — Insights, Wrapped and
every `LibraryControl` see an empty library meanwhile); `LibrarySnapshot.swift:
199` (a `reload()` during a walk interleaves two `apply` streams).
**Fix:** `LibrarySnapshot.apply(seriesId:change:)` patches the one entry in
memory and on disk; `LibraryModel.apply(change:)` mirrors it; full reload only
when the patch cannot be applied; a generation counter so an older walk's
result is ignored. Puts a one-star rating at 1 request instead of 14.

### (k) Loading branch missing or ordered after content — **not in the candidate list; confirmed**

`ScheduleView.swift:39-54` ("0 estimated of 0 in scope" + a live Measure button
during every cold load — the screen the device review rejected);
`LibraryModel.swift:184-190` (subtitle "Nothing here yet" during the walk);
`ReadingInsightsView.swift:30-40` ("0 chapters" then the real number);
`BrowseModel.swift:27,66` ("Loading the vocabulary" forever, `isLoading` read
by no view); `SeriesDetailView+Store.swift:16-27` (editions row replaced under
the reader); `ReleaseSection.swift:13-15` (pops in after the page settled);
`StackView.swift:125-131` (card area collapses); `SearchView.swift:194` ("N
shown" from the previous query above the new skeleton); `MixResults.swift:13-19`
(grid replaced by a spinner); `OnboardingView.swift:112-131` (six static grey
rectangles, no shimmer); `TagPickerSheet.swift:26,72-78`; `WrappedView.swift:
45-60` (`facts` starts empty, no loading branch).
**Fix:** every screen model exposes a `ScreenState` enum (`.loading`, `.failed`,
`.empty`, `.list`) decided in one pure property, `.loading` first, the way
`LibraryModel.screenState` (`:55-63`) already does; the view switches on it.
Pure, testable without ViewInspector.

### (l) Dead controls — a tap that does nothing and says nothing — **not in the candidate list; confirmed**

`RootView+Session.swift:160-176` (`openSeries`/`openFromSpotlight` `guard …
else { return }` — link, Siri and Spotlight all land on the current tab in
silence; `SeriesWebLink.swift:40-46` the same for a non-numeric path);
`AccountCard.swift:164-187` ("Replace"); `LinksSection.swift:127-128` (news row
with an unsafe URL renders as a live button); `AppleVolumesRow.swift:63` (spine
with no link, `PressStyle` has no disabled look); `LibraryList.swift:68` +
`LibraryView.swift:168` (row with nil `series`: tap and context-menu Edit do
nothing); `SearchView.swift:182` ("Surprise me" disabled invisibly);
`RootView.swift:306-309` ("Use as seed" toasts "Added to the mix" when
`mixModel` is nil); `SeedPickerSheet.swift:183-184` (rows dimmed, no reason).
**Fix:** `PressStyle` reads `@Environment(\.isEnabled)` the way `StateAction`
does (`StateAction.swift:25-32` records why), and every nil-path in an open
action ends in `toasts.show(…)`.

### (m) The fallback error is a guess, and copy that promises what the code does not do — **not in the candidate list; confirmed**

`DiscoverView.swift:279` (`model.failure ?? .offline` — a reader online with
tight filters is told "You're offline"); `StackView.swift:312-315` ("dealt
tomorrow morning"); `APIError.swift:111-115` ("Cached copies were cleared" — the
library slice clears nothing on `.decoding`); `PublisherView.swift:190`
(`total ?? series.count` prints the page size, the bug the comment at `:50-52`
records); `SeedPickerSheet.swift:130-132` ("Type a title you love" after they
typed one); `CharacterProfileView.swift:109` ("Nothing knows this character by
this id"); `SearchModel.swift:175-179` (gives up after three filtered pages,
looks like the end); `AppleVolumesRow.swift:76` ("15 of 27" with no "on Apple
Books"); `MangaUpdatesClient.swift:135-138` (a status code as a sentence).
**Fix:** no `?? .offline` anywhere — an `EmptyState` branch for `failure ==
nil`; and each copy line above corrected in place (line edits, all in §4).

---

## 3. Design decisions to put to Abdi

1. **A section that asked and failed (Similar, cast, cadence, releases,
   volumes, Discover row, continuations): inline "Couldn't load · Retry" in the
   slot, or vanish?** Recommend inline, one muted line under the section header
   with an `.aside` Retry; vanish only when the source answered and had
   nothing. This overrides two deliberate silences (`CharacterService.swift:
   12-16`, `ReleaseFeedProvider.swift:17-20`) — the ask overrides them.
2. **A partially loaded library: render with a `StaleBar`, or block until
   complete?** Recommend render with the bar ("Some of your library didn't load
   — 1,100 so far · Retry"), but hide `LibraryControl` and the "Open the shelf"
   button until `isComplete`, because those two act on the data.
3. **"Remove token" and "Deal another now": confirmation dialog?** Recommend
   yes for both, using the header reset's existing dialog and wording style;
   no confirmation for delete-lens and clear-recents (toast instead).
4. **Rate-limit countdown: live ticking timer with one automatic retry, or
   reword to "MangaBaka asked for a 38-second pause"?** Recommend the timer,
   with auto-retry on Search only (the one screen where the reader is waiting
   for exactly that); elsewhere tick without retrying.
5. **Library writes: patch the entry locally and toast "Saved", or keep the
   full re-read "so the screen shows what the server now holds"
   (`RootView+Session.swift:209-210`)?** Recommend the local patch — 1 request
   instead of 14, sheet closes at once — accepting that a server-side
   normalisation (e.g. the API rounding a chapter) shows on the next cold load
   rather than immediately.

---

## 4. Ranked table of every distinct gap

Traps first regardless of reach. Reach: **every** = every reader, **signed-in**,
**rare** (needs a specific sequence, a hostile server, or a corrupt disk).
Kit: FS = `FailureState`, ES = `EmptyState`, SB = `StaleBar`, IF = the new
`InlineFailure`, SK = `Skeleton`/`CoverSkeletonRow`, T = `Toast`, SA =
`StateAction`, CD = `ConfirmDestructive` (new), — = none. Effort: line /
function / file. Confidence from the source report.

| # | Gap | file:line | Reach | Kit | Effort | Conf |
|---|---|---|---|---|---|---|
| **Traps** | | | | | | |
| 1 | `Int(Double)` on server numbers traps; crash loop at launch if 1e20 stored | 27 sites listed in §2(g); first hit `ReadingInsights.swift:90`, `SpotlightIndex.swift:93-94` | rare | — | 27 lines + 1 helper | medium (server acceptance unverified) |
| 2 | Chapter field accepts and sends 1e20 — the source of #1 | `LibraryEditSheet.swift:309-315` | rare | — | line | high |
| 3 | Corrupt SQLite → silent in-memory DB every launch; "the app forgets my stack every day" | `AppServices.swift:154-163` | rare | T | function | high |
| 4 | Unknown `LibraryEntry.State` throws for the whole page; walk stops, spinner forever | `LibraryEntry.swift:13-20` | rare | — | function | medium |
| 5 | `Retry-After: nan` → gate returns NaN, every request refused until relaunch | `APIClient.swift:464`, `RateLimitGate.swift:24-32` | rare | — | line | high (theoretical input) |
| 6 | `ForEach(items)` keyed by `Series.id`; a feed page repeating an id traps | `DetailOnwardRows.swift:85` | rare | — | line | low (API behaviour unverified) |
| **Every reader** | | | | | | |
| 7 | Search failure is a bare sentence; 429 static, re-shown per keystroke, results dropped, nothing auto-retries | `SearchView.swift:275-285`, `SearchModel.swift:16,104,112` | every | FS | function | certain |
| 8 | One 429 on search (30/min) closes Discover, detail, library (180/min) | `RateLimitGate.swift:53-64`, `APIClient.swift:22,126` | every | — | function | high |
| 9 | `extras` five-of-six partial cached 6 h | `SeriesRepository.swift:679,699-716` | every | — | function | high |
| 10 | Series page offline/429: no branch says so | `SeriesDetailView.swift:274-285` | every | SB | function | high |
| 11 | Mix failure = "Nothing matched"; DNA and "Start over" wiped | `SeriesRepository.swift:463-465`, `MixModel.swift:101`, `MixView.swift:232` | every | FS | file | certain |
| 12 | "Deal another now" erases every save, no confirmation, no toast | `StackView.swift:319-320`, `StackModel.swift:247-256` | every | CD + T | line | certain |
| 13 | Discover row failure = "Nothing here right now"; StaleBar above fresh content | `DiscoverView.swift:194`, `DiscoverModel.swift:97,106,122` | every | IF + SB | function | certain |
| 14 | Discover all-empty online says "You're offline" | `DiscoverView.swift:279` | every | ES | line | certain |
| 15 | Page 2+ failure reads as end of feed (Discover, Search, Publisher) | `DiscoverModel.swift:178`, `SearchModel.swift:166`, `PublisherView.swift:289`, `+Paging.swift:38` | every | IF (trailing card) | function | certain |
| 16 | Similar / Readers-also-like vanish on failure | `DetailOnwardRows.swift:63`, `SeriesDetailView.swift:280-281` | every | IF | function | high |
| 17 | Cast row vanishes when both sources fail | `CharacterService.swift:94-95`, `CharacterRow.swift:30` | every | IF | function | medium |
| 18 | Cadence failure = "too few releases" | `ReleaseSchedule.swift:372-377`, `DetailHero.swift:189` | every | IF | function | medium |
| 19 | Release section silent when a matched provider fails | `ReleaseFeedProvider.swift:17-20`, `WebtoonsFeedClient.swift:63-66`, `NaverFeedClient.swift:45-54`, `GigaViewerFeedClient.swift:106-114`, `ReleaseSection.swift:18` | every | IF | file | medium |
| 20 | Release section pops in with no skeleton | `ReleaseSection.swift:13-15` | every | SK | function | medium |
| 21 | Volumes: "Apple Books couldn't be reached" dropped when MangaBaka has no works | `VolumesSection.swift:25`, `+Store.swift:19` | every | IF | function | high |
| 22 | Volumes shelf swaps content under the reader, no loading state | `+Store.swift:16-27` | every | SK | function | high |
| 23 | Character sheet blames MangaBaka / "needs an account" for AniList errors | `CharacterProfileView.swift:92-93`, `APIError.swift:52,130,104` | every | FS | function (shared) | high |
| 24 | `FailureState` countdown static; retry no spinner, double-fires | `FailureState.swift:38-44,63-75`, `APIError.swift:140-145` | every | FS | function | high |
| 25 | Failure toasts last 2 s and are replaced by the next success | `Toast.swift:22-34` | every | T | function | high |
| 26 | Cancellation is `.transport`; kit told to hide cached content | `APIClient.swift:146`, `AniListClient.swift:121,302`, `SeriesCharacter.swift:155`, `MangaUpdatesClient.swift:122`, `APIError.swift:47` | every | — | function | high |
| 27 | No request timeout anywhere; a hung host holds a leg 60 s | `APIClient.swift:377`, six third-party clients | every | — | line | high |
| 28 | Six swallowed `Task.sleep` cancellations fire requests for a page the reader left | `AppleBooksClient.swift:85`, `GoogleBooksClient.swift:76`, `WebtoonsFeedClient.swift:59,103`, `NaverFeedClient.swift:43`, `GigaViewerFeedClient.swift:104` | every | — | line ×6 | high |
| 29 | Webtoons `v3-` / Naver `v1-naver-` keys unbumped after `5bb36b8`; empty feeds cached a week | `WebtoonsFeedClient.swift:51`, `NaverFeedClient.swift:37` | every (Webtoons readers) | — | line | high |
| 30 | AniList/Shikimori never `.offline`; MangaUpdates catches one code of three | `AniListClient.swift:122`, `SeriesCharacter.swift:156`, `MangaUpdatesClient.swift:120` | every | — | line | high |
| 31 | AniList empty cast thrown as `.server(200)` | `AniListClient.swift:161` | every | — | line | high |
| 32 | `images` returns `[]` for failure; gallery reads "one cover" when throttled | `SeriesRepository.swift:653-660` | every | — | line | high |
| 33 | Stack first-load failure dressed as `EmptyState`, string message, no countdown | `StackView.swift:301-308`, `StackModel.swift:48,428` | every | FS | function | certain |
| 34 | "That's today's stack" hides an offline stale queue | `StackModel.swift:429`, `SeriesRepository.swift:319-322` | every | FS | function | certain |
| 35 | "A new one is dealt tomorrow morning" — nothing is scheduled | `StackView.swift:312-315` | every | — | line | certain |
| 36 | Stack save toasts "Saved here" after `shelf.record` threw | `StackModel.swift:267` | every | T | line | certain |
| 37 | Stack reset toasts success after `shelf.clear` threw | `StackModel.swift:248` | every | T | line | certain |
| 38 | Stack loading collapses the card area; layout jumps | `StackView.swift:125-131` | every | SK | line | likely |
| 39 | Browse: "Loading the vocabulary" forever; `isLoading`/`*FetchFailed` read by nothing | `BrowseModel.swift:27,66`, `CatalogueService.swift:57,89` | every | SK + FS | function | certain |
| 40 | Block-a-tag sheet is a blank list on failure | `BlockedTagsSection.swift:120-166`, `CatalogueService.swift:70-80` | every | FS-lite | function | high |
| 41 | Tag picker shows the bundled 2026-08-27 list unlabelled when live fails | `TagPickerSheet.swift:72-86` | every | IF (footnote) | line | certain |
| 42 | Tag picker blank when bundled and live both fail | `TagPickerSheet.swift:217-223` | every | FS | line | certain |
| 43 | Mix re-blend replaces grid with a spinner | `MixResults.swift:13-19` | every | SB-style | function | certain |
| 44 | Seed picker: failure is muted text, no retry; zero results says "Type a title you love" | `SeedPickerSheet.swift:130-132` | every | FS / ES | line | certain |
| 45 | Seed picker: seeds full, rows dimmed, no reason | `SeedPickerSheet.swift:183-184` | every | — | line | certain |
| 46 | Discover StaleBar drops cause and countdown | `DiscoverModel.swift:126-133` | every | SB | line | certain |
| 47 | Discover concurrent `load()`s interleave; StaleBar flickers | `DiscoverModel.swift:79` | every | — | function | likely |
| 48 | Community pulse never retried after a failed launch | `CommunityPulseService.swift:25` | every | — | line | certain |
| 49 | "What's new" writes observed state during body | `WhatsNew.swift:58-63` | every | — | line | likely |
| 50 | Search heading "N shown" from the previous query over a skeleton | `SearchView.swift:194` | every | — | line | certain |
| 51 | Search gives up after three filtered pages, looks like the end | `SearchModel.swift:175-179` | every | IF | line | certain |
| 52 | "Surprise me" disabled with no visual change | `SearchView.swift:182` | every | — | line | certain |
| 53 | Lens saved during a count walk is dropped | `LensCounts.swift:53` | every | — | line | certain |
| 54 | Delete lens / clear recents: no toast, no undo | `SearchIdleView.swift:99-102,157` | every | T | line | certain |
| 55 | Save lens: sheet closes, nothing confirms | `FilterSheet.swift:70`, `SearchLens.swift:81` | every | T | line | certain |
| 56 | Publisher page failure is bare text; stale list unlabelled | `PublisherView.swift:75,258` | every | FS + SB | function | high |
| 57 | Publisher count prints the page size when `count` fails | `PublisherView.swift:190` | every | — | line | high |
| 58 | Publisher pull-to-refresh and `.task(id:)` interleave | `PublisherView.swift` `.refreshable` + `load()` | every | — | line | medium |
| 59 | Character sheet retry shows no loading; second tap re-fires | `CharacterProfileView.swift:119` | every | — | line | high |
| 60 | Character sheet: untranslated description silent | `CharacterProfileView.swift:158,193` | every | IF | function | medium |
| 61 | Open series from link / Siri / Spotlight: nil path is silent | `RootView+Session.swift:160-176`, `SeriesWebLink.swift:40-46` | every | T | line | high |
| 62 | `openSeries` fans out six requests to read `.full` | `RootView+Session.swift:166` | every | — | function | high |
| 63 | Onboarding covers: six static rectangles, no shimmer, failure looks like loading | `OnboardingView.swift:112-131` | every (first launch) | SK | line | high |
| 64 | Onboarding "Connect an account" push across a dismissing cover — unverified | `RootView.swift:130-135` | every (first launch) | — | verify | low |
| 65 | Apple spine with no link looks live | `AppleVolumesRow.swift:63` | every | — | line | medium |
| 66 | "15 of 27" with no "on Apple Books" | `AppleVolumesRow.swift:76` | every | — | line | medium |
| 67 | Cover gallery pages grow under the pager when Apple volumes land | `SeriesDetailView+Covers.swift:20-28` | every | — | line | medium |
| 68 | Block/unblock tag refetches every feed, no footnote | `BlockedTagsSection.swift:47-70` | every | — | line | high |
| 69 | Account card Save greyed with no reason | `AccountCard.swift:206-212` | every | — | line | high |
| 70 | AniList health check at launch can hold 60 s | `RootView.swift:107`, `AniListClient.swift:384` | every | — | line (timeout) | high |
| 71 | `/v1/my/profile` sent with no token every launch | `AppServices.swift:203`, `APIClient.swift:339` | every (signed-out) | — | line | high |
| 72 | File caches expose no age; 7-day-old volumes served as fresh | `AppleBooksClient.swift:126` + Google/Webtoons/Naver/Giga `readCache` | every | SB | function | high (low priority) |
| 73 | Apple 403 (store region) = 60 s backoff + nil, same as 429 | `AppleBooksClient.swift:102` | rare | IF | function | medium |
| 74 | Failed feed discard keeps content the reader just excluded | `SeriesRepository.swift:545`, `+Cache.swift:84,86` | rare | — | line | high |
| 75 | CDN 429 retried once immediately, no gate | `CoverStore.swift:106-116` | rare | — | line | high |
| 76 | Intent task cancelled and restarted; two quick "Open X/Y" can end on X | `RootView.swift:111-115` | rare | — | line | medium |
| 77 | "Use as seed" toasts "Added" when `mixModel` is nil | `RootView.swift:306-309` | rare | — | line | medium |
| 78 | News row with an unsafe URL is a live dead button | `LinksSection.swift:127-128` | rare | — | line | high |
| 79 | `DetailCredits` empty body still costs a row gap (and maybe a hairline) | `DetailCredits.swift:102-182` | rare | — | line | medium |
| 80 | Tag section that is one "more groups" button | `DetailTagSections.swift:47-57` | rare | — | line | medium |
| 81 | Flat `tags` fallback unfiltered by content rating | `SeriesDetailView.swift:317` | rare | — | line | medium (unverified whether flat tags carry ratings) |
| 82 | "Nothing knows this character by this id" — developer copy | `CharacterProfileView.swift:101-117` | rare | ES | line | high (unreachable today) |
| **Signed-in** | | | | | | |
| 83 | Library partial walk: spinner forever, `failure` unread, no retry | `LibraryView.swift:97-99,228-247`, `LibraryModel.swift:58-60,238,255` | signed-in | SB | function | high |
| 84 | Signed-in empty library told "add a token"; `.empty` unreachable | `LibraryModel.swift:272`, `LibraryView.swift:286-294`, `LibraryModelTests.swift:143-148` | signed-in | ES | function | high |
| 85 | No token + offline → "You're offline — showing what was downloaded" | `LibraryModel.screenState`, `APIClient.swift:131` | signed-out | FS | function | high |
| 86 | `LibraryControl` offers "Add to library" when the walk failed or there is no token | `LibraryControl.swift:46` | signed-in | IF / SA(.fixes) | function | high |
| 87 | Write lands, reload fails → control flips to "Add to library"; +1 costs 10 requests | `LibraryControl.swift:75-78`, `LibraryModel.swift:229` | signed-in | SB | function | high |
| 88 | Edit-sheet Save re-walks 13 pages / 25 MB, deletes disk cache, no toast | `RootView+Session.swift:211-220`, `LibrarySnapshot.swift:190-201` | signed-in | T | file | high |
| 89 | Sign-out leaves the previous account's library on screen until relaunch | `RootView+Session.swift:112-130`, `LibraryModel.swift:237` | signed-in | — | function | high |
| 90 | "Remove token" forgets seven stores with no confirmation | `SettingsView.swift:92-103` | signed-in | CD | function | high |
| 91 | Library search matching nothing shows header and blank | `LibraryList.swift:20-28`, `LibraryModel.swift:294-298` | signed-in | ES | function | high |
| 92 | Continuations never retried after a failed session; loop ignores cancel | `Continuations.swift:117-128`, `ContinuationsRow.swift:25` | signed-in | IF | function | high |
| 93 | Insights: no empty state; "0 chapters" flash; built from partial; not recomputed after reload | `ReadingInsightsView.swift:30-49,62,85-103`, `RootView+Session.swift:63-66` | signed-in | ES + SB | function | high |
| 94 | Wrapped: header, provenance, nothing between; partial as total | `WrappedView.swift:45-60` | signed-in | ES + SB | function | high |
| 95 | Schedule shows "0 of 0" and a live Measure button during every cold load | `ScheduleView.swift:39-54`, `ScheduleModel.swift:119` | signed-in | SK | line | high |
| 96 | Schedule: library failed but announced works present → estimates silently missing | `ScheduleView.swift:33-34` | signed-in | SB | line | high |
| 97 | Announced dates failure reads as "nothing announced" | `ReleaseCalendar.swift:44-49,69`, `AnnouncedSection.swift:16` | signed-in | IF | function | high |
| 98 | MangaUpdates down for all → three minutes of progress, then "Measure now" with no explanation | `ScheduleView.swift:47-48,209-215`, `ReleaseSchedule.swift:326-331` | signed-in | SB | line | high |
| 99 | Build loop keeps going offline, 3 s × 55 | `ReleaseSchedule.swift:312-333` | signed-in | — | line | high |
| 100 | "MangaUpdates returned 503." on screen under "MangaBaka had a problem" | `MangaUpdatesClient.swift:135-138`, `ReleaseSchedule.swift:330`, `APIError.swift:130` | signed-in | — | line | high |
| 101 | Announced row not tappable; `publisherLink` bypasses the host allowlist | `AnnouncedSection.swift:38-71`, `UpcomingWork.swift:119-122` | signed-in | — | line | medium |
| 102 | Reminders switch reads On while iOS has denied notifications | `RemindersSection.swift`, `ReleaseReminders.swift:328` | signed-in | — | line | high |
| 103 | Reminders rescheduled on a capped walk drop series past the cap | `ReleaseReminders.swift:119` | rare | — | line | medium |
| 104 | Spotlight index wiped after a failed walk | `SpotlightIndex.swift:48-49`, `RootView+Session.swift:147` | signed-in | — | line | high |
| 105 | Siri "due this week" ignores the library failure | `AppIntents.swift:36-44,82-86` | signed-in | — | line | high |
| 106 | Siri "open a series" failure = "no match" | `LibrarySeriesEntity.swift:43-47` | signed-in | — | line | medium |
| 107 | Stack `canUseProfile = false` cached for the session on a failed status call; caption lies | `StackModel.swift:312-323`, `LibraryService.swift:183` | signed-in | caption | function | certain |
| 108 | Profile source flips to saves/random silently; `coldStart`/`profileStale` discarded | `StackModel.swift:183-192`, `LibraryService.swift:14,17,211-215` | signed-in | caption | function | certain |
| 109 | `LibraryControl` no spinner while writing; failure faint and never cleared | `LibraryControl.swift:171,236,130-135` | signed-in | T | line | high |
| 110 | Edit sheet: Cancel mid-save or timeout after the PATCH landed, no word either way | `LibraryEditSheet.swift:66`, `LibraryService.swift:283` | signed-in | T | line | medium |
| 111 | `.numberPad` blocks half chapters | `LibraryEditSheet.swift:111` | signed-in | — | line | high |
| 112 | Library subtitle "Nothing here yet" during the walk | `LibraryModel.swift:184-190` | signed-in | — | line | medium |
| 113 | Shelf detail is a stale copy; pops the reader off when emptied by an edit | `RootView+Session.swift:28,218`, `LibraryModel.swift:16` | signed-in | T / ES | function | medium |
| 114 | Shelf detail: dropped filter chip leaves `visible` empty with no message | `ShelfDetailView.swift:74,126-130` | signed-in | ES | line | medium |
| 115 | Library row with nil `series`: dead tap, dead Edit | `LibraryList.swift:68,81-90`, `LibraryView.swift:168` | rare | T | line | medium |
| 116 | Disk caches silently shrink when a row no longer decodes, reported complete | `LibrarySnapshot.swift:151-153`, `ShelfStore.swift:46` | rare | — | line | medium |
| 117 | `reload()` during a walk interleaves two `apply` streams | `LibrarySnapshot.swift:199`, `LibraryModel.swift:249-255` | rare | — | function | low |
| **Settings, rare** | | | | | | |
| 118 | Keychain write refusal shown as "Token rejected" | `SettingsView.swift:193-196`, `TokenStatus.swift` | rare | — | function | high |
| 119 | Account check offline uses feed wording | `SettingsView.swift:215-229` | signed-in | — | function | high |
| 120 | "Replace" is a dead control | `AccountCard.swift:164-187` | signed-in | — | line | high |
| 121 | `check()` on every Settings appearance; a 429 backoff flips "Connected" to "Not checked yet" | `SettingsView.swift:79-81` | signed-in | — | line | medium |
| 122 | History clear failure silent | `HistorySection.swift:49-54` | rare | T | line | high |
| 123 | Token revoked mid-session hidden by a fresh cache for up to 6 h | `LibrarySnapshot.swift:86-90` | rare | SB | function | medium (acceptable for reads) |

Developer-only, not ranked: Debug PAT shows "No account" (`TokenProvider.swift:
40`); privacy-manifest comment names 4 of ~15 hosts (`PrivacyInfo.xcprivacy`);
`AppDatabase` downgrade note.

---

## 5. Done well — merged, fixers do not touch

- `FeedResult` (`SeriesRepository.swift:285-323`): `origin`, `cachedAt`,
  `hasMore` from the API's own `next`, `blockingError` only when nothing to
  show. The model for every other read.
- `LibraryModel.screenState` (`:55-63`) decides loading/failed/list in one place;
  `.failed` → `FailureState` with Retry + Open Settings (`LibraryView.swift:76-82`);
  first page drawn as it lands (`LibraryModel.swift:249-251,277`); skeleton rows
  in the list's own shape (`LibraryView.swift:262-284`).
- `APIClient.perform` (`:119-174`): one path for reads and writes, three offline
  codes, 429 recorded before throwing, displayed `retryAfter` capped to match
  the gate. `RateLimitGate` refuses locally, honours both `Retry-After` forms,
  caps at 15 min with the cap labelled a guess; only a 2xx reopens.
- `APIError` / `FailureState` never show raw JSON, a status code or a stack for
  MangaBaka; 401/403 → "This part needs an account" + accent Open Settings; the
  accent rule (`StateAction.swift:3-10`) and the disabled treatment
  (`:25-32`). `EmptyState` has no mark on purpose (`EmptyState.swift:11-14`).
- `AppleBooksClient.volumes` nil-vs-`[]` contract (`:34-36,49`) and the page
  carries it (`+Store.swift:45`); 403 treated like 429; versioned cache keys
  with the reason for each bump (`:42-45`); `WebtoonsFeedClient` never caches
  an empty feed (`:71-79`).
- `extras`/`images` refuse to cache an all-empty answer (`SeriesRepository.swift:
  656-660,676-679`); `+Cache.swift:154-162` misses the whole read rather than
  shortening a feed; `CacheScope`/`apply` one declared invalidation policy;
  `updateLibraryExclusion` compares against the id the cache was written under.
- `CharacterService.isAniListOutage` marks AniList down only on 403/5xx
  (`:141`); the 200-with-no-cast blackout is fixed and documented.
  `AniListClient` handles GraphQL errors-in-200, types the slot-wait cancel
  (`:194-202`), health check uses a real media id.
- `ReleaseSchedule.cadence(for:)` writes a failure row so the next open retries
  (`:372-377`); failure rows retried, null cadences settled; `Task.isCancelled`
  per series (`:313`); `Scope.failure` keeps "offline" from reading as "no
  library" (`:163-168`); undecodable cadence rows treated as failures (`:404-406`);
  `ScheduledWork.Reason.explanation`; stale estimates named with a count
  (`ScheduleView.swift:146-163`); Measure button spins and disables; build
  survives leaving the screen and is re-followed.
- `MangaUpdatesClient` 429 backs the spacer off; sleep cancellation is an error,
  not a hang (`:154-162`). `RequestSpacing` claim-before-wait with the 96 µs
  measurement in the comment.
- `CoverStore` never caches a failure, one retry, 404 settled, decode off the
  main actor; `CoverImage` BlurHash → flat colour, never a broken-image glyph,
  resets `loaded` per fetch. `BlurHash.parse` length-checks before every index.
- Discover: skeleton rows on first load (`DiscoverView.swift:191-192`), StaleBar
  when content survives a failed refresh (`:63-67`), `FailureState` when nothing
  does (`:279` — once the `?? .offline` goes); reload-generation guard and
  de-duplication (`DiscoverModel.swift:163,169`).
- Search: `defer { isSearching = false }` (`SearchModel.swift:95`), generation
  guards (`:103,152`), bounded empty-page loop (`:134`); `SearchEmptyState` names
  the filter count with "Clear filters" — empty and failed *are* distinguishable
  (`:12-18`); `LensCounts` nil-not-zero; `TagSearch`/`PublisherBrowser`
  "could not search" vs "no matches"; `FilterSheet` undoable "Clear all".
- Mix: disabled Blend looks disabled (`MixView.swift:208-219`); debounced filter
  taps (`MixFilterStrip.swift:157-167`).
- Stack: provenance captions incl. the random fallback (`StackModel.swift:27-34`);
  refill join (`:157-166`); save-to-library failure said under the right card
  (`:293-307`); `StackResetMenu` confirmation names the consequence (`:32-46`).
- `CommunityPulseService` a grace note that fails silently by design (`:12-15`).
- Edit sheet: nothing sent until Save, only touched fields, invalid chapter
  blocks Save with a sentence, failure inline and the sheet stays, Save disabled
  and spinning, decimal comma / Arabic digits parsed, 1e20 does not crash the
  formatter (`LibraryEditSheet.swift:137-144,217-220,226-255,273-279,309-315`).
  `NaN`/`inf` refused before `JSONSerialization` (`APIClient.swift:255-268`).
- A failed walk is never cached (`LibrarySnapshot.swift:119-122`); clock going
  backwards ignored (`:146-147`); cache dropped on every write (`:190-201`).
- Pick back up hides when empty, bar only with a real denominator
  (`PickBackUp.swift:12,86-91`); Continuations skeleton while loading, keyed on
  `isComplete` (`ContinuationsRow.swift:18-24`, `LibraryView.swift:145-148`).
- Reminders: asked only from the switch, refusal leaves it off, denied state gets
  Open Settings, library failure keeps yesterday's, trigger never in the past,
  capped at 40 (`ReleaseReminders.swift:14-17,57-68,119,284-291,31`;
  `RemindersSection.swift:35-51`).
- Spotlight cleared on sign-out; thumbnails from `URLCache` only. Intents:
  `services == nil` guard with a sentence; "not measured" distinguished from
  "nothing due" (`AppIntents.swift:33-35,82-86`).
- Token check three-valued; only a real 401/403 clears the Keychain
  (`SettingsView.swift:203-212`). Content opt-in confirmed with the consequence;
  history clear confirmed and says what survives; last format cannot be
  switched off (lock pill). Debug PAT cannot reach Release.
- Every section on the series page hides on empty (detail row 36) — no "None
  listed" printed; all outbound links pass `SafeLink.web` and the reading
  allowlist (`SeriesExtras.swift:90-112,179-191`); synopsis Markdown failure
  falls back to plain text; cover gallery bounds-checked, Reduce Motion honoured;
  `DetailScheduleBlock` "Estimating" with a spinner; `CharacterRow` placeholders;
  `DetailOnwardRows` skeletons while loading.
- Every file-cache write is `try?` + `.atomic` in `.cachesDirectory`; a full
  disk costs a cache write, not a crash. `AppDatabase.onDisk` → in-memory
  fallback (the fallback itself is gap #3, the *existence* of one is right).
- No `try!`, `as!`, `.first!`, `fatalError`, force-unwrap or `URL(string:)!` in
  the tree (four independent greps agree). Every `preconditionFailure` is on a
  compile-time URL literal. Every integer division and range is guarded.
- `Signposts`/`NetworkLedger` on-device only; nothing leaves the phone.
  Privacy manifest keys are right. No ATS exception. Onboarding is not a gate.
- Toast never intercepts taps and announces to VoiceOver (`Toast.swift:28,60`).

---

## 6. Fix batches by file ownership

Seven batches; no file appears in two. **Batch 0 goes first** — 2, 3, 4 and 5
compile against its types. Each gap names the test that proves it; every test
must fail before the change (paste the failure). Stubs: `StubRepositoryBase`
(`MangaBakaTests/SeriesFactory.swift:72`), `URLProtocolStub`, `TestClock`.

### Batch 0 — shared types and kit (goes first)

Files: `Core/Networking/APIError.swift`, `APIClient.swift`, `RateLimitGate.swift`;
`Features/Shared/FailureState.swift`, `Toast.swift`, `StateAction.swift`
(+ `PressStyle` wherever it lives); new `Core/Model/Fetched.swift`,
`Core/Model/Int+Clamped.swift`, `Features/Shared/InlineFailure.swift`,
`Features/Shared/ConfirmDestructive.swift`, `Features/Shared/Countdown.swift`.

| Gap | Change | Test |
|---|---|---|
| 23, 100 (b) | `APIError.party`; `headline`/`needsAccount`/`userFacingMessage` read it | `APIErrorPresentationTests`: `.server(403, "AniList returned 403.", party: .aniList).headline == "AniList had a problem"`, `.needsAccount == false`, message has no `/returned \d{3}/`. Fails today on all three. |
| 26 (d) | `case cancelled`; `perform` maps `URLError.cancelled`; `staleContentRemainsUseful == true` | stub handler that waits, cancel the task → `error == .cancelled`. Fails today: `.transport("…cancelled…")`. |
| 27 (d) | shared `URLSessionConfiguration` with `timeoutIntervalForRequest = 20` | stub that never responds → throws `.transport` within 25 s; before the change still pending at 25 s. |
| 5, 24 (i) | `.rateLimited(until: Date)`; `humanDuration` guards `isFinite`; `parseRetryAfter` guards `isFinite`; `Countdown(until:)` on `TimelineView`; `FailureState` `isRetrying` + optional `autoRetry` | `parseRetryAfter("nan") == nil`, `("inf") == nil` (both non-nil today). `FailureState`: retry closure that waits → second tap during wait is a no-op (`StateFamilyTests`). |
| 8 (a/i) | `RateLimitGate` sliding-window counter for `/v2/series/search` at 30/min | 30 searches in one `TestClock` second succeed, 31st throws `.rateLimited` with `requests.count == 30`; a `discover/rising` in the same second still goes out. |
| 25 (e) | `ToastCentre.show(_:kind:)` — `.failure` 4 s, not replaced by a `.success` within its window | show failure, show success at +0.5 s → `message` still the failure. |
| 1 (g) | `Int(wholeOrClamped:)` helper | `Int(wholeOrClamped: 1e20) == .max`, `(-1e20) == .min`, `(12.5) == 12`. |
| (a) | `Fetched<T>` type; `InlineFailure` view | `Fetched.isUsable` / `blockingError` mirrors `FeedResult`; `InlineFailure` is a branch, verified by screenshot on Haiku. |
| (h) | `ConfirmDestructive(title:consequence:)` extracted from `StackResetMenu` | pure — the dialog is a SwiftUI branch; assert `isConfirming` toggles. |
| 52, 65 (l) | `PressStyle` reads `isEnabled` | assert the disabled colours (`StateFamilyTests`). |

### Batch 1 — repository and MangaBaka services (depends on 0)

Files: `Core/Persistence/SeriesRepository.swift`, `+Paging.swift`, `+Cache.swift`,
`+Count.swift`; `Core/Model/CatalogueService.swift`; `Core/Library/LibraryService.swift`;
`Features/Shelf/ShelfStore.swift`; `MangaBakaTests/SeriesFactory.swift` (stub).

| Gap | Change | Test |
|---|---|---|
| 9 (c) | `fetchExtras` records per-leg failure; `extras` skips the cache when any leg failed; `SeriesExtras.failure: APIError?` | stub `/works` → 429, others fixtures; `extras` twice with `TestClock` +1 s → a second `/works` request. Today: one request, `volumes == []` served 6 h. |
| 11 (a) | `mix` returns `MixResult.failure` | `MockURLProtocol` 429 on `/mix` → `failure == .rateLimited`, `recommendations.isEmpty`. Today `.empty`, no error. |
| 32 (a) | `images` → `[SeriesImage]?` | stub 429 → nil; stub `[]` → `[]`. |
| 15 (a) | `feedPage` keeps `hasMore = true` on `.staleAfter` | stub page 2 → 500 → `result.hasMore == true`. Today false. |
| 39, 40, 41, 42 (a) | `tags(limit:)`/`genres()` return `Fetched<[Tag]>` (failure carried, flags deleted) | stub `.offline` → `failure == .offline`, `value == []`. Today `[]` and a flag nothing reads. |
| 107, 108 (f) | `recommendationStatus` typed throw; `recommendations` returns `PersonalRecommendations { items, coldStart, profileStale, failure }` | stub offline → throws `.offline` (today nil); fixture `cold_start: true` → `coldStart == true, failure == nil`. |
| 71 (f) | `profileID` short-circuits when `authorizationHeader() == nil` | `UnauthenticatedTokenProvider` → `requests.count == 0`. Today one 401. |
| 74 | `discardCachedFeeds` returns `Bool`, callers log | read-only `DatabaseWriter` → `updateContentRatings(["safe"]) == false`. |
| 116 (c) | `ShelfStore.entries` returns `(series, undecodable: Int)` | insert `payload = "{}"` → `undecodable == 1`. Today the shelf is one shorter. |

### Batch 2 — series page (depends on 0, 1)

Files: `Features/Detail/SeriesDetailView.swift`, `+Store.swift`, `+Covers.swift`,
`VolumesSection.swift`, `DetailOnwardRows.swift`, `DetailHero.swift`,
`DetailStatsStrip.swift`, `DetailScheduleBlock.swift`, `CharacterRow.swift`,
`CharacterProfileView.swift`, `LibraryControl.swift`, `PublisherView.swift`,
`LinksSection.swift`, `DetailCredits.swift`, `DetailTagSections.swift`,
`AppleVolumesRow.swift`, `TrackerScores.swift`, `ReleaseSection.swift`.

| Gap | Change | Test |
|---|---|---|
| 10 | `pageFailure` = first failure among `extras.failure`, `similar.origin`, `also.origin`; `StaleBar` between hero and actions | pure `SeriesDetailView.pageFailure(extras:similar:also:)` → `.offline` when any is `.staleAfter(.offline)`, nil when all `.cache`/`.network`. |
| 16 | `DetailOnwardRows(failure:)` → `InlineFailure` instead of hiding | `onwardRowState(items: [], isLoading: false, failure: .offline) == .failed`; `.hidden` when `failure == nil`. |
| 17 | `CharacterRow(failed:)` renders `InlineFailure` | needs batch 3's `CastAnswer`; view test: `failed && cast.isEmpty` → `.failed`. |
| 18 | `DetailScheduleBlock(failure:)` one muted line | `loadCadence` stores `.failed`; `blockState(cadence: .failed(.rateLimited)) == .failed`. |
| 21, 22 | `VolumesSection(note:)` renders header + note with empty volumes; `isStoreLoading` → "Checking Apple Books…" / `CoverSkeletonRow` | `VolumesSection.shows(volumes: [], note: "…") == true`; `shows([], nil) == false`. |
| 19, 20 | `ReleaseSection` shows `InlineFailure` when `summary.isEmpty && !failedSources.isEmpty`; skeleton line while loading and a provider matched | after batch 3: `sectionState(report: .init(failedSources: [.webtoons]), isLoading: false) == .failed`. |
| 23, 59, 60, 82 | sheet passes `party: .aniList`; `load()` sets `.loading` first; `descriptionNote` when translation unavailable; `unavailableState` → `EmptyState` | `availability = .unsupported` → `descriptionNote != nil`; retry sets `state == .loading` before the await. |
| 86 | `LibraryControlModel.load()` keeps `entry = nil` and sets `checkFailure`/`needsAccount` from `store.failure`/`store.hasCredentials`/`store.isComplete` | stub `failure = .offline, entries = []` → `isKnown == false`, `checkFailure == .offline`. Today `isKnown == true`, `current == nil` — the "Add to library" bug. |
| 87, 109 | apply the change locally on success, `refresh()` in background, keep local entry on reload failure; `ProgressView` while `isWorking`; failure via `Toast` and cleared on next action | `library.update` succeeds, `store.reload` fails → `current?.progressChapter == 69`. Today nil. |
| 56, 57, 58, 15 (Publisher) | `state(series:origin:isLoading:)` → `.failed`/`.stale`/`.empty`/`.list`; `FailureState`/`StaleBar` branches; count hidden when `total == nil && hasMore`; trailing `InlineFailure` on page failure; `.refreshable` bumps `reloadToken` | `state([], .staleAfter(.offline), false) == .failed(.offline)`; `headerCount(total: nil, hasMore: true) == nil` (today "100"). |
| 78 | filter news `items` by `safeURL != nil` | `NewsSection.visible(items)` drops `javascript:` item. |
| 79, 80, 81, 65, 66, 67, 6 | `if !rows.isEmpty`; first-group fallback; rating filter on flat tags (or drop); spine disabled look; "on Apple Books"; snapshot gallery images; de-dup `items` by id | one-liners; `DetailTagSections.visibleGroups(groups:)` non-empty when groups exist; `Array(uniqueIDs:)` on the onward items. |
| 1 (g) | `Int(wholeOrClamped:)` at `DetailHero:313`, `DetailStatsStrip:58,61`, `+Store:24,53`, `LibraryControl:180,191,195`, `TrackerScores:54-55` | `Series(totalChapters: 1e300)` → `DetailStatsStrip.stats` has a "Chapters" entry, no trap. |

### Batch 3 — third-party clients and schedule core (depends on 0)

Files: `Core/Characters/CharacterService.swift`, `AniListClient.swift`,
`SeriesCharacter.swift`; `Core/Volumes/AppleBooksClient.swift`,
`GoogleBooksClient.swift`; `Core/Schedule/WebtoonsFeedClient.swift`,
`NaverFeedClient.swift`, `GigaViewerFeedClient.swift`, `ReleaseFeedService.swift`,
`ReleaseFeedProvider.swift`, `MangaUpdatesClient.swift`, `ReleaseSchedule.swift`,
`ReleaseCalendar.swift`.

| Gap | Change | Test |
|---|---|---|
| 30, 31 | three offline codes → `.offline` in AniList, Shikimori, MangaUpdates; empty cast returns `[]` | stub `URLError(.networkConnectionLost)` → `.offline` (today `.transport`); `edges: []` → `[]`, `lastOutcome` `.shikimori` after fallback. |
| 17 | `characters()` → `CastAnswer { cast, failed }`, `failed` only when every asked source threw | both throw `.offline` → `failed == true`; both return `[]` → `failed == false`. |
| 28 (d) | six `Task.sleep` sites → `sleepOrBail`, return nil on cancel | `TestClock`, claim a slot, cancel before resume → `requests.isEmpty`. Today the request is sent. |
| 29 (c) | Webtoons `v4-`, Naver `v2-naver-`, comment naming `5bb36b8` | `readCache("v3-…") == nil`; `WebtoonsTitle.read("외전 3화").number == nil` (exists). |
| 73 | Apple 403 → `.unavailableInStore`, no 60 s backoff | stub 403 → new case; next call does not sleep. |
| 72 | `readCache` returns `storedAt` | write at T, read at T+6 d → `storedAt == T`. |
| 19 | `ReleaseFeedProvider.feed` → `FeedAnswer { notCarried, failed, feed }`; `ReleaseReport.failedSources` | stub `.failed` → `failedSources == [.webtoons]`, `summary == .none`; `.notCarried` → `[]`. |
| 18 | `cadence(for:)` returns `.failed(APIError)` from the catch | stub 503 → `.failed(.server(503, …, party: .mangaUpdates))`, `readCache()[id]?.failure != nil`. Today `.none`. |
| 98, 100 | `progress.failure` keeps the `APIError`; MangaUpdates `.server` message "MangaUpdates isn't answering right now." | 503 stub → `userFacingMessage` has no digits. |
| 99 (d) | build loop breaks on `.offline`/`.rateLimited` | stub `.offline` → `progress.done == 1, total == 55`, elapsed ≪ 3 s × 55. |
| 97 | `ReleaseCalendar.upcoming()` → `Fetched<[UpcomingWork]>` | first page throws → `failure != nil, value.isEmpty`; second call retries (control). |
| 70 | `healthCheck` under the 15 s third-party timeout | shared configuration, covered by batch 0's test. |

### Batch 4 — Discover, Search, Mix, Stack, Browse (depends on 0, 1)

Files: `Features/Discovery/DiscoverModel.swift`, `DiscoverView.swift`,
`WhatsNew.swift`; `Core/Model/CommunityPulseService.swift`;
`Features/Search/SearchModel.swift`, `SearchView.swift`, `SearchIdleView.swift`,
`LensCounts.swift`, `TagPickerSheet.swift`, `FilterSheet.swift`, `SaveLensSheet.swift`;
`Features/Mix/MixModel.swift`, `MixResults.swift`, `MixView.swift`,
`SeedPickerSheet.swift`, `BlendDNAView.swift`; `Features/Stack/StackModel.swift`,
`StackView.swift`, `StackResetMenu.swift`; `Features/Browse/BrowseModel.swift`,
`BrowseView.swift`; `Features/Settings/BlockedTagsSection.swift` (the tag
picker sheet; the rest of Settings is batch 6).

| Gap | Change | Test |
|---|---|---|
| 7 (i) | `SearchModel.failure: APIError?` replaces `message`; `FailureState(autoRetry: true)` on `.rateLimited`; keep last results under `StaleBar` | stub `.staleAfter(.rateLimited(until: +30 s))` → `failure?.countdown` non-nil, `results` unchanged from the previous query. Today `message` is a string and `results == []`. |
| 15 | `loadMore` keeps `hasMore` on `.staleAfter`; `pageFailure` → trailing `InlineFailure` | stub page 2 `.staleAfter(.offline)` → `hasMore == true`, `pageFailure == .offline`. |
| 50, 51, 52, 53, 54, 55 | hide "N shown" while searching; "Stopped early" note; dimmed Surprise; queue the new lens; toasts for delete/clear/save | `heading(isSearching: true) == nil`; `LensCounts` walk running + save → lens counted after the walk. |
| 41, 42 | `TagPickerSheet.status(bundled:fetched:failed:) → .live/.bundledOnly/.nothing` | three cases; today no such state. |
| 13, 14, 46, 47 | `Row.failure`/`pageFailure`; `isShowingStale` requires `.staleAfter` **and** non-empty; `staleDetail` adds headline + countdown; `EmptyState` when `failure == nil`; join concurrent loads | row 0 `.staleAfter(.offline)` empty, rows 1–3 `.network` → `isShowingStale == false`, `rows[0].failure == .offline` (today true). All rows `.network` empty → view state `.empty`, not `.offline`. |
| 48, 49 | pulse retries on next `load()` when `didFail`; first-run stamp out of `isDue` | `isDue(hasCompletedOnboarding: false)` does not mutate `lastSeen`. |
| 11, 43, 44, 45 | `run()` sets `failure`, does not overwrite `results`/`dna`/`moves`; `MixResults` `FailureState` branch and dimmed grid while running; seed picker copy | stub `.rateLimited` → `model.failure == .rateLimited`, `model.dna` unchanged, `message == nil`. Today `dna == .empty`, `message == "Nothing matched…"`. |
| 1 (g) | `BlendDNAView:92` clamp | `percent(1e300)` does not trap (crashes today). |
| 33, 34, 12, 35, 36, 37, 38, 107, 108 | `StackModel.failure: APIError?` from `blockingError` **or** `origin` when all filtered; `FailureState`; "Deal another now" → `ConfirmDestructive` + toast; drop the promise; confirm saves/reset only on success; card-shaped skeleton; `canUseProfile` cached only on a real answer; `Source.unavailable(APIError)` caption | `.staleAfter(.rateLimited)` empty → `failure == .rateLimited`; `.staleAfter(.offline)` all reacted → `failure == .offline` (today nil); `recommendationStatus` throws → `canUseProfile == nil` after one refill (today false); `shelf.record` throws → `saved` does not contain the id, `saveWarning != nil`. |
| 39 | `BrowseModel.failed`; skeleton chips while `isLoading`; `FailureState` when failed and empty; subtitle stops saying "Loading" | failing `MockURLProtocol` → `isLoading == false`, `failed == true`, `subtitle != "Loading the vocabulary"`. |
| 40, 68 | `BlockTagPicker` retry state on `failure != nil`; footnote under the chips | stub `.offline` → picker state `.failed`. |

### Batch 5 — Library, Insights, Wrapped, Schedule screens, intents (depends on 0)

Files: `Features/Library/LibraryModel.swift`, `LibraryView.swift`, `LibraryList.swift`,
`LibraryEditSheet.swift`, `ShelfDetailView.swift`, `ContinuationsRow.swift`,
`ReadingInsightsView.swift`, `WrappedView.swift`; `Core/Library/LibrarySnapshot.swift`,
`LibraryEntry.swift`, `Continuations.swift`, `ReadingInsights.swift`,
`ReadingWrappedYear.swift`, `SpotlightIndex.swift`; `Features/Schedule/ScheduleView.swift`,
`ScheduleModel.swift`, `AnnouncedSection.swift`; `Core/Schedule/UpcomingWork.swift`,
`SeasonReading.swift`; `Core/Notifications/ReleaseReminders.swift`;
`Core/Intents/AppIntents.swift`, `LibrarySeriesEntity.swift`; `Core/Model/CommunityPulse.swift`;
`MangaBakaTests/LibraryModelTests.swift`.

| Gap | Change | Test |
|---|---|---|
| 84, 85, 89 (f) | delete `hasAccount` row heuristic; `screenState` reads `hasCredentials`; `.empty` = `entries.isEmpty && isComplete && failure == nil`; `forget()` for batch 6 to call | stub `[]` → `.empty` (invert `noAccount()` at `LibraryModelTests.swift:143-148`); stub 401 → `.failed(.server(401))` (control); `forget()` → `entries.isEmpty` and next `load()` walks. |
| 83 (i) | `partialFailure` when `!entries.isEmpty`; `LibraryView` three-way `partialLoad`: spinner / `StaleBar` + Retry → `reload()` / "Showing the first 3,000" | `PagedLibrary` throwing on page 3 → `entries.count == 200`, `isComplete == false`, `partialFailure == .offline`, `screenState == .list`. |
| 91, 112 | `isFiltering` + `EmptyState("Nothing matches", "Clear search")`; subtitle blank while loading | 10 entries, `searchText = "zzz"` → `listed.isEmpty && isFiltering`. |
| 117 (j) | generation counter around `fetchAll` | `load()` then `reload()` before page 2 → final `failure == nil`, `entries.count` equals the second walk. |
| 88 (j) | `LibrarySnapshot.apply(seriesId:change:)` in memory + disk row; `LibraryModel.apply(change:)` | cached 3 entries, apply state change → `load().entries` reflects it, no network. |
| 116, 4 (c) | `readCache` nil when `entries.count != rows.count`; `LibraryEntry.State` decodes unknown to `.other(String)` | write 3 rows, corrupt one → `load()` goes to network; a page with `state: "zzz"` decodes with one `.other`. |
| 92 (d) | `guard !Task.isCancelled`; count nil results; do not set `loadedFor` when all failed | all-nil repository → `items.isEmpty`; second `load` calls the repository again (today 0 calls). |
| 93, 94 (c/k) | take `isComplete`; `StaleBar` "Built from the N series that loaded"; `EmptyState` when nothing qualifies; headline hidden until computed; `.task(id: revision)` | `ReadingInsights.hasAnythingToSay([]) == false`, one reading entry → true. |
| 95, 96, 98 (k) | `ScheduleModel.screenState` with `.loading` first; `StaleBar` under announced when `libraryFailure`; `measurementFailureLine` in `firstRunCard` | fresh model → `.loading`; `ScheduleProgress(failure:)` + `pending: 55, measuredAt: nil` → `measurementFailureLine != nil && hasNeverMeasured` (unreachable today). |
| 97, 101 | `announcedFailure` → inline note; row opens the series; `publisherLink` through the allowlist | `publisherLink("http://x")` == nil. |
| 102, 103 | `effectiveEnabled = isEnabled && systemStatus != .denied`; `reschedule` treats `!isComplete` like a failure for removals | `.denied` → `effectiveEnabled == false`; partial walk → `removeAll` not called. |
| 104 | `reindex` skipped when `load().failure != nil` (called from batch 6, decided here) | recording index: failed walk → `deleteSearchableItems` not called. |
| 105, 106 | `DueThisWeek.sentence(libraryFailure:)`; `entities(matching:)` throws on failure | `.offline` → sentence starts "I couldn't read your library". |
| 2, 1 (g) | `parseChapter` refuses `> 100_000`; `Int(wholeOrClamped:)` at the 18 Library/Insights/Wrapped/Spotlight/SeasonReading/CommunityPulse sites; `.decimalPad` | `isInvalidChapter("99999999999999999999") == true`; `ReadingInsights.chaptersRead(in: [entry(progressChapter: 1e20)])` returns — crashes the test process today, which is the proof. |
| 110, 111, 113, 114, 115 | toast on completion regardless of sheet; reload on transport failure; `openShelf` keyed on state, `EmptyState` when emptied; reset `filter` when it leaves `availableFilters`; hide Edit for nil-series rows + toast on tap | `ShelfDetailView.visibleFilter(selected: .x, available: [.all]) == .all`. |

### Batch 6 — shell and Settings (depends on 0, 5)

Files: `App/AppServices.swift`, `RootView.swift`, `RootView+Session.swift`;
`Features/Settings/SettingsView.swift`, `AccountCard.swift`, `TokenStatus.swift`,
`HistorySection.swift`, `RemindersSection.swift`; `Features/Onboarding/OnboardingView.swift`;
`Core/Networking/TokenProvider.swift`; `Core/Model/SeriesWebLink.swift`;
`Resources/PrivacyInfo.xcprivacy`.

| Gap | Change | Test |
|---|---|---|
| 3 | `makeDatabase` renames a bad file to `.corrupt-<date>`, retries once, `databaseWasReset` → one-shot toast in `startSession` | garbage at a temp path → working DB and the renamed file exists; a good file opens without renaming (control). |
| 88 (j) | `saveLibraryChange` patches via `LibrarySnapshot.apply` + `LibraryModel.apply`, `ToastCentre.show("Saved")`; full `reload()` only on patch failure | `LibraryWriteTests`: after a rating save `libraryPage` call count == 0 and `entries.first{…}.rating == 80`. Today 13 calls. |
| 89 (f) | `forgetPreviousAccount` calls `session.library.forget()`, clears `stackModel?.ranker` | sign out → `session.library.entries.isEmpty`. |
| 104 | `startSession` skips `spotlight.reindex` on a failed walk | covered in batch 5. |
| 61, 62, 76, 77 (l) | toast on every nil path of `openSeries`/`openFromSpotlight`/`onOpenURL`; single-series fetch instead of `extras`; `guard !Task.isCancelled` in the intent task; guard the seed toast | stub repository returning empty extras → `ToastCentre.message != nil`. |
| 90 (h) | "Remove token" → `ConfirmDestructive` | `isConfirmingRemoval` toggles. |
| 118, 119, 120, 69, 121 (f) | `TokenStatus.notStored`; `APIError.shortReason` on the card; "Replace" → `status = .idle`; "Tokens start with mb-" note; re-check only when older than an hour | `TokenStatus.isRejection == false` for `.notStored`; `save()` with a stub store whose `write` fails leaves `storedTokenExists` unchanged; `.offline.shortReason == "you're offline"`. |
| 102 | indicator off when `systemStatus == .denied` (view side of batch 5's `effectiveEnabled`) | reads the model flag; screenshot on Haiku. |
| 122 | `ToastCentre` from the environment; toast on `clear()` throwing | stub history that throws → `message == "Couldn't clear the list"`. |
| 63 | `.shimmering()` on the six placeholders; stop when `didFail` | visual; screenshot on Haiku. |
| 64 | verify the Settings push survives the tab switch; if not, `.onChange(of: hasCompleted)` | simulator, once. |
| — | privacy manifest comment lists every host; `AppDatabase` downgrade note | none; comment. |

### Order

0 → 1 → {2, 3, 4, 5 in parallel, one agent each} → 6. Batch 6 is small and
last because it calls into 5's `forget()`/`apply()`. One `xcodegen generate`
after batch 0 (new files), one build per batch, never two at once.

### Unsure, carried from the reports

- Whether MangaBaka stores `progress_chapter: 1e20` (gap 1's reach). Cheap to
  fix either way; the client-side path to sending it is real.
- Whether `navigationDestination(item:)` re-renders `ShelfDetailView` for an
  `==`-equal `Shelf` (gap 113). Device check, not a guess.
- Whether the API repeats an id within one feed page (gap 6).
- Whether v1 flat `tags` carry a content rating (gap 81).
- The `reload()`-during-walk interleave (gap 117) is reasoned, not observed.
- Gap 64 (onboarding push) — the one shell path nobody could reason to a
  certainty.
