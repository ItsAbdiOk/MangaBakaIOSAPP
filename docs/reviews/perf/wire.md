# Wire slice — perf review, 2026-09-15, HEAD 1f5e632

Read-only. Slice: `MangaBaka/Core/Networking/**` (12 files, 1,997 lines) and `MangaBaka/Core/Model/**` (26 files, 3,989 lines).

**Summary**
- Files reviewed: **38 of 38**; 35 read in full, 3 read for their code with doc comments stripped (`SeriesStatus`, the tail of `SeriesWork`, `ReadingPlatforms` past `allows`). Read for context, not reviewed: `SeriesDetailView.swift:280-300, 540-660, 700-716`, `DetailOnwardRows.swift:180-200`, `LinksSection.swift:20-35`, `ReadRow.swift:22-34`, `LibrarySort.swift:20-120`, `SearchModel.swift:155-225`, `SeriesRepository+Cache.swift:300-340`, `OfflineCatalogue.swift:434-462`, `NetworkLedger.swift:57-63`, `AppServices.swift:320-330`.
- Findings: 16 — **certain 11, likely 3, worth checking 2.** Six are for Abdi's two asks directly (P1–P6).
- Single highest-value change: **P1 + P2 together, in `RateLimitGate` only** — a `.background` waiter should wait out a real 429 instead of throwing (`:298`), and a `.userInitiated` request that finds the local window full should wait for the oldest slot to expire (bounded, deadline already computed at `:210`) instead of throwing. Both are a function each; between them they remove every "Too many requests" card the gate itself creates, and the five background legs of a series page stop rendering `InlineFailure` for work the reader never asked for.
- Fixtures checked against the models: every type touched by today's seven `2060`/`similar`/`readers-also-like` captures decodes as modelled; two typed-without-evidence fields remain (P12).
- Not re-filed: everything in `docs/reviews/full/wire.md` (#1–#18) and `full2/SUMMARY.md` W1–W16 that I re-read is fixed in code with a dated comment, except where noted "still true" below.

---

## Requests in flight (this slice)

The slice owns the *mechanism* for every MangaBaka request and *originates* seven of them. Everything else fires from repositories/features (see `detail-page-budget.md`, updated today, for the series page's 8).

| # | Call | File:line | Trigger | Priority | Awaited before draw? | Could be |
|---|------|-----------|---------|----------|----------------------|----------|
| 1 | `GET /v1/genres` | `CatalogueService.swift:56` | first Browse/Search-filter surface that asks | `.userInitiated` (default) | yes — the vocabulary gates chips | `.background` when warming; cached for the process once loaded (`:23`) |
| 2 | `GET /v1/tags?limit=N` | `CatalogueService.swift:81` | Browse (200) / tag picker (500) | `.userInitiated` | yes | later: prewarm at `.background` after launch; P14's clobber means a third caller re-asks |
| 3 | `GET /v1/tags?q=…` | `CatalogueService.swift:135` | tag picker keystroke, 250 ms debounce (`TagSearch.swift:35`) | `.userInitiated` | no — local matches draw first (`TagSearch.swift:73`) | fine as is; general family, not search |
| 4 | `GET /v1/publishers/search` ×1–3 | `CatalogueService.swift:213` via `:171-174` | series page "publisher" chip; composite names retry as halves | `.userInitiated` | no | `.background` — decorates a chip |
| 5 | `GET /v1/publishers/{id}/full` | `CatalogueService.swift:207` | publisher page open | `.userInitiated` | yes | — |
| 6 | `GET /v0/frontpage/community-pulse` | `CommunityPulseService.swift:60` | every Discover appearance until it lands | `.userInitiated` — **cannot be otherwise**, `getRoot` takes no priority (`APIClient.swift:376-380`) | no — "a grace note" per its own comment | `.background`, once `getRoot` accepts one (P5) |
| 7 | `GET /v1/my/profile` | `APIClient.swift:415, 426` | token entry, sign-in check | `.userInitiated` | yes | — |

Mechanism facts that shape every other request:
- One `URLSession`, `.default` configuration, 20 s request timeout (a labelled guess), shared connection pool (`APIClient.swift:34-45`). Third parties share a second, ephemeral, cookie-less session (`ThirdPartySession.swift:43-61`). Good.
- Every request: gate → Keychain-memoised token → transport → ledger → 429 check (`APIClient.swift:131-246`). Decode happens **on the `APIClient` actor**, serialised with every other request's entry and exit (P7).
- `get`, `getWithPagination`, `total`, the conditional `get` and the three `getLossy*` accept a priority and **default to `.userInitiated`** (`APIClient.swift:61, 84, 110, 579`; `LossyArray.swift:52, 66, 80`). `getRoot`, `getResults`, `post`, `patch`, `delete` accept none (`APIClient.swift:376-409, 286-319`). App-wide, 10 call sites pass `.background`; ~25 take the default.
- Conditional GETs use `Last-Modified`/`If-Modified-Since` (no ETag on the wire, measured 09-13, `APIClient.swift:551-557`). A 304 costs a slot but zero bytes. Used for feeds only (`SeriesRepository+Cache.swift:366, 376`); the 6-hour `extras` bundle is not conditional.

---

## Findings

### P1. A `.background` waiter throws on a 429 instead of waiting it out, so the five "invisible" series-page legs surface a card
- **What** — `waitForBackgroundSlot` calls `throwIfBlocked` on every poll (`RateLimitGate.swift:298`); a 429 earned by *anyone* in the family throws `.rateLimited` into every background waiter at once. The doc comment justifies it as "waiting out a real 429 without limit would just be a slower way of hammering it" (`:173-176`) — but a waiter sends nothing until `blockedUntil`, which is already capped at 15 min (`:139`) and cancelled the moment the screen goes away (`:295`). Waiting is the opposite of hammering.
- **Where** — `RateLimitGate.swift:298` (the throw), `:173-176` (the reasoning). Consumer: `DetailOnwardRows.swift:190-194` renders `InlineFailure` for a failed `similar`/`readersAlsoLike` leg — both `.background` since today (`detail-page-budget.md`).
- **Why it matters** — This is ask 1 verbatim. One real 429 on the general family (a stranger on the same NAT, or the reader's own fast walk) puts up to five "Too many requests, briefly" cards on a page whose three foreground legs may have loaded fine. `detail-page-budget.md`'s "the five background legs wait at the gate instead of throwing" is only true for a *full local window*; on a server 429 they throw.
- **Effort** — a function: in the loop, `if let until = blockedUntil[family], until > clock.now { sleep; continue }` instead of `try throwIfBlocked(family)`. Keep the throw for `.userInitiated` (`:196`). Test: `recordRateLimit` then a `.background` `reserveSlot` on a moved clock resolves rather than throws; the existing `cancelledBackgroundWaitNeverSends` (`RateLimitTests.swift:310`) is the control.
- **Confidence** — certain.

### P2. `.userInitiated` throws the instant the local window is full — still true at a new line, and the deadline it throws is the wait it could have taken
- **What** — `full2/SUMMARY.md` decision 7 recommended waiting; not done. `reserveSlot` throws `.rateLimited(until: held[0] + 60 s)` at `RateLimitGate.swift:209-212`. That `until` is by construction ≤ 60 s away and, in the burst that fills a window, usually a few seconds.
- **Where** — `RateLimitGate.swift:198-212`.
- **Why it matters** — 20 cold opens a minute is one every 3 s — a reader flicking through the stack does that. The 181st general request is a card on a page the reader just opened, indistinguishable from MangaBaka being down. With a bounded wait the same reader sees the skeleton for a few seconds longer and never learns the word "throttled".
- **Effort** — a function. Shape that survives a pathological burst: wait when `deadline − now ≤ Metrics.foregroundWaitCeiling` (GUESS 10 s — label it), otherwise throw as today with the deadline. Record the decision in the comment; SUMMARY says this will be re-proposed otherwise, and here it is.
- **Confidence** — certain about the code; the 10 s is a guess.

### P3. A request cancelled mid-flight is refunded as if it never left the device, so the search window under-counts by one per keystroke
- **What** — `perform` refunds the slot on `URLError.cancelled` under the comment "same 'never reached the network' reasoning as `.offline`" (`APIClient.swift:164-173`). A request cancelled 50–500 ms after it started has reached MangaBaka; the server counted it.
- **Where** — `APIClient.swift:172`. Producer: `SearchModel.queryDidChange` "cancels whatever debounce **or in-flight search** is pending" (`SearchModel.swift:157-161`), so a keystroke that lands during a 300–500 ms round trip cancels a request the server already served. `TagSearch.update` (`TagSearch.swift:61`) does the same on the general family.
- **Why it matters** — The local 30/min search gate exists so the app "should not have to spend a real request to be told it is over" (`RateLimitGate.swift:13-15`). Every refunded cancellation is a request the server counted and the gate did not; a slow-but-steady typist earns a real 429 with the local window reading, say, 18. Then `recordRateLimit` closes search for 2/4/8… s and the reader gets the card the window was built to prevent. No test pins this refund (`APIClientCacheAndPrivacyTests.swift:67-160` covers cache hits only).
- **Effort** — a line: delete the refund at `:172` (over-counting is the safe direction; a cancel before the first byte is rare because URLSession dispatches within milliseconds). Or, the honest version: refund only when `metricsDelegate` recorded no transaction — worth checking whether `didFinishCollecting` fires for a cancelled task; if it does, `transactionMetrics.last?.fetchStartDate == nil` is the test.
- **Confidence** — certain the refund happens on every mid-flight cancel; likely that such cancels are common in typing (unmeasured — one `print` in `perform`'s cancel branch over a typed query would count them).

### P4. Nothing distinguishes "background work is in flight" from "the reader tapped" below the gate: no request priority reaches URLSession, and all decodes share one actor lane
- **What** — Ask 2 is "what competes with a tap". On the gate: nothing — a `.userInitiated` request never waits behind background (it is checked against the full window, `RateLimitGate.swift:198`). The competition is *after* the gate: (a) five 20–70 KB background bodies share one HTTP/2 connection with the tapped page's `full`, and `perform` sets neither `URLRequest.networkServiceType` nor a task priority (`APIClient.swift:140-155`, `:462-495`); (b) every response is decoded inside the actor (P7).
- **Where** — `APIClient.swift:439-496` (`makeRequest` — no service type), `:153-155` (`data(for:delegate:)` gives no task handle to set `.priority` on).
- **Why it matters** — A "tap cancels the background leg" mechanism, which the brief asks the cost of: **cheap and mostly already there.** Waiting legs honour `Task` cancellation (`RateLimitGate.swift:295, 308-313`) and an in-flight one is cancelled by URLSession when its `Task` is — so the cost is one `Task` handle per background leg in the caller and a `cancel()` on tap. The catch is P3: today that cancel *refunds a spent slot*, so cancelling background on tap would make the under-count worse. Fix P3 first.
- **Effort** — a few lines for the cheap half: `request.networkServiceType = .responsiveData` for `.userInitiated` (HTTP/2 stream weighting is up to the stack; worth checking on a trace whether it changes anything). The decode half is P7. A gate-level "yield while a foreground request is at the gate" is ~15 lines (`foregroundDemand` counter checked in the wait loop) but buys little, since foreground never waits at the gate anyway.
- **Confidence** — certain about what is and is not set; worth checking whether the service type moves a measurement.

### P5. The five entry points with no `priority` parameter make the launch path foreground by construction
- **What** — Still true at a new line since `full/wire.md` #3: `getRoot`, `getResults` (`APIClient.swift:376-409`) and `post`/`patch`/`delete` → `send` (`:286-360`) take no priority, and `perform`'s default is `.userInitiated` (`:134`). So the community pulse (`CommunityPulseService.swift:60`), recommendations (`LibraryService.swift:337`), mix (`SeriesRepository+Mix.swift:40`) and every library write — including a bulk import — are foreground and compete for the reader's 60-slot reserve.
- **Where** — as above.
- **Why it matters** — A 937-row `LibraryImport` is up to 1,874 `.userInitiated` general writes; the 181st in a minute throws rather than waits (P2), and it cannot opt into waiting because `send` has no parameter to pass. `open-items` "LibraryImport request spacing" is the symptom; this is the missing knob.
- **Effort** — a few lines: thread `priority` through the five and `send`. Separately, consider removing the `.userInitiated` **default** altogether (mechanical, ~30 call sites) — today a new caller is foreground unless it remembers to say otherwise, which is the wrong failure direction for ask 2.
- **Confidence** — certain.

### P6. A timeout or DNS failure hides the cached copy: `.transport` is one string for six different `URLError`s
- **What** — Only three codes become `.offline` (`APIClient.swift:156-158`); `.timedOut`, `.cannotFindHost`, `.dnsLookupFailed`, `.cannotConnectToHost`, `.internationalRoamingOff`, `.callIsActive` all become `.transport(localizedDescription)` (`:174-176`), and `staleContentRemainsUseful` is **false** for `.transport` (`APIError.swift:214-218`). A caller cannot tell a 20 s timeout from a TLS failure — the code is stringified.
- **Where** — `APIClient.swift:174-176`, `APIError.swift:216-217, 323-324`.
- **Why it matters** — On a slow link the series page's `full` leg times out after 20 s and the page *hides* the 6-hour cached copy it was already holding, under "The request didn't complete." A transport failure says nothing about the cache; only `.decoding` does. This is the "here is what we had" half of ask 1 for the non-throttle case.
- **Effort** — a line: `case .offline, .rateLimited, .server, .cancelled, .transport: true` — or, better, carry the `URLError.Code` in `.transport` and route the six unreachable-ish codes to `.offline`.
- **Confidence** — certain about the mechanism; the on-device frequency is unmeasured (`NetworkLedger` records `failed` but not why).

### P7. Every decode runs inside the `APIClient` actor, so a big response delays the *start* of the next tapped request
- **What** — `decodeEnvelope` is actor-isolated (`APIClient.swift:514-525`, called from `:65, 88, 602`); `total`, `getRoot`, `getResults` decode inline too (`:114, 383, 399`). `JSONDecoder.decode` is synchronous; while it runs, no other `perform` can enter the actor to reserve its slot or attach its token.
- **Where** — `APIClient.swift:514-525, 65, 88, 114, 383, 399, 602`.
- **Why it matters** — A `/relationships` page is 67 KB (22 KB per nested `Series`, `full/wire.md` request 2); a library page is ~30 full v1 rows. GUESS 3–10 ms per such decode on device, 20–40 ms for a library page. During the 19-page library walk every request the reader starts waits behind whichever page is decoding. Not a dropped frame (the actor is off-main); a late tap.
- **Effort** — a function: make the decode `nonisolated static` and call it after `rawData` returns. `JSONDecoder` may not be `Sendable` in this SDK (worth checking); if not, `Self.makeDecoder()` per call is microseconds and the strategy closure is already static.
- **Confidence** — certain about the isolation; cost is a guess. One `Signposts.measure` around the decode over one library walk settles it.

### P8. `Dictionary(uniqueKeysWithValues:)` on the API's `dna` array traps on a duplicated `tag_id`
- **What** — `BlendDNA.moves` builds `previous` with `uniqueKeysWithValues` from `before.strands` (`BlendDNA.swift:32`); strands are decoded straight from `/v1/series/mix`'s `dna` (`SeriesRepository+Mix.swift:45`). Two strands with one `tag_id` crash the Mix screen on its second blend. `TagTaxonomy.swift:116` records that this initialiser traps on exactly such twins in the bundled data.
- **Where** — `BlendDNA.swift:32`.
- **Why it matters** — CLAUDE.md's force-unwrap rule in another spelling, reachable from the network. `mix.json` (09-09) has 10 unique ids, so it has not been seen — a negative result, not a proof.
- **Effort** — a line: `Dictionary(_, uniquingKeysWith: { first, _ in first })`.
- **Confidence** — certain mechanism; the input is unobserved.

### P9. `Int(trim.wMm.rounded())` traps on a server value outside ±9.2e18
- **What** — `trimLine` converts two decoded `Double`s with plain `Int(_:)` (`SeriesWork.swift:169`), the exact pattern `Int+Clamped.swift:4, 28` exists to replace and `CommunityPulse.swift:75` already uses it for.
- **Where** — `SeriesWork.swift:166-170`.
- **Why it matters** — One row with `"w_mm": 1e300` crashes the volumes shelf for every reader of that series. Same class as `full2` item 53.
- **Effort** — a line: `Int(wholeOrClamped:)` twice.
- **Confidence** — certain.

### P10. `LossyArray` counts what it dropped and forgets why
- **What** — `try? container.decode(Element.self)` (`LossyArray.swift:23`) discards the `DecodingError`; only `dropped += 1` survives, to `NetworkLedger.recordDropped(path:count:)` (`NetworkLedger.swift:57-63`), which is a count. A `tags_v2` or `works` shape change reaches Abdi as "3 rows dropped" with no key name.
- **Where** — `LossyArray.swift:23-27`.
- **Why it matters** — Debuggability. Charter §1's whole history is shape changes found by reading, and the one counter that would flag them cannot say what changed. `Series.init` logs its own drop count (`Series.swift:189-193`) — also without the reason.
- **Effort** — a few lines: `catch { if firstError == nil { firstError = String(describing: error) } }`; carry `firstError` on the struct; log it once per path in `getLossy` (`LossyArray.swift:56`). The `DecodingError` description names the coding path and key.
- **Confidence** — certain.

### P11. The gate's refusals are invisible to the ledger and to the console
- **What** — A local refusal (`RateLimitGate.swift:209`) makes no request, so `NetworkLedger` has no row; a server 429 is a `failed` row with no status. Neither `RateLimitGate` nor `APIClient` has a `Logger` (grep: none in `Core/Networking`). "Was that card us or the server, and how often?" cannot be answered after the fact.
- **Where** — `RateLimitGate.swift:209-212, 334-343`; `APIClient.swift:231-244`; `NetworkLedger.swift` (no counters for either).
- **Why it matters** — The walk doc's three 429 cards were attributed by inference (`detail-page-budget.md` §3). Two counters per family — `localRefusals`, `serverRateLimits` — plus one `Logger.error` line at each site would have settled it in a minute.
- **Effort** — a few lines each.
- **Confidence** — certain.

### P12. Two `SeriesWork` sub-types are typed without a payload beside them
- **What** — `SeriesWork.Image.image: Cover?` is documented as "the same `Cover` shape … from `/v1/my/*`" (`SeriesWork.swift:47-52`); `series-2060-works-2026-09-15.json` has `images: []` on all 3 rows, and no other works fixture exists. `SeriesWork.Trim.wMm/hMm: Double` non-optional (`:37-40`) is typed from those same 3 rows of one series.
- **Where** — `SeriesWork.swift:37-40, 47-52`.
- **Why it matters** — Charter §1: a `trim: {"w_mm": null, …}` row, or an `image` object of a shape `Cover.init(from:)` does not accept, is one dropped row per `LossyArray` — silently, per P10. Today's fixture cannot fail either way. `SeriesWorkFieldsTests` covers `count_type` with hand-written JSON (`:102-105`), which is charter §2's fixture-from-the-model pattern for these two fields.
- **Effort** — a measurement: one `curl` of a series whose works carry images (ONE PIECE 377 has 267 printings, `detail-page-budget.md`), saved as a fixture; make `Trim`'s fields optional regardless (a line).
- **Confidence** — certain about the gap.

### P13. `DisplayTitle.choose` re-reads `Locale.preferredLanguages` and takes a lock on every call, and was fixed at one caller instead of at source
- **What** — Default arguments `Locale.preferredLanguages` and `TitleSettings.preference` (`DisplayTitle.swift:25-26`) evaluate per call: a CFPreferences read and an `NSLock` (`TitlePreference.swift:53-60`). `Series.displayTitle` (`Series.swift:337-339`) has 68 call sites, most in row bodies. `LibrarySort.swift:26-32` records the cost ("~18k of each plus ~54k `lowercased()` … per keystroke") and decorates its own sort; the other 67 callers still pay per access, and `ReleaseSchedule.swift:262-263` still compares per comparison.
- **Where** — `DisplayTitle.swift:23-27`.
- **Why it matters** — CLAUDE.md: expose a duplication at its source, not at one consumer. Every list row that reads `displayTitle` in `body` pays a preferences read per frame it is re-evaluated.
- **Effort** — a function: cache the normalised preferred-language codes once (invalidate on `NSLocale.currentLocaleDidChangeNotification`), and read `TitleSettings.preference` once per call only when `matching` needs it. Measure first: `measure {}` 10,000 `choose` calls before and after.
- **Confidence** — certain about the mechanism; cost is the sort file's own estimate.

### P14. `SearchQuery.wireTagIDs` rebuilds a 2,686-entry dictionary once per tag
- **What** — `tags.map { OfflineCatalogue.tagIDs(named: [tag]) … }` (`SearchQuery.swift:226-230`) calls a function that builds `Dictionary(TagTaxonomy.bundled().map { ($0.name.lowercased(), $0.id) })` on **every call** (`OfflineCatalogue.swift:434-441, 451-458`) — 2,686 `lowercased()` and inserts per tag, per `queryItems` evaluation. `queryItems` is evaluated per search, per lens count (`SeriesRepository+Count.swift:38`) and per mix (`+Mix.swift:23`).
- **Where** — `SearchQuery.swift:223-235` (the per-element call shape; in slice), `OfflineCatalogue.swift:436-438, 453-455` (the rebuild; out of slice).
- **Why it matters** — GUESS 2–5 ms per tag on device, off-main (repository actors) but on the critical path of every search. Five lenses × two tags each on the idle screen ≈ 20–50 ms of pure rebuild.
- **Effort** — a few lines: pass `tags` once (`tagIDs(named: tags)` returns ids in order — map back by index), and make the two dictionaries `static let` beside `TagTaxonomy.loadResult`.
- **Confidence** — certain about the rebuild; cost is a guess.

### P15. `CatalogueService.tags(limit:)` clobbers a bigger in-flight fetch's registration and its cached limit
- **What** — Caller A (200) sets `tagsInFlight = taskA`; caller B (500) replaces it with `taskB` (`CatalogueService.swift:104-105`); A completes and sets `tagsInFlight = nil` and `cachedTagLimit = 200` (`:107-111`) — B's registration is gone, so a third caller at 500 starts a duplicate request, and if B finishes first A's completion later shrinks `cachedTagLimit` back to 200 so the next 500 ask refetches. Same shape as `full2` item 48 (`StackModel.refill`).
- **Where** — `CatalogueService.swift:104-111`.
- **Why it matters** — One or two extra `/v1/tags?limit=500` requests when Browse and the picker open close together; each is 500 rows.
- **Effort** — two lines: `if tagsInFlight == task { tagsInFlight = nil }`; `cachedTagLimit = max(cachedTagLimit, limit)`.
- **Confidence** — certain for the clobber; likely rare.

### P16. `CommunityPulseService.load()` has no in-flight guard
- **What** — `guard pulse == nil` and a 60 s post-failure floor (`CommunityPulseService.swift:56-58`), but nothing for "a request is already out": two Discover appearances inside one round trip fire two `/v0/frontpage/community-pulse` requests, both `.userInitiated` (P5).
- **Where** — `CommunityPulseService.swift:55-67`.
- **Why it matters** — One wasted general slot on the launch path, exactly when the reserve matters most.
- **Effort** — a few lines: hold the `Task` and `await` it, as `CatalogueService.genres()` does (`:47`).
- **Confidence** — certain; the double-appearance is a "worth checking" on device.

---

## The gate, end to end (ask 1 and ask 2)

Arithmetic, read from `RateLimitGate.swift`:
- Two families by path substring `/series/search` (`:87-91`): search 30/min, general 180/min (`:50-55`, the API's numbers). Reserve for `.userInitiated`: 10 and 60 — labelled guesses (`:60-69`). Window 60 s, sliding, pruned on every check (`:278-281`).
- `.userInitiated`: `throwIfBlocked` (429 memory) → prune → append if `held.count < limit` else throw with `held[0] + 60 s` (`:194-213`). Never waits, never queues.
- `.background`: FIFO ticket (`:290-292`); on each 200 ms poll (`:162`): cancelled? → `.cancelled`; family 429'd? → **throw** (P1); head of queue and `held.count < limit − reserve`? → take a slot (`:301-305`). Drains at ≤ 5 waiters/s.
- Refund removes the exact timestamp (`:247-254`) — correct under concurrency. Refunded on URLCache hit (right), `.offline` (right), `.cancelled` (P3).
- 429: `blockedUntil = now + min(Retry-After ?? min(2^n, 60), 15 min)` (`:334-343`); success clears it (`:351-355`). Sound.

**Is the 60-slot reserve the right shape?** For its stated purpose — background must never starve the reader — yes, and it is the simplest shape that guarantees a floor. What it does not do is make throttling *invisible*, because both refusal paths still throw: the reader's own 181st (P2) and any real 429 for background (P1). A queue would not help the reader's path — a foreground request already jumps every background one at the gate — and the head-of-line FIFO for background is fine at 5/s. So: **not a queue redesign; two waits.** After P1+P2 the only card the gate can produce is a real 429 on a `.userInitiated` request, which is the honest one.

**What competes with a tap** (ask 2, wire layer only): nothing at the gate; the decode lane (P7); the connection (P4); and the launch path's foreground-by-default calls (P5). Prefetch is a caller concept — the wire does not know one; `RequestPriority` is the whole signal, and it stops at the gate.

**"Tap cancels the background leg" cost:** one `Task` handle per leg and one `cancel()` — cancellation already propagates into the wait loop and into URLSession. Fix P3 first or every cancel gives back a slot the server kept.

---

## `APIClient` — the questions asked
- **Connection reuse / configuration** — one static session (`:45`), default cache policy, no `waitsForConnectivity` (so offline fails fast — right for stale-content fallback). Nothing to change.
- **Timeouts** — 20 s request, labelled guess (`:26-33`), copied as a literal to `ThirdPartySession.swift:58` with the copy recorded as such. `NetworkLedger` has the latencies to size it; nobody has read them yet (SUMMARY U9, still open).
- **ETag / `Conditional`** — measured: no ETag, `Last-Modified` only (`:551-557`); 304 is zero bytes (`:537-538`). Used for feeds. Not used for the 6 h `extras` bundle — an idea, not a finding: a conditional `/v1/series/{id}` after expiry would be a 0-byte 304 most of the time.
- **Decode cost** — `LossyArray` per element is `try?` + `Blank` on failure (`LossyArray.swift:20-29`): a failing element is parsed twice; a passing one once. Negligible. `Series.init(from:)`'s lenient decodes construct a `DecodingError` per string-typed numeric on v1 (three per row, `Series.swift:161-163`) — microseconds. Nothing is decoded twice at the client level: `total` decodes `PaginationOnly` only (`:114`); non-2xx decodes `APIErrorEnvelope` once (`:261`).
- **Where decoding runs** — the `APIClient` actor (P7). Not main.
- **Formatters** — the per-value `ISO8601DateFormatter` allocation is fixed with the measurement kept (`:656-676`). Good.

## `APIError` — can a caller always tell?
- Throttle vs offline vs decode: **yes**, three cases, and `party` separates MangaBaka search / MangaBaka / third parties (`APIError.swift:26, 61-99`).
- Throttle vs timeout vs DNS: **no** — all `.transport` with a human string (P6).
- Where `retryAfter` is lost: one place — a 502/503 carrying `Retry-After` becomes `.server(status:message:)` with no deadline (`APIClient.swift:258-266`); `SearchQuery.swift:182-186` records the API answering 503. Minor: the third-party clients route theirs through `RequestSpacing.backOff(retryAfterHeader:)` (`RequestSpacing.swift:68-85`), which clamps and returns the honoured value. A 429's header is parsed, capped, and the gate's date is the one thrown (`APIClient.swift:231-244`) — right.
- `.decoding`'s message promises "Cached copies were cleared" (`APIError.swift:318-322`). Not verified in this slice that any caller clears; worth checking (out of slice).

## `Codable` vs evidence — today's fixtures
Only what is new since `full/wire.md`'s table.

| Type | Fixture (2026-09-15) | Agrees? | Note |
|------|----------------------|---------|------|
| `Series` v1 | `series-2060-record` | yes | `anime: null` **with** `has_anime: true` — handled by `hasAnimeAdaptation` (`Series.swift:353-355`). `genres_v2: null`. `total_chapters: "311"`, `final_volume: "20"` strings. Unmodelled and unread: `canonical_url`, `last_updated_at`, top-level `title`, `links` (18 bare URL strings), `relationships` (`{"other":[5911]}` — id-only, so the `/relationships` leg still earns its nested series). |
| `Popularity`, `Published`, `SecondaryTitle`, `RelationshipV2` | same | yes | `relationships_v2` carries `is_manual`, `published_start_date` — unmodelled, fine. |
| `SeriesWork` | `series-2060-works` (3 rows, `limit=3`) | yes | `images: []` on every row → P12. `inc_chapters: null` on every row (recorded at `:54-60`). |
| `NewsItem` | `series-2060-news` (8 rows) | yes | all `published_at` in the `.000Z` form; `id` number; `mentioned_series` array. Unmodelled `series`, `source_id`, `created_at`, `updated_at`. |
| `SeriesEdition` | `series-2060-collections` (1 row) | yes | `links[0].link` is a URL string (decodes as `URL`); `related_collection_id: null` unmodelled. One row is thin evidence for `CollectionLink.link: URL?` — a malformed string drops the edition. |
| `Recommendation` | `similar-2060`, `readers-also-like-2060` (3 rows each) | yes | `shared_users: 798`, `rank: 1` as modelled; `shared_tags[].weight` unmodelled. Nested `series` lacks `year`, `tags`, `tags_v2` — as the model expects for v2. |

## Model size
- `Series.swift` (496) + `Series+Popularity.swift` (149): the split exists to satisfy `file_length`, not a seam. The 52-line memberwise `init` (`:217-269`) and the 35-line `filling(gapsFrom:)` (`:298-333`) are the generated-looking parts; both must be kept in step by hand when a field is added (six added on 09-15). A macro would generate both; without one, a test that round-trips every optional through `filling` would catch the omission.
- `withTags(_:)` (`Series.swift:280-289`) drops nine fields via the defaults — harmless today because its one caller feeds the taste ledger (`SeriesDetailView.swift:711`), but it is a copy with a silent hole. Could be `filling`-shaped or deleted in favour of `taste.note(series, tags:)`.
- Lenient decoders: `lenientDouble`, `lenientTagNames` (`Series.swift:451-477`), `TrackerEntry.init` (`:482-495`), `SeriesWork.IncludedChapters` (`SeriesWork.swift:61-77`), `Cover.variant` (`Cover.swift:41-49`) — five hand-written string-or-number/shape-A-or-B decoders. One `StringOrNumber<T>` property wrapper would replace three of them. Effort: a file; gain: the next v1/v2 disagreement is a type annotation, not a custom `init(from:)`.
- Deletable now: `APIClient.userAgent` (`APIClient.swift:20`) duplicates `AppUserAgent.value` (`AppUserAgent.swift:25`) byte-for-byte under a comment saying the string lives "in one place"; nothing reads `APIClient.userAgent` except `makeRequest` (`:488`). A line.
- `RateLimitGate.searchLimit/searchWindow/reserve` statics (`:149-154`) exist "because tests and comments use them" — five references outside the file (grep today), all tests. Retire them into `Family.search.limit` at those five sites; a line each.

## Main thread & rendering (helpers this slice hands to views)
- `SeriesLink.grouped(_:)` runs in `LinksSection.body` (`LinksSection.swift:28`) and `SeriesLink.readable` in `ReadRow.body` (`ReadRow.swift:29`): each link pays `ReadingPlatforms.allows` — a linear `hasSuffix` scan over ~130 hosts (`ReadingPlatforms.swift:67`) — per body evaluation. 21 links × 130 ≈ 2.7 k string compares per frame the section re-evaluates. Sub-millisecond; hoist into the model's `refreshDerived()` as `tagGroups` already is (`SeriesDetailView.swift:637-648`).
- `preferredCover` is a computed property on the view (`SeriesDetailView.swift:548-550`) filtering up to 50 covers per access; `frontCover` and the fan both read it.
- `Cover.url(forHeight:scale:)` builds up to six `URL`s by string replacement per call (`Cover.swift:115-134`); called from `CoverImage` per row per render (out of slice). GUESS 10–30 µs a call; memoising per (cover, height, scale) or computing only the winning ratio is a function.
- `SeriesWork.Volume.date/editionLabels` parse `release_date` with a `DateFormatter` per access (`SeriesWork.swift:172-175`, tail of the file); the volumes sort recomputes `compactMap(\.sequenceNumeric).min()` per comparison. Small at 100 rows.
- `DisplayTitle.choose` — P13.
- Nothing in this slice does DB reads or image work on the main actor. `TagTaxonomy.warm()` is called from a detached utility task (`AppServices.swift:325-329`) — the one main-thread decode the prior review flagged is closed.

## Rate-limit invisibility — what exists, what is missing
- Exists: `StaleBar` with a live `deadline` (`SeriesDetailView.swift:288`), `LoadingLine` (`:401`), `InlineFailure` per section (10 sites in `Features/Detail`), `CoverSkeletonRow`/`Grid`, `Fetched.failed(stale:)` so a section can show old content under a bar (`Fetched.swift:34, 62-68`). `APIError.rateLimited` copy never blames the reader (`APIError.swift:272-281`).
- Missing at the wire: the two waits (P1, P2) — every throttle card the gate creates is avoidable by waiting a bounded time while the skeleton stays up. And P6 — a timeout should read as "here is what we had", not hide it.
- Missing at the model: `Fetched` has no `.loaded(_, isStale: true)` / "waiting for a slot" distinction, so a section that is deliberately waiting at the gate is indistinguishable from one whose request is slow. It does not need one if the waits land — "still loading" is the desired reading — but a `deadline: Date?` on `.loading` would let `LoadingLine` say nothing and a debug overlay say why.

## Debuggability
- Swallowed with nothing logged: `LossyArray.swift:23` (P10); `CatalogueService.swift:135, 207, 213` (`try?` → nil, documented as "nil, not []", still no log — the reason is gone); `APIClient.profile()` (`:415`, by design, with `verifiedProfile` beside it); `decodeEnvelope`'s catch stringifies the error into `.decoding(underlying:)` (`:518-519`) and no caller in this slice logs `underlying` — one `Logger.error` there makes every shape change findable in Console.
- No counters: local refusals, server 429s, background wait durations (P11). One `Signposts.measure` around `waitForBackgroundSlot` would give the p50/p99 wait that decides whether the 200 ms poll (`:162`) matters.
- Invisible in production the same way as in tests: a background leg that waits > 60 s (possible after P1) has no timeout of its own — only `Task` cancellation. A `maxBackgroundWait` (GUESS 90 s, label it) that throws `.rateLimited` with the deadline would keep the invisible from becoming the eternal.

## Size
- `APIClient.userAgent` — delete (see Model size).
- `RateLimitGate.swift:177-192` — 16 lines of comment explaining what a previous comment wrongly said; the correction is on record in `full2` item 70, so the history can go and the four-line truth stay.
- `ThirdPartySession.make(configure:)` — "Nothing uses it yet" (`:39`); confirmed by grep today: no caller passes `configure`, and `make()` itself is called only by `shared` (`:67`). A parameter for a caller that never came (the pattern `RequestSpacing.swift:77-81` already removed once).
- `APIError.rateLimited(retryAfter:)` compat constructor (`:142-161`) — every third-party client still uses it; not dead.
- Duplicated logic: five lenient decoders (Model size); `SeriesLink.isOfferableToRead` evaluated in both `grouped` and `readable`.

## Good news
- **Measurements with dates, everywhere it mattered.** `APIClient.swift:180-196` records that `willCacheResponse` never fires under `data(for:delegate:)` — measured, and the eviction that replaced it says what residual it leaves. `:551-557` (no ETag), `Series.swift:41-48` (two `anime` shapes captured live), `SearchQuery.swift:14-17, 22-29, 105-116, 182-186` (nine live measurements including a NOT A BUG that says not to "fix" it without re-measuring), `ReadingPlatforms.swift:13-49` (a 1,631-link sample and an entry-by-entry audit with its one residual named). This is why P12 is findable at all.
- **The `Fetched` seam** (`Fetched.swift`) closes the "empty vs failed" collapse the charter's §1 examples all share, and `CatalogueService` uses it correctly: a failure is never cached (`:58-63, 100-102`).
- **`RateLimitGate.refund` is precise**, not "remove the last" (`:242-254`), and the cache-hit refund is tested with a control that proves the refund is conditional (`APIClientCacheAndPrivacyTests.swift:129-160`).
- **Every trap the previous review named is closed with the guard kept beside the reason**: `Int(wholeOrClamped:)` at `APIError.swift:201, 204`, `CommunityPulse.swift:75`, `Series.swift:168-169`; the third-party `Retry-After` clamp at `APIError.swift:157-159`; `parseRetryAfter`'s `isFinite` (`APIClient.swift:697-705`). Grep today: no `!`, `try!` or `as!` in the slice; P8 and P9 are the two that are not spelled `!`.
- **`TagTaxonomy.warm()` is wired** (`AppServices.swift:325-329`) — the one main-thread decode from `full/wire.md` #16 is off the main thread, with the guess it was made against still in the comment.
- **The one-`URLSession`-per-party design** (`ThirdPartySession.swift`) with cookies off is the privacy note made enforceable, and its comment records the five-cookie Webtoons measurement that motivated it.

## Could not determine
| Question | What would settle it |
|---|---|
| How often does a mid-flight cancel refund a slot the server counted (P3)? | One `print` in `perform`'s `.cancelled` branch, type "omniscient reader" at a normal pace, count the lines against `searchTimestampCountForTesting`. |
| Does `didFinishCollecting` fire for a cancelled task, with `fetchStartDate` set? (Decides P3's honest fix.) | A `URLProtocolStub` that delays 1 s; cancel at 100 ms; print the delegate's metrics. No live request. |
| What does one decode cost on the actor (P7)? | `Signposts.measure` around `decodeEnvelope` over one 19-page library walk on device; report p50/p99 and the sum. |
| Does `networkServiceType = .responsiveData` change anything on HTTP/2 to Cloudflare (P4)? | An Instruments network trace of one cold series open with and without; compare the `full` leg's time-to-first-byte while the five background bodies stream. |
| Is `JSONDecoder` `Sendable` in this SDK (P7's fix shape)? | Mark `decodeEnvelope` `nonisolated`; the compiler answers. Not run here — no build. |
| Are duplicate `tag_id`s ever sent in `dna` (P8)? | `jq '.dna | map(.tag_id) | length == (unique | length)'` over ten live mix responses. Fixture says 10 of 10 unique. |
| Do any works rows carry `images` in a shape `Cover` accepts (P12)? | `curl /v1/series/377/works?limit=50` (ONE PIECE), save as a fixture, decode through `Fixture.decoder()`. |
| How long do the five background legs actually wait at the gate on a cold open under Discover prefetch? | The `waitForBackgroundSlot` signpost above; one launch, Discover, three quick series opens. |
| Is 180/min ever approached on a real cold launch? (SUMMARY U9, still open; it decides whether P2 is ever hit.) | `NetworkLedger.shared.byPath` bucketed per minute across one cold launch on the 937-series account. One launch and a `print`. |
