# Perf review — `persistence` slice (what is kept)

Read-only, 2026-09-15, HEAD 1f5e632. Nothing built, run or edited; every line number below is from reading the file today.

**Summary**
- Files reviewed: 17 of 17 (`Core/Persistence/*` 13 files, `LibrarySnapshot.swift`, `Core/Settings/*` 3 files), plus the call sites in `AppServices`, `AppIntents`, `ScheduleModel`, `SeriesDetailView`, `DetailCacheDiscardTests` that a claim needed.
- Findings: 14 — certain 8, likely 3, worth checking 3. Three prior findings re-verified at new lines and marked as such, not re-counted.
- Highest-value change: **P1** — the `.detail` cache is thrown away on every content-rating and blocked-tag change for a reason that is no longer true (the detail cache holds nothing those filters touch; the page filters at display time). Each toggle costs up to 200 cached series pages, i.e. up to 8 requests per re-open, and a ~40 MB `DELETE` inside the repository actor.
- Second: **P2** — per-series feeds (`series/N/similar`, `series/N/readers-also-like`) are never aged out or capped; `feedEntry` and `series` grow with every series page ever opened, and `trimOrphans` scans both on every feed write.
- Cheapest: **P5** — three cache writes that fail silently and convert a disk error into a permanent network cost (`write`, `writeDetailCache`, `LibrarySnapshot.writeCache`). One `Logger.error` each.

---

## Findings

### P1 — Rating and blocked-tag changes discard a detail cache they do not affect
- **What** — `updateContentRatings` invalidates `.everythingDerived` (feeds, images, detail) and `updateBlockedTags` invalidates `[.feeds, .detail]`, on the stated grounds that the detail cache "holds rating- and tag-filtered tags, editions and images". It holds none of those filtered: `SeriesExtras` is links, news, relationships (state-filtered only), tags, richTags, editions (sorted, not filtered), volumes, worksTotal, year, full — and images are not in it at all.
- **Where** — `SeriesRepository.swift:642-643` (ratings → `.everythingDerived`), `:656-658` (blocked tags → `.detail`, "those live in the detail cache"); `SeriesRepository+Cache.swift:103-106` and `:125-127` (the claim); `SeriesRepository.swift:234-236` (`CodingKeys` — no images); `:941-944` (the `full` leg sends no `filterQuery`, so cached tags are unfiltered); `:968` → `SeriesEdition.swift:177-185` (`presentable` is a sort); `Series.swift:444-446` (`isDiscoverable` is `state == "active"`, not a rating). The page filters tags **at display time** from the cached `richTags` with the *current* rating: `SeriesDetailView.swift:643-647` (`TagGrouping.groups(from: extras.richTags, allowedRatings: contentRatings, …)`). No file under `Features/Detail` reads blocked tags at all (grep, 2026-09-15).
- **Why it matters** — a reader who toggles Erotica or blocks a tag in Settings loses every cached series page: the next open of each previously-visited series is 8 MangaBaka requests instead of 0 (`docs/reviews/detail-page-budget.md`), for up to `detailRowLimit = 200` pages. The refetched page carries the same unfiltered tags, then filters them at display exactly as the cached copy would have. The discard itself is `DELETE FROM seriesDetail` over up to 200 × 204 KB (`+Cache.swift:436-442`, measured) inside the actor, so a series page opened during the toggle waits behind it. `DetailCacheDiscardTests.swift:6-7` restates the false premise — charter pattern 2, a test that agrees with the comment.
- **Effort** — a line each: drop `.detail` from `updateContentRatings` and `updateBlockedTags`, fix the three comments and the test doc. Keep `.images` on ratings (`imagesResult` really does filter by rating at `:812`).
- **Confidence** — certain on the mechanism; likely on "nothing depends on it" (I found no consumer of cached extras that assumes rating-filtered content; a reviewer who knows one should say so before the line is deleted).

### P2 — Per-series feeds are never aged or capped, so `feedEntry`/`series` grow forever
- **What** — `trimOrphans` deletes series rows no feed points at; nothing deletes a *feed*. `feedMetadata`/`feedEntry` rows for `series/N/similar` and `series/N/readers-also-like` are written once per series page opened (24 + 24 rows) and removed only by a filter change or a re-fetch of the same feed.
- **Where** — `SeriesRepository+Cache.swift:428-430` (`trimOrphans`: only series rows), `:312-343` (`write`: replaces one feedKey, never trims another), `:194-209` (the only feed-wide delete, on filter change); `AppDatabase+Schema.swift:41-46, 51-54` (no age column consulted anywhere); contrast `trimDetail` `:444-451`, which caps the detail table at 200.
- **Why it matters** — at the measured 2.9 KB per feed payload (`docs/reviews/full/persistence.md:127`, 854 KB / 294 rows) each series page opened leaves up to 48 `feedEntry` rows and up to 48 distinct `series` rows (~140 KB) behind for good. **GUESS**: a reader who has opened 500 series holds ~24,000 `feedEntry` rows and tens of MB of `series` rows that nothing will read again (24 h freshness, `:386`). Two costs compound: `trimOrphans`' `NOT IN (SELECT seriesId FROM feedEntry)` builds a temp b-tree over all of `feedEntry` and scans all of `series` on **every** feed write — including every `.surprise` deal (freshness 0, `:401`) — and `cachedSeriesCount` (`SeriesRepository.swift:697-701`, Discover's subtitle) counts the accumulation as "series cached".
- **Effort** — a function: in `write`, after the metadata save, `DELETE FROM feedMetadata WHERE cachedAt < ?` (say 7 days — label it a guess) with a matching `feedEntry` delete, then `trimOrphans`; or cap `series/%` feeds at N most recent the way `trimDetail` does. An index on `feedEntry(seriesId)` would make `trimOrphans` cheap either way (`v12` dropped the redundant `feedKey` one; `seriesId` has none).
- **Confidence** — certain by reading; the growth rate is a guess. What settles it: `SELECT COUNT(*), SUM(LENGTH(payload)) FROM series` and `SELECT COUNT(DISTINCT feedKey) FROM feedMetadata` on the real simulator file.

### P3 — Adding a defaulted, non-optional field to `SeriesExtras` silently wipes the detail cache
- **What** — `SeriesExtras` uses synthesized `Decodable`. Swift's synthesized `init(from:)` does **not** honour a property's default value: a missing key throws `keyNotFound`. So every cached row written before a new `var x: [T] = []` field existed fails to decode, `try?` turns that into a miss, and the page is refetched (8 requests) and rewritten. `richTags`, `editions`, `volumes` and `worksTotal` each landed after `v6` and each did this once, invisibly.
- **Where** — `SeriesRepository.swift:185-237` (synthesized; `worksTotal: Int?` at `:210` is the one field that was added safely); `SeriesRepository+Cache.swift:31` (`try? JSONDecoder().decode(SeriesExtras.self …)` — no log); `:81` says "`SeriesExtras` always encodes the key, so no `decodeIfPresent`", which is true of `links` (since v6) and not of `volumes` (`CachedVolumes`, `:87-89`).
- **Why it matters** — after any build that adds a field, every reader's first re-open of every recently-visited series is a cold open. The 6-hour TTL bounds the damage to one refetch per page, and nothing on record says it happened. The same shape applies to `FeedEntry.note` (`Data?`, safe) and to `Series` (custom decoder — not reviewed here).
- **Effort** — a function: a hand-written `init(from:)` on `SeriesExtras` using `decodeIfPresent` with the defaults, or a rule "new `SeriesExtras` fields are Optional". Plus the one log line in P5.
- **Confidence** — certain on the Swift semantics; certain that four fields were added after `v6` (`AppDatabase+Schema.swift:85-98` vs `SeriesRepository.swift:197-210`).

### P4 — `AppIntents.feedDueWorks` decodes a whole `SeriesExtras` per scheduled work to read `links`
- **What** — the one-hop partial-decode read `cachedExtrasLinks(for:)` exists for exactly this; `feedDueWorks` loops `cachedExtras(for:)` instead, one actor hop and one full 204 KB-median decode per work, then uses `.links` only.
- **Where** — `AppIntents.swift:84-90` (the loop) called from `AppIntents.swift:56` (Siri) and `ScheduleModel.swift:422` (`writeWidgetSnapshot`, every schedule measurement); the batched read at `SeriesRepository+Cache.swift:45-47`, whose doc at `:37-41` records that the per-entry form was "939 actor hops on the launch path".
- **Why it matters** — `snapshot.dated` is every library series with a date, so on a large library this is hundreds of sync SQLite reads and full decodes inside the repository actor while the Schedule tab is open, serialising any series-page open behind them. (Outside the slice's file list but inside its question — "where is `cachedExtrasField` NOT used and should be".)
- **Effort** — a function: one `cachedExtrasLinks(for: works.map(\.series.id))` before the loop.
- **Confidence** — certain.

### P5 — Three cache writes fail in silence and turn a disk error into a permanent network cost
- **What** — `try?` on the write, nothing logged, and the caller behaves as if the write succeeded.
- **Where** — `SeriesRepository.swift:612` (`try? write(discoverable, …)` — a failed feed write means the feed is fetched unconditionally on every visit, since `existing.lastModified` is then nil); `:868` (`try? writeDetailCache` — every open of that series is 8 requests, forever); `LibrarySnapshot.swift:354` (`try? database.cacheWriter.write` — every launch walks 24.7 MB); also `:411-412` (`writeSingleEntry`), `:453` (`remove`), `:467` (`invalidate`). The feeds file already has `cacheLogger` (`+Cache.swift:179`) and uses it for the *discard* half (`:206, :228`) — the write half never got the same treatment.
- **Why it matters** — a full disk, a locked file or a `SQLITE_FULL` inside `trimOrphans` produces an app that works perfectly and spends its whole request budget re-fetching what it just fetched. The symptom the reader sees is "too many requests" cards; the cause is on no log anywhere. This is the persistence-side twin of gap 74, which fixed exactly this for discards.
- **Effort** — a line each: `do { try write(…) } catch { Self.cacheLogger.error("feed write failed: …") }`, same for the other two. A counter (writes failed since launch) in `NetworkLedger`'s style would make it findable from a device.
- **Confidence** — certain.

### P6 — `feed` writes the page to disk before returning it to the screen, inside the actor
- **What** — on a network hit, `write(...)` (N encodes, N `save` = up to 2N statements, `DELETE`, N `INSERT`s, metadata `save`, `trimOrphans`) runs synchronously before `return`; every other repository call queues behind it.
- **Where** — `SeriesRepository.swift:612-613`; `+Cache.swift:323-342` (`save` at `:327` is UPDATE-then-INSERT for a new row; `trimOrphans` at `:341`). Same shape for the detail page: `SeriesRepository.swift:867-870` — a 204 KB encode plus a write and `trimDetail` between the last leg landing and the page drawing.
- **Why it matters** — for a 30-row page (~87 KB at 2.9 KB/row, ~92 statements, one WAL commit) this is **GUESS** 5–15 ms on device before the row draws; for `.surprise`/`.mix` it is 50 rows per deal, and the stack deals in the background while the reader taps into series pages, whose `readDetailCache` then waits behind the deal's write. The detail write is **GUESS** 10–30 ms (encode 204 KB + commit + fsync) added to the page's time-to-content. Neither number exists — there is no signpost in this slice (see D2).
- **Effort** — a function: return first, then write from a `Task` on the actor (the actor's serialisation still orders it after the return); or switch `save` to `insert` with `ON CONFLICT DO UPDATE` to halve the statements. Measure first.
- **Confidence** — certain that the order is write-then-return; the ms are a guess.

### P7 — The Stack's blend sends blocked tags under a different key than the Mix screen does
- **What** — `feed(.mix)` builds its query with `filterQuery()` at the default `blockedTagParam: "tag_not"`; `mix()` in `+Mix.swift` insists on `"blocked_tag"` for the same preference on the same endpoint, and `filterQuery`'s own doc says sending the wrong key is "a filter the endpoint silently ignores".
- **Where** — `SeriesRepository.swift:577-581` (`.mix` → `blendExclusionQuery` + `filterQuery()`), `:760-767` (the doc), `:305` (`.mix.path == "/v1/series/mix"`); `+Mix.swift:30-31` (`blocked_tag`); `StackModel.swift:734` (the stack uses `feed(.mix)`).
- **Why it matters** — if `/v1/series/mix` ignores `tag_not` for standing blocks the swipe stack shows blocked tags the Mix screen hides. `+Mix.swift:32-37` says `tag_not` *does* exclude strands on mix (proven live), so the two keys may be equivalent — but one preference under two names on one endpoint is the shotgun-surgery hazard the function was written to close.
- **Effort** — a line: `filterQuery(blockedTagParam: feed.path.hasPrefix("/v1/series/mix") ? "blocked_tag" : "tag_not")`, or a `FeedKind.blockedTagParam`.
- **Confidence** — worth checking: one live request with a blocked tag under each key.

### P8 — `LibrarySnapshot.load()`'s cache-hit path never releases the page observer
- **What** — the disk-cache branch calls `onPage?(stored.entries)` and returns; only `finish` sets `onPage = nil`. The comment at `:206-209` explains why leaving it attached is wrong ("keeps the last screen's closure alive for the life of the app").
- **Where** — `LibrarySnapshot.swift:162-166` vs `:205-209`.
- **Why it matters** — one retained closure (and whatever `LibraryModel` captured in it) per launch on the common path. Small, but it is the exact leak the code says it avoids.
- **Effort** — a line.
- **Confidence** — certain.

### P9 — `vacuumIfBloated` runs on the main thread at every launch and triggers on any large delete
- **What** — the retry added for night finding §4 checks `freelist_count` on every open and `VACUUM`s the reader's file when >256 pages are free — not only after the one-time move, but after any delete that frees 1 MB: sign-out (`ShelfStore.clear`, `HistoryStore.clear`, `TasteLedger.clear`), `v11_recountTaste`, a long history trim.
- **Where** — `AppDatabase+Split.swift:302-311, 351-356`; reached from `AppDatabase.swift:150-151` ← `:263` ← `AppServices.swift:147, 373` (`makeDatabase`, `@MainActor init`, inside the "Database open" signpost).
- **Why it matters** — a VACUUM is a full file copy, synchronous, before the first frame. On a reader's file of a few MB that is **GUESS** 20–100 ms on device; the threshold is honestly labelled a guess (`:347`). The "Database open" signpost already brackets it, so the number is one launch away.
- **Effort** — a measurement first; if bad, a line (raise the threshold, or run it from a background task after first paint — VACUUM needs no other writer, and nothing writes the reader's file until a tap).
- **Confidence** — worth checking.

### P10 — `readCacheWithDate(requireFresh:)`'s `true` branch is dead
- **What** — the only production caller passes `false`; the freshness check moved into `feed` (whose comment says so: "which this replaces").
- **Where** — `SeriesRepository+Cache.swift:248-264` (the parameter and branch); `SeriesRepository.swift:555` (the only caller), `:559-560`. No test passes `true` (grep).
- **Effort** — lines: delete the parameter and the branch.
- **Confidence** — certain.

### P11 — Dead code still alive in the slice
- `AppDatabase.OpenResult.init(database:wasReset:)` — `AppDatabase.swift:203-205`; no caller in app or tests (grep 2026-09-15; the tests use `outcome:`). Delete.
- `LibrarySnapshot.all()` / `seriesIDs()` — `LibrarySnapshot.swift:293-306`; deprecated with "delete both once the last call site has moved". Warnings-as-errors means no app caller remains; the one test reference is a comment (`SessionTests.swift:84`). Delete.
- `TestClock` — `Clock.swift:16-34`, a test double compiled into the app target; 175 uses, all in tests. Move to the test target.
- **Effort** — lines. **Confidence** — certain.

### P12 — `LibrarySnapshot.writeCache` skips a row that fails to encode and the read then reports the shrunk library as whole
- **What** — `guard let payload = try? encoder.encode(entry) else { continue }` drops the row; `readCache`'s completeness check compares decoded count to *row* count, so a table written short is read back as complete.
- **Where** — `LibrarySnapshot.swift:359` vs `:337`.
- **Why it matters** — gap 116 closed the decode side and left the encode side open. Encode failures are rare (a non-finite `Double` is the realistic one), so this is a hole, not a live bug.
- **Effort** — a line: throw instead of `continue`, so the whole write fails (and, with P5, logs).
- **Confidence** — likely (certain on the mechanism, no known input that trips it).

### P13 — Underived numbers that shape output
- `limit=6` for the news leg — `SeriesRepository.swift:932`; no derivation, no `guess` label.
- `.trending, .mix: 3_600` and `.newReleases: 1_800` freshness — `:389, :392`; reasoned ("an hour keeps them lively"), not measured, not labelled. The other four are derived from `x-cache-ttl-cdn-seconds` (`:379-386`) — the same file shows what the label should look like.
- `pageCap = 30` — `LibrarySnapshot.swift:25`: "far past any real library" — a guess with its reason; the label is missing.
- **Effort** — a word each. **Confidence** — certain.

### P14 — Sync GRDB inside actors: still true at new lines, with one new consequence (prior F16, do-not-fix without U10)
- **Where now** — `SeriesRepository+Cache.swift:25, 93, 196, 222, 252, 323, 408` (sync `read`/`write`); `LibrarySnapshot.swift:311, 354, 412, 453, 467`; the only async reads in the slice are `+Cache.swift:63` and `EditionAnswerStore.swift:112`.
- **New consequence** — `DiscoverModel.swift:118` fetches the four rows concurrently, but each `feed` call's cache read is sync inside one actor, so the four reads serialise and `DatabasePool`'s reader connections are never used in parallel. The async overload would let them overlap. Still unmeasured; U10 is the measurement, and D2 below is the cheap way to get most of it.
- **Confidence** — worth checking (unchanged).

---

## Requests in flight (this slice)

| Call | Path | Trigger | Priority | Awaited before drawing? | Could be |
|---|---|---|---|---|---|
| `feed(.rising/.hiddenGems/.trending/.newReleases)` | `/v2/series/discover/*`, `/v2/series/search` | Discover load, 4 rows concurrently (`DiscoverModel.swift:118`); single-row retry `:208` | `.userInitiated` (`SeriesRepository.swift:530-531`) | Cache hit returns without network (`:557-572`); miss → network → **disk write** → return (`:612-613`) | 304 revalidation already (`:593-595`); write could follow the return (P6) |
| `feed(.similar/.readersAlsoLike)` | `/v2/series/{id}/similar`, `…/readers-also-like` | Series page open (`SeriesDetailView.swift:565`, per budget doc) | `.userInitiated` | Same as above; 24 h TTL | `.background` — both rows render below the fold (budget doc (d)) |
| `feed(.mix/.surprise)` | `/v1/series/mix`, `/v2/series/search?sort_by=random&schema=full` | Stack refill (`StackModel.swift:734`) | Caller's choice; `.surprise` never fresh (`:401`) so every deal is a request + 50-row write | Yes, then 50-row write before return | Write after return; see P7 for the blocked-tag key |
| `feedPage` | as feed, `page=N` | Discover row prefetch | `.background` from `DiscoverModel` (`:48-52`) | Not cached, never | On `.rateLimited` return `hasMore: true` already (`+Paging.swift:44-50`) — good |
| `search` | `/v2/series/search` | Search screen, `PublisherFollows.check` | `.userInitiated` / `.background` | Never cached (by design, `:28-31`) | — |
| `count` | `/v2/series/search?limit=1` | Lens counts, publisher total | `.background` / `.userInitiated` | `try?` → nil, no log (`+Count.swift:40`) | Log the failure kind |
| `mix()` | `/v1/series/mix` | Mix screen (`MixModel.swift:153`) | default `.userInitiated` (`getRoot` takes none, `APIClient.swift:376-380`) | Not cached; failure carried (`+Mix.swift:54`) | — |
| `extras` → 5 legs | `/v1/series/{id}` (+`/news`, `/relationships`, `/collections`, `/works`×1–2) | Series page open | `full`, `works` p1 `.userInitiated`; news/relationships/collections/works p2 `.background` (`:928-957`, `+Works.swift:39-41`) | All five awaited together (`:959`), then **detail write** (`:868`), then return | Cache the partial (see rate-limit section) |
| `imagesResult` | `/v1/series/{id}/images?limit=50&language=…` | Series page covers (`SeriesDetailView+Covers.swift:42`) | `.userInitiated` (no priority passed, `:806-808`) | In-memory `BoundedCache` (200) only; nothing on disk | Persist in the detail row, or `.background` — the fan is below the hero |
| `relationships` | `/v1/series/{id}/relationships` | Library row continuations (`Continuations.swift:137`) | default `.userInitiated` (`:879-881`) | In-memory only | `.background` — the reader did not ask |
| `series(id:)` | `/v1/series/{id}` | Deep link / Siri / Spotlight (`RootView+Session.swift:347`) | `.userInitiated` | Reads detail cache first (full 204 KB decode for one field) | Partial-decode `CachedFull` — cheap, low value |
| `LibrarySnapshot.walk` | `/v1/my/library` ×≤30 pages | First `load()` with no fresh disk copy | Provider's (not in slice) | Progressive via `onPage` (`:251`); disk hit fires `onPage` once with all rows (`:164`) | — |

Not in the slice but on its wire: every `feed` fetch is preceded by a **sync disk read** (`readCacheWithDate`) inside the actor, cache hit or not — that read is the one thing the reader waits on before a cached Discover draws.

## Main thread & rendering
- **No GRDB call runs on the main actor** except `AppServices.makeDatabase` at launch (`AppServices.swift:147, 373`, signposted) — verified by grep of every `.read {`/`.write {` in the app: all ten files are actors (`ShelfStore`, `HistoryStore`, `TasteLedger`, `LibrarySnapshot`, `SeriesRepository`, `ReleaseSchedule`, `OwnedVolumes`, `EditionAnswerStore`). That part is right, and worth saying.
- What runs on main at launch, in order: two `DatabasePool` opens with migrator checks (`AppDatabase.swift:96-112, 244-258`), `excludeFromBackup` (three `stat`s + `setResourceValues`, `+Split.swift:382-395`), two `ATTACH`/`DETACH` cycles (`+Split.swift:89-90, 298-299`), the `freelist_count` pragma and a possible VACUUM (P9). All inside "Database open". `SeriesRepository.init` (`SeriesRepository.swift:506-523`) does no I/O — good; nothing in it could be lazier.
- The `@MainActor` preference stores' `set` methods `await onChange` (`ContentPreferences.swift:130`, `FormatPreferences.swift:123`, `BlockedTags.swift:80`) — a suspension, not a block; the toggle's own state is written before the await, so the switch flips immediately. The cost lands in the repository actor (P1's `DELETE`).
- No sorting, decoding or DB work in any `body` in this slice (there are no views here).

## Rate-limit invisibility — what the persistence layer offers and what it lacks
Exists today: feeds fall back to stale rows with `origin: .staleAfter(error)` and `cachedAt` (`SeriesRepository.swift:615-624`) — that is what `StaleBar` reads; `blockingError` hides the error whenever anything can be drawn (`:445-448`); `feedPage`/`search` return `hasMore: true` on failure so a throttled page 2 is "keep loading", not "the end" (`+Paging.swift:49, 85`); `SeriesExtras.failure` names the leg (`:973-976`); `MixResult(failure:)` (`+Mix.swift:54`).

Missing, and specific to this layer:
1. **No stale fallback for the detail page.** `readDetailCache` answers nil past six hours (`+Cache.swift:30`), so a throttled `extras` on a series opened yesterday draws empty sections with a Retry, while the same throttle on Discover draws yesterday's row with a stale bar. A `readDetailCache(allowStale: true)` used only when `fresh.failure == .rateLimited` (and the row kept for, say, 7 days by `trimDetail` age rather than 6 h) makes the page read "here is what we had". Effort: a function.
2. **A partial `extras` is never cached, so a throttled open makes the next open more likely to throttle.** Five legs succeed, one 429s, nothing is written (`:867-869`), and the re-open pays all eight again. Cache the five good legs with the failed leg recorded (a `missingLegs: Set<Leg>` beside `failure`, excluded from `Codable` today at `:227-236`), and refetch only the missing leg at `.background`. Effort: a function. This is the single change most likely to make a throttle invisible on the series page.
3. **`.surprise` at freshness 0 spends a search-family request on every deal** (`:401`) and the stack is the surface most often open while Discover prefetches. A short freshness (60 s, the endpoint's own `max-age=60` per `:549-552`) is a derived number, not a guess, and turns a burst of deals into one request.
4. **Images have no disk cache** (`:496, :803`) — a throttled image fetch after a relaunch has nothing to fall back to. Persisting `[SeriesImage]` (URLs, not bitmaps) in the detail row costs nothing measurable and gives the fan a "what we had".
5. **`count` and `relationships` swallow the error kind** (`+Count.swift:40`, `:879-881`) — a throttled count shows no count, indistinguishable from an outage; a `Result` here would let the lens row say "…" instead of blank and retry at `.background`.

## Debuggability
- **D1 — every `try?` on a DB call that logs nothing** (the write half is P5; the rest): `SeriesRepository.swift:555` (read → treated as no cache, and unconditional fetch), `:608` (304 touch), `:698` (count → 0, which Discover then shows as "0 series cached"), `:845, :852, :856` (detail read → miss → 8 requests); `+Cache.swift:31, 73` (decode → miss; P3 is the trigger), `:63` (batched read → `[]`, so `refreshReminders` sees no links and schedules nothing); `LibrarySnapshot.swift:311` (read → walk), `:328` (row decode, count-guarded, unlogged: the walk that follows says nothing about *why*); `AppDatabase.swift:253` (`splitHasCompleted` → `false`, safe direction), `:399` (salvage → 0 rows); `+Split.swift:90, 299` (detach). `BlockedTags.swift:64, 77` (a corrupt stored block list silently becomes "nothing blocked" — the one Settings case where silence changes what the reader sees).
- **D2 — no signpost anywhere in the slice.** `Signposts.measure` is used for "Database open" and "Reminder links" from outside; `feed` (cache read / write), `readDetailCache`, `writeDetailCache`, `LibrarySnapshot.readCache` and `writeCache` have none. Four `Signposts.measure` wrappers would answer U10, P6 and P9 from one Instruments run instead of an argument. Effort: lines.
- **D3 — the invisible-in-production cases:** a full disk (P5), a shape change (P3), a stale VACUUM (P9's log exists — good), a wrong blocked-tag key (P7 — nothing distinguishes "the endpoint ignored it"). One counter — "cache writes failed" — in the Settings diagnostics row beside "counted but no tags known" would surface P5 and P3 both.

## Size
- Deletable now: P10 (~8 lines), P11 (three items, ~30 lines), the `wasReset` shim and its 10-line comment (`AppDatabase.swift:187-205`).
- The protocol carries 22 requirements plus 11 default overloads across `+Priority`/`+Defaults` (`SeriesRepository.swift:9-180`, `+Priority.swift`, `+Defaults.swift`) purely so stubs need not change — the doc says so at each site. A `SeriesRepositoryProtocol` with the four priority-taking forms only, and stubs updated once, removes ~70 lines and the "which overload dispatched" question the comments spend 40 lines on.
- `SortOrder` (`SeriesRepository.swift:239-263`) is a UI vocabulary living in the repository file; it belongs beside `SearchQuery`.
- Duplicated logic: `readDetailCache` and `cachedExtrasField` each implement the freshness rule (`+Cache.swift:27-30` and `:71-72`, with a comment promising they "cannot drift apart" — they are two copies); `feed`'s freshness check (`SeriesRepository.swift:561-571`) is a third. One `static func isFresh(cachedAt:now:ttl:)`.
- The three preference stores are the same 40 lines three times (`ContentPreferences.swift:96-132`, `FormatPreferences.swift:83-125`, `BlockedTags.swift:48-82`): read defaults in `init`, `set` with an equality guard, persist, `await onChange`. A generic `PreferenceStore<Value>` is one file; not urgent.

## Cache invalidation — the four paths, cited
| Change | Scope cleared | Where | Justified? |
|---|---|---|---|
| Content rating | feeds + images + detail | `SeriesRepository.swift:639-644` | feeds yes (server-filtered, `:581`); images yes (`:812`); **detail no — P1** |
| Format | feeds | `:646-651` | yes; the cached read also re-filters on the way out (`+Cache.swift:295`) |
| Blocked tags | feeds + detail | `:653-659` | feeds yes; **detail no — P1** |
| Token / exclusion id | feeds | `:683-691`, compared against the persisted id (`+Cache.swift:172-177`) | yes; detail and images are not account-scoped |
| — | `cachedRelationships` | cleared by nothing (`:498-504`, admitted) | fine: relationships are state-filtered only (`:965`), never rating-filtered |

So the sets are deliberately not identical, every difference has a stated reason, and two of the reasons are false (P1).

## `AppDatabase+Split` at launch, steady state
Both moves are already done on every launched device, so per launch: `splitHasCompleted` (1 query), ATTACH, six `tableExists` in `cache`, DETACH (`+Split.swift:83-99`); ATTACH, two `tableExists` in `main`, `freelist_count`, DETACH (`:297-311`). Sub-millisecond work apart from P9's conditional VACUUM. Nothing here need be lazy; the upgrade-launch cost (night §5) remains unmeasured.

## Good news, same standard
- **Measurements with dates and controls, all through the slice:** the 304/`Last-Modified` finding (`SeriesRepository.swift:548-554`, 2026-09-13), the detail payload re-measured at 204 KB median with the correction recorded rather than acted on (`+Cache.swift:435-442`), the `mix` comma-vs-repeated-key 400 with the reason the wrong comment survived for months (`:340-349`), the `popularity_asc` inversion (`:249-253`), `/works` paging verified on ONE PIECE (`+Works.swift:13-21`), the `clockSlack` derivation from GRDB's millisecond rounding with the flaky-hook rate that found it (`LibrarySnapshot.swift:47-51, 313-322`).
- **Guesses labelled as guesses:** `BoundedCache.defaultLimit` (`BoundedCache.swift:21-25`), `vacuumIfBloated`'s 256 (`+Split.swift:347`), with what would settle each.
- **Empty-vs-failed kept apart everywhere it matters:** `FeedResult.Origin.staleAfter` (`:413-415`), `hasMore: true` on a failed page (`+Paging.swift:44-50, 79-86`), `SeriesExtras.failure` and the refusal to cache a partial (`:855-871`), `images(for:)` nil-not-empty (`:791-798`), `LibrarySnapshot.Result.failure` (`:27-38`) and `noAccount` as a real 401 (`:111-121`).
- **Read once, not twice** (`SeriesRepository.swift:539-546`) — prior F9, fixed, with the old cost written beside the fix; the empty-but-fresh refetch (prior F12) fixed at `:562-568` with the reasoning kept.
- **`CacheScope` is the right shape** (`+Cache.swift:119-129`): declared, not remembered — P1 is a wrong *entry* in a right table, which is exactly the failure this design makes a one-line fix.
- **The migration rule and its enforcement** (`AppDatabase+Schema.swift:230-246`, `ifStillInCacheFile` `:303-308`) and the split's copy-verify-mark-drop with the positional-copy hazard reasoned through and labelled "not run" (`+Split.swift:119-141`).
- **`writeCache` uses `insert`, not `save`, with the count of statements it saves** (`LibrarySnapshot.swift:360-365`); `write` for feeds still uses `save` (`+Cache.swift:327`) — the same reasoning applies there (P6).

## Could not determine
- **How long `readCacheWithDate` + `write` take for a 30-row page on device, and `writeDetailCache` for a 204 KB row** (P6). Settled by: the four `Signposts.measure` wrappers in D2 and one Instruments run of a cold Discover open plus one series open. Control: the "Database open" signpost, whose number already exists.
- **Whether `/v1/series/mix` treats `tag_not` and `blocked_tag` identically for a standing block** (P7). Settled by: two live requests with one blocked tag, diffing the returned DNA.
- **How big `feedEntry`/`series` are on the real simulator file today** (P2). Settled by: two `SELECT COUNT(*)` / `SUM(LENGTH(payload))` queries via `sqlite3` on `mangabaka.sqlite`.
- **Whether any consumer of cached extras assumes rating-filtered content** (P1's "likely"). Settled by: grep confirmed none under `Features/Detail`; a reviewer of the Detail slice should confirm nothing else reads `SeriesExtras.richTags` unfiltered.
- **Whether the VACUUM-at-launch ever fires in normal use** (P9). Settled by: `PRAGMA freelist_count` on `mangabaka-library.sqlite` after one sign-out on a real account; if >256 the next launch pays it.
- **U10 (sync GRDB in actors)** — unchanged; still needs the Swift Concurrency Instruments template at cold launch.
