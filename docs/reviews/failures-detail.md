# Failure audit — the series page (`Features/Detail`)

Read-only audit, 2026-09-13. Every claim below was made by reading the branch,
not by running the app. Line numbers are as of commit `1f118cd`.

## Scope

Read in full (all 26 files under `MangaBaka/Features/Detail/`, 4,700 lines):
`SeriesDetailView.swift`, `+Covers`, `+Releases`, `+Store`, `DetailHero`,
`DetailScheduleBlock`, `DetailStatsStrip`, `DetailSynopsis`, `CharacterRow`,
`CharacterProfileView`, `DetailCredits` (incl. `DetailTags`), `PublisherView`,
`VolumesSection` (incl. `VolumeSheet`), `AppleVolumesRow`, `ReleaseSection`,
`DetailEditions`, `DetailOnwardRows`, `TrackerScores`, `ReadRow`,
`LinksSection` (incl. `NewsSection`), `CoverGallery` (incl. `CoverStack`),
`LibraryControl`, `AlternativeTitles`, `DetailBackdrop`, `DetailBarTitle`.
`DetailTagSections`: first 60 lines plus a trap grep only.

Services, read for failure semantics: `CharacterService.swift` (full),
`AniListClient.swift:286-340` (profile path only), `AppleBooksClient.swift`
(full), `GoogleBooksClient.swift` (grep of every `return nil`/`try?`),
`ReleaseFeedService.swift` (full), `WebtoonsFeedClient.swift:33-85`,
`NaverFeedClient.swift` and `GigaViewerFeedClient.swift` (grep + the date
parser), `ReleaseSchedule.swift:357-378` (`cadence(for:)`),
`CatalogueService.swift:140-196`, `SeriesRepository.swift` (`feed`, `images`,
`extras`, `fetchExtras`) and `SeriesRepository+Cache.swift:23-40`.
Supporting reads: `LibraryModel.swift:30-60, 215-280`, `LibraryEntry.swift`
(field types, `asSeries`), `Series.swift:370-395` (`lenientDouble`),
`SeriesExtras.swift` (`SafeLink`, `readable`, `grouped`), the shared kit
(`FailureState`, `EmptyState`, `Skeleton`, `Toast`, `StateAction`, `APIError`).

Not read: `LibraryEditSheet` (Library slice), `ShikimoriClient` beyond its
thrown errors, `AppleBooksMatch`, `VolumeShelf`, `ReleaseSummary`,
`TranslationGate`, `TagGrouping`, `DetailTagSections.swift:60-209`,
`RateLimitGate` (the detail page never touches it directly), `Signposts`.

## How the page loads, so the table makes sense

`SeriesDetailView.load()` (`:265-297`) runs two phases:

1. `loadCore` (`:274-285`): four concurrent reads — `feed(.similar)`,
   `feed(.readersAlsoLike)`, `extras(for:)` (itself six concurrent v1 calls:
   links, news, relationships, `/series/{id}`, collections, works) and
   `images(for:)`. **Every one returns a value, never an error.** `feed`
   returns a `FeedResult` whose `.origin` can be `.staleAfter(APIError)`; the
   view reads only `.series` (`:280-281`). `extras` folds six `try?` into a
   struct with no failure field (`SeriesRepository.swift:699-729`).
   `images` is `try? … ?? []` (`:653-660`).
2. `loadOnward` (`:287-297`): five concurrent — cast, cadence, taste, store,
   releases. Each has a loading flag or none; none has a failure flag except
   the store (`appleUnreachable`, `+Store.swift:45`).

So ten sub-loads run; **one** of them (Apple Books) can tell the reader it
failed, and it can only say so when MangaBaka happened to have volumes to
put the note beside (`+Store.swift:16-20` → `VolumesSection.swift:25`).
Every other failure renders as the section not existing.

## Failure table

| # | Screen/section | Trigger | What the reader sees today | What they should see | Effort | Confidence |
|---|---|---|---|---|---|---|
| 1 | Whole page, opened from Library while offline, no detail cache (or cache older than 6 h — `+Cache.swift:29` refuses stale rows) | offline | Title and cover (the library copy has no description/authors/status/rating/chapters — `LibraryEntry.swift:169-193`), "Add to library" or the saved state, nothing else. No stats strip (`DetailStatsStrip.swift:72` hides on empty), no synopsis, no tags, no credits, no links, no volumes, "Similar"/"Readers also like" show skeletons then vanish (`DetailOnwardRows.swift:63`). **No branch says offline anywhere on the page.** | `StaleBar` under the hero: "You're offline — showing what was downloaded", with Retry re-running `load()`. Needs `extras(for:)` to return `(SeriesExtras, APIError?)` or a `SeriesExtras.failure` field, and `loadCore` to keep `similarResult.origin`. | function (`loadCore`, `fetchExtras`) + a `StaleBar` row in `body` | high |
| 2 | Whole page, rate-limited (page costs 9 MangaBaka requests; 4 pages/min exhausts a 30/min shared budget) | 429 on any of the nine | Same as #1: the sections whose request got 429 are simply absent. A series that *has* 146 tags shows none. `APIError.rateLimited`'s countdown is never shown here. | `StaleBar` with `error.headline`/`userFacingMessage` (rate limit wording already defends the reader). | same as #1 | high |
| 3 | `extras` partial failure is cached for 6 h | one of the six v1 calls fails, the other five succeed | `fresh != SeriesExtras()` is true, so the partial struct is written (`SeriesRepository.swift:679`). For six hours every open of this series shows no tags / no synopsis (if `/series/{id}` was the one that failed), or no links, or no volumes — and nothing can refresh it. | Only cache when all six answered; or cache per field; or record `failedFields` and skip the cache when non-empty. | function (`extras(for:)`) | high |
| 4 | "Similar" / "Readers also like" rows | feed fails, no cache | Skeleton placeholders while `isLoading`, then the row disappears (`DetailOnwardRows.swift:63`). Indistinguishable from "MangaBaka has no recommendations". | Keep the row with an inline note ("Couldn't load — Retry") when `origin` is `.staleAfter`; hide only on a real empty `.network`/`.cache` answer. | function (`loadCore` keep origin; `onwardRow` gains a `failure:` param) | high |
| 5 | Characters row | AniList AND Shikimori fail (offline, 429, 5xx) | `characters()` returns `[]` (`CharacterService.swift:94-95`), row hidden (`CharacterRow.swift:30`). Placeholders show during the ask (`:28`), so the row *appears* then vanishes. By design per the doc comment (`CharacterService.swift:12-16`), but that comment argues for hiding *which* source failed, not that both failed. | Inline note in the row's slot ("Cast couldn't load · Retry") when both sources threw; nothing when both answered empty. Needs `characters()` to return `Result` or `(cast, failed: Bool)`. | function | medium — the silent design is deliberate; Abdi's ask overrides it |
| 6 | Character profile sheet | AniList 401/403 | `FailureState` with headline **"This part needs an account"** and body **"Your library, recommendations and schedule are tied to a MangaBaka token…"** (`APIError.swift:80-88`, reached via `CharacterProfileView.swift:92-93`). Wrong service, wrong fix; "Open Settings" is not offered (no `openSettings`) so it falls back to Retry. | `FailureState` still, but the sheet must map third-party errors: 403 from AniList → `.server(status: 403, message: "AniList refused the request.")` with `needsAccount` suppressed. Cleanest: an `APIError.origin`/`service` field, or `FailureState(error:, service: "AniList")` overriding headline. | function (`load()` in the sheet) + kit tweak | high |
| 7 | Character profile sheet | AniList/Shikimori 5xx, or GraphQL error inside a 200 | Headline "MangaBaka had a problem" over body "AniList returned 500." (`APIError.swift:118`, `AniListClient.swift:315`). Contradictory attribution. | Same fix as #6. | same as #6 | high |
| 8 | Character profile sheet | 429 from AniList/Shikimori | "Too many requests, briefly / MangaBaka is throttling this connection…" — names the wrong service. | Same fix as #6. | same as #6 | high |
| 9 | Character profile sheet, "Try again" | any failure, then retry | `load()` (`CharacterProfileView.swift:119`) never sets `state = .loading`, so the failure screen stays on screen with no indicator until the retry completes; a second tap re-fires. | Set `.loading` at the top of `load()`; `FailureState` retry then shows the spinner. | line | high |
| 10 | Character profile sheet, Shikimori description | translation pack not installed / declined / times out | Portrait, names, facts, **no "About" section and no note** (`:158`, `:193`). Reader cannot tell "no description" from "untranslatable". | Inline note under the facts: "Description is in Russian and hasn't been translated — install the pack in Settings" (the `TranslationSection` route already exists). | function (`beginShowing` sets a `descriptionUnavailableReason`) | medium |
| 11 | Character profile sheet | `CharacterProfileRequest` yields no id | `unavailableState` (`:101-117`) — custom layout, not the kit; wording "Nothing knows this character by this id." is developer-speak. | `EmptyState(title: "No profile", message: "Neither AniList nor Shikimori has a page for this character.")`. Unreachable today (`:56-60`); low priority. | function | high |
| 12 | Hero "Estimated next" block | MangaUpdates down / 429 / offline | `cadence(for:)` returns `.none` on error (`ReleaseSchedule.swift:372-377`), identical to "too few releases". `loadCadence` sets nothing (`SeriesDetailView.swift:369-371`); block hidden (`DetailHero.swift:189`). "Estimating" spinner shows during the ask, then the line vanishes. | `SeriesCadence` already has an `.unavailable(reason)` shape per `ScheduleWork` (`ReleaseSchedule.swift:18-23`); return a `.failed(APIError)` case and show one muted line "Couldn't reach MangaUpdates" in the block's slot. | function | medium |
| 13 | Hero cadence — cancelled Task | reader leaves before the 3-second-spaced MangaUpdates request | `catch` writes a `failure` cache row (`ReleaseSchedule.swift:375`), next open retries. Correct. No reader-visible problem. | — | — | high (done well) |
| 14 | Volumes shelf, Apple Books unreachable **and** MangaBaka has no `works` | store nil, `extras.volumes` empty | Nothing. `VolumesSection` renders only when `!volumes.isEmpty` (`VolumesSection.swift:25`), so the "Apple Books couldn't be reached" note (`+Store.swift:19`) is dropped with it. | Render the header + note alone when `note != nil`, or a one-line inline note in the slot. | function (`VolumesSection.body`) | high |
| 15 | Volumes shelf, still loading | store request in flight (up to 3.5 s spacing + network, `AppleBooksClient.swift:12`) | MangaBaka's editions row shows as if final, then is replaced by Apple's row when it lands (`+Store.swift:16-27`). No loading state; the section swaps content under the reader. | `isStoreLoading` flag; show MangaBaka's row with a small "Checking Apple Books…" trailing note, or a `CoverSkeletonRow` when MangaBaka has none. | function | high |
| 16 | Volumes shelf, Google Books | Google 429/5xx/offline | `?? []` (`+Store.swift:55`); Apple's gaps stay gaps with no note. `AppleVolumesRow.countLine` then says "15 of 27" with no explanation of why. | Acceptable to stay silent (Google is a gap-filler), but the count line should say "on Apple Books" per its own doc comment (`AppleVolumesRow.swift:76`) — today it prints "15 of 27" only. | line | medium |
| 17 | `AppleVolumesRow` spine with no `link` | `ShelfVolume.link == nil` | `.disabled(volume.link == nil)` (`AppleVolumesRow.swift:63`); `PressStyle` has no `isEnabled` treatment, so the spine looks live and does nothing on tap. | Either dim the spine or drop the accessibility "Opens it in Apple Books" hint when there is no link. | line | medium — depends on how often `link` is nil |
| 18 | Release section | Webtoons/Naver/GigaViewer unreachable, or 429 | Every provider returns nil on failure (`WebtoonsFeedClient.swift:63-66`, `NaverFeedClient.swift:45-54`, `GigaViewerFeedClient.swift:106-114`); `ReleaseSection` renders nothing (`ReleaseSection.swift:18`). Documented as deliberate (`:9-15`). A series the links say is on Webtoons therefore shows no release section on a bad connection, same as one that is not on Webtoons. | Keep silent when no link matched a provider; show a one-line "Couldn't reach Webtoons" when a link *did* match and the fetch failed. Needs `ReleaseFeedProvider.feed` to return `.notCarried` / `.failed` / `.feed`. | file (protocol change across 3 clients) | medium |
| 19 | Release section, loading | providers in flight (each spaced) | Nothing (`ReleaseSection.swift:13-15`, deliberate). Section pops in below the credits after the page has settled — exactly the "second page load" the volumes comment warns about (`SeriesRepository.swift:713-716`). | A single-line skeleton in the slot while `isReleasesLoading` and at least one provider matched a link. | function | medium |
| 20 | `LibraryControl`, library walk failed | offline / 429 / 5xx on `/v1/my/series` | `store.load()` sets `store.failure`; `LibraryControlModel.load()` ignores it and sets `entry = .some(nil)` (`LibraryControl.swift:46`), so **"Add to library" is offered for a series that may already be saved**. Tapping it → 409/offline → muted text under the button. The exact bug the doc comment at `:32-40` says was fixed for the paging case. | Read `store.failure`/`store.isComplete`: keep `entry == nil` (control hidden) and show a muted "Couldn't check your library · Retry" line, or `StaleBar`. | function (`load()` + one branch in `body`) | high |
| 21 | `LibraryControl`, no token | `hasAccount == false` after the walk | Same as #20: "Add to library" shown live. Tap → 401 → `failure` = the account paragraph in muted 12-pt under the button, no "Open Settings". | Hide the control, or a `StateAction(.fixes)` "Connect account" that opens Settings. `store.hasAccount` is already computed (`LibraryModel.swift:264`). | function | high |
| 22 | `LibraryControl`, write succeeds then reload fails | +1 / add / state change lands; `store.reload()` hits 429 | `refresh()` (`:75-78`) re-pages the whole library (10 requests for 937 entries) after every tap; on failure `entries` was cleared (`LibraryModel.swift:229`) so `entry` becomes `.some(nil)` and the control **flips from "Reading · ch 68" to "Add to library"** although the write succeeded. Not optimistic, so there is nothing to revert — but the displayed state is now wrong in the other direction. | Apply the change locally (`LibraryEntry` with the new field) and reload in the background; on reload failure keep the local entry and show `StaleBar`/muted note. Also: a +1 should not cost ten requests. | function | high |
| 23 | `LibraryControl`, while writing | `isWorking` | Buttons disabled (`:171`, `:236`); `PressStyle` shows no disabled look, no spinner. A slow write reads as a dead button. | `ProgressView` replacing the "+1" glyph while `isWorking`, or `.opacity` via `StateAction`-style `isEnabled` read. | line | high |
| 24 | `LibraryControl`, write fails | 4xx/5xx/offline | `failure` text under the button in `textMuted` (`:130-135`), stays until the next success. Haptic `.error` fires. No retry, no toast. Adequate but faint. | `Toast` for the failure line (it already exists for success elsewhere), and clear `failure` when a new action starts. | line | medium |
| 25 | `LibraryControl`, remove | — | `remove()` exists (`:91`) but nothing in this control calls it; no confirmation issue here. (`LibraryEditSheet`'s remove is the Library slice's.) | — | — | high |
| 26 | Publisher page | search fails, no cache | `failed` is set only when `origin` is `.staleAfter` **and** the list is empty (`PublisherView.swift:258`); plain `Text("Couldn't reach MangaBaka. Pull to try again.")` (`:75`). Not the kit, no cause (offline vs 429 vs 5xx), no button. | `FailureState(error:)` with retry — the error is in `result.origin`. | function | high |
| 27 | Publisher page, stale list | search fails, cache has yesterday's list | List shown with no age note; `failed` stays false. | `StaleBar` above the grid using `result.cachedAt`. | function | high |
| 28 | Publisher page, directory record | `/v1/publishers/search` or `/full` fails | `try?` → nil (`CatalogueService.swift:183-195`); header shows the name alone. Documented as "not a failure" (`PublisherView.swift:241-243`) because studios are genuinely absent from the directory. Acceptable. | — | — | high |
| 29 | Publisher page, `count` fails | `repository.count` nil | Header falls back to `series.count` (`:190`) — for Shueisha that is "100" again, the exact bug the comment at `:50-52` records fixing. | Show nothing rather than the page size when `total == nil && hasMore`. | line | high |
| 30 | Publisher page, re-entrant load | pull-to-refresh while `.task(id: order)` load is in flight, or switching order mid-load | Two `load()`s interleave: both set `page = 1`, both assign `series`; the slower one wins. No guard. | Cancel-and-restart via `.task(id:)` only (drop `.refreshable`'s direct call in favour of bumping a `reloadToken`). | line | medium |
| 31 | Publisher page, `loadMore` page fails | 429 on page 2 | `result.series` empty, `hasMore` = `result.hasMore` — on a stale/empty result that is false, so paging stops for good with no note. | Keep `hasMore` when `origin` is `.staleAfter`; show a one-line "Couldn't load more · Retry" under the grid. | function | medium |
| 32 | Cover gallery | zero other images | `pages == [front]`, caption "Cover" (`CoverGallery.swift:166`). Fine. | — | — | high (done well) |
| 33 | Cover gallery, image fails to load | 4xx/offline on the CDN | `photo` glyph, no text (`:237-240`). Acceptable for a full-screen artwork viewer. | — | — | high |
| 34 | Cover gallery, `otherCovers` changes while open | Apple volumes arrive after the gallery opened (the store load is concurrent, `+Covers.swift:20-28`) | `pages` grows under the pager; `scrolledIndex` stays put, `pages[safe:]` guards the backdrop and caption. Content shifts but no crash. | Snapshot `images` in `GalleryStart` so the open gallery is stable. | line | medium |
| 35 | Hero, series with no title | `displayTitle == nil` | "Untitled series" (`DetailHero.swift:253`), copy button disabled. Fine. | — | — | high |
| 36 | Stats strip, credits, synopsis, tags, links, editions, tracker scores, news, read row, release, volumes, alt titles — series with none of them | any empty payload | Every section hides itself on empty: `DetailStatsStrip.swift:72`, `SeriesDetailView.swift:104`, `DetailTags` `:273`, `DetailTagSections.swift:47`, `LinksSection.swift:29`, `DetailEditions.swift:24`, `TrackerScores.swift:78`, `NewsSection` `:119`, `ReadRow.swift:30`, `ReleaseSection.swift:18`, `VolumesSection.swift:25`, `AlternativeTitlesButton` `:32`. **No empty header renders.** | — | — | high (done well) |
| 37 | `DetailCredits` with zero rows | series with no authors, artists, publishers, content rating or anime field (a library-copy series offline, #1) | Not guarded: `body` (`DetailCredits.swift:102-182`) always emits the `VStack` + `clipShape` + `hairlineBorder` + gutter padding. With no children it is 0 pt tall, so probably invisible, but it still occupies one `detailRowGap` in the parent stack. | `if !rows.isEmpty` around the body, like every sibling. | line | medium — the 0-pt border may draw a faint line; not verified visually |
| 38 | `DetailTagSections` with groups but none of the four leading names | tags exist only in non-leading groups | `visibleGroups` empty; only the "more groups" button renders (`DetailTagSections.swift:47-57`). A tag section that is one button. | Fall back to the first group when no leading group exists. | line | medium (only read to line 60) |
| 39 | News row with an unsafe URL | `item.safeURL == nil` (non-http scheme) | Row renders as a live button that does nothing (`LinksSection.swift:127-128`). | Filter `items` by `safeURL != nil` like `ReadRow`/`LinksSection` do. | line | high |
| 40 | Read row / links section / publisher links with unsafe URLs | scheme not http(s), or host not on `ReadingPlatforms` | Filtered out before rendering (`SeriesExtras.swift:90-100`, `:179-191`; `PublisherView.swift:147`). Done well. | — | — | high |
| 41 | Synopsis Markdown fails to parse | malformed Markdown from the API | `try? … ?? AttributedString(cleaned)` (`SeriesDetailView.swift:248-249`) — raw text, never a crash. Done well. | — | — | high |
| 42 | Content-filtered images/tags | reader's rating excludes them | `images(for:)` filters (`SeriesRepository.swift:659`); `TagGrouping.groups(allowedRatings:)` (`SeriesDetailView.swift:307-309`). `DetailTags` fallback (`:317`) passes the flat v1 names **unfiltered** — the doc at `:30-33` says a tag is rated independently of its series. | Filter `extras.tags` too, or drop the flat fallback when a rating filter is active. | line | medium — depends on whether flat `tags` carry ratings at all; not verified |
| 43 | Hero cadence "Estimating" spinner | series with `mangaUpdatesID` but `schedule == nil` (no service injected) | `loadCadence` returns before setting `isCadenceLoading` (`:363-366`); block hidden. Fine. | — | — | high |
| 44 | "Use as seed" | `mixModel == nil` at tap | `mixModel?.addSeed` is a no-op but the tab still switches and the toast says "Added to the mix" (`RootView.swift:306-309`). Out of slice but reached from this page. | Guard the toast on the seed actually being added. | line | medium |
| 45 | Cache directory unwritable (disk full) for Apple/Google/feed caches | `write(to:)` throws | `try?` everywhere (`AppleBooksClient.swift:136-138` and the three feed clients); the answer is still returned, just not cached. Done well. | — | — | high |
| 46 | Detail page `Task` outlives the view | pop mid-load | `.task(id:)` cancels; `async let` children cancel; `try?` turns the cancellation into nil → `appleUnreachable = true` is written to a dead view (`+Store.swift:45`). Harmless. Re-entering the same series starts fresh. | — | — | high |

## Traps

Grepped `!` (non-`!=`, non-prefix), `try!`, `as!`, `fatalError`,
`precondition`, `Int(`, `[0]`, `.first!`/`.last!`, `URL(string:`, `...`/`..<`,
`/ `, `String(format:`, `Task.sleep` across every file in scope
(`scratchpad/traps.sh`). Each hit read in context.

- **Force unwraps: none found.** `try!`/`as!`: none found. `.first!`/`.last!`: none found.
- `Int(Double)` on API-controlled numbers — traps if the value is finite but
  outside `Int` range (≈ ±9.2e18). `lenientDouble` (`Series.swift:384-395`)
  guarantees finite, not magnitude; `LibraryEntry`/`TrackerEntry` decode a
  plain `Double` (JSONDecoder rejects NaN/inf tokens, not `1e300`). Reachable
  only from a hostile or broken API; recorded because the rule is "no trap
  reachable from real input":
  - `DetailHero.swift:313` `Int(chapters)` — `totalChapters`
  - `DetailStatsStrip.swift:58` `Int(chapters)`; `:61` `Int(volumes)`
  - `SeriesDetailView+Store.swift:24, :53` `Int($0)` on `finalVolume`
  - `LibraryControl.swift:180` `Int(entry.progressChapter ?? 0)`; `:191` `Int((rating / 20).rounded())`; `:195` `Int(chapter)`
  - `TrackerScores.swift:54-55` `Int(highest.score.rounded())` — `ratingNormalized`
  - Fix once: `Int(exactly: value.rounded())` or a `Double.clampedInt` helper; `Series.swift:136` already does this for `ratingCount`.
- `preconditionFailure` on hard-coded URLs — `AppleBooksClient.swift:144`,
  `GoogleBooksClient.swift:131`. Not reachable from input.
- `URL(string:)` — `GigaViewerFeedClient.swift:101, :247`,
  `NaverFeedClient.swift:77`: all optional-handled. `host` at `:101` comes
  from an allowlisted match, so a malformed host cannot reach it.
- Ranges — `AppleVolumesRow.swift:90` `(1...expected)` guarded by
  `expected > 0` at `:88`. `CatalogueService.swift:165-166` guarded by
  `openParen < closeParen`.
- Division — `CoverGallery.swift:127` guarded `width > 0`; `:219` guarded
  `ratio > 0`; the rest divide by named constants.
- Array index — `DetailCredits.swift:144` `names[0]` under `count == 1`;
  `:157` `publishers[0]` under `count == 1`; `NaverFeedClient.swift:132-134`
  `parts[0]` under `count == 3`. `CoverGallery` uses `[safe:]` throughout.
- `String(format:)` — all `%.1f` with a `Double`; correct.
- `Task.sleep` — every call is guarded `wait > 0` or a positive constant.
- `ForEach` duplicate ids: `PublisherView.loadMore` de-duplicates (`:277-278`);
  `DetailCredits` publishers keyed by offset (`:194`); `ReleaseSection` keyed
  by offset (`:66`). `DetailOnwardRows` `ForEach(items)` keyed by `Series.id`
  — a feed that repeats an id would trap; the repository does not de-duplicate
  feeds. Not verified whether the API ever repeats within one feed page.

## Done well — do not touch

- `AppleBooksClient.volumes` returns nil for "couldn't ask", `[]` for "asked, none" (`AppleBooksClient.swift:34-36, 49`), and the page carries the distinction (`+Store.swift:45`). The only sub-load with a failure branch.
- `FeedResult.origin`/`cachedAt` already carry everything a `StaleBar` needs (`SeriesRepository.swift:285-300`); the detail view just does not read them.
- `extras`/`images` refuse to cache an empty answer (`SeriesRepository.swift:656-660, 676-679`) — a dropped connection does not stick.
- `CharacterService` only remembers an outage on 403/5xx, not on cancel/offline/429 (`CharacterService.swift:74-83, 141-143`).
- `ReleaseSchedule.cadence(for:)` records a failure row rather than a null cadence, so the next open retries (`:372-377`).
- `CharacterProfileView` uses `FailureState` with retry (`:92-93`); translation never blocks the profile (`:143-148`); no system prompt from inside the sheet (`:149-158`).
- `LibraryControl` renders nothing until the library has answered (`:105-107, 125-129`) — no "Add" flash for a saved series in the happy path.
- Every section hides on empty (row #36); no "None listed" is printed without an explicit field (`DetailCredits.swift:94-98`).
- All outbound links pass `SafeLink.web` and the reading allowlist (`SeriesExtras.swift:90-100, 103-112, 179-191`; `SeriesWork.swift:84-87`).
- `DetailScheduleBlock` shows "Estimating" with a spinner rather than a blank (`:33-49`); `CharacterRow` reserves the space with placeholders (`:109-129`); `DetailOnwardRows` skeletons while loading (`:70-81`).
- Cover gallery: bounds-checked paging (`CoverGallery.swift:147-151, 165, 338-345`), Reduce Motion honoured (`:79-84`).
- Synopsis: Markdown failure falls back to plain text (`SeriesDetailView.swift:248-249`).
- No `http://` in the slice; Google's thumbnails are upgraded to https (`GoogleBooksVolume.swift:108-130`, read by grep only).
- No raw JSON, stack trace or developer string reaches a screen, with one exception: `CharacterProfileView.swift:109` "Nothing knows this character by this id." (row #11).

## Proposed fixes, by file, with the test that proves each

### `MangaBaka/Core/Persistence/SeriesRepository.swift`
- `fetchExtras` records which of the six calls threw: `SeriesExtras.failed: Set<Field>` (or `failure: APIError?` keeping the first). `extras(for:)` writes the cache only when `failed.isEmpty`.
  - Test: stub client where `/series/{id}` throws `.rateLimited` and the other five succeed → `extras.failed == [.full]`, `readDetailCache` returns nil afterwards. Proves #3. Today's code: the same stub caches a struct with empty `tags`; assert that first to show the test fails without the fix.
- `loadCore`'s feed results: nothing to change here; the view must read `origin`.

### `MangaBaka/Features/Detail/SeriesDetailView.swift`
- Keep `similarOrigin`/`alsoOrigin` and `extras.failure`; derive `pageFailure: APIError?` = first non-nil among them. Render `StaleBar(headline: error.headline, detail: error.userFacingMessage, retry: load)` between the hero and `actions` when `pageFailure != nil`, using the kit's own rule (content wins, reason becomes a bar).
  - Test (pure): `SeriesDetailView.pageFailure(extras:, similar:, also:)` → `.offline` when any is `.staleAfter(.offline)`, nil when all are `.cache`/`.network`. Proves #1, #2.
- `DetailOnwardRows`: pass `failure: APIError?` per row; row shows header + one muted line + `StateAction(.aside, "Retry")` instead of hiding when `items.isEmpty && failure != nil`.
  - Test: `onwardRowState(items: [], isLoading: false, failure: .offline) == .failed`; `.hidden` when `failure == nil`. Proves #4.

### `MangaBaka/Features/Detail/SeriesDetailView+Store.swift`, `VolumesSection.swift`
- `isStoreLoading` set around `loadAppleVolumes`; `VolumesSection(note:)` renders the header + note even when `volumes.isEmpty` if `note != nil`; while loading pass "Checking Apple Books…".
  - Test: `VolumesSection.shows(volumes: [], note: "Apple Books couldn't be reached") == true`; `shows(volumes: [], note: nil) == false`. Proves #14, #15.

### `MangaBaka/Features/Detail/LibraryControl.swift`
- `load()`: after `store.load()`, if `store.failure != nil || !store.hasAccount || !store.isComplete` leave `entry = nil` and set `checkFailure = store.failure` / `needsAccount = !store.hasAccount`. `body`: `needsAccount` → `StateAction(.fixes, "Connect account")`; `checkFailure` → muted line + Retry.
  - Test: `LibraryModel` stub with `failure = .offline`, `entries = []` → `model.isKnown == false`, `model.checkFailure == .offline`. Today: `isKnown == true`, `current == nil` (the "Add to library" bug) — paste that as the failing run. Proves #20, #21.
- `apply`/`add`/`advanceChapter`: on success construct the updated `LibraryEntry` locally and set `entry` before `refresh()`; on `refresh()` failure keep it and set `failure = "Saved. Couldn't refresh your library."`.
  - Test: `library.update` succeeds, `store.reload` fails → `model.current?.progressChapter == 69`. Today it is nil. Proves #22.
- `isWorking` → `ProgressView` in the "+1" button. Visual; no pure test, note as unverified.

### `MangaBaka/Features/Detail/CharacterProfileView.swift` (+ `APIError` or `FailureState`)
- `load()` sets `state = .loading` first (#9).
- Map third-party errors before `.failed`: `error.attributed(to: "AniList")` returning `.server(status:, message: "AniList …")` with `needsAccount` false for 401/403, and rate-limit wording "AniList is throttling…". Simplest: a `FailureState(error:, service: String?)` init that overrides `headline` when `service != nil`.
  - Test: `FailureState.headline(for: .server(status: 403, message: ""), service: "AniList") == "AniList refused the request"` and the body never contains "MangaBaka token". Today it does. Proves #6–#8.
- `beginShowing`: when `TranslationGate.allows` is false set `descriptionNote = "Description is in Russian; install the translation pack to read it."`; render under the facts.
  - Test: `availability = .unsupported` → `descriptionNote != nil`. Proves #10.

### `MangaBaka/Core/Characters/CharacterService.swift`, `CharacterRow.swift`
- `characters()` returns `CastAnswer { cast: [SeriesCharacter]; failed: Bool }` — `failed` true only when every source that was asked threw (not when they answered empty). `CharacterRow(failed:)` shows header + "Cast couldn't load · Retry" in the placeholder slot.
  - Test: AniList throws `.offline`, Shikimori throws `.offline` → `failed == true`; AniList returns `[]`, Shikimori `[]` → `failed == false`. `lastOutcome` already exists for the assertion. Proves #5.

### `MangaBaka/Core/Schedule/ReleaseSchedule.swift`, `DetailScheduleBlock.swift`
- `cadence(for:)` returns `.failed(APIError)` from the catch; `loadCadence` stores it; `DetailScheduleBlock(failure:)` shows "Couldn't reach MangaUpdates" one-line, muted, no button (the schedule tab has retry).
  - Test: `mangaUpdates.releases` throws `.rateLimited` → `cadence(for:) == .failed(.rateLimited(retryAfter: nil))`, and `readCache()[id]?.failure != nil`. Proves #12.

### `MangaBaka/Core/Schedule/ReleaseFeedService.swift` + three clients, `ReleaseSection.swift`
- `ReleaseFeedProvider.feed` → `enum FeedAnswer { case notCarried, failed, feed(ReleaseFeed) }`. `ReleaseReport` gains `failedSources: [ReleaseSource]`. Section shows "Couldn't reach Webtoons" only when `summary.isEmpty && !failedSources.isEmpty`.
  - Test: stub provider returns `.failed` → `report.failedSources == [.webtoons]`, `summary == .none`; `.notCarried` → `failedSources == []`. Proves #18. Larger change; do last.

### `MangaBaka/Features/Detail/PublisherView.swift`
- Replace the `Text` at `:75` with `FailureState(error:) { await load() }` when `series.isEmpty && failure != nil`; `StaleBar` above the grid when `origin` is `.staleAfter` and `series` is non-empty; `total == nil && hasMore` → hide the count.
  - Test (pure): `PublisherView.state(series:, origin:, isLoading:)` → `.failed(.offline)` / `.stale(.offline, cachedAt)` / `.empty` / `.list`. Proves #26, #27, #29.

### One-liners
- `LinksSection.swift:126` `ForEach(items.filter { $0.safeURL != nil }.prefix(4))` — test: an item with `url: "javascript:…"` is not in `NewsSection.visible(items)`. Proves #39.
- `DetailCredits.swift:102` wrap in `if !rows.isEmpty`. Proves #37.
- `Int(Double)` sites → `Int(exactly:)`/clamp helper; test: `Series(totalChapters: 1e300)` → `DetailStatsStrip.stats` has no "Chapters" entry rather than trapping.
- `SeriesDetailView.swift:317` filter flat `tags` by rating or drop when filter active (#42) — needs a look at whether v1 flat tags carry a rating; not verified.
