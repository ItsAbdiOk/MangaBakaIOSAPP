# Failure audit — the services layer (2026-09-13)

Read-only. What the services let a screen see, and where an error is born, swallowed, or turned into "nothing". The screen audits report what the reader sees; this one reports what they *could* have been shown.

## Scope

Read in full (31 files): `Core/Networking/*` (7), `Core/Persistence/*` (7), `Core/Model/CatalogueService.swift`, `Core/Library/LibraryService.swift`, `Core/Characters/{AniListClient,CharacterService}.swift`, `Core/Characters/SeriesCharacter.swift` (the `ShikimoriClient` actor, lines 110–200; the profile extension from line 200 only via grep), `Core/Volumes/{AppleBooksClient,GoogleBooksClient}.swift`, `Core/Schedule/{MangaUpdatesClient,WebtoonsFeedClient,ReleaseFeedService,ReleaseFeedProvider}.swift`, `Core/Schedule/ReleaseSchedule.swift` (lines 160–380 in full, rest by grep), `Core/Schedule/{NaverFeedClient,GigaViewerFeedClient}.swift` (request paths in full, parsers by grep), `Core/Images/*` (3), `Features/Shelf/ShelfStore.swift`, `App/AppServices.swift`, `App/RootView.swift` lines 85–130 and 245–275, `App/RootView+Session.swift` lines 137–167.

Not reviewed: `Core/Library/LibrarySnapshot.swift` (only `load()` lines 81–121), `Core/Library/TasteProfile.swift` (only `ranker`/`favouredTagIDs`), `Core/Auth/TokenStore.swift` (only the `read()` status check), `Core/Characters/ShikimoriClient.characterProfile` (lines 244–300), `NetworkLedger`, `Signposts`, the feed parsers' bodies, every `Features/*Model.swift` (the screen auditors' slice).

## Per-function table

Columns: how it can fail → what it returns → can the caller tell failure from emptiness → stale surfaced as stale? → 429 remembered locally? → timeout / retry → cancellation.

"Default timeout" = `URLRequest`'s 60 s; **no file in the slice sets `timeoutInterval` or a `URLSessionConfiguration`** (grep, 0 hits). "Cancel → transport" = `URLError.cancelled` is caught by the generic `catch` and rethrown as `APIError.transport`, indistinguishable from a real transport failure.

### APIClient (`Core/Networking/APIClient.swift`)

| Function | Can fail how | Returns on each | Failure vs empty | Stale as stale | 429 remembered | Timeout / retry | Cancellation |
|---|---|---|---|---|---|---|---|
| `get` :35 | offline → `.offline` :145; timeout/other URLError → `.transport` :147; non-HTTP → `.transport` :161; 429 → `.rateLimited` :171; 4xx/5xx → `.server(status, message)` :186; bad JSON or `data == null` → `.decoding` :45/:48; gate closed → `.rateLimited(wait)` :127 | throws `APIError` (typed) | yes — typed throw; an empty `[]` payload returns normally | n/a (no cache here) | yes — `limiter.recordRateLimit` :165, refused locally at :126 | default 60 s; no retry | cancel → `.transport("…cancelled…")` :147 — **not distinguished** |
| `getWithPagination` :65 | same as `get` | same + `pagination?` | yes | n/a | yes | default / none | same |
| `total` :99 | same; missing pagination → `nil` :102 | `Int?` — nil for "no count", throws for failure | yes | n/a | yes | default / none | same |
| `post` :209 | as `get`; 409 → `false` :220; 401/403 → `.server` with a Settings-pointing message :277 | `Bool` / throws | yes | n/a | yes | default / none | same |
| `delete` :226, `patch` :238 | as `post` minus 409 | throws | yes | n/a | yes | default / none | same |
| `getRoot` :300, `getResults` :316 | as `get`; `results == null` → `.decoding` :325 | throws | yes | n/a | yes | default / none | same |
| `profile` :338 | any of the above | **`nil` for all of them** (`try?` :339) | **no** — offline, 429, 401 and 500 all read as "no account" | n/a | yes (gate) | default / none | cancel → nil |
| `verifiedProfile` :349 | as `get` | throws | yes | n/a | yes | default / none | same |

### SeriesRepository (`Core/Persistence/SeriesRepository*.swift`)

| Function | Can fail how | Returns on each | Failure vs empty | Stale as stale | 429 remembered | Timeout / retry | Cancellation |
|---|---|---|---|---|---|---|---|
| `feed` :393 | network (all `APIError`s); DB read throws (`try?` :394, :420); DB write throws (`try?` :414) | network ok → `.network`; fresh cache → `.cache`; failure → `.staleAfter(error)` with whatever is on disk (possibly `[]`) :421 | **yes** — `origin` carries the error; `blockingError` :319 is non-nil only when both failed *and* the cache is empty. A DB write failure after a good fetch is silent (:414) — the reader sees fresh data now and no cache next time | **yes** — `cachedAt` :424 from `feedMetadata` | via `APIClient` | default / none | cancel → `.staleAfter(.transport)` — a screen that is left mid-load and then revisited **can show a StaleBar for a cancellation**; `staleContentRemainsUseful` is `false` for `.transport` (`APIError.swift:47`) so the kit would even prefer a whole-screen failure |
| `mix` :429 | network; decode | **`.empty` for every failure** :464 | **no** — a rate-limited blend and a blend with no matches are both `MixResult.empty` | n/a (not cached) | via client | default / none | cancel → `.empty` |
| `feedPage` (+Paging :15) | network | `.staleAfter(error)` with `[]` :38 | yes (origin), but `hasMore` defaults `false` :311 so a failed page 2 **ends the row silently** unless the caller reads `origin` | n/a | via client | default / none | cancel → `.staleAfter(.transport)` |
| `search` (+Paging :42) | network | `.staleAfter(error)` with `[]` :59 | yes — `blockingError` fires because `series.isEmpty` | n/a | via client | default / none | cancel → `.staleAfter(.transport)`; `SearchModel.swift:112` shows it as a message — a debounce race that cancels a request shows "The request didn't complete." (the model guards with `generation`, screen slice to confirm) |
| `count` (+Count :17) | network; decode | `nil` for all :26 | **partially** — nil is documented as "unknown, never zero", but the caller cannot tell "offline" from "server has no count" | n/a | via client | default / none | cancel → nil |
| `extras` :673 | six concurrent `get`s, each `try?` :699–716; cache read/write `try?` :674/:679 | each failing leg becomes `[]`/nil; whole result cached for 6 h **only if not all-empty** :679 | **no** — a series with no links and a series whose `/links` call was offline are the same `[]`. A *partial* failure (5 of 6 legs ok) **is cached for six hours** with the failed leg as `[]`: e.g. `/works` 429'd → the volumes shelf reads "none" for six hours | no — a 6 h detail cache is served as fresh with no age; `readDetailCache` returns only the payload :23 | via client (a 429 on leg 1 makes legs 2–6 refuse locally, all six become empty, and *that* result is not cached — the all-empty guard :679 saves this case only) | default / none | cancel → the leg becomes `[]`; if any leg finished first, the partial is cached for 6 h |
| `images` :651 | network | `[]` for failure **and** for "one cover" :657; not cached on either | **no** — comment at :654 acknowledges it | n/a | via client | default / none | cancel → `[]` |
| `relationships` :687 | network | `nil` :691, empty list is `[]` | **yes** | in-memory for the process, no age | via client | default / none | cancel → nil |
| `cachedSeriesCount` :548 | DB read throws | `0` :555 | **no** — a broken DB reads as "0 series cached" | n/a | n/a | n/a | n/a |
| `updateContentRatings` / `updateFormats` / `updateBlockedTags` / `updateLibraryExclusion` :495–546 | DB delete throws (`try?` +Cache :84/:86, :545) | nothing | n/a — but a failed discard **keeps serving content the reader just excluded**, silently | — | — | — | — |

### CatalogueService (`Core/Model/CatalogueService.swift`)

| Function | Can fail how | Returns on each | Failure vs empty | Stale as stale | 429 remembered | Timeout / retry | Cancellation |
|---|---|---|---|---|---|---|---|
| `genres` :44 | network | `[]` :59; sets `genresFetchFailed` :57 | **only via the side flag** — the array alone cannot tell; flag is read by **no caller anywhere** (`grep FetchFailed MangaBaka/` → 0 hits outside this file, Features included), so Browse cannot tell "no genres" from "offline" | process-lifetime cache, no expiry, no age | via client | default / none; a second caller joins the in-flight task :47 | cancel of the *joining* caller is fine; cancel of the *first* caller cancels the shared task → **both get `[]` and `genresFetchFailed = true`** |
| `tags` :64 | network | `[]` :91; `tagsFetchFailed` :89 | same as `genres` | same | via client | same | same |
| `children` :95 | as `tags` | `[]` | no | — | — | — | — |
| `searchTags` :109 | network | `nil` :119; empty query → `nil` :111 (**same value as failure**) | yes for network, **but an empty/whitespace query also returns nil** | n/a | via client | default / none | cancel → nil |
| `findPublisher` :145 | network (per candidate, `nil` from `searchPublishers` → `continue` :149) | `nil` for "no match" **and** for "every candidate's request failed" :152 | **no** | n/a | via client | default / none; up to 3 sequential requests | cancel → nil |
| `publisher(id:)` :183, `searchPublishers` :187 | network | `nil` :184/:188 | yes (nil vs `[]`) | n/a | via client | default / none | cancel → nil |

### LibraryService (`Core/Library/LibraryService.swift`)

| Function | Can fail how | Returns on each | Failure vs empty | Stale as stale | 429 remembered | Timeout / retry | Cancellation |
|---|---|---|---|---|---|---|---|
| `profileID` :138 | as `APIClient.profile` | `nil` :140; **nil is not cached** (`if let cachedProfileID` :139), so it retries every call | **no** — offline reads as "unauthenticated" and a blend silently stops excluding the reader's library | process cache | via client | default / none | cancel → nil |
| `library` :160 | any | `[]` :161 | **no** (documented; `libraryPage` exists for callers who care) | n/a | via client | default / none | cancel → `[]` |
| `libraryPage` :169 | any | throws | yes | n/a | via client | default / none | cancel → `.transport` |
| `recommendationStatus` :180 | any | `nil` :183 | **no** — "no profile" vs "offline" | n/a | via client | default / none | cancel → nil |
| `recommendations` :198 | any | `[]` :215 | **no** — and `ResultsEnvelope.coldStart` / `profileStale` (:14/:17) are decoded and **thrown away**, so the "your library is too small" explanation the envelope offers never reaches a screen | n/a | via client | default / none | cancel → `[]` |
| `hiddenTagIDs` :227 | any page failing | `nil` :252; nothing disallowed → `[]` :234 | yes | process cache keyed by ratings :236 | via client | default / none; ≤3 sequential requests | cancel → nil |
| `add` :263, `remove` :279, `update` :283 | any; 401/403 carry a Settings-pointing message | throws | yes | n/a | via client | default / none | cancel → `.transport("…cancelled")` — a reader who leaves the sheet mid-save gets "The request didn't complete." for a write that **may have succeeded on the server** |
| `topGenres` :297 | any | `nil` :298 | yes | n/a | via client | default / none | cancel → nil |

### Characters

| Function | Can fail how | Returns on each | Failure vs empty | Stale as stale | 429 remembered | Timeout / retry | Cancellation |
|---|---|---|---|---|---|---|---|
| `AniListClient.characters` :105 | any URLError → **`.transport`, never `.offline`** :122; non-2xx → `.server(status, "AniList returned N.")` :134; 429 → `.rateLimited` :131; decode → `.decoding` :144; GraphQL `errors` in a 200 → `.server(200, msg)` :151; **empty cast → `.server(200, "AniList knows no cast.")`** :161 | throws | yes, but the taxonomy is bent: an empty cast is thrown as a server error | n/a | yes — `spacing.backOff` :130, honoured on the *next* call's `waitForSlot` :194 (it sleeps rather than refusing) | default 60 s; none | `waitForSlot` sleep cancelled → `.transport` :200; in-flight cancel → `.transport` :122 |
| `AniListClient.characterProfile` :286 | as above; unknown id → `.server(200, "…no such character.")` :335 | throws | yes | n/a | yes | default / none | same |
| `AniListClient.healthCheck` :384 | transport / non-2xx | throws | n/a | n/a | yes | default / none — **this runs at every launch** (`RootView.swift:107`) and waits up to 60 s against a hung AniList; nothing waits on it | same |
| `ShikimoriClient.characters` (`SeriesCharacter.swift:144`) | same shape as AniList; offline → `.transport` :156 | throws; empty cast returns `[]` (no throw) | yes | n/a | yes :164 | default / none | same |
| `CharacterService.characters` :68 | AniList throws → tried Shikimori; Shikimori `try?` :87 | **`[]` for every failure** :95 | **no** — by design (:12–16); `lastOutcome` :32 is diagnostic only | n/a | 403/5xx from AniList remembered 15 min :81 | default / none | a cancelled AniList call is `.transport` → falls through to Shikimori, which **also** runs on a task the reader has left (`try?` :87 hides its cancel too) |
| `CharacterService.primeAniListHealth` :116 | as `healthCheck` | nothing | n/a | n/a | 403/5xx → 15 min | — | — |

### Volumes

| Function | Can fail how | Returns on each | Failure vs empty | Stale as stale | 429 remembered | Timeout / retry | Cancellation |
|---|---|---|---|---|---|---|---|
| `AppleBooksClient.volumes` :38 | no title → `[]` :41; URL build → nil :97; URLError (incl. offline, timeout, **cancel**) → nil :101; 429 **or 403** → nil + 60 s backoff :102; other non-2xx → nil :107; decode → nil :112 | `nil` for "could not ask", `[]` for "asked, none"; **`[]` cached for 7 days** :56 | **yes** (nil vs `[]`) — but a *matcher* miss (200 OK, results present, nothing matched) is `[]` and is cached a week, which is the intended contract | **no** — a 7-day cache is served as fresh with no age; `readCache` :126 drops `storedAt` | 60 s backoff :104 — held in `spacing`, so the next caller **sleeps up to 60 s** (:85) instead of refusing; and a 403 from a store-region mismatch is indistinguishable from a rate limit and also backs off | default / none | sleep cancelled at :85 is **swallowed** (`try?`) and the request is fired anyway; the `data(from:)` then throws cancelled → nil |
| `AppleBooksClient.japaneseVolumes` :65 | same | same | same | same | same | same | same |
| `GoogleBooksClient.volumes` :50 | same shape; only 429 backs off :94 | nil / `[]`; `[]` cached 7 d :66 | yes | no | 60 s sleep on next call | default / none | same swallowed sleep :76 |

### Schedule

| Function | Can fail how | Returns on each | Failure vs empty | Stale as stale | 429 remembered | Timeout / retry | Cancellation |
|---|---|---|---|---|---|---|---|
| `MangaUpdatesClient.releases` :97 | offline → `.offline` :121 (**only `.notConnectedToInternet`**; `.networkConnectionLost` and `.dataNotAllowed` become `.transport`, unlike `APIClient.swift:142–144`); 429 :132; non-2xx → `.server(status, "MangaUpdates returned N.")` :135; decode :148 | throws; empty history returns `[]` | yes | n/a | yes :131 (sleep-on-next-call) | default / none | `waitForSlot` :154 → `.transport`; in-flight → `.transport` |
| `ReleaseScheduleService.cadence(for:)` :357 | `releases` throws; DB read/write `try?` :363/:370/:375 | `.unavailable` (no id), `.measured`, **or `.none` for both "too few releases" and "the request failed"** :377 | **no** — the failure is written to the DB row (:375) so the *next* open retries, but the screen this time sees a settled-looking "not enough history" | rows carry `fetchedAt`; `snapshot()` counts `stale` :219 — surfaced there, not from `cadence(for:)` | via MangaUpdates client | default / none | cancel → `.transport` → **written to disk as a failure row** with message "The request didn't complete." and returned as `.none` |
| `ReleaseScheduleService.snapshot` :186 | library walk failure → `libraryFailure` :194; DB read `try?` :189 → `[:]` | partial snapshot; `pending` counts both "never asked" and "asked and failed" :213 | **yes for the library** (`libraryFailure`); **no for the DB** — an unreadable cadence table reads as "everything pending" | yes — `stale` count :219, `measuredAt`/`oldestMeasuredAt` :249 | — | — | — |
| `ReleaseScheduleService.build` :257 / `run` :288 | per-series `releases` throws → row written as failure :329, `progress.failure` set :330 | `progress` | yes (`progress.failure` carries the last `userFacingMessage`, which for MangaUpdates says "MangaUpdates returned 503." under the headline "MangaBaka had a problem" if a screen uses `headline`) | — | via client | 55 requests × 3 s; `Task.isCancelled` checked per series :313 | honoured :313 |
| `ReleaseFeedService.report` :33 | every provider returns `nil` for both "no link" and "failed" | `.empty` :59/:62 | **no** — by design (`ReleaseFeedProvider.swift:17–20`) | n/a | per provider | — | providers swallow cancel |
| `WebtoonsFeedClient.feed` :45 | no candidate → nil :55; URLError/cancel → `continue` :63; 429 → nil + backoff :66; **500 (wrong slug) or any non-2xx → `continue`** :71; parse fail → `continue`; empty entries → `continue` :77 | nil / cached feed | **no** | no — 7-day cache with no age exposed | 60 s sleep-on-next :65 | default / none; up to 3 sequential requests (lookup + 2 variants) | sleep swallowed :59/:103, request fired anyway |
| `NaverFeedClient.feed` :35 | same shape :45–54 | nil | no | no (7 d) | 60 s :49 | default / none | swallowed :43 |
| `GigaViewerFeedClient.feed` :44 / `magazineItems` :98 | same shape; a title that does not match the magazine feed → nil :49 | nil | no | no (24 h, `cacheLife` :24) | 60 s :110 | default / none | swallowed :104 |

### Images and shelf

| Function | Can fail how | Returns on each | Failure vs empty | Stale as stale | 429 remembered | Timeout / retry | Cancellation |
|---|---|---|---|---|---|---|---|
| `CoverStore.image(for:)` :54 | URLError → retried once after 400 ms :132; non-2xx other than 404 → retried :116; 404 → nil :115; undecodable bytes → retried then nil | `UIImage?`; failures never cached :19 | n/a for a cover | in-memory only | **no** — a 429 from the CDN is retried immediately (once) and then dropped; nothing remembers it | default; 2 attempts | honoured :128 for the *fetch*, but the caller's cancel does not propagate (by design :51) |
| `BlurHashCache.image(for:)` :22 | malformed hash → nil (`BlurHash.parse` :58–64 length-checks before every index) | nil | n/a | — | — | — | — |
| `ShelfStore.record/remove/clear` :22/:34/:57 | GRDB throws (disk full, corrupt) | throws | yes | — | — | — | — |
| `ShelfStore.entries` :40 | GRDB throws; a row that fails to decode is **dropped** (`try?` :46) | throws / shorter list | **no for the per-row case** — a `Series` shape change silently shrinks the shelf, the same defect the feed cache fixed at `SeriesRepository+Cache.swift:154–157` | — | — | — | — |

## Systemic findings

### 1. Every `try?` in the slice (84 hits; `grep -n 'try?'` over the 31 files, comments excluded)

"Reader wants to know" = swallows offline / rate-limited / revoked token / a server refusal. "Routine" = a cache miss, a body encode, or a duplicate check where nil is the honest answer.

| File:line | What is swallowed | Verdict |
|---|---|---|
| `APIClient.swift:185` | error-envelope decode on a non-2xx | routine — falls back to a generic message :188 |
| `APIClient.swift:265` | JSON body encode (guarded by `isValidJSONObject` :264) | routine |
| `APIClient.swift:339` | **everything** behind `profile()` | **reader wants to know** — `LibraryService.profileID` :140 and any "am I signed in" check read offline/429/500 as "no account". `verifiedProfile` exists for Settings; nothing else uses it |
| `SeriesRepository.swift:394` | fresh-cache DB read | routine — falls through to network |
| `SeriesRepository.swift:414` | feed cache **write** | reader wants to know *eventually* — a full disk means no offline copy next launch, and nothing says so |
| `SeriesRepository.swift:420` | stale-cache DB read | routine — `[]` + `staleAfter` still carries the error |
| `SeriesRepository.swift:545` | feed discard on account change | **reader wants to know** — a failed discard keeps another account's blends on screen |
| `SeriesRepository.swift:553` | count query | routine, but reads as "0 cached" |
| `SeriesRepository.swift:653` | `/images` fetch | **reader wants to know** — gallery reads "one cover" when rate-limited |
| `SeriesRepository.swift:674` | detail cache read | routine |
| `SeriesRepository.swift:679` | detail cache write | same as :414 |
| `SeriesRepository.swift:689` | `/relationships` | routine — nil is returned, distinct from `[]` |
| `SeriesRepository.swift:699,700,704,708,709,716` | six detail legs | **reader wants to know** — each becomes `[]`/nil; a 429 on all six is the *only* case not cached (the all-empty guard :679). Five-of-six is cached for six hours with the sixth blank |
| `SeriesRepository+Cache.swift:30` | detail payload decode | routine (a shape change → cache miss → refetch) |
| `SeriesRepository+Cache.swift:84,86` | feed/detail discard on filter change | **reader wants to know** — see :545 |
| `SeriesRepository+Count.swift:26` | lens count | routine by contract (nil = unknown, never 0) — but offline and "server sent no count" collapse |
| `CatalogueService.swift:50,70` | genres/tags | half-routine — `[]` plus a side flag that nothing in this slice reads |
| `CatalogueService.swift:112,184,188` | tag search / publisher | routine (nil, distinct from `[]`) |
| `LibraryService.swift:161` | library page | routine by contract — `libraryPage` throws; documented |
| `LibraryService.swift:183` | recommendation status | **reader wants to know** — "no profile" and "offline" are one nil; the stack picks a worse source silently (the comment at `APIClient.swift:293–296` records exactly this class of bug) |
| `LibraryService.swift:211` | personal recommendations | **reader wants to know** — plus `coldStart`/`profileStale` discarded |
| `LibraryService.swift:249` | hidden-tag pages | routine (nil = withhold caption) |
| `LibraryService.swift:298` | top genres | routine (nil) |
| `AniListClient.swift:112,293,391` | request body encode of a string literal + Int | routine (cannot fail for these inputs) |
| `CharacterService.swift:87` | Shikimori cast | by design (silent fallback) — but it also hides a Shikimori 429 that `spacing` will then sleep on next time |
| `AppleBooksClient.swift:85`, `GoogleBooksClient.swift:76`, `WebtoonsFeedClient.swift:59,103`, `NaverFeedClient.swift:43`, `GigaViewerFeedClient.swift:104` | **`Task.sleep` cancellation** | **wrong** — a cancelled wait falls through and fires the request anyway; the reader has left the page and the app spends the third party's budget on a response nobody will read. Six copies of the same bug; `MangaUpdatesClient.waitForSlot` :154–162, `AniListClient` :194 and `ShikimoriClient` :182 got it right |
| `AppleBooksClient.swift:99`, `GoogleBooksClient.swift:91`, `WebtoonsFeedClient.swift:61,106`, `NaverFeedClient.swift:45`, `GigaViewerFeedClient.swift:106` | the whole `data(from:)` — offline, timeout, cancel | by design for the feeds (`ReleaseFeedProvider.swift:17`); for Apple Books it hides offline behind the same nil as a 403 |
| `AppleBooksClient.swift:112`, `GoogleBooksClient.swift:99`, `NaverFeedClient.swift:52` | response decode | routine → nil, not cached |
| `AppleBooksClient.swift:127,128`, `GoogleBooksClient.swift:114,115`, `WebtoonsFeedClient.swift:129,130`, `NaverFeedClient.swift:154,155`, `GigaViewerFeedClient.swift:141,142` | cache file read/decode | routine (miss) |
| `AppleBooksClient.swift:136,138`, `GoogleBooksClient.swift:123,125`, `WebtoonsFeedClient.swift:138,140`, `NaverFeedClient.swift:163,165`, `GigaViewerFeedClient.swift:150,152` | cache dir create + atomic write | routine — see §4 |
| `MangaUpdatesClient.swift:114` | body encode | routine |
| `ReleaseSchedule.swift:189,297,363` | cadence table read | reads as "everything pending" — reader wants to know only if the DB is actually broken; acceptable |
| `ReleaseSchedule.swift:325,329,370,375` | cadence row write | routine-ish — a failed write of a *failure* means the next build does not retry that series; low |
| `ReleaseSchedule.swift:399,414` | cadence payload decode/encode | routine — :404 converts an undecodable payload into a retryable failure |
| `CoverStore.swift:132` | 400 ms retry sleep | routine — `Task.isCancelled` is checked at :128 first |
| `ShelfStore.swift:46` | a shelf row that no longer decodes | **reader wants to know** — a save silently vanishes from the shelf |

### 2. Error taxonomy per third party

`APIError` (`APIError.swift:9–28`) has five cases and its `headline`/`userFacingMessage` are written for MangaBaka. Who throws what:

| Party | offline | timeout / cancel | 4xx | 5xx | 429 | decode | "200 but no" |
|---|---|---|---|---|---|---|---|
| MangaBaka (`APIClient`) | `.offline` (3 codes :142–144) | `.transport` | `.server(status, API's own message)` | `.server` | `.rateLimited` + gate | `.decoding` | `.decoding("no data")` :48 |
| AniList | **`.transport`** :122 | `.transport` | `.server(403, "AniList returned 403.")` | `.server` | `.rateLimited` | `.decoding` | `.server(200, GraphQL message)` :151 and `.server(200, "AniList knows no cast.")` :161 |
| Shikimori | **`.transport`** :156 | `.transport` | `.server(N, "Shikimori returned N.")` | same | `.rateLimited` | `.decoding` | `[]` (no throw) |
| MangaUpdates | `.offline` (1 code only :120) | `.transport` | `.server(N, "MangaUpdates returned N.")` | same | `.rateLimited` | `.decoding` | `[]` |
| Apple Books | nil | nil | nil (403 also backs off 60 s :102) | nil | nil + backoff | nil | `[]` (cached 7 d) |
| Google Books | nil | nil | nil | nil | nil + backoff | nil | `[]` (cached 7 d) |
| Webtoons / Naver / GigaViewer | nil | nil | nil | nil (Webtoons: 500 = wrong slug, tries next :68–71) | nil + backoff | nil | nil / `[]` |

Where the message is untrue for the party:

- `APIError.headline` for `.server` is **"MangaBaka had a problem"** (`APIError.swift:130`) — for an AniList/Shikimori/MangaUpdates `.server`, wrong party. `userFacingMessage` for those shows the raw `"AniList returned 403."` (:104, because the message is non-empty), which is a status code on screen — rubric item 10. Today the only place a third-party `.server` reaches a screen is `ReleaseScheduleService.progress.failure` (:330) and the cadence failure row (:375); `CharacterService` swallows the rest. Confirmed reachable: a MangaUpdates 503 during a schedule build puts "MangaUpdates returned 503." in `progress.failure`.
- `APIError.needsAccount` (:52) fires on **any** 401/403 — an AniList 403 (the 2026-09-10 outage was exactly that, `AniListClient.swift:5–8`) would render as **"This part needs an account"** with a person-badge symbol if any screen ever passed it to `FailureState`. Not reachable today because `CharacterService` swallows it; it becomes reachable the moment a character screen stops swallowing.
- `.offline` is never produced by AniList or Shikimori, so a reader on a train opening a series page gets `.transport` from both, and `staleContentRemainsUseful == false` (:47) — the kit's own rule says "don't show the cached copy" for what is actually just being offline.
- `MangaUpdatesClient.swift:120` catches one URLError code where `APIClient.swift:142–144` catches three; a connection dropping mid-request on MangaUpdates is `.transport`, "The request didn't complete."
- Apple Books cannot produce an `APIError` at all, so a store-region 403 (the case the task asked about) is `nil`, backs off 60 s (:104), and the shelf says whatever the caller says for nil — not in this slice to confirm.

### 3. Caches: expiry, versioning, and this week's unbumped keys

| Cache | Where | Expiry | Version key | Age exposed to caller |
|---|---|---|---|---|
| feed rows (`series`, `feedEntry`, `feedMetadata`) | SQLite | per feed 0 s–24 h (`FeedKind.freshness` :267) | none — a `Series` shape change is caught by the strict decode at `+Cache.swift:158–162` (whole read misses) | yes (`FeedResult.cachedAt`) |
| series detail (`seriesDetail`) | SQLite | 6 h (`+Cache.swift:21`), ≤200 rows | none — `SeriesExtras` decode via `try?` :30 → miss on shape change; **an additive optional field decodes fine and stays nil for 6 h** | **no** |
| cadence (`cadenceEntry`) | SQLite | never; `snapshot()` counts >`staleAfter` as stale :219 | none — undecodable payload → retryable failure :404 | via `snapshot()` only |
| library (`libraryEntry`) | SQLite | not reviewed (`LibrarySnapshot`) | — | — |
| shelf / history | SQLite | never (by design) | none — undecodable row dropped (`ShelfStore.swift:46`) | n/a |
| Apple Books | files | 7 d | `v5-` :46/:67 | no |
| Google Books | files | 7 d | `v2-` :57 | no |
| Webtoons | files | 7 d | `v3-` :51 | no |
| Naver | files | 7 d | `v1-naver-` :37 | no |
| GigaViewer | files | 24 h | `v1-giga-` :99 | no |
| `CatalogueService` genres/tags | memory | process | n/a | no |
| `cachedImages`, `cachedRelationships`, `cachedProfileID`, `cachedHiddenTags` | memory | process | n/a | no |
| `CoverStore` | NSCache 96 MB | eviction | n/a | n/a |
| `URLCache.shared` 256 MB (`AppServices.swift:170`) | disk | HTTP headers | n/a | n/a |

Keys vs. `git log -p` since 2026-09-11 (`AppleBooksClient`, `GoogleBooksClient`, `WebtoonsFeedClient`, `NaverFeedClient`, `GigaViewerFeedClient` and their model files):

- **Bumped correctly**: Apple `v2→v3→v4→v5` (81eab8d, e55dd97, df43edc, 5c3f17f), Google `v1→v2` (5c3f17f), Webtoons `v1→v2→v3` (f1ba553, 434af07). Each bump is on the commit that changed the matcher or the `Codable` shape.
- **Not bumped — `5bb36b8` (2026-09-13 12:14, "Trust a release feed only as far as its shape allows")**. It changed `WebtoonsTitle.read` (finale, 외전, full-width digits) and `WebtoonsFeedParser` (French `pubDate`, never cache an empty feed) and left the Webtoons key at `v3-`. `WebtoonsFeedParser.parse` applies `WebtoonsTitle.read` at parse time (`WebtoonsFeed.swift:278`) and the parsed `number`/`season` are what the file caches (`WebtoonsFeedClient.swift:119–121`). So: any Webtoons feed cached between `434af07` (10:52) and `5bb36b8` (12:14) keeps the old numbers for up to seven days — "외전 3화" stays episode 3 — and **an empty feed cached in that window stays cached for a week, hiding the series, which is the exact bug the commit says it fixed**. The window on Abdi's own device is 82 minutes; on any other device that had the intervening build it is a week. Naver in the same commit made `no` optional and tightened the date guard (`NaverFeedClient.swift` diff) with `v1-naver-` unchanged — the shape change is additive so old files still decode, but entries whose date the new guard would have rejected stay in for a week. GigaViewer's only change in that commit was a fallback string; `v1-giga-` is fine.
- Not checked: whether `cfe6cb8` ("Type the wire from captured payloads") changed `AppleBooksVolume`'s stored shape *before* `5c3f17f` bumped to v5 — both are in the same push at 12:14:17 and `5c3f17f` is the later parent, so v5 covers it. Stated, not proven by diff.

### 4. Disk writes without full-disk handling

- Five file caches (`AppleBooksClient.swift:136–138`, `GoogleBooksClient.swift:123–125`, `WebtoonsFeedClient.swift:138–140`, `NaverFeedClient.swift:163–165`, `GigaViewerFeedClient.swift:150–152`): `createDirectory` and `write(to:options:.atomic)` both `try?`. **Handled** — a full disk costs a cache write, not a crash, and `.atomic` means no half-file. Nothing tells the reader; acceptable for a cache. They live in `.cachesDirectory`, which iOS may purge — also fine since every read is a `try?` miss.
- SQLite via GRDB: `AppDatabase.onDisk` :33–48 throws on an unopenable file → `AppServices.makeDatabase` :158–162 falls back to in-memory (**`preconditionFailure` :161 only if even that fails** — an in-memory `DatabaseQueue()` cannot realistically throw; acceptable). Every write in the repository is `try?`; `ShelfStore` writes throw to the caller (correct — a save that failed must be reported). `SQLITE_FULL` mid-transaction rolls back; no partial rows.
- `URLCache.shared` (`AppServices.swift:170`): Foundation-managed; no exposure.
- `FileManager` writes without `try`: **none found** (grep `write(to` / `createDirectory` across the slice; every hit is `try?` with `.atomic`).

### 5. Rate-limit policy

- **One gate, one client, no bypass.** `RateLimitGate()` is constructed exactly once (`APIClient.swift:22`); `APIClient(` is constructed once (`AppServices.swift:146`); no other file talks to `api.mangabaka.org` (grep `session.data(` / `mangabaka.org` outside Core → only string literals for the website). Every read *and* write goes through `perform` (:119), which checks the gate at :126 before spending a request.
- **The gate is reactive only.** It knows nothing about 30/min vs 180/min; it opens after a 429 and closes on the next 2xx (`RateLimitGate.swift:53–64`). There is no local counter, so the app cannot refuse the 31st search of a minute before the server does — it will always take one 429 to learn. `SearchModel.swift:69–71` debounces 300 ms (screen slice), which caps typing at ~3 searches/s, i.e. 30/min is reachable in ten seconds of typing.
- **One 429 closes everything.** A search 429 (30/min bucket) blocks Discover, the series page, library writes — all on the 180/min bucket that was not exhausted — for the `Retry-After` or 2…60 s exponential (:55). Defensible (shared IP) but it means a fast typist locks the whole app for up to a minute, and the screen they are on says "Too many requests" for a bucket it never touched.
- Third parties each keep their own `RequestSpacing` (AniList 0.7 s, Shikimori 0.25 s, MangaUpdates 3 s, Apple/Google/feeds 3.5 s). A 429 there is honoured by **sleeping the next caller** (`RequestSpacing.backOff` → `claim` returns the wait), not by refusing — so a series page opened during an Apple Books backoff waits up to 60 s for a shelf that then says nil.
- `CoverStore` has no gate at all; a CDN 429 is retried once immediately (:106–116).
- A 429 from a *write* (`send` :272) is recorded like any other; the write is not retried and the reader gets `.rateLimited` — correct, because a blind retry could double-apply.

### 6. Network calls at launch

All fire from `.task` modifiers after the tab view is on screen; **nothing blocks the tabs on the network**. Blocking work at launch is `AppServices.init` (`AppServices.swift:45`): SQLite open + migrations (:158, measured per its comment) and the Keychain read for `applyStoredFilters` — no network.

| Order | Call | Where | Requests | Blocks anything? |
|---|---|---|---|---|
| 1 | `library.profileID()` → `GET /v1/my/profile` | `AppServices.swift:203` (unstructured `Task` :196) | 1 — **sent even with no token** (`ResolvingTokenProvider` :40 returns nil, the request goes out and 401s). One wasted request per launch against the shared 180/min for every signed-out reader | no |
| 2 | `repository.feed(.rising)` | `RootView+Session.swift:139`, only while onboarding is incomplete | 0–1 (cache first) | blocks `refreshReminders` behind it (sequential :139→:144) |
| 3 | `refreshReminders()` → library walk | `RootView+Session.swift:144` → `LibrarySnapshot.load` :81 | 0 (disk) or 1–13 pages of `/v1/my/library` | Spotlight reindex :147 waits on it; nothing visible does |
| 4 | `characters.primeAniListHealth()` → `POST graphql.anilist.co` | `RootView.swift:107` | 1 | no; up to 60 s against a hung AniList |
| 5 | `taste.ranker()` → `favouredTagIDs` → library walk | `RootView.swift:265` | joins #3's in-flight task via `LibrarySnapshot` (if `buildIDs` uses the snapshot — `TasteProfile.swift:82–83` passes both `library` and `snapshot`; not verified which it walks) | the stack's ranker; stack draws without it |
| 6 | Discover's first feed loads | `DiscoverModel` — screen slice | 4 feeds (cache first) | no |

A reviewer on a slow connection reaches the tabs immediately; the first thing they can *see* fail is Discover, which carries `staleAfter` + `cachedAt` and so has what it needs to explain itself.

## Traps (crash-reachable from real input)

Grepped `!` (not `!=`), `Int(`, `[0]`, `.first!`, `fatalError`, `precondition`, `try!`, `as!`, `URL(string:` across the 31 files and read each hit.

- `preconditionFailure` on hard-coded URL literals: `AppServices.swift:215`, `AniListClient.swift:207`, `SeriesCharacter.swift:195`, `AppleBooksClient.swift:144`, `GoogleBooksClient.swift:131`, `MangaUpdatesClient.swift:167`. Compile-time constants; not reachable from input. **Not a trap.**
- `AppServices.swift:161` `preconditionFailure` if an in-memory `DatabaseQueue()` cannot open. Not reachable from input.
- `Int(` on input: `APIError.swift:33,36` — `Int(seconds.rounded())` where `seconds` is `TimeInterval` from `Retry-After`. `parseRetryAfter` :464 clamps to `max(_, 0)` but **not to a maximum**: `Retry-After: 1e300` parses as `TimeInterval`, is capped by `RateLimitGate.maxHonouredRetryAfter` before display (:170) — so `humanDuration` never sees it. A `Retry-After: inf` → `TimeInterval("inf")` = `.infinity` → `max(inf, 0)` = inf → `min(inf, 900)` = 900. Safe. A `nan`: `TimeInterval("nan")` = NaN → `max(NaN, 0)` returns 0 in Swift (`max` picks the second when comparison is false) — actually `max(x, y)` returns `y >= x ? y : x` → `0 >= NaN` false → returns NaN → `min(NaN, 900)` → `900 < NaN` false → returns NaN → `Int(NaN.rounded())` **traps**. Reachable from the wire only if MangaBaka sends `Retry-After: nan`, which no server does. **Theoretical; one `guard seconds.isFinite` closes it.** Same path at `RateLimitGate.recordRateLimit` :56 (`addingTimeInterval(NaN)` does not trap; `secondsUntilAllowed` :27 returns NaN, `NaN <= 0` false → returns NaN → `.rateLimited(retryAfter: NaN)` → `countdown` :142 `NaN > 0` false → nil. No trap there.)
- `MangaUpdatesClient.swift:47` `Int(volume.trimmingCharacters…)` — failable `Int(String)`, safe. `:70` `Double(digits)` failable, safe.
- `BlurHash.swift:61,66,73,77` — subscripts on `Array(hash)` guarded by `count >= 6` :58 and `count == 4 + 2·cx·cy` :64 before any index; `:36` guarded by `count >= 6`. `render` :109–111 `UInt8(linearTosRGB(…))` where `linearTosRGB` clamps to 0…1 then ×255 + 0.5 → 0…255.5 → `Int` ≤ 255. **Safe.**
- `ReleaseSchedule.swift:219` `now.timeIntervalSince(row.fetchedAt)` — no trap.
- `CharacterService.swift:154` `Int(raw)` failable. Safe.
- `SeriesRepository+Cache.swift:145` `Dictionary(uniqueKeysWithValues:)` — **traps on duplicate keys**; `rows` come from `CachedSeries.filter(ids.contains(Column("id")))` on a table whose primary key is `id` (`AppDatabase.swift:62`), so duplicates are impossible. Safe by schema.
- `try!`, `as!`, `.first!`, `fatalError`: **none found** in the slice.
- `URL(string:)` on input: `AniListClient.swift:186,355,361` and `GigaViewerFeedClient.swift:101` all optional-chained. Safe.

## Done well (leave alone)

- `APIClient.perform` :119–174 — one path for reads and writes; three offline codes; ledger before status check; 429 recorded before throwing; displayed `retryAfter` capped to match the gate :170.
- `RateLimitGate` — refuses locally before spending a request (:126), honours `Retry-After` in both RFC forms (`parseRetryAfter` :462), caps at 15 min with the cap labelled a guess (:37–45), only a 2xx reopens (:192–195).
- `APIClient.total` :99 — decodes only the pagination block so a count cannot be lost to a row-shape change; nil is "unknown", never 0.
- `FeedResult` :285–323 — `origin`, `cachedAt`, `hasMore` from the API's own `next`, and `blockingError` that fires only when there is nothing to show. This is the model the rest of the slice should copy.
- `SeriesRepository+Cache.swift:154–162` — a feed row that fails to decode misses the whole read instead of silently shortening the feed (comment records the 20→14 bug).
- `CacheScope` / `apply` (`+Cache.swift:62–87`) — one invalidation policy, declared.
- `updateLibraryExclusion` :538 — compares against the id the cache was *written* under, persisted; both wrong guesses are documented.
- `CatalogueService.genres/tags` — in-flight joining :47/:67, failure not cached :56, limit-keyed cache :66.
- `CatalogueService.searchTags/findPublisher/publisher` — nil vs `[]` distinguished and documented (:107–108, :125–128).
- `LibraryService.libraryPage` :169 (typed throw beside the swallowing `library`), `hiddenTagIDs` nil-means-withhold :224–226, `LibraryChange` double-optional :65–67, empty change is a no-op :286.
- `AniListClient` — GraphQL errors-in-200 handled :150; empty cast not preferred over the other source :160; cancellation during the slot wait is a typed error :194–202; health check uses a real media id with the rejected alternatives recorded :367–375.
- `CharacterService.isAniListOutage` :141 — only 403/5xx mark AniList down; the 200-with-no-cast case that used to black out AniList for 15 min is fixed and documented.
- `RequestSpacing` :12–31 — claim-before-wait, with the 96 µs measurement in the comment.
- `AppleBooksClient` — 403 treated like 429 :102; `releaseDate` as `String` so one bad row cannot fail 200 :108–111; nil vs `[]` contract :34–35; versioned keys with the reason for each bump :42–45.
- `WebtoonsFeedClient` :71–79 — never caches an empty feed; tries the English variant then the landed one.
- `ReleaseScheduleService` — failure rows are retried, null cadences are settled (`AppDatabase.swift:105–124`, `ReleaseSchedule.swift:306–307`); `Scope.failure` keeps "offline" from reading as "no library" :163–168; `Task.isCancelled` per series :313; `progress.isRunning` set before the task starts :266.
- `CoverStore` — never caches a failure :19–22, one retry, 404 settled :115, decode off the main actor :93–104.
- `AppDatabase.onDisk` → in-memory fallback (`AppServices.swift:154–163`) — a corrupt cache costs offline support, not the launch.
- Every file cache write is `try?` + `.atomic` in `.cachesDirectory`.
- `ShikimoriClient` base host moved to `.io` with the redirect measured :125–130.

## Proposed fixes, grouped by file

Each with the test that proves it. Tests use the existing `URLProtocolStub` (`MangaBakaTests/URLProtocolStub.swift`) and `TestClock`.

### `Core/Networking/APIError.swift`

1. **Add `case cancelled`** (or a `isCancellation` flag on `.transport`) and map `URLError.cancelled` to it in `APIClient.perform` :146, `AniListClient` :121/:302, `ShikimoriClient` :155, `MangaUpdatesClient` :122. `staleContentRemainsUseful` → true, `userFacingMessage` → never shown (callers drop it). *Test:* stub a request whose handler waits; cancel the task; `#expect(error == .cancelled)`; then `SeriesRepository.feed` on a cancelled fetch returns `origin == .cache` (or `.staleAfter(.cancelled)` with `blockingError == nil` when the cache is non-empty). Fails today: the error is `.transport("…cancelled…")` and `staleContentRemainsUseful == false`.
2. **Carry the party.** Add `party: Party` (`.mangaBaka, .aniList, .shikimori, .mangaUpdates`) to `.server` and `.rateLimited`, defaulting to `.mangaBaka`, and use it in `headline` :130 and `needsAccount` :52 (only MangaBaka's 401/403 means "needs an account"). *Test:* `APIError.server(status: 403, message: "AniList returned 403.", party: .aniList).headline == "AniList had a problem"` and `.needsAccount == false`. Fails today: headline says MangaBaka, `needsAccount` is true.
3. **Strip status codes from `userFacingMessage`** for non-MangaBaka parties (the "documented safe to show" promise at :19–21 is MangaBaka's, not AniList's). *Test:* no `userFacingMessage` in the family matches `/returned \d{3}\./`.
4. `humanDuration` :31 — `guard seconds.isFinite else { return "a moment" }`. *Test:* `APIError.rateLimited(retryAfter: .nan).countdown` does not trap (today `countdown` guards `> 0` so it is nil; the trap is only via a direct `humanDuration` call — make the guard explicit so the next caller cannot reach it).

### `Core/Networking/APIClient.swift`

5. **Set a timeout.** `request.timeoutIntervalForRequest`-equivalent: `URLRequest.timeoutInterval = 20` in `makeRequest` :377 (and 15 in the six third-party clients, or one shared `URLSessionConfiguration`). *Test:* stub a handler that never responds under a session with the configured timeout; `#expect` the call throws `.transport` within 25 s — and, before the change, that it is still pending at 25 s (the "prove it fails first" run). Practical impact: today a series page on a flaky connection can spin for a full minute per leg.
6. **Do not send `/v1/my/profile` with no token.** In `profile()`/`verifiedProfile()`, or better in `LibraryService.profileID` :138, short-circuit when `tokenProvider.authorizationHeader()` is nil. *Test:* `UnauthenticatedTokenProvider` + `URLProtocolStub.requests.count == 0` after `profileID()`. Fails today: one request, one 401, per launch.

### `Core/Persistence/SeriesRepository.swift`

7. **`extras(for:)` — do not cache a partial.** Track per-leg failure in `fetchExtras` (six `Result`s instead of six `try?`) and either skip the cache when any leg failed, or cache with a `failedLegs: Set<String>` so the screen can show an inline note per section. *Test:* stub `/works` → 429, others → fixtures; `extras` twice with `TestClock` advanced 1 s; `#expect(URLProtocolStub.requests` contains a second `/works`). Fails today: `/works` is asked once and `volumes == []` is served from cache for six hours.
8. **`images(for:)` :651 — return `[SeriesImage]?`** (nil = failed) and let `cachedImages` hold only real answers. *Test:* stub 429 → `nil`; stub `[]` → `[]`.
9. **`mix` :429 — return the error.** `MixResult.failure: APIError?` set in the `catch` :463. *Test:* stub offline → `result.failure == .offline`, `recommendations.isEmpty`.
10. **`feedPage` :15 (+Paging) — `hasMore` on failure should be `true`,** not the default `false`, so the row can retry rather than quietly end. *Test:* stub page 2 → 500; `#expect(result.hasMore)`; today it is `false`.
11. **`apply` / `updateLibraryExclusion` — surface a failed discard.** Return `Bool` from `discardCachedFeeds` callers and log via the ledger, or at minimum `assertionFailure` in debug. *Test:* inject a read-only `DatabaseWriter`; `#expect(await repository.updateContentRatings(["safe"]) == false)`.

### `Core/Persistence/SeriesRepository+Cache.swift` and `ShelfStore.swift`

12. **`ShelfStore.entries` :46 — do not drop undecodable rows silently.** Mirror `+Cache.swift:154–162`: throw, or return `(series, undecodable: Int)`. *Test:* insert a row with `payload = "{}"`; `#expect(throws:)` or `undecodable == 1`. Today: the shelf is one shorter and nothing says so.

### `Core/Library/LibraryService.swift`

13. **`recommendations` :198 — return the envelope flags.** `struct PersonalRecommendations { items; coldStart: Bool; profileStale: Bool; failure: APIError? }`. *Test:* fixture with `cold_start: true, results: []` → `coldStart == true, failure == nil`; stub 429 → `failure == .rateLimited`. Today both are `[]`.
14. **`recommendationStatus` :180 — typed throw** (a `throws(APIError)` twin like `libraryPage`). *Test:* stub offline → throws `.offline`; today nil.

### `Core/Volumes/AppleBooksClient.swift`, `GoogleBooksClient.swift`, `Core/Schedule/{Webtoons,Naver,GigaViewer}FeedClient.swift`

15. **Honour cancellation in the slot wait** (six sites: Apple :85, Google :76, Webtoons :59/:103, Naver :43, Giga :104). Replace `try? await Task.sleep` with `do { try await Task.sleep } catch { return nil }`. *Test:* `TestClock`, claim a slot so `wait > 0`, cancel the task before it resumes; `#expect(URLProtocolStub.requests.isEmpty)`. Fails today: the request is sent after the cancelled sleep.
16. **Expose age on the file caches.** Return `(volumes, storedAt)` from `readCache` so a StaleBar can say "a week old" — the Apple key doc at :42–45 already reasons about a week of stale matches. *Test:* write with `TestClock` at T, read at T+6d → `storedAt == T`.
17. **Apple 403 vs 429** :102 — record which; a store-region 403 should not back off 60 s and should tell the caller "not sold in your store" rather than nil. *Test:* stub 403 → result is `.unavailableInStore` (new case) and the next call does not sleep.
18. **Bump Webtoons to `v4-`** (:51) for `5bb36b8`'s parser change, and Naver to `v2-naver-` for the date-guard change; add a comment naming the commit as the other bumps do. *Test:* a `WebtoonsFeedParser` fixture containing "외전 3화" cached under `v3-` must not be served — i.e. `readCache("v3-…") == nil` after the bump because the key no longer matches. (The real proof is the git diff of the key line; the test is that `WebtoonsTitle.read("외전 3화").number == nil`, which already exists per the commit message.)

### `Core/Schedule/MangaUpdatesClient.swift`

19. **Match `APIClient`'s three offline codes** :120 (`.networkConnectionLost`, `.dataNotAllowed`). *Test:* stub `URLError(.networkConnectionLost)` → `.offline`; today `.transport`.

### `Core/Schedule/ReleaseSchedule.swift`

20. **`cadence(for:)` :377 — return `.failed(APIError)`** instead of `.none` in the catch. *Test:* stub MangaUpdates → 503; `#expect(await schedule.cadence(for: series) == .failed(.server(503, …)))`; today `.none`, which the screen renders as "not enough history".
21. **`progress.failure` :330 — keep the `APIError`,** not its `userFacingMessage` string, so the screen can use `headline`/`symbolName` and the party fix (#2) reaches it.

### `Core/Characters/AniListClient.swift`, `SeriesCharacter.swift`

22. **Map offline to `.offline`** (AniList :121, Shikimori :155) with the same three codes. *Test:* stub `URLError(.notConnectedToInternet)` → `.offline`. Practical impact: today a series page opened offline treats the cast as a shape failure and `staleContentRemainsUseful` says to hide any cached copy.
23. **Empty cast is not `.server`** (:161) — return `[]` and let `CharacterService` decide to fall through. *Test:* fixture with `edges: []` → returns `[]`, `lastOutcome` still `.shikimori` after fallback.

### `Core/Networking/RateLimitGate.swift`

24. **Two buckets, or a local counter.** At minimum a sliding-window counter for `/v2/series/search` at 30/min so the 31st search is refused locally with `.rateLimited(retryAfter: secondsUntilWindow)` and Discover keeps working. *Test:* 30 searches in one `TestClock` second succeed; the 31st throws `.rateLimited` with `URLProtocolStub.requests.count == 30`; a `/v2/series/discover/rising` in the same second still goes out.

### `App/AppServices.swift`

25. `applyStoredFilters` :196 — the unstructured `Task` is unobservable; if `updateLibraryExclusion`'s `try? discardCachedFeeds()` fails, nothing knows. Covered by #11.

## Top gaps

1. `extras(for:)` caches a five-of-six partial for six hours — one rate-limited leg blanks a section of the series page and stays blank (`SeriesRepository.swift:679, 699–716`).
2. `APIError` speaks for MangaBaka only: AniList/Shikimori/MangaUpdates failures get "MangaBaka had a problem", an AniList 403 reads as "needs an account", and neither AniList nor Shikimori can ever say "offline" (`APIError.swift:52,130`; `AniListClient.swift:122`).
3. No timeout anywhere and cancellation is a transport error — a hung host holds a leg for 60 s, and leaving a screen mid-load is reported as a failure (`APIClient.swift:146`; zero `timeoutInterval` hits).

Then: the six swallowed `Task.sleep` cancellations that fire third-party requests for a page the reader left; `5bb36b8` shipped a Webtoons parser change under the unbumped `v3-` key.
