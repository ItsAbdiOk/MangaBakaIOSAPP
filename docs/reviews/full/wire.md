# Wire slice — full review, 2026-09-14

Read-only. No build, no test, no edit outside this file. Slice: `MangaBaka/Core/Networking/**`
(8 files, 1,413 lines) and `MangaBaka/Core/Model/**` (27 files, 3,266 lines).

**Read in full: 35 of 35 files, 4,679 of 4,679 lines.** Read for context only (not reviewed):
`SeriesRepository.swift:545-575, 750-880`, `SeriesRepository+Paging.swift` (whole),
`LibraryService.swift:195-215`, `LibraryEntry.swift:40-60`, `AppServices.swift:55-70, 150-200`,
`TokenStore.swift:1-45`, `NetworkLedger.swift:1-40`, `AniListClient.swift:129-133`,
`MangaUpdatesClient.swift:143-145`, `RateLimitTests.swift`, `LossyArrayTests.swift`,
`SeriesExtrasTests.swift:29-77`, and the OpenAPI spec (`docs/schemas/mangabaka_openapi.json`)
via a script that printed required/nullable per field.

**Already on record, not re-filed.** Yesterday's `docs/reviews/wire.md` W1–W12: W1, W2, W3, W4,
W5, W8, W9, W11 are fixed in code with dated comments (`Catalogue.swift:60-68`,
`DisplayTitle.swift:88-103`, `Series.swift:131-136, 283-285`, `APIClient.swift:300-313, 604-623`,
`RateLimitGate.swift:81-91`, `SeriesWork.swift:93-99`, `CatalogueService.swift:151-199`); W7 is
recorded as NOT A BUG with the measurement (`SearchQuery.swift:105-113`); W6 and W10 are fixed
(`SeriesEdition.swift:34-44, 70`, `LanguageFlag.swift:22-34`); W12's in-slice `try?` sites are
partly closed (`CatalogueService.genres/tags` now return `Fetched`; `searchTags`,
`searchPublishers`, `publisher(id:)` still `try?` into nil, which the doc comments now justify as
"nil, not []"). Search review E F12 landed as `LossyArray`.

## Live requests (2 used, 2026-09-14, host api.mangabaka.org)

| # | Request | What it settled |
|---|---------|-----------------|
| 1 | `GET /v2/series/search?q=solo%20leveling&limit=1` (headers) | `cache-control: public, max-age=60`, `last-modified`, `cdn-cache-control: public, max-age=3600, stale-while-revalidate=60`, `cf-cache-status: EXPIRED`, `x-api-stability: beta`. **Search responses are cacheable by URLCache for 60 s** — finding 1. Pagination on the wire: `{count, next, previous, page, limit}`, all integers. |
| 2 | `GET /v1/series/3397/relationships` | 3 rows, **67,416 bytes** (22 KB per row). Each row is `{id, relation_type, is_manual, note, series}`; `series` is the full v1 series (36 keys) **including `titles`** — so `SeriesRelationship.series: Series` and the "real response shapes" fixture at `SeriesExtrasTests.swift:49-61` agree with the wire. Negative result, recorded so it is not re-checked. `total_chapters` arrives `"270"` (string), `rating_count` null — both already handled. |

Standalone check, not a request: `LossyArray`'s `Blank` skip was run through `swift` against
`null`, a number, a string and a nested array in element position (script in this session's
scratchpad, 2026-09-14). All four drop one element and continue; the container advances. The
"infinite loop on a null element" I suspected does not reproduce.

---

## Ranked top ten

| # | Finding | Where | Conf. | Effort | Lens |
|---|---------|-------|-------|--------|------|
| 1 | URLCache answers a repeat search inside 60 s with no network, but the gate still charges a search slot and the ledger records a ~0 ms "request" | `APIClient.swift:156, 168, 185-195, 441-443`; measured today | certain (header), likely (URLCache serves it) | a function | 5, 6 |
| 2 | A third-party `Retry-After: 1e300` traps in `humanDuration` — `Int(Double)` on an uncapped server number | `APIError.swift:130, 167`; fed by `AniListClient.swift:131`, `MangaUpdatesClient.swift:143` | certain | a line | 8 |
| 3 | `RequestPriority.background` is a no-op for the general family: no local 180/min window, no reserve, so `DiscoverModel`'s prefetch is not "capped below the full window" as the type promises | `RateLimitGate.swift:134`; `RequestPriority.swift:6-12, 18-21`; `DiscoverModel.swift:205` | certain | a function | 6 |
| 4 | Two lenient-array decoders: `LossyArray` and `lenientElements`+`AnyDecodable`; one counts drops, the other does not | `LossyArray.swift:12-35`; `Series.swift:358-370, 419-429` | certain | a function | 9 (duplication) |
| 5 | `LossyArray` belongs at twelve more array decodes, two of which have already lost a whole section to one row | list under finding 5 | certain | a line each | 2 |
| 6 | Two `ISO8601DateFormatter`s are allocated per decoded date value, not per decoder | `APIClient.swift:563-567` vs `:595` | certain (unmeasured cost) | 4 lines | 3 |
| 7 | `.reloadIgnoringLocalAndRemoteCacheData` stops reading the cache, not writing it — the "never on disk" promise rests on the server's `no-store` | `APIClient.swift:428-443` | worth checking | a function | 8 (privacy) |
| 8 | A Keychain `SecItemCopyMatching` on every request | `TokenProvider.swift:40`; `TokenStore.swift:18-33` | certain (unmeasured cost) | a function | 3 |
| 9 | The envelope decode is written three times | `APIClient.swift:65-75, 96-106, 531-540` | certain | a function | 4 |
| 10 | `ReadingPlatforms` admits any path under `line.me`, `iqiyi.com`, `crunchyroll.com` — portal roots, against the file's own rule | `ReadingPlatforms.swift:58, 109, 115` vs `:72-77, 90-93` | worth checking | a line each | 9 |

---

## Findings

### 1. A cached search still spends a search slot and pollutes the latency ledger

- **What** — `perform` calls `limiter.reserveSlot` (`APIClient.swift:156`) and records a ledger row (`:185-195`) around `session.data(for:)` (`:168`), but for any request URLCache can answer, `session.data(for:)` never touches the network.
- **Where** — `APIClient.swift:156, 168, 185-195`. The session is `URLSessionConfiguration.default` (`:34-38`), whose policy is `.useProtocolCachePolicy`; only `/v1/my`, `/v0/my` and identity-carrying URLs opt out (`:441-443`). Measured today (request 1): `/v2/series/search` answers `cache-control: public, max-age=60`.
- **Why it matters** — Two things, one per charter pattern. (a) Load: a reader who retypes a query, taps a recent search, or flips a filter and back within 60 s gets the cached page from disk, and the gate still appends to `searchTimestamps` (`RateLimitGate.swift:139`) — so the local "31st search is refused" (`:142-145`) can fire when only, say, 22 requests reached MangaBaka. The reader reads "Search is paused" for a limit the server never imposed. (b) Measurement: `NetworkLedger` gains a row with `bytes` and ~0 ms for a request that never left the device. `APIClient.swift:31-33` says the 20 s timeout is a guess to be re-sized "once `NetworkLedger`'s recorded latencies give a real p99" — that p99 will be computed against a distribution salted with cache hits. Charter §5: the number will move and mean the wrong thing.
- **Fix** — Use `session.data(for:delegate:)` with a small `URLSessionTaskDelegate` that keeps `URLSessionTaskMetrics`; after the call, if `metrics.transactionMetrics.last?.resourceFetchType == .localCache`, call a new `limiter.refund(path:)` that removes the timestamp just appended (search family only) and skip `NetworkLedger.record`. Keep the cache — the point is to not count it, not to disable it. Add a test through `URLProtocolStub` that serves one 200 with `max-age=60`, issues the same GET twice, and asserts `searchTimestamps.count == 1` and one ledger row.
- **Effort** — a function (delegate + refund).
- **Confidence** — certain that the header is sent and the slot is charged before the load; likely that URLCache actually serves the second request (it does for `.useProtocolCachePolicy` and a fresh `max-age`; I did not run the app to see it). The measurement in "Could not determine" #1 settles it.
- **Lens** — 5 (measurement), 6 (load balancing).

### 2. `humanDuration` traps on an uncapped third-party `Retry-After`

- **What** — `Int((wholeSeconds / 60).rounded())` at `APIError.swift:167` is `Int(Double)` on a value that ultimately comes from a server header. `APIError.rateLimited(retryAfter:)` (`:130`) converts any finite seconds to a `Date` with no cap; `countdown` (`:331`) rejects only non-finite.
- **Where** — `APIError.swift:130, 164, 167`. Callers that pass an uncapped header: `AniListClient.swift:131, 393`, `MangaUpdatesClient.swift:143, 201`, `SeriesCharacter.swift:167, 272`, `GigaViewerFeedClient.swift:147`, `WebtoonsFeedClient.swift:133`, `NaverFeedClient.swift:67` — all `TimeInterval.init` on the raw header. MangaBaka's own path is safe: `parseRetryAfter` checks `isFinite` and the gate caps at 15 min (`APIClient.swift:616-623`, `RateLimitGate.swift:221`).
- **Why it matters** — `Retry-After: 1e300` (finite, parses) → `Date().addingTimeInterval(1e300)` → `timeIntervalSinceNow ≈ 1e300` → `/60`, `.rounded()`, `Int(...)` traps the moment a `StaleBar` or failure screen renders the countdown. CLAUDE.md's "no force-unwrap reachable from real input" in a different spelling, the same class as W4, on a path W4 did not cover. Yesterday's review said "confirm force-unwraps are still absent" — they are (grep today: no `try!`, `as!`, or postfix `!` in the slice), but this is the one that is not spelled `!`.
- **Fix** — In `rateLimited(retryAfter:party:)` (`:130`): `seconds.flatMap { $0.isFinite ? min(max($0, 0), RateLimitGate.maxHonouredRetryAfter) : nil }`. Belt and braces: `Int(wholeOrClamped:)` at `:164` and `:167`, which exists for exactly this (`Int+Clamped.swift:41`). The clients' `spacing.backOff(until: now + retryAfter)` (`AniListClient.swift:132`) has the same hole for the client's own spacing — out of slice, same one-line cap.
- **Effort** — a line.
- **Confidence** — certain mechanism; the input is a hostile or broken third party, which is what `Party` exists to distrust.
- **Lens** — 8.

### 3. `.background` shapes search only; the 180/min general window has no budget at all

- **What** — `reserveSlot` returns early for `.general` before any priority check (`RateLimitGate.swift:134`). There is no sliding window for the general family, so `.background` and `.userInitiated` are indistinguishable on every non-search path.
- **Where** — `RateLimitGate.swift:134`; `RequestPriority.swift:6-12` ("cannot spend the same 30-a-minute search window") is accurate, but `:18-21` ("Capped below the full window and will wait for room") is stated for the case in general. `DiscoverModel.swift:205` passes `.background` to `feedPage` — a general path — and gets nothing for it. `getRoot`/`getResults` (`APIClient.swift:346, 362`) take no priority at all, so the "swipe-stack deal while the reader is elsewhere" the gate's doc names (`RateLimitGate.swift:25-27`) cannot be background even in principle.
- **Why it matters** — The series page fires seven general requests per open (`SeriesRepository.swift:838-873` plus `/images` at `:755`); the library's continuations row fires ten `/relationships` per page (`LibraryView.swift:145`), each 22 KB per related series (request 2). A reader paging Library while Discover prefetches feeds can reach 180/min with nothing local to say so; the first sign is a 429 that closes every general path for the backoff (`RateLimitGate.swift:216-224`). The per-IP limit is shared with strangers, which is the argument the gate makes for search and does not apply to general.
- **Fix** — Either (a) generalise the window: `family.limit` (30 / 180), `family.reserve` (10 / 30 — both GUESS, label them), one `timestamps: [Family: [Date]]`, and let `.background` wait on general too; or (b) honestly narrow the contract: rewrite `RequestPriority.swift:18-21` to "search paths only", drop the `.background` argument from `DiscoverModel.swift:205`, and add a test that a general-path background request is never queued. (a) is the right one if the 180 cap is ever hit in practice; `NetworkLedger` can say whether it is before anyone writes it.
- **Effort** — a function for (a); a few lines for (b).
- **Confidence** — certain.
- **Lens** — 6.

### 4. Two lenient-array decoders

- **What** — `LossyArray` (`LossyArray.swift:12-35`) and `KeyedDecodingContainer.lenientElements` (`Series.swift:358-370`) with its private `AnyDecodable` (`:419-429`) do the same job. `LossyArray` counts what it dropped; `lenientElements` drops silently, so a `tags_v2` shape change would be invisible — the exact failure `LossyArray`'s comment (`:9-11`) says it exists to prevent.
- **Where** — as above; `Series.swift:144` is the one caller of `lenientElements`.
- **Why it matters** — Charter's duplicated-mechanism pattern: the next person fixes one and not the other. It also means `AnyDecodable` is private to `Series.swift` and cannot be reused where finding 5 wants leniency.
- **Fix** — `tagsV2 = try container.decodeIfPresent(LossyArray<SeriesTag>.self, forKey: .tagsV2)?.elements` (with the drop count logged the way `SeriesRepository+Paging.swift:67-69` does); delete `lenientElements` and `AnyDecodable`. Safe to swap: the `Blank` skip was checked against null/number/string/array elements today (see "Live requests"). `WireNullabilityTests.swift:80-98` (Solo Leveling's null tag name) must still pass unchanged — it is the control.
- **Effort** — a function.
- **Confidence** — certain.
- **Lens** — 9, 4.

### 5. Where else `LossyArray` belongs

- **What** — Every `[T]` decode below fails the whole array on one bad row. Two of them have already done so in production (SeriesWork: `SeriesWork.swift:12-15`; PublisherRecord: `Catalogue.swift:60-64`); LibraryEntry documents a third (`LibraryEntry.swift:43-47`).
- **Where** — `SeriesRepository.swift:755` (`[SeriesImage]`), `:845` (`[SeriesLink]`), `:850` (`[NewsItem]`), `:856` (`[SeriesRelationship]`), `:865` (`[SeriesEdition]`), `:873` (`[SeriesWork]`), `:555` (mix `data: [Recommendation]`); `SeriesRepository+Paging.swift:32` (feed pages `[Series]` — the same shape `search` at `:66` already protects); `CatalogueService.swift:76-80` (`[Tag]`), `:130` (`[Tag]`), `:206` (`[PublisherRecord]`); `LibraryService.swift:201` (`[LibraryEntry]`, 937 rows in 19 pages — one row kills a page and the walk).
- **Why it matters** — `NewsItem.publishedAt: Date?` (`SeriesExtras.swift:125`) has been seen on the wire once; a fourth date form on one article empties the news section. `SeriesEdition.language: Language?` is `object` required in the spec but every field of it optional here — fine — while `SeriesEdition.id: String` is required and non-null on the wire, fine. The risk is not any one field; it is that the failure mode is a silent empty section, which the charter says is this project's characteristic defect.
- **Fix** — Change the type annotation at each site to `LossyArray<T>` and read `.elements`; log `dropped` when non-zero; better, add a `NetworkLedger.recordDropped(path:count:)` so the count is visible in the same place the request counts are, instead of os_log only (`SeriesRepository+Paging.swift:67-69`). Feed pages first (most rows per reader-second), library second (most rows per account).
- **Effort** — a line each, 12 sites; the ledger counter a function.
- **Confidence** — certain.
- **Lens** — 2.

### 6. A formatter pair allocated per date value

- **What** — The custom date strategy (`APIClient.swift:561-578`) constructs two `ISO8601DateFormatter`s on every call, i.e. per date field per row. `dateOnlyFormatter` (`:595`) is already a `static let`; the two ISO ones are not.
- **Where** — `APIClient.swift:563-567`.
- **Why it matters** — In this slice only `NewsItem.publishedAt` is a `Date`, but the same decoder serves `LibraryEntry.startDate/finishDate` (`LibraryEntry.swift:73-74`) — up to two dates per entry, and `library.json` shows both `"2024-01-05T00:00:00.000Z"` and the bare `"1999-09-27"` form, the latter paying for both ISO formatters before falling through. A 937-entry library is up to ~3,700 formatter constructions per walk. GUESS at cost: 20–60 µs each, so 75–225 ms of actor time per full library sync, off the main thread. Not a hitch; pure waste, and the kind that grows with the library.
- **Fix** — Two `static let`s beside `dateOnlyFormatter`, built once; `ISO8601DateFormatter` is documented thread-safe. Measure first if the number matters: `measure { }` 1,000 constructions.
- **Effort** — 4 lines.
- **Confidence** — certain that the allocation happens; the cost is an estimate.
- **Lens** — 3.

### 7. The identity cache policy prevents reads, probably not writes

- **What** — `APIClient.swift:442` sets `.reloadIgnoringLocalAndRemoteCacheData` on `/v1/my`, `/v0/my` and identity-carrying URLs, under a comment promising the response never sits in the shared URLCache on disk (`:428-432`). That policy governs whether the cache is consulted for the load; as far as I can tell (Apple's cache-policy docs describe loading, not storing), URLSession still stores the response if the headers allow it. Today they do not — MangaBaka sends `private, no-store` on those endpoints (verified 2026-09-09 per the comment) — and the comment itself says that is "their guarantee to change, not ours to depend on". The code depends on it.
- **Where** — `APIClient.swift:428-443`.
- **Why it matters** — If MangaBaka ever relaxes `no-store` on `/v1/my/library`, a 937-entry library with the reader's dates lands in a 256 MB on-disk cache (`AppServices.swift:191-194`) that `SpotlightIndex.swift:102` also reads. Privacy note in the charter.
- **Fix** — A `URLSessionDataDelegate` on the client's session implementing `urlSession(_:dataTask:willCacheResponse:completionHandler:)` that answers `nil` when `task.originalRequest?.cachePolicy == .reloadIgnoringLocalAndRemoteCacheData` (or when the path/params match `identifyingParameters`). Test: `URLProtocolStub` serving `/v1/my/profile` with `cache-control: public, max-age=60`, then `URLCache.shared.cachedResponse(for: request) == nil`. If the test passes before the change, this finding is withdrawn and the comment should say so.
- **Effort** — a function.
- **Confidence** — worth checking.
- **Lens** — 8 (privacy), 9.

### 8. A Keychain query per request

- **What** — `ResolvingTokenProvider.authorizationHeader()` (`TokenProvider.swift:40`) calls `store.read()` on every request; `read()` is a `SecItemCopyMatching` (`TokenStore.swift:18-33`). The per-request resolution exists for a good reason (`:23-26`: a token entered in Settings must take effect without relaunch).
- **Where** — `TokenProvider.swift:36-42`.
- **Why it matters** — Seven requests per series page open, ~19 per library walk, each paying a Keychain round-trip on the client actor before the request can start. GUESS: 0.3–2 ms each. Small per request; it is in the critical path of every first paint that needs the network.
- **Fix** — Cache the token behind a lock in `TokenStore` (or make `ResolvingTokenProvider` an actor) and invalidate on `write`/`clear`, which are the only writers (`TokenStore.swift:36+`). Measure first: time 100 `read()` calls on device; if it is under 100 µs each, record the number in the comment and leave it.
- **Effort** — a function.
- **Confidence** — certain that it happens; cost unmeasured.
- **Lens** — 3.

### 9. The envelope decode written three times

- **What** — `get` (`APIClient.swift:65-75`), `getWithPagination` (`:96-106`) and the conditional `get` (`:531-540`) each decode `APIEnvelope<Payload>`, map the error, and guard `data`.
- **Where** — as above.
- **Why it matters** — Shotgun surgery: finding 5's `dropped` logging, or any change to the "carried no data" message, is three edits. `getWithPagination` exists to keep `get`'s signature stable (`:80-88`), which is fine; the decode inside them need not be triplicated.
- **Fix** — `private func decodeEnvelope<P: Decodable>(_ data: Data) throws(APIError) -> (P, Pagination?)`; three call sites become one line each.
- **Effort** — a function.
- **Confidence** — certain.
- **Lens** — 4.

### 10. Portal roots in the reading allowlist

- **What** — `ReadingPlatforms.allowed` lists `line.me` (`:109`), `iqiyi.com` (`:115`) and `crunchyroll.com` (`:58`) as registrable roots. `allows` (`:38-46`) admits any subdomain and any non-empty path, so a LINE share link, an iQIYI video page or a Crunchyroll episode renders under "Read it". The file's own rule for naver, daum, kakao, pixiv, nicovideo and bilibili (`:72-77, 90-93, 112-113`) is that a portal root gets only its reader subdomain.
- **Where** — `ReadingPlatforms.swift:58, 109, 115`.
- **Why it matters** — The allowlist exists for App Review 5.2.3 (`:5-11`); its value is that it fails closed. Three entries fail open on hosts far larger than their comics sections.
- **Fix** — `manga.line.me`; for iqiyi and crunchyroll, the reader subdomain or path observed in the 450-series sample of 2026-09-12 — the sample's host list says which. If Crunchyroll Manga no longer exists as a reading surface, drop the entry.
- **Effort** — a line each.
- **Confidence** — worth checking (I did not re-sample the hosts).
- **Lens** — 9.

### Lower priority, still findings

- **11. `Int?` on `number`-typed integers.** `Pagination.count/page/limit` (`APIEnvelope.swift:20-35`), `Tag.level/seriesCount` (`Catalogue.swift:27, 31`), `SeriesTag.seriesCount` (`SeriesTag.swift:27`), `Recommendation.sharedTagsTotal` (`Recommendation.swift:22`) are `Int?` where the spec says `number`. This API has emitted `290.0` for a `number` (`CommunityPulse.swift:14-16`), and `Int` throws on `290.0`. All 14 fixtures show plain integers for these; the 450-series sample of 2026-09-12 would settle it with a grep for `\.0[,}]`. Fix if it ever appears: decode through `lenientDouble` + `Int(wholeOrClamped:)`. Worth checking; a line each. Lens 1.
- **12. `CommunityPulse.swift:70`** `Int(current - previous)` beside `Int(wholeOrClamped: current)` at `:73` — the same guard applied to one of two adjacent conversions. Both operands are decoded finite `Double`s, so this needs `> 9.2e18` to trap; one line for consistency. On record as W4's third site; still open. Lens 8.
- **13. The search window charges offline and cancelled attempts.** `searchTimestamps.append` (`RateLimitGate.swift:139`) precedes the load; `.offline` and `.cancelled` (`APIClient.swift:170-180`) leave the slot spent. `recordSuccess`'s comment (`:229-232`) chooses this deliberately for failed *requests*; an attempt that never left the device is not a request. Fold into finding 1's refund. Likely; a line. Lens 6.
- **14. No retry, anywhere, for 502/503/504.** `perform` throws every non-2xx straight up; `SearchQuery.swift:182-186` records the API answering 503 twice for a legal parameter. That is a defensible design given the shared budget, so this is an *other way*: one retry, GETs only, on 502/503/504, after 500–1500 ms jitter, never on 429. Cost: doubles the worst-case latency of a transient failure and spends a second slot. Only worth it if `NetworkLedger` shows 5xx as a real share of failures — nothing on record says it is. Lens 5.
- **15. `TitleSettings.set`** reads `store` outside the lock (`TitlePreference.swift:66`) while `resetForTesting` writes it under the lock (`:74`). Benign in production (`store` never changes); a test-only race. A line. Lens 9.
- **16. `TagTaxonomy.loadResult`** (`TagTaxonomy.swift:28`) is a lazy static: the first `bundled()` call does the file read and a 2,686-row decode synchronously on whichever thread asks, and two of the four callers are views (`TagPickerSheet.swift:364`, `BlockedTagsSection.swift:207`). GUESS 10–30 ms, once per process, on the main thread if the picker opens before the first search. Warm it from `OfflineCatalogue`'s background setup or make the first read async. Lens 7.
- **17. `SeriesImage.id`** falls back to `"\(index)-\(language)"` (`SeriesImage.swift:29`) when both `id` and `raw` are nil; two such rows collide and `ForEach` misbehaves. Spec has `id` nullable; the `/images` payloads seen carry ids. Worth checking; a line (append `indexNumeric`/`type`). Lens 1.
- **18. `/v1/series/{id}/relationships` is 22 KB per row** (request 2): the nested `series` is the full v1 record with `links`, `tags_v2`, `relationships` of its own. The series page fetches it once (`SeriesRepository.swift:856`); the library continuations row fetches it ten times a page (`LibraryView.swift:145`) — ~0.7 MB per library page for cards that need a title, a cover and a relation type. Nothing in-slice can shrink the response; the out-of-slice option is to read `relationships_v2` off the `/v1/series/{id}` the page already fetched (it is in the payload — 36 keys today — and unmodelled) and fetch only the related ids' covers via the cheaper v2 endpoint. Cost: a second request per relation; worth it only for the library row. Lens 6, 3.

---

## Where every decoded type stands — the evidence question

For each type: is there a captured payload beside the Swift type, and when. Changes since
yesterday's table are in bold.

| Type | Endpoint | Evidence, date | Gap |
|------|----------|----------------|-----|
| `Series` v2 | `/v2/series/*` | `rising.json` 09-08; `search-solo-leveling.json` 09-13; **live headers + row today** | `.0` integers, finding 11 |
| `Series` v1 | `/v1/series/{id}`, `/v1/my/library`, mix | `mix.json`, `library.json` 09-09/09-13; live 638 09-13; **nested in relationships today** (`total_chapters: "270"`) | — |
| `Cover` | both shapes | `Cover.swift:25-28` 09-09; today | — |
| `SeriesTitle` | both | `SeriesTitle.swift:12-14` 09-08; 638 09-13 | order not stable (fixed in `DisplayTitle`) |
| `SeriesTag` | `tags_v2` | 3397 09-11; 638 09-13 | — |
| `Recommendation`, `BlendDNA.Strand` | mix | `mix.json` 09-09 (has `dna`, `seed_count`, 10× `tag_id`/`weight`) | — |
| `SeriesWork` | `/works` | live 09-11; `release_date` 50/50 ten chars 09-13 | fixtures still hand-built |
| `SeriesLink`, `NewsItem` | `/links`, `/news` | `SeriesExtrasTests.swift:29-48` 3397 | `published_at` seen once |
| `SeriesRelationship` | `/relationships` | **live 3397 today: `series` nested with `titles`; 3 rows, 67 KB** | — |
| `SeriesImage` | `/images` | 3397 09-12 | `id` nullable, finding 17 |
| `SeriesEdition` | `/collections` | comment 09-10 (`SeriesEdition.swift:7`) | no fixture file; spec agrees on `id`, `medium`, `status` |
| `PublisherDetail` | `/publishers/{id}/full` | Ize Press 09-11, Yen Press 09-13, **Kodansha USA 09-13 (`founded` date)** | `id` is `number\|null` in spec, `Int` here — fetched by id, theoretical |
| `PublisherRecord` | `/publishers/search` | **`publishers-search-2026-09-13.json`** | — |
| `Tag` | `/v1/tags` | **`tags-page1.json`, `tags-search-2026-09-13.json`** | `level`/`series_count` are `number`, finding 11 |
| `Genre` | `/v1/genres` | **`genres-2026-09-13.json`** | — |
| `CommunityPulse` | `/v0/frontpage/community-pulse` | live 09-11 | — |
| `Pagination` | any | 09-10; **today: `{count, next, previous, page, limit}`** | — |
| `ResultsEnvelope` | recommendations | 09-09 | — |
| `APIErrorEnvelope` | non-2xx | 09-13 | — |
| `TagTaxonomy.Row` | bundled file | 2026-08-27 fetch | no test asserts the bundle decodes — `CatalogueTests.swift:322-329` passes in both states (W12, still true) |

Every type in the slice now has a dated payload. The remaining charter-§1 exposure is not a
missing payload but a missing *width*: a field typed from one or two examples (`Int?` on
`number`, `Date?` on one `published_at`), which finding 5's lossy decodes turn from "section
vanishes" into "one row vanishes, counted".

## Decode failures a caller cannot tell from empty — in-slice count

- `CatalogueService.swift:130` `searchTags` → nil; `:202` `publisher(id:)` → nil; `:206` `searchPublishers` → nil. All three collapse offline / 429 / 500 / decode into one nil; the comments (`:125-127, 143-146`) argue nil-vs-`[]` is the line that matters on screen, which is true for the screen and false for anyone reading the ledger — a decode failure on `/v1/publishers/search` is the W1 bug re-happening, and nil is how it hid. `Fetched` (`Fetched.swift:14`) exists for exactly this and the two sibling methods in the same actor already use it (`:44-65, :69-108`). A function each.
- `APIClient.profile()` (`APIClient.swift:384`) → nil, deliberately, with `verifiedProfile()` beside it. Fine.
- `TagTaxonomy.swift:82, 86` → `([], true)`: distinguished by `loadFailed`; no production caller reads `loadFailed` (grep today: only `CatalogueTests.swift:325-327`) — charter §3 in miniature. And that test (`:322-329`) asserts only that `bundled().isEmpty` and `loadFailed` agree, so it passes with a missing bundle *and* with a present one — it cannot fail on the packaging bug it describes (charter §5). Wire `loadFailed` into the picker's empty state, and make the test assert `!loadFailed && !bundled().isEmpty` outright.
- `Cover.swift:42, 45` per-variant `try?` — correct: a variant is either shape and absence is meaningful.
- `Series.swift:359-366, 373-374, 386-389, 406-408` — per-field leniency with the reason written down. Correct.
- Everything else in the slice throws typed `APIError`. Three sites, one function each, and the in-slice count is zero.

---

## What the slice does well

- **Yesterday's findings were fixed at the source, with the measurement kept.** `Catalogue.swift:60-68` names the publisher, the date and the fixtures that missed it; `Series.swift:131-136` names the input that would have trapped; `APIClient.swift:300-313` explains why `isValidJSONObject` must run first and what `try?` cannot catch; `APIClient.swift:606-615` records that `TimeInterval("nan")` parses, "confirmed on device, not an assumption". `SearchQuery.swift:105-113` records a *non*-bug as NOT A BUG with both request forms and the id they returned. This is the standard the charter asks for and it is met.
- **Guesses are labelled and dated.** `APIClient.swift:26-33` (timeout), `RateLimitGate.swift:83-90` (cap), `:101-106` (reserve), `:110-114` (poll interval), `SearchQuery.swift:168-169` (minimum length). Each says what would replace the guess.
- **The gate has the tests its design claims.** `RateLimitTests.swift:257-304` prove the 21st background request waits, a user search is not queued behind waiters, and a cancelled wait throws `.cancelled` — the three properties `RateLimitGate.swift:62-67, 117-129` promise.
- **Failure is a type, not a nil.** `Fetched` (`Fetched.swift`) with its `isPartial` rule ("the cache layer must refuse to persist a value with this set", `:26-30`) and `MixResult.failure` (`BlendDNA.swift:58-64`) both carry the gap number they closed.
- **The wire is measured for counts, not just shapes.** `SearchQuery.swift:14-17, 22-28, 121-128` record `tag=` versus `genre=` versus `tag=<id>` with the result counts; `TagTaxonomy.swift:153-162` records the 37/18/2/3 rating split under one root. These are the numbers a future change will be argued against.
- **No force-unwrap, `try!`, `as!` or `fatalError` in the slice** — re-verified by grep today, 0 hits across 35 files. Finding 2 is the same hazard spelled `Int(`.
- **`LossyArray` reports what it dropped** (`LossyArray.swift:9-11`) and its tests include a control (`LossyArrayTests.swift:21-28`).

## Could not determine

1. **Does URLCache serve a second identical search inside 60 s without a network round-trip, and does it serve a fresh cached 200 to a request carrying `If-Modified-Since`?** One test through `URLProtocolStub` counting `startLoading` calls settles both and decides finding 1's refund and whether the conditional GET (`APIClient.swift:505`) ever re-sends inside `max-age`.
2. **Does `.reloadIgnoringLocalAndRemoteCacheData` write to URLCache?** The test in finding 7.
3. **What a MangaBaka 429 carries.** Still uncaptured; do not provoke it.
4. **Keychain read cost** (finding 8) and **`ISO8601DateFormatter` construction cost** (finding 6): 100 and 1,000 iterations respectively, on device.
5. **Whether any `number`-typed integer arrives as `N.0`** (finding 11): `grep -E '\.0[,}]'` over the 450-series sample from 2026-09-12. No request needed.
6. **Whether CDN-served search responses count against the 30/min.** Today's headers say Cloudflare caches search for an hour (`cdn-cache-control: public, max-age=3600`). If edge hits are not counted, identical repeat searches are free and the local window is stricter than the server. Two identical requests with `cf-cache-status` inspected, then a third distinct one, against a known count — but that is three of the shared 30 and the answer only matters for finding 1's sizing. Ask MangaBaka instead.
7. **Whether the 180/min general cap is ever reached in practice** (finding 3's (a) versus (b)). `NetworkLedger`'s per-minute request count over a library page + Discover session says so; nothing on record has looked.
