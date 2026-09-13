# Failure audit — Discovery slice

Read-only audit, 2026-09-13. Slice: the screens that fetch to fill themselves — Discover, Search, Mix, Stack, Browse — plus the repository methods they call. Every claim below was checked by reading the branch; nothing was run.

## Scope

Read in full (35 files):
- `MangaBaka/Features/Discovery/{DiscoverView,DiscoverModel,CommunityPulseCard,RecentlyViewedRow,WhatsNew}.swift`
- `MangaBaka/Features/Search/{SearchView,SearchModel,SearchEmptyState,SearchIdleView,LensCounts,FilterSheet,TagPickerSheet,SearchLens,SaveLensSheet}.swift`
- `MangaBaka/Features/Mix/{MixView,MixModel,MixResults,MixFilterStrip,SeedPickerSheet,BlendDNAView}.swift`
- `MangaBaka/Features/Stack/{StackView,StackModel,StackHeader,StackHint,StackSections,StackResetMenu}.swift`
- `MangaBaka/Features/Browse/{BrowseView,BrowseModel,PublisherBrowser}.swift`
- `MangaBaka/Core/Persistence/SeriesRepository.swift`, `SeriesRepository+Paging.swift`, `SeriesRepository+Count.swift`
- `MangaBaka/Core/Networking/{RateLimitGate,APIError}.swift`, `MangaBaka/Core/Model/{TagTaxonomy,TagSearch}.swift`
- Kit: `MangaBaka/Features/Shared/{FailureState,EmptyState,Skeleton,Toast}.swift`
- Read for one question only (not in slice): `MangaBaka/Features/Detail/PublisherView.swift` (the "page 2" question), `MangaBaka/Core/Model/CatalogueService.swift` lines 1–130, `MangaBaka/Core/Model/CommunityPulseService.swift`, `MangaBaka/Core/Library/LibraryService.swift` lines 155–230, `MangaBaka/Core/Networking/APIClient.swift` lines 120–171 (gate and Retry-After).

Not read: `SeriesRepository+Cache.swift`, `ShelfStore`, `HistoryStore`, `SearchQuery.swift`, `APIClient` beyond the lines above, any test file beyond `SeriesFactory.swift` (to name the stub). `docs/designs/app-feature-spec.md` read only for section 10 ("Empty, offline and rate-limited states"), which names the requirement and draws nothing per screen.

One fact that shapes many rows: `APIClient` has **one `RateLimitGate` for the process** (`APIClient.swift:22`), and it refuses locally with `.rateLimited(retryAfter:)` before any request goes out (`APIClient.swift:126–127`). So a 429 on search (30/min) blocks every Discover, Mix and Stack request too until the window passes, and each of those screens explains it — or fails to — in its own words.

## Table

Confidence: **certain** = the branch is quoted; **likely** = follows from the code but needs a run to see the exact rendering; **w.c.** = worth checking, I could not settle it by reading.

| # | Screen/section | Trigger | What the reader sees today | What they should see | Effort | Confidence |
|---|---|---|---|---|---|---|
| D1 | Discover, one row | One feed fails with no cache, the others succeed | `"Nothing here right now."` (`DiscoverView.swift:194`) — identical to a genuinely empty feed. And because `failure` is set (`DiscoverModel.swift:97,106`) while other rows have content, `isShowingStale` is true (`:122`) and the screen shows `StaleBar("Showing what you had", "Refresh failed")` (`:63–67`) **above fresh content** — the bar describes a row it does not point at | Row-level inline note carrying the error's headline ("You're offline" / "Too many requests, briefly") with a Retry `StateAction(.aside)`; the screen-level StaleBar only when at least one row is actually stale (`origin == .staleAfter` **and** non-empty) | function (`Row` gains `failure: APIError?`; `rowView` gains a branch) | certain |
| D2 | Discover, whole screen | All four feeds return **0 series on a successful network call** (a format filter like `["novel"]` plus `safe`-only rating can do this; `rising`/`hidden-gems` ignore `type` and are filtered locally, `SeriesRepository.swift:413`) | `isCompletelyEmpty` is true, `failure` is nil, so `FailureState(error: model.failure ?? .offline)` (`DiscoverView.swift:279`) tells a reader who is online **"You're offline"** | `EmptyState("Nothing to show with these filters", …, "Open Settings")` when `failure == nil`; `FailureState` only when `failure != nil` | line | certain |
| D3 | Discover, StaleBar | Refresh fails with 429 while cache exists | `"Last updated N ago · refresh failed"` (`DiscoverModel.swift:126–133`). The cause and the countdown (`APIError.countdown`) are dropped; the bar reads the same for offline, 429 and a 500 | StaleBar detail built from `failure.headline` + age; append `countdown` when present so the reader knows to wait, not tap | line (`staleDetail`) | certain |
| D4 | Discover, StaleBar | Refresh fails, cache exists, but `cachedAt` is nil for every stale row | `"Refresh failed"` with no age (`DiscoverModel.swift:128`). Cannot tell how old the content is | Acceptable as a fallback; add the headline per D3 so at least the cause is named | line | certain |
| D5 | Discover, row paging | Page 2+ fails (offline, 429) after page 1 succeeded | `hasReachedEnd = !result.hasMore` (`DiscoverModel.swift:178`) — the failure is read as "end of feed". Spinner (`DiscoverView.swift:222–229`) disappears, row simply stops. No note, no retry; the row never asks again until a pull-to-refresh | An inline trailing card in the row: "Couldn't load more · Retry" (`StateAction(.aside)`) when `origin == .staleAfter`; keep `hasReachedEnd` false so a later scroll retries | function (`Row` gains `pageFailure`; `feedPage` already carries `.staleAfter`) | certain |
| D6 | Discover, header | Cache count not yet read / DB read fails | `cachedSeriesCountSync` answers `0` on error (`SeriesRepository.swift:553–556`); `todayLine` omits the clause when 0 (`DiscoverView.swift:137`). Reader sees just the weekday | Fine as is — a missing number, never a wrong one | — | certain |
| D7 | Discover, first load | Feeds loading | `CoverSkeletonRow()` per row (`DiscoverView.swift:191–192`) | Done well | — | certain |
| D8 | Discover, pull-to-refresh | Refresh while a `loadMore` is in flight | Guarded by `reloads` (`DiscoverModel.swift:163`) | Done well | — | certain |
| D9 | Discover, concurrent loads | `.task { load() }` and `.refreshable { load(forceRefresh:) }` overlap | Two `withTaskGroup`s write `rows[index]` interleaved; last writer wins per row, `staleSince` is reset by the second start (`:79`) and may be set by the first finishing. No crash; a StaleBar can flicker on then off | A `loadTask` join like `StackModel.refill` (`StackModel.swift:157–166`) | function | likely |
| D10 | Discover, community pulse | `/v0/frontpage/community-pulse` fails | Card absent; `didFail` set and never read (`CommunityPulseService.swift:15,30`). Documented choice ("a grace note") | Accepted as is — but on a rate-limited launch the card silently vanishes for the whole session (`hasLoaded` guard, `:25`). Consider retry on next `load()` when `didFail` | line | certain |
| D11 | Discover, recently viewed | `history.entries` throws (DB) | `series = []` via `try?` (`RecentlyViewedRow.swift:42–44`); row hidden because `isWorthShowing` is false. Indistinguishable from "nothing viewed" — but the row is *only* ever hidden, never wrong | Acceptable; a hidden optional row is the right call for a local read failure | — | certain |
| D12 | Discover, "What's new" | Fresh install, `lastSeen == nil` | `isDue` calls `dismiss()` — a write to observed state — **during body evaluation** (`WhatsNew.swift:58–63`, called from `DiscoverView.swift:72`). One extra render pass; not a loop because the second pass sees `lastSeen != nil` | Move the first-run stamp to `WhatsNewState.init` or an `onAppear`; keep `isDue` pure | line | likely |
| D13 | Discover, "What's new" | "Got it" tapped | `dismiss()` writes `UserDefaults` (`:67–70`), card animates out. No confirmation needed | Done well | — | certain |
| D14 | Discover, "Open the stack" | Tap | Navigates via callback; no request, nothing to fail | Done well | — | certain |
| S1 | Search, results | Search fails (offline / 429 / 5xx / decode) | `errorState(message)` — a **bare centred sentence** (`SearchView.swift:275–285`), no symbol, no headline, no Retry, no countdown. The model keeps only `message: String?` (`SearchModel.swift:16,112`) so the `APIError` is gone by the time the view sees it | `FailureState(error:retry:)` — the kit already renders headline, cause, countdown and "Retry now" for `.rateLimited` | function (`SearchModel.failure: APIError?` replaces `message`; view swaps one branch) | certain |
| S2 | Search, 30/min hit mid-typing | Gate is closed; every debounced keystroke throws `.rateLimited` locally within ~0 ms | Skeleton flashes for one frame, then S1's sentence "MangaBaka is throttling this connection…" — **static**, no countdown, and re-shown identically on every keystroke. Previous results are gone (`results = result.series` → `[]`, `:104`). Nothing retries when the window opens | `FailureState` with `countdown` ("Retrying in 38s.") and an automatic re-search when `retryAfter` elapses; or keep the last good results under a `StaleBar` ("Showing the last search · throttled, 38s") | function | certain |
| S3 | Search, zero results | Query + filters match nothing (network OK) | `emptyState` (`SearchEmptyState.swift:20–62`): "Nothing matched …", filter count, "Clear filters", "Random with these filters". **Distinguishable from S1** because `message` is only set on `blockingError` (`SearchModel.swift:112`) | Done well — though it is a hand-rolled layout rather than the kit's `EmptyState`; consider swapping for consistency | — | certain |
| S4 | Search, load more | Page 2+ fails | `hasMore = result.hasMore` → false (`SearchModel.swift:166`); spinner gone, list stops dead, no note, never retried. Reads as "that's all" | Trailing "Couldn't load more · Retry" row; leave `hasMore` true when `origin == .staleAfter` | function | certain |
| S5 | Search, load more | Three consecutive fully-filtered pages | Gives up silently (`:175–179`) with the same "end of list" look | Inline note "Stopped early — more may exist, tighten the filters" | line | certain |
| S6 | Search, heading | A new search is in flight | Heading reads `"\(results.count) shown"` from the **previous** query (`SearchView.swift:194`) above a skeleton for the new one | Hide the count while `isSearching`, or say "Searching…" | line | certain |
| S7 | Search, "Surprise me" | Tap while searching | `.disabled(model.isSearching)` (`:182`) with no visual change — the link looks live | Dim it (`Palette.textMuted`) while disabled | line | certain |
| S8 | Search, idle — lens counts | `count(_:)` fails or is rate-limited | `nil` → row shows the filter rule, never "0 now" (`LensCounts.swift:59–62`, `SearchIdleView.swift:120–123`) | Done well | — | certain |
| S9 | Search, idle — lens counts | Walk cancelled by leaving the screen | Un-answered lenses stay un-asked and are retried next visit (`LensCounts.swift:51–53`) | Done well | — | certain |
| S10 | Search, idle — lens counts | A lens saved while a walk is `running` | `guard … running == nil` (`:53`) drops the ask; the new lens has no count until the next visit | Queue the new lens rather than drop it | line | certain |
| S11 | Search, idle — delete lens | Tap the minus in edit mode | Deletes at once, no undo, no toast (`SearchIdleView.swift:99–102`). Edit mode is the only guard | Toast "Lens deleted" (kit `ToastCentre`), or undo | line | certain |
| S12 | Search, idle — "Clear" recents | Tap | Clears at once, no confirmation (`:157`) | Low stakes; a toast would do | line | certain |
| S13 | Search, save lens | "Save lens" | `SearchLensStore.save` returns `false` for an empty query (`SearchLens.swift:81`) — unreachable because the button is disabled until a filter is set (`FilterSheet.swift:70`). On success the sheet closes and **nothing confirms the save** while results are on screen; the lens is only visible after clearing the field | Toast "Saved as a lens" via `onConfirm` | line | certain |
| S14 | Filter sheet, tag picker | Live `/v1/tags` fetch fails, bundled taxonomy present | Bundled 2,686-row list from 2026-08-27 shown **unlabelled** (`TagPickerSheet.swift:72–86`); placeholder says "Search 2,686 tags" as if current. Nothing reads `CatalogueService.tagsFetchFailed` | A one-line inline note under the field: "Showing the built-in list — the live one couldn't load." Set when `fetched.isEmpty` after a non-empty bundled | line | certain |
| S15 | Filter sheet, tag picker | Bundled taxonomy missing/corrupt **and** live fetch fails (`TagTaxonomy.loadFailed`) | `tags == []`, `isLoading = false`, `groups` renders nothing — a field, a legend, and blank space (`:217–223`, no empty branch) | `FailureState(.transport)`-style inline block with Retry; the sheet should not open onto nothing | line | certain |
| S16 | Filter sheet, tag picker | Typing while live search fails and no local match | `"Could not search tags just now."` (`TagSearch.swift:85`, rendered `TagPickerSheet.swift:200–205`) | Done well — distinct from "No tag matches" | — | certain |
| S17 | Filter sheet, tag picker | Sheet opens | `isLoading = true` but nothing renders a skeleton; the bundled list lands synchronously so it is invisible in practice (`:26,72–78`) | Acceptable | — | likely |
| S18 | Filter sheet | "Clear all" | Reversible in place with "Undo clear" (`FilterSheet.swift:85–102`) | Done well | — | certain |
| M1 | Mix, blend | `mix` fails for **any** reason (offline, 429, 400 from a bad seed id, 5xx, decode) | `SeriesRepository.mix` returns `.empty` on catch (`SeriesRepository.swift:463–465`); `MixModel.run` then sets `"Nothing matched. Try loosening the filters."` (`MixModel.swift:101`) and `dna = .empty`. A throttled or offline reader is told their filters are too tight | `mix` returns the error (`MixResult.failure: APIError?` or `Result`); `MixResults` shows `FailureState` with Retry/countdown; "Nothing matched" only on a real empty answer | file (`SeriesRepositoryProtocol.mix` signature + stub + `MixModel` + `MixResults`) | certain |
| M2 | Mix, DNA after a failed re-blend | A strand is excluded, the re-blend 429s | `dna` becomes `.empty` so `dnaSection` disappears (`MixView.swift:232`) — including the "Start over" button — while `excludedTags` stays set (`isDNAEdited` true). The only way back is remove/re-add a seed | On failure keep the previous `dna`/`moves` and show the error beside them (follows from M1: do not overwrite state on `.failure`) | function | certain |
| M3 | Mix, seeds | "Blend" with no seeds | Button disabled and visibly different (`MixView.swift:208–219`); `run()` also guards with a message (`MixModel.swift:78–83`) | Done well | — | certain |
| M4 | Mix, seeds | A seed series no longer exists on the server (deleted/merged id) | The API's 400/404 is caught as M1 → "Nothing matched" | Follows from M1: `.server(400, message)` shows the API's own sentence, which names the seed problem | — | likely |
| M5 | Mix, suggested seeds | `shelf.entries(.saved)` throws | `try? … ?? []` (`MixModel.swift:74`) → "Nothing saved yet. Swipe a few series in the Stack first." (`MixView.swift:164`) even when the reader has saves | Acceptable for a local read; a DB failure here is rare and the sentence is not harmful | — | certain |
| M6 | Mix, results while running | Reshuffle / filter tap | `MixResults` swaps the grid for a spinner (`MixResults.swift:13–19`); the count line and grid vanish and pop back | Keep the grid, dim it, spinner in the header row (StaleBar-style "Re-blending…") | function | certain |
| M7 | Mix, filter chip taps | Rapid taps | Debounced via a `static var pendingFilterBlend` (`MixFilterStrip.swift:157–167`) | Done well (already fixed as L10) | — | certain |
| M8 | Mix, seed picker | Search fails | `Text(search.message ?? …)` — muted small text, no retry (`SeedPickerSheet.swift:132`) | Same fix as S1 once `SearchModel` carries `APIError`: `FailureState` compact, or at least a Retry | line | certain |
| M9 | Mix, seed picker | Query typed, **zero results**, network fine | `search.message` is nil, so the branch shows the idle prompt **"Type a title you love."** (`:130–132`) — the reader has typed and is told to type | `"Nothing called \u{201C}…\u{201D}"` when `!search.query.isEmpty` | line | certain |
| M10 | Mix, seed picker | Seeds full | Non-seed rows at `opacity 0.4`, hit-testing off (`:183–184`); nothing says why | Footer line "Three seeds is the limit — remove one to swap" | line | certain |
| K1 | Stack, first load | Queue empty and fetch fails | `EmptyState("Can't load the stack", message, "Try again")` (`StackView.swift:301–308`) — uses the **empty** kit for a **failure** (no mark, which the kit's own doc says is what tells them apart, `EmptyState.swift:11–14`). No countdown for 429; `message` is a `String` (`StackModel.swift:48,428`) | `FailureState(error:retry:)`; `StackModel.failure: APIError?` from `result.blockingError` | function | certain |
| K2 | Stack, "That's today's stack" | Offline **with** a stale mix cache whose every entry was already reacted to | `blockingError` is nil (series non-empty, `SeriesRepository.swift:319–322`), all filtered out at `StackModel.swift:429`, so `message = nil` → "That's today's stack … A new one is dealt tomorrow morning." No hint the network failed | Carry `origin` up: when the last result was `.staleAfter`, prefer K1's failure state | function | certain |
| K3 | Stack, empty state | "Deal another now" | Calls `model.resetStack()` **directly** (`StackView.swift:319–320`), which `shelf.clear()`s every local save and skip (`StackModel.swift:247–256`) — with **no confirmation and no toast**, two lines under the text "N saved". The header's own reset has a confirmation dialog that names exactly this consequence (`StackResetMenu.swift:32–46`) | Route through `StackResetMenu`'s confirmation, then `onConfirm("The stack has been reset")` as the header path does (`StackView.swift:82–83`) | line | certain |
| K4 | Stack, "tomorrow morning" | Any exhaustion | Copy promises "A new one is dealt tomorrow morning" (`StackView.swift:312–315`); the comment credits the rising feed's one-day cache (`:292–293`), but the queue is built from `.mix` (1 h) or `.surprise` (never cached) (`SeriesRepository.swift:273–279`). Nothing is scheduled for the morning | Drop the promise or make it true; "Deal another now" already exists | line | certain |
| K5 | Stack, provenance | Random queue | Caption "A random sample — save a few to make it yours" (`StackModel.swift:32`, rendered `StackHeader.swift:45`) | Done well — the silent fallback is said | — | certain |
| K6 | Stack, provenance | Reader **has** a token, `recommendationStatus()` fails (offline/429) | `try?` → nil → `canPersonalise ?? false` → `canUseProfile = false` **cached for the session** (`StackModel.swift:312–323`, `LibraryService.swift:180–184`). Then `library.library(page:1)` also `try? … ?? []` (`LibraryService.swift:160–162`) → `source = .random`. The reader with 300 series on file is told "save a few to make it yours" and the profile recommender is never retried until relaunch | Only cache `canUseProfile` on a real answer; on failure leave it nil and say so in the caption ("Couldn't reach your library — showing a random sample") | function | certain |
| K7 | Stack, profile page | `recommendations()` fails mid-session | `[]` (`LibraryService.swift:211–215`) → falls through to a blend; `source` flips from `.yourProfile` to `.yourSaves`/`.random` silently (`StackModel.swift:183–192`) | Same caption note as K6, one refill long | line | certain |
| K8 | Stack, save | `shelf.record` throws | `try?` (`StackModel.swift:267`); `saved.insert` still runs and the toast says "Saved here" (`:42`, `StackView.swift:240`) for a save that did not persist | Only insert and confirm on success; otherwise a warning under the card (the `saveWarning` slot exists, `:70`) | line | certain |
| K9 | Stack, save to library | POST fails (no token, 401, offline) | `saveWarning` under the card: "Saved here, but not to your MangaBaka library." (`StackModel.swift:306`, `StackSections.swift:85–90`); toast says "Saved here" | Done well | — | certain |
| K10 | Stack, refill | Overlapping refills | Joined on one task (`StackModel.swift:157–166`) | Done well | — | certain |
| K11 | Stack, reset | `shelf.clear()` throws | `try?` (`:248`); in-memory state is wiped, the toast says "The stack has been reset", the DB still holds the saves — next launch resurrects them | Surface the failure via `onConfirm` text ("Couldn't reset — try again") | line | certain |
| K12 | Stack, loading | Queue empty, refill running | `ProgressView` only (`StackView.swift:125–126`); the card area collapses to nil height (`:131`) so the layout jumps when a card lands | A card-shaped skeleton at `Metrics.stackArea` height | line | likely |
| B1 | Browse, vocabulary | `/v1/genres` and/or `/v1/tags` fail | `genres = []`, `tags = []` (`CatalogueService.swift:59,91`); subtitle stays **"Loading the vocabulary"** forever (`BrowseModel.swift:27`), genre row empty, "All tags" header over nothing, footer still explains dimming rules. `isLoading` is set (`:66`) but **no view reads it**; `genresFetchFailed`/`tagsFetchFailed` exist and nothing reads them. Retry only by leaving and returning (`.task`, `guard tags.isEmpty`) | Skeleton chips while `isLoading`; `FailureState` with Retry when both are empty and a fetch failed; "N genres" when only tags failed | function | certain |
| B2 | Browse, publishers | Search fails | "Could not search publishers just now." (`PublisherBrowser.swift:36–40`), distinct from "No publisher by that name." (`:41–45`) | Done well (no Retry, but re-typing retries) | — | certain |
| B3 | Browse, publishers | `/v1/publishers` itself is 503 (documented, `:9–12`) | Not used; search endpoint used instead | Done well | — | certain |
| B4 | Browse, block a tag | `blocked.toggle` fails | Not reviewed (`BlockedTagsStore` outside slice) | — | — | not reviewed |
| P1 | Publisher page (adjacent) | Page 1 fails | Muted sentence "Couldn't reach MangaBaka. Pull to try again." (`PublisherView.swift:75`) — no mark, no countdown, and the reader must know pull-to-refresh exists | `FailureState` with Retry | line | certain |
| P2 | Publisher page (adjacent) | Page 2+ fails | `hasMore = result.hasMore` → false (`:289`); silent end, documented as a known gap (`:282–288`) | Same trailing "Couldn't load more · Retry" row as D5/S4 | function | certain |
| P3 | Publisher page (adjacent) | `count()` fails | `total` nil → header shows `series.count` (`:190`) — the page size, which is the bug the comment at `:50–52` says was already reported | Show nothing rather than the page size when `total == nil` | line | certain |
| R1 | Repository | `readCache` throws | `try?` (`SeriesRepository.swift:394,420`) — a DB read failure looks like a cache miss and goes to the network; on network failure it looks like "no cache" | Acceptable degradation; nothing to show the reader | — | certain |
| R2 | Repository | `write` throws (disk full) | `try? write(…)` (`:414`) — fresh content is shown, not cached; next offline launch has nothing and says "You're offline" | Acceptable; a one-time toast "Couldn't save for offline" would be honest but noisy | — | certain |

## Traps

Grepped `!` (excluding `!=` and prefix-not), `try!`, `as!`, `.first!`, `.last!`, `fatalError`, `precondition`, `assertionFailure`, `URL(string:`, `Int(`, `[0]`/`[1]`, `removeFirst`/`removeLast`, `...]`, `..<`, `String(format`, and ` / ` across the 35 files above. Each hit read in context.

- **Force unwraps, `try!`, `as!`, `fatalError`, `precondition`, `URL(string:)!`: none found** in the slice.
- `MangaBaka/Features/Mix/BlendDNAView.swift:92` — `Int((weight * 100).rounded())`. `weight` is a `Double` straight from `/v1/series/mix`'s `dna[].weight` (`BlendDNA.swift:15`). `JSONDecoder` rejects NaN/Inf, but a finite value ≥ ~9.2e16 traps `Int()`. Reachable only by a malformed server answer. **Low likelihood, real trap.** Fix: clamp (`min(weight, 1)`) before converting.
- `MangaBaka/Features/Search/TagPickerSheet.swift:403–404` — `Double(below) / Double(counts.count - 1)` and `Int(…)`: guarded by `counts.count > 1` (`:401`); percentile ∈ [0,1]. Safe.
- `MangaBaka/Features/Stack/StackModel.swift:261` — `queue.removeFirst()`: guarded by `guard let series = current` (`:259`) with no `await` between. Safe.
- `MangaBaka/Features/Stack/StackModel.swift:418` — `seedPool[seedCursor...]`: guarded by `seedCursor < seedPool.count` (`:417`). `seedPool = []` at `:275` leaves a stale `seedCursor`, but `buildSeedPoolIfNeeded` resets it (`:379`) before any read. Safe.
- `MangaBaka/Features/Mix/MixView.swift:112` — `0..<(maxSeeds - seeds.count)`: `addSeed` refuses past `maxSeeds` (`MixModel.swift:60`); never negative. Safe, but a `max(0, …)` would make it unconditionally so.
- `MangaBaka/Features/Discovery/DiscoverView.swift:263`, `StackSections.swift:146,157` — `String(format: "%.1f", Double)`: argument types match. Safe.
- Divisions at `DiscoverView.swift:227,254`, `MixView.swift:145`, `StackView.swift:185`: constant non-zero divisors. `BlendDNAView.swift:58` guards `heaviestWeight > 0`. Safe.
- `APIError.humanDuration` (`APIError.swift:33,36`, adjacent) — `Int(seconds.rounded())`: `retryAfter` is capped at 15 min before it reaches the error (`APIClient.swift:170`, `RateLimitGate.swift:45`), and the gate's own `secondsUntilAllowed` is bounded by the same cap. Safe.

## Done well

- `DiscoverView.swift:191–192` skeleton rows on first load; `:63–67` StaleBar when content survives a failed refresh; `:279` FailureState when nothing does.
- `DiscoverModel.swift:163` reload-generation guard on paging; `:169` de-duplication before `ForEach`.
- `SearchModel.swift:95` `defer { isSearching = false }` (the eternal-spinner fix); `:103,152` generation guards; `:134` bounded empty-page loop.
- `SearchEmptyState.swift:12–18` names the active filter count and offers "Clear filters" — empty and failed are distinguishable (S3).
- `LensCounts.swift:27–30,59–62` nil-not-zero; `SearchIdleView.swift:120–123` falls back to the rule text.
- `TagSearch.swift:68–73,84–86` "could not search" vs "no tag matches"; `PublisherBrowser.swift:111–113` the same for publishers.
- `FilterSheet.swift:76–102` reversible "Clear all".
- `MixView.swift:208–219` a disabled Blend that looks disabled; `MixFilterStrip.swift:157–167` debounced filter taps.
- `StackModel.swift:27–34` provenance captions incl. the random fallback; `:157–166` refill join; `:293–307` save-to-library failure said under the right card; `StackResetMenu.swift:32–46` confirmation naming the consequence.
- `CommunityPulseService.swift:12–15` a grace note that fails silently by design.
- `SeriesRepository.swift:319–322` `blockingError` only when there is nothing to show; `+Count.swift:15–17` count is nil on failure, never zero.

## Proposed fixes, grouped by file

Each names the test that proves it. Stubs: `StubRepositoryBase` in `MangaBakaTests/SeriesFactory.swift:72` already satisfies the protocol; new tests subclass it as `MixModelTests.swift:13` does.

**`MangaBaka/Core/Persistence/SeriesRepository.swift` (+ protocol, + `SeriesFactory.swift` stub) — M1, M2, M4**
- `mix` returns `MixResult` with a `failure: APIError?` (or `Result<MixResult, APIError>`) instead of `.empty` on catch (`:463–465`).
- Test (`SeriesRepositoryTests`): a `MockURLProtocol` 429 on `/v1/series/mix` → `failure == .rateLimited`, `recommendations.isEmpty`. Fails today because the result is `.empty` with no error.

**`MangaBaka/Features/Mix/MixModel.swift` / `MixResults.swift` / `MixView.swift` — M1, M2, M6, M9**
- `run()`: on `failure != nil`, set `failure`, **do not** overwrite `results`/`dna`/`moves`; `message` only for a real empty answer.
- `MixResults`: `FailureState(error:retry:)` branch before the message branch; keep the grid dimmed under a spinner while `isRunning`.
- `SeedPickerSheet.swift:130–132`: zero-result copy when `!search.query.isEmpty`.
- Tests (`MixModelTests`): stub `mix` returning `.rateLimited` → `model.failure == .rateLimited`, `model.dna` unchanged from the previous run, `model.message == nil`. Fails today: `dna == .empty`, `message == "Nothing matched…"`.

**`MangaBaka/Features/Search/SearchModel.swift` / `SearchView.swift` / `SeedPickerSheet.swift` — S1, S2, S4, S6, S7, M8**
- Replace `message: String?` with `failure: APIError?` (`:16,112`); `SearchView.errorState` → `FailureState(error:retry:)`; when `failure` is `.rateLimited(retryAfter:)`, schedule one automatic `search()` after `retryAfter`.
- `loadMore`: keep `hasMore` when `result.origin` is `.staleAfter`; expose `pageFailure` for a trailing Retry row.
- Hide the "N shown" heading while `isSearching`; dim "Surprise me" when disabled.
- Tests (`SearchModelTests`): stub `search` returning `.staleAfter(.rateLimited(retryAfter: 30))` → `failure?.countdown == "Retrying in 30 seconds."`; stub page 2 as `.staleAfter(.offline)` → `hasMore` still true and `pageFailure == .offline`. Both fail today (`message` is a string; `hasMore` becomes false).

**`MangaBaka/Features/Search/TagPickerSheet.swift` — S14, S15**
- After the live fetch: if `fetched.isEmpty && !bundled.isEmpty` (or `await catalogue.tagsFetchFailed`), set `isShowingBundled = true` and render one footnote under the field. If `tags.isEmpty` after both, render an inline failure with Retry.
- Test: `TagBreadth`-style pure helper `TagPickerSheet.status(bundled:fetched:loadFailed:) -> Status` with three cases (`.live`, `.bundledOnly`, `.nothing`); the view switches on it. Fails today because no such state exists.

**`MangaBaka/Features/Discovery/DiscoverModel.swift` / `DiscoverView.swift` — D1, D2, D3, D5, D9**
- `Row` gains `failure: APIError?` and `pageFailure: APIError?`; `isShowingStale` requires a row with `origin == .staleAfter` **and** non-empty series; `staleDetail` includes `failure.headline` and `countdown`.
- `rowView`: per-row inline note + Retry when `row.failure != nil && series.isEmpty`; trailing Retry card when `pageFailure != nil`.
- `emptyState`: `EmptyState` when `failure == nil`, `FailureState` otherwise.
- Join concurrent `load()` calls on one task.
- Tests (new `DiscoverModelTests`): stub feeds where row 0 is `.staleAfter(.offline)` with no series and rows 1–3 are `.network` with series → `isShowingStale == false`, `rows[0].failure == .offline`. Fails today (`isShowingStale == true`). Second test: all rows `.network` and empty → `failure == nil` and the view-model state is `.empty`, not `.offline`.

**`MangaBaka/Features/Stack/StackModel.swift` / `StackView.swift` — K1, K2, K3, K4, K6, K7, K8, K11**
- `failure: APIError?` replaces `message`; set from `result.blockingError` **or** from `result.origin` when every entry was filtered as reacted (K2).
- `emptyState` failure branch → `FailureState`.
- "Deal another now" → same `confirmationDialog` as `StackResetMenu` (extract the dialog so both use one), then `onConfirm`.
- Drop "A new one is dealt tomorrow morning."
- `profileIsUsable`: cache only when `recommendationStatus()` returned non-nil; add `Source.unavailable(APIError)` caption "Couldn't reach your library — showing a random sample".
- `react`: only `saved.insert` / confirm when `shelf.record` succeeded; on failure set `saveWarning` = "Couldn't save — try again".
- Tests (`SurpriseAndStackTests` / `StackSaveTests`): stub `feed` returning `.staleAfter(.rateLimited(retryAfter: 10))` with empty series → `failure == .rateLimited`. Stub `feed` returning `.staleAfter(.offline)` with series all in `reacted` → `failure == .offline`, not nil (fails today). A `LibraryProviding` stub whose `recommendationStatus()` returns nil → `canUseProfile` still nil after one refill (fails today: false).

**`MangaBaka/Features/Browse/BrowseModel.swift` / `BrowseView.swift` — B1**
- `BrowseModel` gains `failure: Bool` from `catalogue.genresFetchFailed && catalogue.tagsFetchFailed`; view renders skeleton chips while `isLoading`, `FailureState(.transport, retry:)` when failed and empty; subtitle stops saying "Loading" once loading is over.
- Test (`BrowseModelTests`): a `CatalogueService` over a failing `MockURLProtocol` → after `load()`, `isLoading == false`, `failed == true`, `subtitle != "Loading the vocabulary"`. Fails today on the subtitle.

**`MangaBaka/Features/Detail/PublisherView.swift` (adjacent) — P1, P2, P3**
- `FailureState` for page-1 failure; trailing Retry row for page-2; header count blank when `total == nil`.
- Test (`PublisherPageTests`): stub `count` nil → header shows no number. Fails today (shows `series.count`).

**`MangaBaka/Features/Mix/BlendDNAView.swift:92`** — clamp before `Int()`. Test: `percent(1e300)` does not trap (fails today with a crash).

**`MangaBaka/Features/Discovery/WhatsNew.swift:58–63`** — move the first-run stamp out of `isDue`. Test: `isDue(hasCompletedOnboarding: false)` does not mutate `lastSeen`.

## Top three gaps

1. **Mix cannot tell failure from emptiness at all** (M1/M2): every network error becomes "Nothing matched. Try loosening the filters." and wipes the DNA the reader was editing.
2. **Search under the 30/min limit shows a static sentence with no countdown, no retry, and drops the last good results on every keystroke** (S1/S2) — the one failure the app is guaranteed to meet.
3. **"Deal another now" on the stack's empty state erases every local save without a confirmation** (K3), while the identical action in the header has one.
