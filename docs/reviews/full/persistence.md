# Persistence, Settings, Offline, Images — slice 2 of the full review

Date: 2026-09-14. HEAD `99a1124`. Read-only; no builds, no tests run, no edits outside this file.

**Coverage.** All 3,233 lines of the slice were read in full: `Core/Persistence/**` (1,871),
`Core/Settings/**` (339), `Core/Offline/**` (670), `Core/Images/**` (353). Plus the callers
needed to answer the invalidation question: `App/AppServices.swift`, `App/RootView+Session.swift`,
`Core/Library/LibrarySnapshot.swift`, the `absorb`/`retract`/`clear` region of
`Core/Library/TasteLedger.swift`, `LibraryService.swift:130-260`, `SettingsView.swift:195-345`,
`SeriesDetailView+Store.swift:120-160`, and the tests `GunzipTests`, `AppDatabaseResetTests`,
`SeriesRepositoryTests`, `ExclusionInvalidationTests`.

**One measurement taken** (read-only, `sqlite3 -readonly` on the simulator's own
`mangabaka.sqlite`, 2026-09-14): 17 MB file; `series` 294 rows / 854 KB; `feedEntry` 351;
`feedMetadata` 16; `shelfEntry` 0; `viewedEntry` 6; `seriesDetail` 6 rows / 1.22 MB (204 KB a
row); `libraryEntry` 945 rows / 13.86 MB; `tagAffinity` 3,175; `tasteSource` 945;
**`tasteContribution` 0**; `cadenceEntry` 2. WAL sidecar 103 KB. Also
`OfflineIndex.json.gz`: 1,477,873 bytes → 4,747,454 uncompressed, 19,300 rows, version 1,
built 2026-09-13; FLG byte = 0x08 (FNAME set — the real file exercises the branch the `named`
fixture covers). No `curl` was needed; this slice has no open wire question.

Not re-filed: gap 74 (feed discard now returns `Bool`), gap 75 (CDN 429 retried immediately),
gap 116 (undecodable library rows), gap 88/j (library re-walk after a write), the `CacheScope`
decision, and the Search review's #52/#53 (offline page total, landed).

---

## Top ten, value against effort

| # | Finding | Effort | Confidence |
|---|---------|--------|------------|
| 1 | Signing in mid-session never sets the library-exclusion id; the comment beside the `nil` call describes this exact bug as its reason (F1) | a line | certain |
| 2 | `v9_tasteContribution` left every series counted before it with no contribution row — 945 of 945 on the real file — so removing a series from the library retracts nothing (F2) | a line (a migration) | certain, measured |
| 3 | `Gunzip` sizes its output buffer from the last 4 bytes of whatever it was given; a truncated or corrupt file asks for up to 4 GB and is killed before it can throw (F3) | a function | certain |
| 4 | The corrupt-database reset renames the file on *any* open or migrate failure, and that file holds the shelf, the history and the taste ledger — which two doc comments still call "disposable cache data" (F4) | a function | likely |
| 5 | Stored filters reach the repository in a detached `Task` after the repository exists, so the first feed can be fetched and cached under the defaults; constructor injection removes the race and the whole `applied` mechanism (F5) | a file | worth checking |
| 6 | Account change leaves the previous account's widget snapshot on the home screen until relaunch, and a failed taste-ledger clear is swallowed (F6, F7) | a line each | likely / certain |
| 7 | `discardDetailCache` is still `try?` — the same swallowed-discard shape gap 74 fixed for feeds (F8) | a line | certain |
| 8 | `feed()` reads and decodes the same feed from SQLite twice on every miss (F9) | a function | certain |
| 9 | Both bundled files are copied into memory and held for the process lifetime; opening one series page pays the 7.4 MB read plus the gunzip + 19,300-row JSON decode, to look up twelve titles (F10, F11) | a function / a file | likely |
| 10 | An empty-but-fresh feed is refetched on every visit (F12); the WAL pragma duplicates what `DatabasePool` already does (F13) | a line each | likely / certain |

---

## Cache invalidation — the four paths, side by side

What each change discards, verified by reading `SeriesRepository.swift:486-530`,
`SeriesRepository+Cache.swift:63-139` and `RootView+Session.swift:112-141`.

| Change | feeds (disk) | detail (disk, 6 h) | images (memory) | relationships (memory) | library snapshot | taste ledger | profile id | exclusion id | reminders / Spotlight | widget snapshot |
|---|---|---|---|---|---|---|---|---|---|---|
| content rating (`:490-495`) | yes | yes | yes | no — not rating-filtered (`:722` filters `isDiscoverable` only) | no — filtered on read | no | no | no | no | no |
| format (`:497-501`) | yes | no — deliberate, `CacheScope` doc `:65-71` | no | no | no | no | no | no | no | no |
| blocked tag (`:503-509`) | yes | yes | no — images carry no tags | no | no | no | no | no | no | no |
| token (`forgetPreviousAccount`) | only if the exclusion id was non-nil (`:526-530`) | no — per series, not per account | no | no | yes, memory + disk (`LibrarySnapshot.swift:232-243`) | `try?` (F7) | yes | set to nil, never to the new id (F1) | yes | **no** (F6) |

The three filter paths are consistent with the declared `CacheScope`; nothing a filter governs
is missed. The token path is the one with gaps, and both are in what it *doesn't* set rather
than what it clears. History (`viewedEntry`) and the shelf survive an account change by design
(`HistoryStore.swift:4-16`) — that is a product decision, recorded here so nobody re-derives
it: the next person to enter a token on this phone sees the previous person's recently-viewed
row.

---

## Findings

### F1 — Sign-in mid-session never enables the library exclusion
- **What:** `updateLibraryExclusion(userID:)` is called with the real id only at launch and with `nil` on every account change; nothing ever calls it with the *new* account's id.
- **Where:** `MangaBaka/App/AppServices.swift:224` (launch), `MangaBaka/App/RootView+Session.swift:132` (`nil`). The only two callers — grepped. The comment at `RootView+Session.swift:128-131` says "because it is only ever written at launch, signing in mid-session never enabled the exclusion at all until the next relaunch" as the justification for a line that sets `nil`.
- **Why it matters:** enter a token in Settings → `onAccountChanged()` (`SettingsView.swift:325`) → exclusion becomes nil → every blend until relaunch recommends series the reader already tracks. The repository's own doc (`SeriesRepository.swift:369-372`) calls this "the single largest source of 'these recommendations are bad'". Charter 3: computed (the id, by `profileID()`) and discarded.
- **Fix:** in `forgetPreviousAccount()` after `library.forgetProfile()`, replace line 132 with `await repository.updateLibraryExclusion(userID: await library.profileID())` — the profile cache was just cleared, so this fetches the new id (one request) or nil when signed out. Test: `ExclusionInvalidationTests` already has "Signing in after browsing signed out discards the cache" (`:58`) at the repository level; add one at the `RootView+Session` level with a recording `LibraryProviding` whose `profile()` returns a 32-char id, asserting `blendExclusionQuery` is non-empty after `forgetPreviousAccount`.
- **Effort:** a line. **Confidence:** certain. **Lens:** 1 (bug), 3.

### F2 — `v9_tasteContribution` never backfilled, so R9's retraction is inert for the existing library
- **What:** the migration creates the table and nothing recounts the series already in `tasteSource`; `absorb` skips any series whose state is unchanged, so those rows never get a contribution and `retract` finds nothing to undo.
- **Where:** `MangaBaka/Core/Persistence/AppDatabase.swift:296-307` (the migration); `MangaBaka/Core/Library/TasteLedger.swift:87-88` (`if previous?.state == entry.state.rawValue { continue }`), `:249-254` (`guard !rows.isEmpty else { return }`).
- **Why it matters:** measured on the simulator's real file: `tasteSource` 945, `tasteContribution` 0, `tagAffinity` 3,175. On that database, dropping a series from the library removes it from `tasteSource` (`:115-119`) and retracts nothing — the weight stays forever, which is precisely the bug R9 was recorded as fixing on 2026-09-13. It stays that way for every series until its state changes. Charter 5: the fix landed with a test that starts from an empty ledger, so the number moved and the existing data didn't.
- **Fix:** a new migration `v11_recountTaste` executing `DELETE FROM tasteSource; DELETE FROM tagAffinity; DELETE FROM tasteSeen;` — the next `absorb` of the full snapshot (`TasteProfile.buildIDs`) recounts everything with contributions. One-time cost: one absorb pass, bounded by the statement-level rewrite already measured in `TasteLedger.swift` (517 ms / 200 series before that rewrite). Test: open an in-memory database at v9 with a `tasteSource` row and no contribution, migrate to v11, assert `tasteSource` is empty; control: a fresh v11 database absorbs and produces one contribution row per tag.
- **Effort:** a line (a migration). **Confidence:** certain. **Lens:** 1.

### F3 — `Gunzip` trusts the trailer's size field from a file it has not validated
- **What:** the output buffer is `[UInt8](repeating: 0, count: ISIZE)` where ISIZE is the last four bytes of the input; for a truncated file those bytes are DEFLATE payload, i.e. random.
- **Where:** `MangaBaka/Core/Offline/Gunzip.swift:61-69`. The only size check before the allocation is `bytes.count - offset >= 8` (`:59`). CRC32 (`:58` says it is there; `:62` skips it) is never verified.
- **Why it matters:** a file cut anywhere after the header yields a "promised size" uniformly distributed over 0…4 GB; the zero-fill at `:69` is attempted before `compression_decode_buffer` can fail, and iOS kills the process at a few hundred MB. So on a truncated file this throws `decodeFailed` only when the garbage happens to be small. For a *bundled* resource this is a build-time hazard, but `Gunzip` is a general utility with a doc comment promising "exact for anything under 4 GB", and the tests (`GunzipTests.swift`) cover neither truncation nor a lying trailer. A same-length corruption (one flipped byte) decodes to wrong bytes with no error, then `JSONDecoder` fails and the index is silently empty (see F11).
- **Fix:** (1) cap `destinationSize` to `min(ISIZE, payload.count * 1032 + 64, 64 * 1024 * 1024)` — 1032:1 is DEFLATE's maximum ratio, so anything larger is a lie — and throw `.decodeFailed` when ISIZE exceeds it; (2) verify CRC32 over the output (`zlib`'s `crc32` is linkable; ~4 ms for 4.7 MB) and throw on mismatch; (3) relabel the `bytes.count > 18` guard at `:36` — a 12-byte gzip is `truncatedHeader`, not `notGzip`. Tests: `plain` with its last 8 bytes replaced by `FF FF FF FF FF FF FF FF` must throw without allocating 4 GB (assert it throws in under a second); `plain` with the last 10 bytes dropped must throw; `plain` with one payload byte flipped must throw on CRC. Control: the two existing fixtures still decode.
- **Effort:** a function. **Confidence:** certain (the allocation is unconditional). **Lens:** 8.

### F4 — The corrupt-file reset fires on any failure, and the file is not "disposable"
- **What:** `onDiskResettingIfCorrupt` renames the database aside whenever `onDisk` throws for any reason; the file holds `shelfEntry`, `viewedEntry`, `tagAffinity` — the reader's own data, not a cache.
- **Where:** `MangaBaka/Core/Persistence/AppDatabase.swift:89-119` (`try? onDisk` → rename, no inspection of the error); the doc comments at `:43-44` ("losing it costs a re-download, not user data") and `:76-80` ("It is disposable cache data") are false since `v2_shelf` (`:164-181`) and `v4_history` (`:205-218`). `AppServices.swift:181` also reports `wasReset: true` for the in-memory fallback, which is the case where the file could *not* be renamed — the toast at `RootView+Session.swift:157-160` then says the saves "were reset" when they are intact on disk and merely unopened this launch.
- **Why it matters:** a migration that throws for a transient reason — disk full during `v10`'s `ALTER TABLE` (`:318-320`), `SQLITE_BUSY` from a connection the previous process instance still held, a future migration with a bug — renames the shelf and history aside permanently. They are on disk under `.corrupt-<stamp>` but the app never reads that file again, and the `.corrupt-*` files accumulate forever (`:107-109` removes only the identical stamp). The reader is told their saved stack was reset; it was, by the app, for a failure that would have cleared itself on the next launch. `AppDatabaseResetTests` covers only "garbage at the path" (`:40`), not "a good file whose migration threw".
- **Fix:** (1) make `onDisk` failures inspectable — catch `DatabaseError` and rename only for `resultCode` in `[.SQLITE_CORRUPT, .SQLITE_NOTADB]`; for anything else return `nil` so the caller's in-memory fallback runs *and the file is left alone*; (2) after a genuine corruption rename, try a salvage: `DatabaseQueue(path: renamed)` then `ATTACH` into the fresh database and `INSERT OR IGNORE` `shelfEntry` and `viewedEntry` — if the file is truly corrupt this throws and nothing is lost versus today; (3) keep only the newest `.corrupt-*` file; (4) split `OpenResult.wasReset` into `.reset` / `.unopened` so the toast can say "couldn't be opened this time" for the second; (5) fix the two comments. Tests: a migrator that throws `SQLITE_FULL` once → file *not* renamed, second open succeeds with the shelf row intact; a `SQLITE_NOTADB` file with a readable-but-unmigratable copy → salvage copies the shelf rows.
- **Effort:** a function. **Confidence:** likely (the path is reasoned, not reproduced). **Lens:** 8, 9.

### F5 — Stored filters arrive by detached `Task`, after the repository can already be asked
- **What:** `applyStoredFilters` posts the stored rating/format/blocked-tag values to the repository in `Task { }`; the repository starts with hard-coded defaults, and its first-application guard means a feed fetched before the values land is written to disk under the wrong filter and *not* discarded when they do.
- **Where:** `MangaBaka/App/AppServices.swift:216-225` (the `Task`); `MangaBaka/Core/Persistence/SeriesRepository.swift:383-384, 392-395` (defaults `["safe","suggestive"]`, `[]`, `[]`), `:404-405` (first `feed()` reads cache then fetches), `:453` (writes the result), `:482-499` (`applied` / `shouldDiscard`: the first call for each key never discards).
- **Why it matters:** a reader with a blocked tag or novels switched off can, on one launch, get a Discover row fetched without `tag_not`/`type` and cached for up to 24 h (`:329`). Whether the race is ever lost depends on actor scheduling: the `Task` is enqueued on the main actor before `RootView`'s `.task`, so it *probably* wins, but actor queues are priority-ordered, not FIFO, and nothing proves it. Charter 4/6: the `applied` set exists only because the values arrive late.
- **Fix:** build the three stores before the repository (they are `@MainActor` and cheap — `UserDefaults` reads) and pass the values through the initialiser: `SeriesRepository(client:database:contentRatings: store.preferences.queryValues, formats: formatStore.preferences.queryValues, blockedTags: blocked.blocked.ids)` — `contentRatings:` and `formats:` already exist on `init` (`:392-395`); add `blockedTags:`. Then delete `applied`, `shouldDiscard` and the `changed:` guard's first-application half (`:482-499`, `+Cache.swift:83-84`), and `applyStoredFilters` shrinks to the one call that genuinely needs the network (`updateLibraryExclusion`). Test: a recording `APIClient`, defaults with `content.blockedTags = [42]`, construct `AppServices`, call `repository.feed(.rising)` immediately; assert the first request carries `tag_not=42`. Prove it fails first by running it against today's wiring with the `Task` starved (a `Task.yield()` loop before the feed call).
- **Effort:** a file. **Confidence:** worth checking (the race window is unmeasured; the deletion of a mechanism is the value either way). **Lens:** 1, 6.

### F6 — Account change leaves the previous account's widget on the home screen
- **What:** `WidgetSnapshot.write(pickBackUp:)` is written from the library walk in `startSession` and never rewritten on account change.
- **Where:** `MangaBaka/App/RootView+Session.swift:181-183` (write), `:151-152` (`startSession` runs once per launch), `:112-141` (`forgetPreviousAccount` — no widget line).
- **Why it matters:** sign out, or enter someone else's token, and the widget keeps naming the previous account's series until the next launch. Everything else on that list (reminders `:136`, Spotlight `:140`) was added for exactly this reason; the widget was missed, which is the same shape as the missed third caller the comment at `:104-110` describes.
- **Fix:** add `WidgetSnapshot.write(pickBackUp: [])` to `forgetPreviousAccount()` next to `spotlight.clear()`. Test: `WidgetSnapshotTests` with a recording writer — after `forgetPreviousAccount`, the last write is empty.
- **Effort:** a line. **Confidence:** likely (`WidgetSnapshot.write` not read in full; its call site and doc `WidgetSnapshot.swift:6` were). **Lens:** 1.

### F7 — A failed taste-ledger clear on account change is swallowed
- **What:** `forgetEverything()` does `try? await ledger?.clear()`; if the `DELETE`s throw, the previous account's ledger survives and nothing says so.
- **Where:** `MangaBaka/Core/Library/TasteProfile.swift:163`; `TasteLedger.clear` at `TasteLedger.swift:201-207`.
- **Why it matters:** the same gap-74 shape (a discard whose failure is invisible), on the one cache whose survival is about the wrong person. Gap 74 fixed feeds; this is its sibling.
- **Fix:** have `clear()`'s caller log on failure the way `discardCachedFeeds` does (`+Cache.swift:128-131`), and return `Bool` from `forgetEverything` so `forgetPreviousAccount` can show the existing failure toast. Test: a read-only `DatabaseWriter` → `forgetEverything() == false`.
- **Effort:** a line. **Confidence:** certain. **Lens:** 2.

### F8 — `discardDetailCache` is still fire-and-forget
- **What:** `apply` calls `try? discardDetailCache()`.
- **Where:** `MangaBaka/Core/Persistence/SeriesRepository+Cache.swift:87`; contrast `:117-133`, which fixed the feeds half and documents why.
- **Why it matters:** a rating change whose detail discard fails keeps showing the tag rows the rating was set to hide, for six hours, with nothing logged — the exact failure `discardDetailCache`'s own doc at `:45-50` was written for. `SeriesRepositoryFetchedTests.swift:164` proves the feeds path reports failure; nothing proves the detail path does.
- **Fix:** give `discardDetailCache` the same `@discardableResult -> Bool` + `cacheLogger.error` shape, and have `apply` return `false` if either discard failed. Test: read-only writer → `updateContentRatings(["safe"])` logs/returns false for the detail half.
- **Effort:** a line. **Confidence:** certain. **Lens:** 2.

### F9 — `feed()` decodes the same cached feed twice on every miss
- **What:** the fresh check reads and decodes the feed; on a miss the stale fallback reads and decodes it again.
- **Where:** `MangaBaka/Core/Persistence/SeriesRepository.swift:405` (`readCache(feed, requireFresh: true)`) then `:419` (`readCacheWithDate(feed, requireFresh: false)`), each a transaction plus `IN (…)` fetch plus `JSONDecoder` over up to 50 `Series` (`+Cache.swift:163-210`).
- **Why it matters:** every stale visit, every pull-to-refresh and every `.surprise` deal (freshness 0, `:337`, so it *always* misses) pays two decodes of 20–50 payloads at ~2.9 KB each (854 KB / 294 rows measured). Small, but it is the hot path for every row on Discover and runs inside the actor, serialising every other repository call behind it.
- **Fix:** read once with `requireFresh: false`, then decide freshness in-process from `existing.cachedAt` against `feed.freshness` (the same `age >= 0 && age < freshness` rule `+Cache.swift:171-174` applies) and return `.cache` early. `readCache(_:requireFresh:)` then has one caller left (tests) — keep it or fold it.
- **Effort:** a function. **Confidence:** certain. **Lens:** 3.

### F10 — The embeddings file is copied, not mapped, and held forever
- **What:** `load` reads 7.45 MB with `Data(contentsOf:)`, then copies the 7.37 MB vector block into an `[Int8]` and builds a 19,203-entry dictionary; `loaded` is never released.
- **Where:** `MangaBaka/Core/Offline/EmbeddingIndex.swift:117` (read), `:143-149` (copy), `:151-153` (`rowOf`), `:50` (held). Trigger: `SeriesDetailView+Store.swift:146-147` calls `neighbours(of:)` on every series page, online or not.
- **Why it matters:** ~15 MB peak during load and ~8 MB resident from the first series page for the life of the process, with no response to memory pressure. On a device under pressure the app is a jetsam candidate for a feature that is a single row on one screen. Not measured on device; the file's own note (`:76`) is honest that the dot-product cost is a guess.
- **Fix:** `Data(contentsOf: fileURL, options: .alwaysMapped)`, keep the `Data`, and run the dot product over `withUnsafeBytes` of the mapped region (the `ids` array and `rowOf` stay — 0.7 MB). The OS then pages the vectors in and out; no copy. Optionally drop `loaded` on `UIApplication.didReceiveMemoryWarningNotification` — it reloads lazily. Also: `topNeighbours` (`:77-97`) runs *inside* the actor, so two series pages opened quickly serialise their 7.4 M multiply-adds, and the doc at `:13-17` claims callers "run concurrently with the load already in flight" — they don't, `loadIfNeeded` (`:99-109`) is synchronous on the actor. Make `topNeighbours` `nonisolated` over the (value-typed, `Sendable`) `LoadedIndex` snapshot and fix the comment. The full sort at `:95-96` to take 12 of 19,203 could be a bounded insertion instead; minor.
- **Effort:** a function. **Confidence:** likely. **Lens:** 3, 7, 8. Measurement that settles it: Xcode memory gauge before and after the first series page; `Signposts.measure` around `loadIfNeeded` on a device.

### F11 — The offline catalogue is decoded to look up twelve titles, and swallows its own failure
- **What:** every series page resolves its embedding neighbours' titles through `OfflineCatalogue.titles(for:)`, which forces the gunzip (1.48 → 4.75 MB) and JSON decode of 19,300 rows; `load` reports a missing or corrupt resource as an empty index with no log; `Wire.version` is decoded and never checked.
- **Where:** `MangaBaka/Features/Detail/SeriesDetailView+Store.swift:153` (call), `MangaBaka/Core/Offline/OfflineCatalogue.swift:226-246` (`ensureLoaded`/`load`, three `try?`, no logger), `:249` (`version` unused), `:98` (held forever). The doc block at `SeriesDetailView+Store.swift:139-145` still says `titles(for:)` "**Requires** … this needs a small addition" — it landed; the comment is stale (charter 7's cousin).
- **Why it matters:** the first series page on a warm, online device pays ~200 ms of CPU (the file's own simulator-host measurement, `:87-89`; device unmeasured) and ~5–8 MB resident for the rest of the session, to label twelve cards. A packaging mistake — the resource missing from a target — reads as "offline browse has nothing" and "similar by description is empty" with nothing in the console, where `EmbeddingIndex` at least logs once (`:104-108`). A version-2 export decodes to nonsense or to empty, silently.
- **Fix:** (1) carry the 19,203 titles in `OfflineEmbeddings.bin` (or a 300 KB sidecar keyed by id) so a series page never needs the catalogue; (2) `do/catch` in `load` with one `Logger.error`, mirroring `EmbeddingIndex`; (3) `guard wire.version == 1`; (4) delete the stale "Requires" paragraph. Also pre-sort at load (see F15).
- **Effort:** (1) a file plus the export script; (2)–(4) a line each. **Confidence:** likely for the cost, certain for the swallowed failure and stale comment. **Lens:** 3, 2, 9.

### F12 — An empty-but-fresh feed is refetched on every visit
- **What:** the cache hit requires `!fresh.isEmpty`, so a feed that was legitimately written as empty is never served from cache inside its freshness window.
- **Where:** `MangaBaka/Core/Persistence/SeriesRepository.swift:405`.
- **Why it matters:** an obscure series' `similar` row (24 h freshness) or a heavily filtered Discover row fires a request per visit. With `Last-Modified` it is a cheap 304, but `.trending`/`.newReleases`/`.surprise` are search-backed (`:262-265`) and spend the 30/min search window. Per visit, per empty row.
- **Fix:** distinguish "no metadata" from "metadata with zero rows": `readCacheWithDate` already returns `cachedAt` for the empty case (`+Cache.swift:181-183`); return `.cache` when `cachedAt` is inside the window regardless of row count. Test: write `[]` for `.similar(1)`, call `feed` inside the window, assert zero requests (the existing "A second read inside the freshness window issues no request" test at `SeriesRepositoryTests.swift:100`, with an empty write).
- **Effort:** a line. **Confidence:** likely. **Lens:** 6.

### F13 — `PRAGMA journal_mode = WAL` duplicates GRDB's own setup
- **What:** `prepareDatabase` sets WAL on every connection; `DatabasePool.init` already calls `setUpWALMode()`.
- **Where:** `MangaBaka/Core/Persistence/AppDatabase.swift:42-47`; GRDB `DatabasePool.swift:81` → `Database.swift:531-532` (verified in the checked-out package).
- **Why it matters:** charter 6 — hand-rolling what the platform provides. Harmless today (the pragma is idempotent), but the comment at `:43-44` attaches the wrong justification to it and a reader will think removing it changes the journal mode. WAL handling otherwise: auto-checkpoint at SQLite's default 1,000 pages is adequate — the largest transaction (the 13.9 MB library write) checkpoints at commit; the observed sidecar is 103 KB; the sidecar removal after a rename at `:114-116` is correct.
- **Fix:** delete the `prepareDatabase` block; keep `Configuration()` for future use or drop it too.
- **Effort:** a line. **Confidence:** certain. **Lens:** 4, 9.

### F14 — Redundant index on `feedEntry`
- **What:** `feedEntry_on_feedKey` duplicates the leading column of the primary key `(feedKey, position)`.
- **Where:** `MangaBaka/Core/Persistence/AppDatabase.swift:152-154`.
- **Why it matters:** every feed write maintains a second B-tree for a query the PK already serves (`WHERE feedKey = ? ORDER BY position` is a single PK range scan). Negligible cost; filed because "queries without an index" was asked and the honest answer for this slice is the opposite — one index too many, none missing. `trimOrphans`' `NOT IN (SELECT seriesId FROM feedEntry)` (`+Cache.swift:297`) materialises the 351-row subquery once; `trimDetail`'s `ORDER BY cachedAt` (`:305-310`) is over ≤200 rows; `tagAffinity`'s `ORDER BY score` is over 3,175 — all fine at these sizes.
- **Fix:** `v11`: `DROP INDEX feedEntry_on_feedKey`. **Effort:** a line. **Confidence:** certain. **Lens:** 3.

### F15 — Every offline page and every live count re-sorts the whole filtered set
- **What:** `filteredAndSorted` filters 19,300 rows then sorts the survivors, per page and per filter-panel change.
- **Where:** `MangaBaka/Core/Offline/OfflineCatalogue.swift:276-287, 402-408`; driven per keystroke of the panel by `SearchModel.swift:243-249` (`offlineCount`) and per page by `page` (`:193-207`).
- **Why it matters:** a text-less offline browse matches most of the index; O(n log n) over ~15,000 rows per page-turn, on the actor, so page 3 waits behind a count for the panel. Unmeasured on device; the 200 ms load number is the only figure this file has.
- **Fix:** sort once at load — keep `entries` in popularity order and a second `byScore` array; `filter` preserves order, so `sorted(_:by:)` becomes "choose the input array". Measurement: `Signposts.measure("Offline page")` on a device with an empty query, before and after.
- **Effort:** a function. **Confidence:** likely. **Lens:** 3, 7.

### F16 — Synchronous GRDB inside actors blocks cooperative-pool threads
- **What:** every store in and around this slice uses GRDB's synchronous `read`/`write` inside an actor; the closure runs on the actor's current cooperative thread and holds it for the duration of the SQLite work *and* the JSON decode.
- **Where:** `SeriesRepository+Cache.swift:25, 37, 120, 136, 163, 218, 276`; `LibrarySnapshot.swift:142-163` (945 rows, 13.9 MB decoded synchronously); `ShelfStore.swift:24-51`, `HistoryStore.swift:48-91`, `TasteLedger.swift:80, 131`, `ReleaseSchedule.swift:426, 452`. No GRDB call runs on the main actor except the migration at launch (`AppServices.swift:178`, signposted) — that part is right.
- **Why it matters:** the pool has one thread per core. At launch `startSession` triggers the library read, the taste absorb, four Discover feeds and the history read at once; on a 6-core device that can pin most of the pool on SQLite and JSON while SwiftUI's own async work waits. Not measured — this is the one finding in the slice I would not fix without the number.
- **Fix:** GRDB's `async` overloads (`try await database.writer.read { … }`) run the closure on GRDB's own dispatch queue and *suspend* the actor instead of blocking a thread. Mechanical, one store per agent. Measurement first: Instruments' Swift Concurrency template at cold launch, "threads blocked" during the first two seconds.
- **Effort:** a file per store. **Confidence:** worth checking. **Lens:** 7.

### F17 — The `.surprise` comment says never cached; the code serves it stale
- **What:** freshness 0 means every deal misses and refetches, but the write at `:453` and the fallback at `:459-463` mean a failed deal serves the previous surprise queue — the "same series on every visit" the comment rules out.
- **Where:** `MangaBaka/Core/Persistence/SeriesRepository.swift:334-337` vs `:453, 459-463`. Also each deal writes 50 rows and runs `trimOrphans` for a cache that is only read on failure.
- **Why it matters:** behaviour is arguably right (a stale queue beats an error); the comment is wrong, and a reader of it will "fix" the fallback. Write amplification is 50 `save`s (each UPDATE-then-INSERT in GRDB, so ~100 statements) per deal.
- **Fix:** amend the comment to "never served from cache while the network answers; served stale on failure". Optionally skip the write for `.surprise` if the fallback is not wanted.
- **Effort:** a line. **Confidence:** certain. **Lens:** 9.

### F18 — Underived cache ceilings
- **What:** 96 MB (`CoverStore.swift:32`), 32 MB / 256 MB (`AppServices.swift:191-194`), 200 detail rows "about 300 KB" (`+Cache.swift:300-302`) carry no derivation or `guess` label; 400 placeholders (`BlurHashCache.swift:17-19`) and 20 history rows (`HistoryStore.swift:19-24`) do.
- **Why it matters:** charter 4. The detail figure is now measurable: 204 KB/row on the real file, so the cap is ~40 MB on disk, not 60. 96 MB ≈ 300 covers at 320 KB decoded — say so, or say "guess".
- **Fix:** a comment on each: derive or label. **Effort:** a line each. **Confidence:** certain. **Lens:** 9.

### F19 — `LibrarySnapshot.writeCache` doubles its statements
- **What:** after `DELETE FROM libraryEntry` every row is written with `save`, which in GRDB is an `UPDATE` followed by an `INSERT` when no row changed — two statements per row on a table just emptied.
- **Where:** `MangaBaka/Core/Library/LibrarySnapshot.swift:181-185` (adjacent to the slice; the table is defined in `AppDatabase.swift:272-275`).
- **Why it matters:** ~1,900 statements for 945 rows once per walk; inside one transaction, so tens of milliseconds, not seconds. Filed under write amplification because it was asked.
- **Fix:** `insert(db)` instead of `save(db)` after the `DELETE`. **Effort:** a line. **Confidence:** certain. **Lens:** 3.

### F20 — One database file mixes the reader's own rows with 15 MB of re-fetchable cache
- **What:** the 17 MB file is 82 % library cache (13.9 MB) plus feeds and detail (2.1 MB); the shelf, history and taste ledger — the only rows that are theirs — are a few hundred KB. Application Support is backed up to iCloud, so every backup carries the cache, and every corruption reset (F4) takes the shelf with the cache.
- **Where:** `MangaBaka/Core/Persistence/AppDatabase.swift:33-49` (one path, one pool), tables `:139-321`.
- **Why it matters:** this is the "other way" for F4 — a structural answer instead of a salvage routine. Two files: `mangabaka.sqlite` (shelf, history, taste, lenses) and `cache.sqlite` (series, feeds, detail, library, cadence) with `isExcludedFromBackup = true`. A corrupt cache can then be deleted outright, exactly as its doc comment already claims, and the reader's file is never renamed for a cache failure.
- **Cost, honestly:** two `AppDatabase` instances threaded through `AppServices`, a migration that moves five tables (or simply drops them — they are caches), every store told which file it owns, and `AppDatabaseResetTests` doubled. A redesign, not a fix; worth it only if F4's salvage path proves fiddly.
- **Effort:** a redesign. **Confidence:** likely. **Lens:** 5.

### F21 — Minor, certain, one line each
- `BlurHash.render` (`BlurHash.swift:93-113`) calls `cos` twice per pixel per component — 32×32×81×2 ≈ 166 k `cos` for a 9×9 hash; precomputing the two basis tables per row/column is the reference implementation's own optimisation and makes a first-appearance grid of 20 uncached hashes (~20 ms on the main thread, via `CoverImage.swift:27-30`'s computed property in `body`) cheaper. Lens 7; unmeasured.
- `OfflineCatalogue.Wire.source` (`:251`) decoded and unused — the export's licence string; either show it in Settings' offline-index row or drop it from `Wire`. Lens 3.
- `cache.libraryExclusionUserID` (`+Cache.swift:96-101`) stores the account id in `UserDefaults.standard` while `APIClient.swift:428-441` works to keep the same id out of `URLCache`. Not a secret, but two standards for one value; note which is intended. Lens 9.

---

## What the slice does well

- **One invalidation policy, declared, and it agrees with itself.** `CacheScope`/`apply` (`+Cache.swift:63-88`) — the matrix above shows the three filter paths discard exactly what each filter governs and nothing else. The doc at `:53-62` records the four-copies history that motivated it.
- **The exclusion id is compared against what the cache was built under, not what the process started with** (`+Cache.swift:90-101`), with both wrong answers written down (`SeriesRepository.swift:512-530`) and a test for each (`ExclusionInvalidationTests.swift:39, 58`).
- **A row that fails to decode makes the read a miss, not a shorter hit**, with the measurement that found it (20 → 14, `+Cache.swift:197-205`); the same rule for the library at `LibrarySnapshot.swift:155-161` (939 → 938).
- **Conditional feed requests were measured before being built** — no `ETag`, `Last-Modified` only, 304 with a zero-byte body, dated (`AppDatabase.swift:312-314`, `SeriesRepository.swift:410-418`).
- **The corrupt-file path renames rather than deletes, removes the WAL sidecars, and has a test with a control** (`AppDatabase.swift:76-116`, `AppDatabaseResetTests.swift:40, 75`). F4 narrows *when* it fires; the mechanism is right.
- **A backwards clock is stale in every place a date is compared** (`+Cache.swift:28-30, 172-174`, `LibrarySnapshot.swift:145-147`).
- **No force-unwrap or `try!` reachable from input anywhere in the slice** — grepped. `BlurHash.parse` length-checks before every index (`BlurHash.swift:58-64, 76-77`) and `decode83` returns nil on an unknown character, so a malformed hash from the API is nil, not a trap. `EmbeddingIndex` reads little-endian by hand because the buffer promises no alignment (`:158-168`) and checks the exact file size before touching it (`:136`).
- **Cover decode is off the main actor and explains why `nonisolated` is load-bearing** (`CoverStore.swift:91-105`); failures are never cached (`:19-22`); the same URL is one request (`:57`); `Cover.url(forHeight:scale:)` picks the smallest sufficient variant, so no full-size cover is ever decoded for a 120-pt card — the memory question I expected to file does not arise.
- **The offline page returns its total from the same pass** (`OfflineCatalogue.swift:187-207`), and `Gunzip` handles all four optional header sections with a fixture whose provenance is stated (`GunzipTests.swift:10-27`) — the real file has FNAME set, so the fixture matches production.
- **Constants that are guesses say so**: `EmbeddingIndex.swift:76`, `OfflineCatalogue.swift:87-89` (and it distinguishes simulator-host from device), `HistoryStore.swift:19-24`.
- **The history store states its privacy position in its own header** (`HistoryStore.swift:10-13`): on-device, never sent, one tap to erase.

## What I could not determine, and what would settle each

- **Whether F5's race is ever lost.** One `os_signpost` at `applyStoredFilters`' first `await` and one at the first `feed()` entry, twenty cold launches on a device; or the starved-Task test in F5.
- **Device cost of the two bundled loads (F10, F11).** `Signposts.measure` around `EmbeddingIndex.loadIfNeeded` and `OfflineCatalogue.ensureLoaded`, one series page, iPhone not simulator. And the Xcode memory gauge before/after that page for the resident figure.
- **Whether synchronous GRDB-in-actor hurts launch (F16).** Instruments, Swift Concurrency template, cold launch: count of cooperative threads blocked in `sqlite3_step`/`JSONDecoder` during the first two seconds.
- **Offline page/count cost (F15).** `Signposts.measure` around `page` with an empty query on device, before and after pre-sorting.
- **Whether `OfflineEmbeddings.bin`'s 19,203 ids are a subset of the catalogue's 19,300** — `SeriesDetailView+Store.swift:135-137` says "not proven here". One script: read the `MBE1` id block and the `.gz` ids, print the difference. If non-empty, "Similar by description" silently drops cards.
- **How many distinct sizes `Cover.url(forHeight:scale:)` produces per cover across the app** — each is a separate download and a separate 96 MB-cache entry. Count the distinct `forHeight` call sites; if more than three, a shared thumbnail size would halve cover traffic.
