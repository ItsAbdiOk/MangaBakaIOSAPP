# Deep review — slice 7, the series page (`Features/Detail`)

Read-only, 2026-09-14, HEAD `99a1124`. Every line number below was read, not
guessed. No build, no test, no simulator, no curl was run.

**Fraction read:** all 29 files under `MangaBaka/Features/Detail/` (6,478
lines) in full. Supporting reads, for the request count and the crash lens:
`App/RootView+Session.swift:300-430`, `App/AppServices.swift:21-41,90-110`,
`Core/Volumes/OpenLibraryCovers.swift` (full), `VolumeShelf.swift` (full),
`Core/Volumes/AppleBooksClient.swift:12-82`, `GoogleBooksClient.swift` (grep),
`Core/Characters/CharacterService.swift:118-200`,
`Core/Schedule/ReleaseSchedule.swift:340-435`, `MangaUpdatesClient.swift`
(grep), `ReleaseFeedService.swift:38-70`, `Core/Library/TasteProfile.swift`
(grep), `Features/Library/LibraryModel.swift:311-345`,
`Core/Persistence/SeriesRepository.swift:460-475,748-880`,
`Core/Offline/EmbeddingIndex.swift:59-120`, `Features/Shared/CoverStore.swift:1-120`,
`CoverImage.swift:60-135`, `RowAmbient.swift:1-80`, `DesignSystem/Motion.swift:24-70`,
`MotionModifiers.swift:48-75`, `Core/Model/Series.swift:212-238`,
`Core/Model/Int+Clamped.swift:41-49`, `Core/Model/Cover.swift:115-130`,
`Core/Volumes/AppleBooksVolume.swift:234-243`, `Core/Schedule/MangaUpdatesID.swift:24-37`.
Not read: `AppleBooksMatch.swift` beyond grep, `ShikimoriClient`, `AniListClient`,
the three feed clients beyond their spacing constants, `TagGrouping`,
`SeriesExtras`, `FeedResult`.

Already on record and not re-filed: the 46-row failure audit in
`docs/reviews/failures-detail.md` (most rows are now fixed in code — the
"gap N" comments throughout the slice cite them), the source-text test
assertions (`docs/reviews/tests.md` F19 — `DetailHeroFormTests.swift:79-93`,
`LibraryControlTests.swift:304-311`, `DetailFidelityTests.swift:231-238,353-396,450`
are still that pattern), the Open Library caption, the volume-cover gap filler,
MangaUpdates categories.

---

## Ranked top ten (value against effort)

| # | Finding | Effort | Confidence |
|---|---|---|---|
| 1 | **F3** Two `MangaUpdatesClient` instances → cadence and categories hit MangaUpdates concurrently on every page open, defeating the 3 s spacing the client exists for; a 429 back-off on one is invisible to the other | two lines | certain |
| 2 | **F1** `scrollOffset` is `@State` on `SeriesDetailView` → the whole page body (Markdown parse, tag grouping, cover sort, shelf merge, ~11 `Series.filling` copies, a model allocation) re-runs on every scroll frame | a function (`@Observable` tracker) + a line (cache the prose) | likely |
| 3 | **F5** `SeriesPager` starts at page 0 and jumps in `onAppear`, under `.animation(value: position)` → page 0's `SeriesDetailView.task` fires its 9-request `loadCore` before the jump; the jump itself may animate through every page between | two lines | likely / worth checking |
| 4 | **F2** `DetailBackdrop.height` is declared and never applied → the 72 pt blur covers the whole ScrollView, not 420 pt, and is re-offset every frame; the gallery draws two of them | two lines + one measurement | likely |
| 5 | **F10** `loadOpenLibraryCovers` is an unbounded sequential loop, 3 s per ISBN, that commits nothing until the last answer → a long cover-less shelf shimmers for minutes | a function | certain |
| 6 | **F7** `VolumesSection` uses a plain `HStack` (its sibling `AppleVolumesRow` uses `LazyHStack`) → every MangaBaka volume cover is requested at once, and `CoverStore` deliberately never cancels | a line | certain |
| 7 | **F4** `coversFailure` is computed, commented, and never read (charter #3) → a failed `/images` fetch says nothing anywhere | a line | certain |
| 8 | **F14** The volumes shelf is the one section whose failure is a bare `Text` with no retry and no reason (`appleUnreachable: Bool`) | a function | certain |
| 9 | **F20** `StaleBar` retry re-runs the whole `load()` including every onward leg that already succeeded (≈9 MangaBaka + up to 9 third-party requests) | a line | certain |
| 10 | **F33** `cadence(for:)` reads and JSON-decodes the entire `cadenceEntry` table to look up one series, per page open | a function | certain (cost: worth checking) |

---

## The request budget of one page open — counted by reading

Order and priority, from `SeriesDetailView.swift:428-485` and
`+Releases.swift`, `+Store.swift`, `+Categories.swift`:

**Phase 1, `loadCore` (`:437-467`), four `async let`s, all `RequestPriority.userInitiated`
(`SeriesRepository.swift:463-465`), 9 MangaBaka requests worst case:**
- `feed(.similar)` — 1 (`/v2` feed; 24 h disk cache, `SeriesRepository.swift:331-337`)
- `feed(.readersAlsoLike)` — 1 (same)
- `extras(for:)` — 6 concurrent `/v1` calls: `links`, `news?limit=6`, `relationships`,
  `/series/{id}`, `collections`, `works` (`SeriesRepository.swift:840-873`); 6 h cache
- `images(for:)` — 1 (`:748-762`; in-memory per session)

Alongside, not awaited by anything: `LibraryControl.task` → `store.load()`
(`LibraryControl.swift:224-231` → `LibraryModel.swift:311-345`): the shared
library walk, up to 10 pages of 100 for a 937-entry account, **once per session**
(`fetchAll` short-circuits on `!entries.isEmpty`). So the first series page of a
session is a 19-request burst against the 180/min general window; every later
page is 9 (or 0-9, depending on cache).

**Phase 2, `loadOnward` (`:469-484`), seven `async let`s, all started at once:**
- `loadCast` — AniList 1 + Shikimori 1, concurrent (`CharacterService.swift:120-123`). **No cache** — see F11.
- `loadCadence` — MangaUpdates 1 (`ReleaseSchedule.swift:394-415`; GRDB cache, settled answers never re-fetched). Skipped for finished series / no id.
- `loadTaste` — 0-1 (`TasteProfile.swift:46-60`, once per session).
- `loadAppleVolumes` — Apple iTunes Search 1, +1 Japanese-store fallback when the first is empty (`+Store.swift:53-61`; 7 d file cache) → then Google Books 0-1 only when Apple left gaps (`:69-74`; keyless builds are nil) → then Open Library **N** sequential HEADs, 3 s apart, one per numbered cover-less volume with an ISBN (`:97-126`, `OpenLibraryCovers.swift:24,56-58`; 30 d cache incl. 404s).
- `loadReleases` — 0-3 (one per provider whose link matched; `ReleaseFeedService.swift:58-66` `TaskGroup`; each client has its own 3.5 s spacer).
- `loadSimilarByDescription` — 0 (on-device).
- `loadCategories` — MangaUpdates 1 (`+Categories.swift:40`; 7 d cache).

**Total for a cold open of a running series with an Apple shelf and a Webtoons link:**
9 MangaBaka + 2 cast + 2 MangaUpdates + 1-2 Apple + 0-1 Google + 1 feed + 1 taste
= **16-18 API requests**, plus N Open Library, plus the library walk on the
session's first page. Image requests on top: hero cover + backdrop + 2 fan
covers (`CoverStack`), every MangaBaka volume spine at once (F7), every cast
portrait at once (`CharacterRow.swift:78-84`, plain `HStack`), every card in
Related / Similar / Readers-also-like / Similar-by-description at once
(`DetailOnwardRows.swift:90,153,192`, plain `HStack`s). For a series with a
20-name cast, 3 × ~20 onward cards and a 30-volume `works` list that is
~110 CDN requests fired in the first second.

**Still in flight when the reader pops the page:** `.task(id: series.id)`
(`:292`) cancels the structured tree — all nine core requests
(`APIClient.swift:168-179` maps `URLError.cancelled` → `APIError.cancelled`),
the seven onward legs (`try? await session.data` → nil in every third-party
client; the Open Library loop checks `Task.isCancelled` between HEADs,
`+Store.swift:118,123`). What does **not** stop: every `CoverStore` image
fetch, by design (`CoverStore.swift:51-53` "Deliberately not cancelled") — so
the ~110 image requests above run to completion after a pop; and the
`LibraryControl` walk (a separate `.task` on a child view, also cancelled on
disappear but `LibrarySnapshot` may continue — not read). And one pager
neighbour's full `loadCore` if F5 is real.

**What blocks first paint:** nothing. `body` renders from the `series` the
push carried; `isLoading` only gates the `StaleBar` (`:202`) and the onward
rows' skeletons (`DetailOnwardRows.swift:41-47`). Synopsis, tags, credits'
gaps, stats' year, links, editions, volumes and related all arrive with
`extras` (the slowest of six v1 calls); cast/cadence/store/releases/categories
arrive after `loadCore` completes, because `loadOnward` is sequenced after it
(`:433-434`). `Signposts "Detail readable"` therefore measures "the slowest
of nine requests", not "the page stopped looking empty" — see U2.

---

## Failure kit — which section uses what (verified by reading)

`Fetched<T>` is not used anywhere in this slice (it lives in
`Core/Model/Fetched.swift` and is used by `ContinuationsRow`, `ReleaseCalendar`,
`CatalogueService`, `BlockedTagsSection`, `InlineFailure`). The page carries its
own `APIError?` per leg instead, which is equivalent.

| Section | Kit | Where | Verdict |
|---|---|---|---|
| Page (extras / either feed stale) | `StaleBar` | `SeriesDetailView.swift:202-207` | ✓ |
| Similar / Readers also like | `InlineFailure` + retry | `DetailOnwardRows.swift:144-146`, `:41-47` | ✓ |
| Related | none — part of `extras` → page bar | `:82` | ✓ acceptable |
| Similar by description | none (on-device) | `:60-65` | ✓ |
| Cast | `InlineFailure` + retry | `CharacterRow.swift:61-69` | ✓ |
| Estimated next (cadence) | `InlineFailure` + retry | `DetailScheduleBlock.swift:55-56` | ✓ |
| Releases | `InlineFailure` + retry, skeleton only when a link matched | `ReleaseSection.swift:40-51,64-71` | ✓ |
| Categories | `InlineFailure` + retry | `DetailCategories.swift:65-75` | ✓ |
| Library control | `InlineFailure` + retry; writes → `Toast` | `LibraryControl.swift:207-211,251-253` | ✓ |
| Character profile sheet | `FailureState` + retry; `EmptyState` | `CharacterProfileView.swift:99,113-117` | ✓ |
| Publisher page | `StaleBar`, `FailureState`, `EmptyState`, `InlineFailure` | `PublisherView.swift:112-131,334` | ✓ |
| **Volumes shelf (Apple)** | bare `Text(note)`, no retry, no reason | `VolumesSection.swift:72-76`, `+Store.swift:20,62` | ✗ F14 |
| **Covers / gallery** | `coversFailure` set, never read | `SeriesDetailView.swift:98,463-466` | ✗ F4 |
| Google Books | silent (documented gap-filler) | `+Store.swift:73` | acceptable |
| Open Library | silent; transport failure reads as "no cover" | `OpenLibraryCovers.swift:70-72`, `+Store.swift:125` | see F14b |
| Editions, links, news, read row, stats, credits, tags, trackers, synopsis, alt titles | hide on empty; failure is the page bar | (each `body` guard) | ✓ |

---

## Findings

### F1 — One `@State` for scroll offset re-runs the whole page body every frame
- **What.** `scrollOffset` is `@State` on `SeriesDetailView` and is written on every scroll frame; the only reader is `DetailBackdrop`'s 6 pt parallax.
- **Where.** `SeriesDetailView.swift:124` (decl), `:266-270` (`onScrollGeometryChange` → `scrollOffset = travelled`, unguarded), `:272-275` (the one consumer).
- **Why it matters.** Every frame of every scroll re-evaluates `body` (`:176-294`) and, because most children take closures (`onRetrySchedule`, `onOpenCovers`, `retry:`, `onOpenPublisher`, `path:` …) SwiftUI cannot prove them equal, so their bodies re-run too. Per frame that is: `Self.prose(from:)` — a Markdown parse of the whole description (`:217`, `:403-413`); `TagGrouping.groups(from:allowedRatings:favouredIDs:)` over up to 146 tags (`:494-498`); `otherCovers` — two sorts and three `compactMap`s over Apple + Google + MangaBaka covers (`:190`, `+Covers.swift:43-61`); `shelf` — `VolumeShelf.merge` dictionary build, evaluated twice (`+Store.swift:16,31`); `shown` — a full `Series.filling(gapsFrom:)` copy (`Series.swift:212-238`), evaluated at `:183,214,228,253,273,278,281,339` and `+Store.swift:18,32,34` (≈11 copies); `DetailStatsStrip.stats` three times (`DetailStatsStrip.swift:72,98,119`); `DetailCredits.rows` (`DetailCredits.swift:108,114,185`); `RowAmbient.tint` BlurHash averages for three rows; and a fresh `LibraryControlModel` allocation (F12). None of it is needed for the parallax. At 120 Hz the budget is 8.3 ms; a 3 KB Markdown parse alone is on the order of a millisecond.
- **Fix.** (a) Hold the offset in `@Observable final class ScrollTracker { var offset: CGFloat = 0 }` kept in `@State`; write `tracker.offset = travelled` in the action; pass the object to `DetailBackdrop` and read `tracker.offset` only there — Observation re-runs only the body that read it. (b) Cache the parsed synopsis: `@State private var prose: AttributedString?` set in `loadCore` after `extras` lands (or `.task(id: shown.description)`), and pass that. (c) Same for `TagGrouping.groups` — compute once when `extras`/`favouredTagIDs` change. (d) Fold `DetailBarTitle`'s second `onScrollGeometryChange` (`DetailBarTitle.swift:59-63`) into the same tracker so one observer feeds both.
- **Effort.** A function for (a), a line each for (b)–(d).
- **Confidence.** Likely. The re-evaluation is certain (it is how `@State` works); that it costs visible frames is the part to measure — Instruments → SwiftUI → "View Body" counts while scrolling one series page, before and after (a).
- **Lens.** 7 Speed, 3 Optimisation, 9 (`@State` that should be `@Observable`).

### F2 — `DetailBackdrop.height` is never applied; the blur is full-screen and re-composited per frame
- **What.** `height` (default 420, doc: "blurring a full-page image costs more the taller it is") is a stored property nobody reads; the `GeometryReader` frames the wash at the ScrollView's full size.
- **Where.** `DetailBackdrop.swift:22-25` (decl), `:96,126` (`proxy.size` used instead), `:127-131` (`scaleEffect(1.6)`, `blur(radius: 72)`, `saturation`, `opacity`), `:144` (`.offset` from scroll). Host: `SeriesDetailView.swift:272-275` (`.background` on the whole `ScrollView`). Gallery: `CoverGallery.swift:164-170` draws **two** of them, cross-faded by `progress`, which is itself written every frame (`:141-146`).
- **Why it matters.** A 72 pt Gaussian on a 1.6×-scaled full-screen layer is among the most expensive things Core Animation composites; moving it via `.offset` every frame keeps it live for the whole scroll. On the gallery, two such layers with per-frame opacity changes. This is the likeliest cause of any hitch on this screen that image decode is not.
- **Fix.** Apply the property: `.frame(width: proxy.size.width, height: min(height, proxy.size.height), alignment: .top)` on the `ZStack` (the gradient already fades to `Palette.ground` by 74 %, so a 420 pt wash is visually what the mockup intends). Then rasterise the blurred result once — `.compositingGroup()`/`.drawingGroup()` after `.blur` and before `.offset` — so the parallax moves a bitmap rather than re-filtering. In the gallery, blend two pre-blurred bitmaps. Delete the `height` parameter if the decision is that it should stay full-screen; either way the doc comment and the code must agree.
- **Effort.** Two lines. The measurement is the work.
- **Confidence.** Likely. Certain that `height` is dead; the per-frame GPU cost is a well-known property of `.blur` but not measured here — Instruments "Core Animation FPS" / Metal System Trace on a device, scrolling the page, with and without `.offset`.
- **Lens.** 7 Speed, charter #3 (declared, documented, unused).

### F3 — Two `MangaUpdatesClient`s, so one page fires two MangaUpdates requests at once
- **What.** The cadence leg and the categories leg use different `MangaUpdatesClient` actors, each with its own `RequestSpacing`; `loadOnward` starts both concurrently.
- **Where.** `AppServices.swift:38` (`mangaUpdatesCategories = MangaUpdatesClient()`), `:100` (`ReleaseScheduleService(library:database:)` — no `mangaUpdates:` passed), `ReleaseSchedule.swift:122` (default `MangaUpdatesClient()`); `SeriesDetailView.swift:471,483`; `MangaUpdatesClient.swift:10-19` ("their terms ask for reasonable spacing … three seconds"), `:144,:202` (per-instance `backOff` on 429).
- **Why it matters.** The spacing the client documents as the terms-compliance mechanism is violated by construction on every page open of a running series with a MangaUpdates id; a 429 that backs one instance off for 60 s leaves the other free to hit the same host immediately. The schedule tab's ten-page build shares the same problem with any open series page.
- **Fix.** `let mangaUpdates = MangaUpdatesClient()` once in `AppServices`; pass it as `ReleaseScheduleService(library:database:mangaUpdates:)` and as `mangaUpdatesCategories`. Test: a `TestClock` stub client counting `claim` calls sees two requests ≥3 s apart when cadence and categories are asked together; today it sees two at t=0.
- **Effort.** Two lines. **Confidence.** Certain. **Lens.** 6 Load balancing.

### F4 — `coversFailure` is computed and never read
- **What.** Set from `images(for:)` returning nil, with a comment saying the fan and gallery "can tell 'no covers' from 'couldn't ask'". Nothing reads it (`grep coversFailure MangaBaka MangaBakaTests` → the declaration and the assignment only).
- **Where.** `SeriesDetailView.swift:98`, `:452-466`.
- **Why it matters.** A throttled or offline reader sees a series with no fan and a gallery that opens on one cover, identical to a series with one cover — the exact gap (32) the comment says this closes. Charter #3.
- **Fix.** Either include it in `pageFailure` (`:147-154`: `extras.failure ?? coversFailure ?? feed origins`), so the `StaleBar` names it and its Retry refetches; or delete the property and the two comments. The first is one line and is what the comment promises.
- **Effort.** A line. **Confidence.** Certain. **Lens.** 2 Errors, charter #3.

### F5 — The pager lays out page 0 first, then jumps — animated
- **What.** `position` starts nil; the selected id is assigned in `onAppear`; `.animation(Motion.reduced(Motion.settle), value: position)` covers that change.
- **Where.** `SeriesPager.swift:21,68,77`; `:43-50` (`LazyHStack` of `content(series)`); `RootView+Session.swift:399-401` (each page is a full `detailPage`); `SeriesDetailView.swift:292` (`.task(id:)` starts `load()` on appear).
- **Why it matters.** (a) On the first layout the ScrollView is at offset 0, so `items[0]`'s `SeriesDetailView` appears and its `.task` starts `loadCore` — 9 MangaBaka requests at `userInitiated` for a series the reader did not open — before `onAppear` moves the position. Cancellation on disappear stops what has not left the socket; requests already sent still count against the shared window. (b) nil → id is a value change under `.animation(value:)`, so the jump to page N may animate through pages 1…N-1, each appearing and each firing its own `.task`. A row of 60 (PublisherView sets `zoomRoute?.neighbours = series`, `PublisherView.swift:304`) opened at its 40th card is the worst case.
- **Fix.** `init(items:selected:content:)` sets `_position = State(initialValue: selected.wrappedValue.id)`; `scrollPosition(id:)` then lays out at the right page from the first frame and `LazyHStack` never creates page 0. Keep the animation for later swipes. Test: on the simulator, count `Detail readable` signposts (or `RateLimitGate` claims) for one tap on card ≥2 of a Discover row — expect 1, predict 2 today.
- **Effort.** Two lines. **Confidence.** Likely for (a); worth checking for (b) — whether `scrollPosition` honours the `.animation` modifier for a programmatic first set is exactly what a device run settles. **Lens.** 6 Load balancing, 7 Speed.

### F6 — `SeriesPager.selected` is bound to `.constant`, so its only write is a no-op
- **What.** The pager's public contract is a `@Binding var selected`; the one call site passes `.constant(series)`. `selected = match` at `:73` writes into a constant.
- **Where.** `SeriesPager.swift:18,69-74`; `RootView+Session.swift:399` and the comment at `:408-416` acknowledging it.
- **Why it matters.** Charter #7 (a callback passed down and never honoured). Consequences today: `recentlyViewed.record` (`:408`) records only the push-named series; a related-series push from a swiped-to page appends to the path correctly (each page owns its `path` binding) so nothing breaks — but the binding invites a future caller to rely on it.
- **Fix.** Either make `detail()` own `@State var current: Series` and pass `$current`, recording it in `.task(id: current.id)`; or drop the binding and expose `onSettle: (Series) -> Void`. **Effort.** A line either way. **Confidence.** Certain. **Lens.** 9 / charter #7.

### F7 — `VolumesSection` is an eager `HStack`; its sibling shelf is lazy
- **What.** MangaBaka's own volumes shelf builds every spine up front, so every `CoverImage` starts its `CoverStore` fetch at once; `AppleVolumesRow` uses `LazyHStack` for the same row shape.
- **Where.** `VolumesSection.swift:84-96` vs `AppleVolumesRow.swift:66-82`; `CoverStore.swift:51-53` (never cancelled); also `CharacterRow.swift:77-84` and `DetailOnwardRows.swift:88-110,150-169,189-210` (plain `HStack`s of image cards).
- **Why it matters.** A series whose `works` list is long fires one CDN request per volume in the first frame, all of which outlive a pop. The onward rows do the same for three feeds of cards. This is the "in flight when the reader leaves" number: roughly the whole page's image count.
- **Fix.** `LazyHStack` in the four places; the `.scrollTargetLayout()` already present in three of them works unchanged. **Effort.** A line each. **Confidence.** Certain for the fan-out; the size of a long `works` list is unmeasured — one `curl 'https://api.mangabaka.dev/v1/series/{id}/works' | jq length` on a long-running series settles it. **Lens.** 6, 7.

### F8 — Cast portraits use `AsyncImage`, the loader `CoverStore` was written to replace
- **What.** `CharacterRow`, the profile header and the voice-actor rows use `AsyncImage`, whose documented failure modes (cancel on scroll-out, remember `.failure` per view identity — `CoverStore.swift:4-12`) are why `CoverStore` exists.
- **Where.** `CharacterRow.swift:130-134`; `CharacterProfileView.swift:279-283,513-519`; `DetailBackdrop.swift:114-124` (same, though a single non-scrolling image).
- **Why it matters.** A portrait that loses its race in the horizontal scroll stays a grey square until the sheet is dismissed — the exact bug already fixed once for covers. Charter #6, twice.
- **Fix.** A `PortraitImage(url:size:)` over `CoverStore.shared.image(for:)` (or `CoverImage` with a square `CoverFrame`), used in all three places. **Effort.** A function. **Confidence.** Likely (the mechanism is documented; not reproduced here). **Lens.** 4 Better way, 1 Bugs.

### F9 — `cadence(for:)` records a cancelled ask as a failure
- **What.** The single-series path catches every error and writes a failure row; the batch path three functions up guards `error != .cancelled` and skips the write.
- **Where.** `ReleaseSchedule.swift:394-415` (catch-all) vs `:350-352` (the guard); `SeriesDetailView+Releases.swift:89-94` then sets `cadenceFailure = .cancelled`.
- **Why it matters.** Popping a page during MangaUpdates' 3 s wait writes `failure` for that series, so the next open re-asks — one MangaUpdates request per abandoned page, on a host with a spacing requirement. And with the pager keeping neighbours alive, `cadenceFailure = .cancelled` can reach a live `DetailScheduleBlock` as an `InlineFailure` reading "cancelled".
- **Fix.** Copy the guard from `:350` into `:410` before the write; in `loadCadence`, treat `.failed(.cancelled)` as `.none`. **Effort.** Two lines. **Confidence.** Certain. **Lens.** 2, 6.

### F10 — Open Library gap-fill is unbounded, serial, and all-or-nothing
- **What.** One HEAD per cover-less numbered volume with an ISBN, 3 s apart, and `openLibraryCovers` is assigned only after the loop ends; `openLibraryStatus` stays `.loading` throughout.
- **Where.** `+Store.swift:100-125` (`for (number, isbn) in isbnsByNumber` … `openLibraryCovers = found` at `:124`); `OpenLibraryCovers.swift:24,56-58`; `VolumesSection.swift:304,309-319` (every stand-in draws a shimmering skeleton while `.loading`).
- **Why it matters.** A 40-volume series with no publisher art and ISBNs on each = 2 minutes of sequential HEADs during which every spine shimmers and no found cover is shown, even the first. Dictionary iteration order also means the covers are not asked in shelf order. On a pop the loop stops (`:118`) but nothing found so far was ever committed.
- **Fix.** Iterate `isbnsByNumber.keys.sorted()`; commit per hit (`openLibraryCovers[number] = url`); cap the pass at the first N (guess: 12, the width of two screens of spines) and let the rest stay `.notAsked`; set `.answered` per volume rather than per pass — `MissingVolumeCover.openLibrary` is already a per-view parameter (`VolumesSection.swift:254`). **Effort.** A function. **Confidence.** Certain by reading; the shelf sizes that trigger it are unmeasured (same curl as F7). **Lens.** 7 Speed, 6 Load balancing, 5 Other way.

### F11 — The cast is fetched from two third parties on every open of the same page
- **What.** `CharacterService.characters` has no per-series memory; only the AniList outage flag is remembered.
- **Where.** `CharacterService.swift:120-145`; `SeriesDetailView+Releases.swift:43-58`.
- **Why it matters.** Back-and-forth between a row and the same series (the pager makes this a swipe) costs AniList + Shikimori a request each time; both are shared, keyless, per-IP services and AniList publishes a per-minute limit (their docs; not measured here). Every other leg on the page is cached.
- **Fix.** `private var cache: [CacheKey: CharacterCast]` on the actor keyed by `(aniListID, shikimoriID)`, session-lived, storing only casts where at least one source `.answered`. **Effort.** A function. **Confidence.** Certain that there is no cache. **Lens.** 6, 3.

### F12 — `LibraryControl` allocates a model on every construction
- **What.** `State(initialValue: LibraryControlModel(...))` in `init` runs each time the parent builds the view struct — SwiftUI keeps the first and discards the rest.
- **Where.** `LibraryControl.swift:193-201`; constructed at `SeriesDetailView.swift:339` from `libraryAction`, which F1 makes per-frame.
- **Fix.** Falls out of F1; alternatively `@State private var model: LibraryControlModel?` created in `.task`. **Effort.** A line. **Confidence.** Certain (allocation); minor on its own. **Lens.** 3.

### F13 — The hero lays out four columns to show one, each with a sheet presenter
- **What.** Three hidden measurers each build the full column — `DetailScheduleBlock` and `AlternativeTitlesButton` (which carries `.sheet(isPresented:)`) included — to read a height.
- **Where.** `DetailHero.swift:164-185` (measurers), `:191-238` (`column`, incl. `:230-233`); `AlternativeTitles.swift:52-56`.
- **Why it matters.** 4× text layout per hero pass (and F1 makes that per frame), four sheet presenters per hero, three `@State` writes on first layout → three re-layouts. The technique is justified in the doc comment (`:97-102`, `ViewThatFits` rejected for a real reason); the waste is in measuring the interactive parts.
- **Fix.** Measure a text-only replica (kicker / title / byline / chapter line / schedule line as `Text`s, no buttons, no sheet), or measure once and stop re-measuring when `series.id` and width are unchanged. **Effort.** A function. **Confidence.** Likely. **Lens.** 3, 7.

### F14 — The volumes shelf's failure is a string, with no reason and no retry
- **What.** `appleUnreachable: Bool` collapses offline / 429 / 5xx / decode into "Apple Books couldn't be reached", rendered as `Text` — the only section on the page outside the kit.
- **Where.** `+Store.swift:20,62`; `VolumesSection.swift:25,72-76`; `AppleBooksClient.swift:34-36,108-112` (returns nil, throws nothing, so the reason is lost at the source).
- **Fix.** `AppleBooksClient.volumes` returns `Result<[AppleBooksVolume], APIError>` (the client already distinguishes 429 at `:112`); `+Store` keeps `appleFailure: APIError?`; `VolumesSection(failure:retry:)` renders `InlineFailure(error:retry:)` in the header slot. **Effort.** A function across two files. **Confidence.** Certain. **Lens.** 2.
- **F14b (low, may be covered by the known caption item).** `OpenLibraryCovers.coverURL` returns nil for a transport failure (`OpenLibraryCovers.swift:70-72`, uncached) and `loadOpenLibraryCovers` sets `.answered` regardless (`+Store.swift:125`), so an offline reader is told "No cover from the publisher" (`VolumesSection.swift:288-291`) — a claim the app could not check. Fix: `coverURL` returns `.notFound` / `.found(url)` / `.unreachable`; `.unreachable` leaves the status `.notAsked`. A line in each file.

### F15 — `EmbeddingIndex` sorts all 19 k scores to take 12
- **Where.** `EmbeddingIndex.swift:76-96` (`scored.sort` then `prefix(limit)`; comment: "Guess: comfortably under a frame … not measured"). Called per page open from `+Store.swift:147`, serialised on the actor.
- **Fix.** Partial selection (keep a 12-slot min-heap while scanning, or `partition` at the k-th). **Effort.** A function. **Confidence.** Certain that it is O(n log n); the cost is the guess the comment admits. **Lens.** 3.

### F16 — Pager membership guard trusts a coincidence
- **What.** `detail()` wraps the page in a pager when `zoomRoute.neighbours` contains the series' id. `neighbours` is never cleared; pushes from inside a page (`DetailOnwardRows`) set `source` but not `neighbours`.
- **Where.** `RootView+Session.swift:394-396`; `DetailOnwardRows.swift:93,156,195` (set `source` only); `ZoomRoute.swift:24`; writers in Discover, Library, Mix, Search, Publisher.
- **Why it matters.** Open A from a Discover row, tap a related series B that also happens to be in that row → B is wrapped in the Discover row's pager, and swiping from B steps through Discover's row, not B's related row. Rare, but the comment at `:389-393` claims the guard rules it out and it does not.
- **Fix.** Set `zoomRoute?.neighbours = []` (or the row's own items) beside each `source =` in `DetailOnwardRows`. **Effort.** Three lines. **Confidence.** Likely. **Lens.** 1.

### F17 — `StaleBar` retry re-pays every onward leg
- **Where.** `SeriesDetailView.swift:206` (`retry: { await load() }`), `:428-435`.
- **Why it matters.** A page-level stale bar (extras or a feed failed) retries cast, cadence, Apple, Google, Open Library, feeds and categories too — up to 9 third-party requests, several with 3 s spacers, for a MangaBaka-side failure.
- **Fix.** `retry: { await loadCore() }` and let the sections' own `InlineFailure`s cover the rest. **Effort.** A line. **Confidence.** Certain. **Lens.** 6.

### F18 — `cadenceEntry` is read whole to look up one row
- **Where.** `ReleaseSchedule.swift:400` → `:425-435` (`SELECT seriesId, payload, fetchedAt, failure FROM cadenceEntry`, then JSON-decode every payload).
- **Why it matters.** Per page open, on the schedule actor, proportional to the library size; with F3's shared client fixed this actor is also what the categories leg waits behind.
- **Fix.** `readCache(seriesId:)` with `WHERE seriesId = ?` for the single-series path; keep the bulk read for the ten-page build. **Effort.** A function. **Confidence.** Certain (no `WHERE`); cost worth measuring — time `readCache()` against a 937-row table. **Lens.** 7.

### F19 — Crash-risk sweep (result: clean)
- Force-unwraps, `try!`, `as!`, `.first!`, `fatalError`, `precondition`: none in the slice (grep + read). The two index reads are guarded: `DetailCredits.swift:154` (`names[0]` under `count == 1`), `:167` (`publishers[0]` under `count == 1`).
- Vendor number parsing: Apple `AppleBooksVolume.swift:237-243` — regex `\d+` capture → `Int(digits)`, nil on overflow (safe); Japanese bare numbering same path. Google `GoogleBooksVolume.swift:79-105` reuses Apple's matcher. MangaBaka `SeriesWork.Volume.number` is a `String` and is converted with `Int.init` via `flatMap` everywhere (`VolumesSection.swift:138,174`, `+Store.swift:107`) — "1.5", "01", "" all safe. `MangaUpdatesID.number(from:)` (`:31,37`) — `Int(_:)` / `Int(_:radix:)`, nil on overflow. Every `Double → Int` on API numbers goes through `Int(wholeOrClamped:)` (`DetailHero.swift:319`, `DetailStatsStrip.swift:58,61`, `+Store.swift:32,71`, `LibraryControl.swift:297,311,315`, `TrackerScores.swift:54-55`) — `Int+Clamped.swift:41-49` handles NaN and ±inf.
- Ranges: `AppleVolumesRow.swift:112-114` and `VolumeShelf.swift:103-105` — `(1...expected)` guarded `> 0`; with `expected` clamped to `Int.max` the `allSatisfy` stops at the first gap, so no runaway. `CoverGallery.swift:159-169` — `pages[safe:]` throughout.
- `MainActor.assumeIsolated`: `Motion.swift:27-34` only, guarded by `Thread.isMainThread`. Correct.

### F20 — Smaller items, one line each
- `SeriesDetailView.swift:21-26` — the doc comments say "AppServices should hold one instance … (wiring line in report)"; it does (`AppServices.swift:36-37`, `RootView+Session.swift:343-344`). Stale comment; the defaults still allocate a 7.3 MB-file actor if any caller omits them. Make the two parameters non-defaulted.
- `SeriesDetailView+Categories.swift:10-26` — a 17-line doc block describing wiring "not done by this file" that is done. Delete it.
- `SeriesDetailView.swift:345-366` — `seedAction` body is indented one level too deep (lint passes; reads as a leftover `if`).
- `CoverGallery.swift:113-117` — `ForEach(Array(pages.enumerated()), id: \.offset)` rebuilds `pages` (`:32-34`) on every `progress` frame; hoist to a `let` in `body`.
- `DetailHero.swift:252-255` — unstructured `Task` for the "Copied" hide; harmless, but `.task(id: copies)` would cancel on pop.
- `PublisherView.swift:37` and `CharacterProfileView.swift:23-25` — per-view default instances (`PublisherFollows()`, `AniListClient()`, `ShikimoriClient()`); the publisher one is documented and wired at `RootView+Session.swift:421`; the profile sheet still builds two clients per sheet presentation and bypasses `CharacterService`'s AniList outage memory (`CharacterService.swift:147-155`). Pass the service's clients in.

---

## What the slice does well (same evidence standard)

- Every leg of the page distinguishes "asked and failed" from "asked and empty", and the pure decision functions are tested without views: `DetailOnwardRows.onwardRowState` (`:41-48`), `CharacterRow.state` (`:28-35`), `DetailScheduleBlock.blockState` (`:38-43`), `ReleaseSection.sectionState` (`:40-51`), `DetailCategories.state` (`:123-129`), `VolumesSection.shows` (`:49-53`), `PublisherView.state` (`:95-101`), `SeriesDetailView.pageFailure` (`:147-154`) — `DetailSectionStateTests`, `DetailOnwardRowStateTests`, `DetailCategoriesTests`.
- Reduce Motion is honoured at the source, not per call site: `Motion.arrival` returns nil (`Motion.swift:66-68`), `Motion.reduced` gates every `.animation(value:)` and `.transition(.blurReplace)` in the slice, `DetailBackdrop.parallaxOffset` returns 0 (`:46-55`, pinned by `DetailMotionTests:60`), `CoverGallery.glide` keeps only the fade (`:95-100`), `CompletionCheckmark` draws the full mark rather than skipping it (`LibraryControl.swift:402-405`). The hero/bar crossfade is continuous and reduced (`DetailBarTitle.swift:36-55`), with the bar copy hidden from VoiceOver until the hero title has gone (`:91`).
- The stagger is capped (`Motion.stagger` cap 6, `Motion.swift:60`), so `.arrives(index:)` on a 100-item row cannot delay the tail by seconds.
- Rate-limit discipline in every third-party client: per-actor `RequestSpacing`, a claimed slot that is not spent after cancellation (`OpenLibraryCovers.swift:56-63`, cited from `AppleBooksClient` gap 28), `backOff` on 429, negative answers cached (`OpenLibraryCovers.swift:10-12`), Google asked only when Apple left gaps (`VolumeShelf.needsGoogle`, `+Store.swift:65-74`).
- Images: `CoverStore` dedupes, decodes off-main with `byPreparingForDisplay`, caps memory by bytes (`CoverStore.swift:30-34,91-104`); `Cover.url(forHeight:scale:)` picks the smallest sufficient rendition (`Cover.swift:115-130`), so the backdrop never fetches more than x350@3x.
- Measurements are recorded with dates and methods in the code: `VolumesSection.swift:184-190` (UTC date bug, S2), `AppleVolumesRow.swift:108-110` (S12), `DetailCredits.swift:56-62,82-93` (verified against `/v1/series/3397/full`), `ReleaseSection.swift:143-147` (duplicate timestamps in the live feed), `OpenLibraryCovers.swift:7-12` (live 302/404), `RowAmbient.swift:26-30` (measured RGB). This is why F2 and F4 were findable: the comments say what the code was meant to do.
- Guesses are labelled: `DetailBackdrop.swift:50`, `DetailBarTitle.swift:31`, `TrackerScores.swift:25-27`, `DetailCategories.swift:30`, `VolumesSection.swift:324`, `OpenLibraryCovers.swift:22,25`, `CharacterProfileView.swift:52`.
- `LibraryControl` patches the shared store in place after a write instead of re-walking (`LibraryControl.swift:109-127`), and `shouldCelebrate` excludes the first load so opening a Completed series never fires the reward (`:158-171`).
- No `http://`, no raw JSON or status code reaches a screen; every outbound link passes `safeURL` (`LinksSection.swift:85,123-125`, `ReadRow.swift:61`, `PublisherView.swift:234-241`).

---

## What I could not determine, and the one measurement that settles each

- **U1 (F1)** How many view bodies re-run per scroll frame on this page. Instruments → SwiftUI template, "View Body" lane, one 2-second flick on a loaded series page; compare before/after the `@Observable` tracker.
- **U2 (F2)** Whether the full-screen blur costs frames. Instruments → Core Animation FPS + Metal System Trace on a device (the simulator's GPU path is not representative), same flick, with `.offset` removed as the control.
- **U3 (F5)** Whether `LazyHStack` in the pager creates page 0 (and fires its `.task`) before `onAppear` moves the position, and whether the move animates. Count `Detail readable` signposts (or `RateLimitGate` claims, or Charles) for one tap on the fourth card of a Discover row. Expected 1; predicted 2 today, or more if the move animates.
- **U4 (F7/F10)** How long a real `works` list gets. One `curl` of `/v1/series/{id}/works` for a long-running series (ONE PIECE's id) piped to `jq length`; and how many of those have no `cover` and an ISBN.
- **U5 (F18)** The cost of decoding the whole `cadenceEntry` table. `Signposts.measure("cadence cache read")` around `readCache()` with a 937-row table.
- **U6** Whether `CoverGallery`'s `.navigationTransition(.zoom)` on a `fullScreenCover` does anything (the code says UNVERIFIED, `CoverGallery.swift:66-74`). Open and close the gallery on a device once.
- **U7 (F11)** AniList's actual per-IP limit and whether a swipe-heavy session reaches it. One session of 30 page opens with Charles counting 429s; AniList's published number is the control.
- **U8** `Signposts "Detail readable"` (`SeriesDetailView.swift:430-434`) ends when the slowest of nine requests returns, but the page paints from `series` at frame one and becomes "readable" (synopsis, tags) when `/v1/series/{id}` returns — one of the six. The number is the max of nine latencies, not time-to-synopsis. Charter #5, mild: worth splitting into "hero painted" (synchronous) and "extras landed" (`extras.full != nil`) before the next perf pass quotes it.
