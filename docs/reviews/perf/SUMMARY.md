# Perf review — synthesis

2026-09-15, HEAD `1f5e632`. Built from the eight slice reports in this directory, the charter, and the run brief. Read-only: this file is the only thing written. Nothing built or measured. Every top-ten citation below was re-opened at the line today; where a slice was wrong I say so.

IDs: W = wire, PS = persistence, R = reader, E = editions, L = library-ui, D = discovery-ui, DT = detail, S = surface. Numbers are each report's own P-numbers.

---

## 1. Counts

| Slice | Filed | Certain / likely / worth checking |
|---|---|---|
| wire | 16 | 11 / 3 / 2 |
| persistence | 14 | 8 / 3 / 3 |
| reader | 21 | 13 / 5 / 3 |
| editions | 19 | 9 / 5 / 5 |
| library-ui | 7 | 1 / 4 / 2 |
| discovery-ui | 7 | 2 / 3 / 2 |
| detail | 19 | 9 / 7 / 3 |
| surface | 22 | 9 / 9 / 4 |
| **Raw** | **125** | |

Cross-report duplicates (same defect, same line):
- DT4 = S7 — `LoadingLine`'s `TimelineView(.animation)` at opacity 0 (`LoadingLine.swift:36,49`).
- D1 ⊂ W5 — `CommunityPulseService` at `.userInitiated` because `getRoot` takes no priority (`APIClient.swift:376`).
- R4 = S12 — launch fetches ≤6 pages of `/v1/works/upcoming` and sequences zero-request work behind them (`RootView+Session.swift:396`).
- W11 = S18 — nothing counts local refusals, server 429s or background waits (`RateLimitGate.swift:209, 298`).

**Deduped: 121.** One slice claim corrected: D7 says `StackModel.failure` has no renderer — it does, `StackView.swift:488`, but only inside `emptyState`, so the narrower gap (a stalled refill with 1–2 cards left shows nothing) stands.

Regressions from today's commit: 12 of the 121 (section 11). Two are things fixed on 09-13/14 that came back.

---

## 2. The ten highest-value changes

Each: what · where · effort · which ask · the before-number that proves it. "Ask" keys: func / size / health / bug-prone / eff / speed / resp / debug / rl-invis / timing.

**1. Split `extras` so the hero draws from `full` and never waits for the background legs — DT1 (today's regression).**
`SeriesDetailView.swift:606-630` awaits similar, also, and `extras` — and `extras` (`SeriesRepository.swift:928-959`) assembles only when news/relationships/collections/works have all returned; works p1 additionally awaits the `.background` last page sequentially (`+Works.swift:39-41`). Five of eight legs now *wait at the gate* from 120 held (`RateLimitGate.swift:302`), so between 120 and 180 the synopsis, stats and tags stall for up to 60 s on a page that rendered yesterday. Verified at the lines. Effort: a function each side (`fetchExtras` returns `full`+works p1 first, tail second; `loadCore` writes `filled` after the first). Asks: speed, resp, rl-invis, bug-prone. Proof: `print(Date())` at `:612` and `:628` after a Discover fling that fills the window — today the gap is the gate wait; after, ≤ one RTT. Control: same page on an empty window, both numbers equal before and after.

**2. Two waits in `RateLimitGate` — W1 + W2.**
`:298` throws a family 429 into every `.background` waiter (a waiter sends nothing, so "waiting is hammering" is wrong); `:209-212` throws `.userInitiated` the instant the local window is full, with a deadline that is usually seconds away. Verified. Effort: a function each — background: `if blockedUntil > now { sleep; continue }`; foreground: wait when `deadline − now ≤ 10 s` (GUESS, label it), throw otherwise; add a `maxBackgroundWait` (GUESS 90 s) so the invisible cannot become eternal. Asks: rl-invis, resp. Proof: `RateLimitTests` — `recordRateLimit` then a `.background` `reserveSlot` on a moved clock resolves (throws today); 181st `.userInitiated` on a window whose oldest slot is 3 s old returns after 3 s (throws today). Control: `cancelledBackgroundWaitNeverSends` (`RateLimitTests.swift:310`) still passes. On device: gate counters from #8 — `localRefusals` per session before/after.

**3. Record the status baseline on every pass, not only on a `finished-` send — R1 + R2 + R3 (today's).**
`ReleaseReminders.swift:263-265` is the only status write and only fires for `finished-`; `:444-449` refuses to overwrite a seeded baseline. A series that enters hiatus after first sighting never has `previous == "hiatus"` (`NotificationPolicy.swift:158`), so "back from hiatus" cannot fire for the common case; a sent `back-` never advances either, so it repeats on day 61. `announced`/`lastKnownEpisode`/`notifiable` are computed and discarded at `NotificationPolicy.swift:111`. Verified. Effort: a function — after `applyFatigueGuard`, write `status` for every series with no candidate this pass; extend the send-time advance to `back-`; delete the two parameters and the episode baseline. Asks: func, bug-prone, size. Proof: a three-pass test `releasing → hiatus → releasing` expects one `back-` — zero today (every existing test starts on hiatus, charter §2).

**4. Take the discarded requests off the launch path and reorder `startSession` — R4/S12 + R5 + S11.**
`RootView+Session.swift:396` awaits `calendar.mine` (≤6 `.userInitiated` general requests) for a value `decide` throws away; `:400` spends one *search* request per followed publisher for a feature deleted 09-13; `session.library.load()`, Spotlight and the widget queue behind both. `AppServices.swift:431` fires `/v1/my/profile` at `.userInitiated` at t≈0 and a failure disables the Mix exclusion for the session, unlogged. Verified `:385-401`, `NotificationPolicy.swift:104-112`. Effort: lines (delete two calls, reorder to walk → library.load → widget → reminders; profile id persisted per token hash, fetched at `.background`). Asks: timing, speed, eff, rl-invis. Proof: `NetworkLedger.byPath` after one cold launch with reminders on and three follows — today ≥ 6 general + 3 search before Discover's rows can retry; after, 0 + 0. Control: the four Discover row requests still appear.

**5. Stop discarding the detail cache on rating / blocked-tag changes — PS1.**
`SeriesRepository.swift:642-643` (`.everythingDerived`) and `:656-658` (`[.feeds, .detail]`) rest on "those live in the detail cache". They do not: the page filters tags at display time from cached `richTags` with the current rating (`SeriesDetailView.swift:643-647`, verified), editions are sorted not filtered, images are not in the row. Each toggle deletes up to 200 × 204 KB inside the actor and makes every re-open 8 requests. Effort: a line each + three comments + `DetailCacheDiscardTests` doc. Asks: eff, timing, resp. Proof: toggle Erotica, re-open a series opened an hour ago — 8 requests in the ledger today, 0 after. Control: toggle a *format*, which never cleared `.detail`, and confirm 0 both times.

**6. Pause the two `TimelineView(.animation)`s — DT4/S7 + L1.**
`LoadingLine.swift:36` ticks at display rate at opacity 0 for the life of every series page (verified `:29-50`); `WrappedShapes.swift:163` does the same for every headline card after its 0.45 s count-up. Effort: a line each — `.animation(paused: !isActive)` / `paused: progress >= 1`. Asks: eff (battery/thermal), health. Proof: Instruments → Display on a settled series page — expect 120 Hz today, 10 Hz after on ProMotion. If it reads 10 Hz today, the finding is dead; record it.

**7. Cache a partial `extras` and stop swallowing the works last page — PS "missing 2" + DT11.**
`SeriesRepository.swift:867-869` writes the detail row only when `failure == nil`, so five good legs and one 429 are thrown away and the re-open pays all eight again — the throttle makes the next throttle likelier. `+Works.swift:39-41` `try?`s the last page: the badge says 113 over a 50-row list and the widget loses the newest volume, nothing logged. Verified. Effort: a function — `missingLegs: Set<Leg>` beside `failure`, cache the rest, refetch only the missing leg at `.background`; last page as its own `Result`. Asks: rl-invis, eff, debug. Proof: a stub whose `/news` 429s — today `readDetailCache` is nil after the open; after, it holds five legs and the second open sends one request.

**8. Make the gate and the ledger say what happened — W11/S18 + S17 + W10 + PS5.**
No counter for local refusals, server 429s or wait seconds; `NetworkLedger.Entry.failures` is written (`:51`, verified) and shown nowhere (`DataUseSection.swift:120-137`, verified); `LossyArray` drops the `DecodingError`; three cache writes `try?` in silence (`SeriesRepository.swift:612, 868`, `LibrarySnapshot.swift:354`). Effort: a few lines each. Asks: debug, rl-invis (the honesty that lets screens stay quiet). Proof: the walk that saw three throttle cards (`detail-page-budget.md` §3) becomes attributable from Settings in one glance. Section 6 has the full design.

**9. Refund a cancelled request only if it never left — W3.**
`APIClient.swift:172` refunds `URLError.cancelled` as "never reached the network" (verified `:164-173`); a keystroke that cancels an in-flight search refunds a slot the server counted, so the 30/min local window under-counts and the reader earns the real 429 it was built to prevent. It also blocks "tap cancels background" (section 5): every cancel would give back a spent slot. Effort: a line (delete the refund) or a function (refund only when `metricsDelegate` saw no `fetchStartDate`). Asks: rl-invis, bug-prone. Proof: one `print` in the cancel branch while typing "omniscient reader" at a normal pace; count against `searchTimestampCountForTesting`.

**10. The cover pipeline: decode at the drawn size, drop the row blurs, bound visible loads — S1 + S2 + S3.**
`CoverStore.swift:185` decodes at the fetched rendering (x350@2 = 700 px for a 531 px card, 1.74× the pixels; verified); `MotionModifiers.swift:28` and `:58` stack two Gaussian blurs per arriving card (verified) — 40–60 offscreen passes at 120 Hz on a fling; visible loads are unbounded while only prefetch is capped at 6. Effort: a function (thumbnail decode, precedent `MangaBakaWidgets/CoverLoader.swift:76`), a line each (opacity-only in rows), a function (store-level width ~8). Asks: speed, resp, eff. **Measure first** — Instruments Core Animation FPS on a 30-card fling, three runs, control = the same fling with `CoverFrame.shadow` commented out (the code already asks for that).

Just below the line: W5 (thread `priority` through `getRoot`/`getResults`/`send`, drop the `.userInitiated` default — lines, and the knob everything in section 5 needs); E1 + E2 (progressive shelf, stored answer first — a function each); R7 (a settled cadence is never re-measured: "47 days late" on a weekly series that shipped yesterday); DT6 (item 30 back); PS6 (feed writes to disk before returning, inside the actor — measure first).

---

## 3. Cross-cutting causes

**A. "Background means wait, but the caller still awaits it."** The gate half is right (background waits); the view half undoes it. Explains DT1 (hero awaits five waiting legs), DT11 (works last page awaited inside a foreground leg), E1 (three editions legs merged once, ANN hidden behind Open Library's 4 s slot), D2 (`react` awaits `refill`, so the *next* swipe is dropped), PS6 (feed writes before returning). One rule fixes all five: write what the reader looks at first, await the rest afterwards.

**B. "Foreground by default."** `perform` defaults to `.userInitiated` and five entry points cannot say otherwise (`APIClient.swift:376-409, 286-360`). Explains W5, D1 (pulse), S11 (profile), S20 (blocked tags), R11 (continuations), R4 (upcoming pages), PS table rows for `imagesResult`, `relationships`, `mix`, every library write incl. a 939-row import (R21). The knob is a parameter; the default is the wrong direction for ask 2.

**C. "Throw on 429 means a card."** `RateLimitGate.swift:298` and `:209`. Explains every `InlineFailure` on a background leg (DT table, `DetailOnwardRows.swift:190-194`), DT3 (StaleBar on a cold page), L2 (continuations card with no countdown), S "missing 1" (bold "Retrying in 40 s"), D7 (Stack low-queue silence).

**D. "Cancel is treated as never-sent, or as failure."** W3 (slot refunded), DT6 ("Cancelled" written into rows — item 30 back), DT10 (pager neighbour starts three foreground requests then cancels), E14 (a cancelled wait keeps the shared Open Library slot claimed — compounding across pages).

**E. "No Logger in the file."** Ten files in the app have a `Logger`; none in `Core/Networking`, `Core/Editions`, `Core/Volumes`, `Core/Notifications`, App, Settings, Shared, DesignSystem, the widget. Explains W10, W11, PS5, PS-D1 (13 silent `try?` on DB calls), R20 (seven files), E11 (4,326 lines, zero lines), L3, D4–D6, S14, S19, DT11. Nine `Signposts.measure` sites exist; none around the gate wait, a decode, a cache read/write, an editions leg, or a reschedule.

**F. "Tests that start in the state the bug needs."** R1 (every hiatus test starts on hiatus), DT13 (a source-grep test that passes against the wrong await order), PS1 (`DetailCacheDiscardTests` restates the false premise), E4/E8 (happy fixtures, hand-typed Apple/Google answers), W12 (works fields typed from three rows of one series).

**G. "TimelineView never stops."** DT4/S7, L1. Same one-parameter fix.

**H. "Declared, documented, never wired / computed, then discarded."** R3, R5, R6 (failed `top-genres` cached for the session), S5 (`CoverImage.onLoaded`), E2 (30-day answer written every open, read by nothing on the page), E3/E6 (`isPartial` dropped or hard-coded), S13, S17, R17, R18, PS10, PS11, DT17, L4.

**I. "Rebuilt per call: formatter, regex, dictionary, locale."** W13 (`DisplayTitle.choose` — 68 callers, fixed at one), W14 (2,686-entry dictionary per tag), E7 (~3,000 regex compiles per store answer), E15, DT5 (`now` defaulted per pass + eager 160-row `ForEach`), DT14, D3, S6, R13.

**J. "Every row gets the arrival treatment."** S2 (blur per card), S8 (270 ms floor on every scrolled-in library row), S9 (`arrives` + `enterScale` stacked at ten sites), S10 (a spring per drag sample), DT5 (160 blur layers when a shelf lands). The mockup asks for an arrival, not a blur.

**K. "One rule in N copies."** Request count in four comments (DT), file cache ×6 and 429 branch ×5 (E), freshness rule ×3 and preference store ×3 (PS), lenient decoder ×5 (W), hiatus check ×2 (R9), `isWebtoons` ×2 (R12), `nativeTitle` ×2 (DT18), `isNovel` ×2 (E16), blocked-tag key ×2 (PS7 — one preference under two names on one endpoint).

---

## 4. Rate-limit invisibility — the design

**The gate (`RateLimitGate`).**
- `.background`: waits through a server 429 until `blockedUntil` (already capped 15 min); cancelled the moment the screen goes; new `maxBackgroundWait` (GUESS 90 s) throws `.rateLimited(until:)` after that.
- `.userInitiated`: if the local window is full and the oldest slot expires within `Metrics.foregroundWaitCeiling` (GUESS 10 s), wait; otherwise throw with the deadline as today. A real server 429 on a foreground request still throws — that is the one honest card.
- Refund only when the request never left (W3). Counters per family: `localRefusals`, `serverRateLimits`, `backgroundWaits` + total seconds (section 6).
- Not a queue redesign: foreground already jumps background at the gate; 5 waiters/s FIFO is fine.

**One decision, in one place.** A `FailurePresentation` chosen from `(error, hasStale, consecutiveLimits)` — S "missing 1" — replaces per-screen choices:
- has stale content → `StaleBar` (exists, `FailureState.swift:120-206`, countdown + auto-retry). Stays.
- nothing stale and `.rateLimited` → skeleton stays up + `LoadingLine(isActive: true)` + a silent `Countdown` whose `onReachZero` retries. No text on the first limit; the bold "Retrying in N s" only on the second consecutive one.
- offline / 5xx / decode → `InlineFailure` per section (exists). Stays — "here is why" is honest there.
- `.cancelled` → never written to state (DT6; `presentableFailure` already exists at `SeriesDetailView.swift:588-591`, apply it to the two feed rows and `pageFailure`).

**Per screen, while waiting.**
- Discover: rows keep `CoverSkeletonRow`; a row's 429 keeps the skeleton and retries at the deadline instead of `InlineFailure` (`DiscoverView.swift:227`); `StaleBar` gets a `deadline` at `:76-89` (full2 item 39 still open). Pulse card: absent silently (already).
- Search: 30/min is the reader's own typing — `StaleBar` with countdown stays; page 2 already reads "keep loading" (`+Paging.swift:49`). Search results should never be "quiet": the reader asked.
- Series page: hero from `full` (#1). Cold `full` 429 → synopsis skeleton + `LoadingLine` with an optional caption and deadline ("Still loading · 12 s"), never `StaleBar` (DT3). Six background legs → skeleton + one scheduled retry via a `RetryAfterThrottle` helper lifted from `scheduleCoversRetry` (`+Covers.swift:57-67`). `readDetailCache(allowStale: true)` when `fresh.failure == .rateLimited` (PS "missing 1"), rows kept 7 days by age not 6 h. `isAnyLegLoading` includes `coversRetry != nil` (DT2) and excludes the tail once the hero is up.
- Stack: current card never waits (already); a refill under a full gate with ≤2 cards shows "topping up" on the disabled action row (D7); `.surprise` freshness 60 s from the endpoint's own `max-age` (PS "missing 3").
- Library: `partialLoad` (`LibraryView.swift:220-274`) is already the model — keep. Continuations at `.background`, reading the detail cache first (R11), with the error kind threaded so `InlineFailure` can take a `deadline` (L2).
- Editions shelf: stored 30-day answer first (E2), rows per leg as each lands (E1), "first 50 of 84 on record" for partial (E3/E6), `storedAt` from all three legs (E13). Third-party wording stays by `party` — never "MangaBaka is busy" for Open Library.
- Cadence: keep the last good payload on a failure write and return `.measured(stale)` with an age (R "missing"), so the hero says "about every 7 days · measured 3 weeks ago", not a red line.

**Retries.** One scheduled retry per leg at `deadline + 0.5 s`; no exponential fan (the gate's own backoff already handles the server). `Countdown` (`initial: true`, item 18) is the timer everywhere. A retry never flips `isLoading` on a mounted bar (DT3's flicker).

**What the reader sees.** Skeleton, then content — a few seconds longer on a hot window. At worst a one-line caption under the loading line. The words "too many requests" appear only for a real 429 on something they tapped.

---

## 5. Request timing — the design

**Launch (signed in, cold).** Synchronous before first paint: `AppServices` (Keychain, two SQLite opens — keep; skip `finishOpening`'s ATTACH/DETACH on a settled device behind the `cache.libraryMove` marker, S22, only if "Database open" reads > 10 ms). Move `URLCache.shared` replacement (`MangaBakaApp.swift:21`, a 256 MB index open) to a detached task before the first cover request. Then, in order:
1. Discover's four rows, `.userInitiated` — the visible content. Nothing else foreground.
2. `session.library.load()` from the 6 h cache (zero requests) → widget write (`Task.detached(.utility)`, S14) → Spotlight (already detached).
3. `/v1/my/profile` from `UserDefaults` keyed on the token hash; fetch at `.background` only on a miss (S11).
4. Community pulse `.background` (D1). Tag taxonomy warm (already detached).
5. Reminders: no `upcoming` pages, no follow searches (R4/R5); the walk is shared with `taste.ranker()` via `inFlight` (already).
Result: 4 foreground general requests at t≈0 instead of up to 12 + N search.

**Tab switch.**
- Library: walk streams page by page (already). Page 1 `.userInitiated`; pages 2+ could be `.background` — a design call, since a 13-page walk at foreground is 13 of the 60-slot reserve while the reader taps a row; the first series page after a cold Library tab pays them (DT table). Continuations `.background` after `isComplete` (already gated), reading `readDetailCache` first.
- Search idle: `LensCounts` walk `.background`, 250 ms spaced (already right). Keystroke: 300 ms debounce, in-flight cancelled (already; W3 makes the accounting honest).
- Stack: refill `.userInitiated` only while visible (already wired, `StackView.swift:110-111`); the *next* swipe must not await it (D2).
- Discover: `loadMore` `.background` at 4-from-end (already right).

**Series page.** Foreground: `full`, works p1, `/images` — written to the hero the instant `full` lands (#1). Background, after `isLoading = false`: similar, also-like, news, relationships, collections, works last page. Onward third-party legs keep their own spacers; Open Library covers (up to 12 × 4 s) and the editions legs fire on scroll into the shelf, not on open (DT table "behind scroll"). Cadence first on the MangaUpdates spacer, categories second (already). `.task(id:)` guarded by `coreLoadedID` (already, item 32).

**Tap cancels / yields background.** Mechanism, cheap and mostly present: each screen holds one `Task` handle for its background legs; a navigation push cancels the source screen's handle; waiting legs already honour cancellation (`RateLimitGate.swift:295`) and URLSession cancels in-flight ones. Prerequisite: W3, or every cancel refunds a slot the server kept. No gate-level "yield to foreground demand" is needed — foreground never waits behind background at the gate. Below the gate, `request.networkServiceType = .responsiveData` for `.userInitiated` (worth checking on a trace) and the decode moved off the `APIClient` actor (W7) so a 67 KB relationships page cannot delay the *start* of a tapped request.

**Prefetch policy.** No series-detail prefetch exists; keep it that way. Pager neighbour loads only when settled (DT10). Cover prefetch width 6 at `.utility` (already); visible loads bounded at ~8 with scrolled-off ones demoted, not dropped (S3). `CatalogueService` tags/genres warmed at `.background` after launch, with the in-flight clobber fixed (W15). `.surprise` deals cached 60 s.

---

## 6. Debugging — the design

**Diagnostics screen** = `DataUseSection` extended, nothing new to build the plumbing:
- Per family, from `RateLimitGate`: local refusals, server 429s, background waits (count, total s, worst s). Caption: "3 requests waited 12 s this session".
- Per endpoint, from `NetworkLedger.Entry`: add `· N failed` (S17 — the field exists) and the `LossyArray` first `DecodingError` string per path (W10 — names the key that changed, which is charter §1's whole history).
- Cache: writes failed since launch (PS5), detail rows / feed rows / `series` rows and bytes (PS2's growth becomes visible), `LibrarySnapshot` source this launch (cache vs walk).
- Covers: `CoverStore` hit/miss/evict via the `NSCacheDelegate` its own comment asks for.
- Third parties: `NetworkLedger.record` from `ThirdPartySession` users with the host as the path, so NDL's 764 KB and ANN's 237 KB appear (E11).
- Notifications: last pass's decision list (planned / dropped by fired / cooldown / cap / iOS refused) — R debuggability.

**Log lines** (one `Logger` per file, categories `gate`, `wire`, `cache`, `editions`, `reminders`, `covers`, `widget`, `shelf`), `.error` at every `try?` that changes what the reader sees:
- wire: `decodeEnvelope` catch (`APIClient.swift:518`), gate refusal and 429 (`RateLimitGate.swift:209, 334`), `CatalogueService.swift:135, 207, 213`.
- persistence: the 13 sites in PS-D1; `SeriesRepository.swift:612, 868`; `LibrarySnapshot.swift:354`; `BlockedTags.swift:64, 77`.
- reader: `ReleaseSchedule.swift:385,397,446,465`; `TasteProfile.swift:109,112,146`; `LiveNotificationCentre.add`; `WebtoonsFeedClient.swift:128, 206`; `GigaViewerFeedClient.swift:138`.
- editions: one line per leg at the merge — `leg=<ndl|ol|ann> outcome=<hit|miss|failed:case> rows=N partial=B ms=N`.
- UI: `Continuations.swift:134-140`, `RecentlyViewedRow.swift:42-48`, `StackModel.swift:332, 653`, `SearchLens.swift:59-62`, `WidgetSnapshot.swift:200-240`, `RootView+Session.swift:307`, `+Covers.swift:57-67` ("covers retry in N s").

**Signposts** (on the existing `Signposts.signposter`): `gate wait` per family (would have shown #1 in one trace), `decode` in `decodeEnvelope` (settles W7), `feed read` / `feed write` / `detail read` / `detail write` (settles PS6, PS9, U10), `.event` at each detail leg's start with the path (one Instruments run gives the whole page timeline), each editions leg, `performReschedule`, `hasAnythingToSay`.

---

## 7. Size

Deletions (lines, estimated): `APIClient.userAgent` 1; gate history comment 12; `ThirdPartySession.make(configure:)` ~10; `RateLimitGate` test statics 5 + five test sites; PS10 dead branch ~8; PS11 (`OpenResult.init(database:wasReset:)`, `LibrarySnapshot.all/seriesIDs`, `TestClock` → test target) ~30; `wasReset` shim + comment 10; R3 dead parameters + episode baseline + `title(for:in:fallback:)` ~40; R17 `decades` + 2 tests ~15; R18 3; R5 `PublisherFollows.check`/`Update` ~100 if the list never notifies (product call); DT17 3; S5 `onLoaded` 3 (or wire it); `LibraryList.swift:48` duplicate transition 1; L4 `hasAccount` 5 + 2 tests. **≈ 250 lines, no behaviour change.**

Merges: six file caches → one (`E`, ~150 net, and the only place to add a size cap — none prunes today); five 429 branches → `RequestSpacing.backOff` (~40); three `unsafe…Fallback` extensions (~12); three preference stores → `PreferenceStore<Value>` (~80); three freshness rules → `isFresh(cachedAt:now:ttl:)` (~10); five lenient decoders → `StringOrNumber<T>` (~40); `Motion.arrives` vs `enterScale` (~25); `SeriesRepositoryProtocol`'s 11 default overloads (~70, stubs updated once); `RootView`'s 35-parameter init → pass `services` (~110, design call). **≈ 500 lines.**

Not deletable, checked: `WidgetSnapshot`/`WidgetSnapshotData` (two targets, contract-tested); `ArrivalHapticModifier`'s second `stagger` call (deliberate, timed off one function); `ScrollEdge.swift` (129) goes only if the three tab roots take a real navigation bar — a design change Abdi has to see.

---

## 8. Everything ranked by value/effort

Effort: line / lines / fn (function) / file / redesign. Conf: C certain, L likely, W worth checking. `†` = regression from today.

| # | id | slice | one line | effort | conf |
|---|---|---|---|---|---|
| 1 | DT1† | detail | hero awaits five `.background` legs; stalls 120–180 held | fn×2 | C |
| 2 | W1 | wire | background waiter throws on a family 429 instead of waiting | fn | C |
| 3 | W2 | wire | foreground throws when the wait is seconds away | fn | C |
| 4 | R1† | reader | status baseline never records a non-notifying transition; "back" inert | fn | C |
| 5 | R4/S12 | reader/surface | launch fetches ≤6 `upcoming` pages for a discarded value; zero-request work queued behind | line | C |
| 6 | PS1 | persistence | rating/blocked-tag change discards a detail cache it does not affect | lines | C/L |
| 7 | DT4/S7† | detail/surface | `LoadingLine` ticks at display rate at opacity 0 | line | L |
| 8 | R5 | reader | one search request per follow at launch, result discarded | line | C |
| 9 | W3 | wire | cancelled in-flight request refunds a slot the server counted | line | C |
| 10 | W5 | wire | five entry points take no priority; default is foreground | lines | C |
| 11 | S11 | surface | launch profile at `.userInitiated`; failure disables Mix exclusion for the session | fn | C |
| 12 | PS-m2 | persistence | partial `extras` never cached — a throttle makes the next likelier | fn | C |
| 13 | DT11† | detail | works last page `try?`, awaited inside the foreground leg | fn | C |
| 14 | W11/S18 | wire/surface | nothing counts refusals, 429s, wait seconds | lines | C |
| 15 | S17 | surface | `Entry.failures` written, shown nowhere | line | C |
| 16 | W10 | wire | `LossyArray` forgets the `DecodingError` | lines | C |
| 17 | PS5 | persistence | three cache writes fail silently → permanent network cost | line×3 | C |
| 18 | R2† | reader | a sent `back-` never advances the baseline; repeats on day 61 | line | C |
| 19 | R3† | reader | dead `announced`/`lastKnownEpisode`/episode baseline | fn | C |
| 20 | DT6† | detail | cancelled `.background` feed writes "Cancelled" (item 30 back) | lines | L |
| 21 | DT3 | detail | `StaleBar` on a cold page; hides itself on retry | fn | C |
| 22 | DT2† | detail | `LoadingLine` off while a throttled covers retry is pending | line | C |
| 23 | E1 | editions | ANN rows hidden until Open Library's slowest request lands | fn | C |
| 24 | E2 | editions | 30-day merged answer written every open, read by nothing on the page | fn×2 | C |
| 25 | R7 | reader | settled cadence never re-measured; "N days late" grows forever | fn | C |
| 26 | R6 | reader | failed `top-genres` cached for the session; asked twice | fn | C |
| 27 | L1 | library-ui | `CountUpNumber` timeline never stops | line | L |
| 28 | S1 | surface | row covers decoded at 1.7× drawn pixels | fn | C |
| 29 | S2 | surface | two Gaussian blurs per arriving card | line×2 | L |
| 30 | S3 | surface | visible cover loads unbounded; only prefetch capped | fn | L |
| 31 | D2 | discovery | next swipe dropped while `react` awaits `refill` | fn | L |
| 32 | R11 | reader | continuations: 8 `.userInitiated` requests, ignoring the detail cache | fn | C/L |
| 33 | PS6 | persistence | feed/detail write to disk before returning, inside the actor | fn | C (ms guess) |
| 34 | W7 | wire | every decode inside the `APIClient` actor delays the next tapped request | fn | C (cost guess) |
| 35 | PS2 | persistence | per-series feeds never aged; `trimOrphans` scans all on every write | fn | C |
| 36 | PS3 | persistence | a new non-optional `SeriesExtras` field silently wipes the detail cache | fn | C |
| 37 | DT7† | detail | `originalRun` reshapes the hero; measurers do not re-run (item 66 back) | line | C |
| 38 | DT5 | detail | shelf section re-evaluated per pass (`now` per construction), 160 eager blur rows | lines | L |
| 39 | S8 | surface | 270 ms floor hides every scrolled-in library row | fn | L |
| 40 | R21 | reader | import sends two requests per row; 240/min vs 180; no resume | fn | C |
| 41 | E3 | editions | partial NDL shelf shown as complete until a row is ticked | fn | C |
| 42 | E6 | editions | Open Library `isPartial` hard-coded false | fn | C |
| 43 | E4 | editions | ANN spin-offs land as a second "vol. 1" (NDL fixed today, ANN not) | fn | C/L |
| 44 | R8 | reader | finale without a season number discarded → "overdue" | fn | L |
| 45 | R9 | reader | `on_hiatus` is a hiatus everywhere except the notification | line | L |
| 46 | W6 | wire | timeout/DNS hide the cached copy (`.transport` not stale-useful) | line | C |
| 47 | D1 | discovery | pulse at `.userInitiated` at launch (⊂ W5) | line | C |
| 48 | S20 | surface | blocked-tags confirmation fetch at `.userInitiated` | line | C |
| 49 | S14 | surface | widget write sync on main, both failures swallowed | fn | C |
| 50 | S15 | surface | widgets re-download four covers hourly (~8 MB/day) | fn | L |
| 51 | PS4 | persistence | `feedDueWorks` full-decodes a 204 KB row per work to read `links` | fn | C |
| 52 | R10 | reader | `hasAnythingToSay` re-runs three library passes in `body` | line | C |
| 53 | W8 | wire | `uniqueKeysWithValues` traps on a duplicated `tag_id` | line | C |
| 54 | W9 | wire | `Int(Double)` traps on an out-of-range trim size | line | C |
| 55 | PS12 | persistence | `writeCache` skips an unencodable row; read reports it whole | line | L |
| 56 | R16 | reader | export writes a 0-byte backup on encode failure | line | W |
| 57 | R15 | reader | `seriesLastNotified` all-or-nothing cast (item 36's sibling) | line | L |
| 58 | DT13 | detail | priority test greps source; nothing tests the page while a leg waits | hour | C |
| 59 | E11 | editions | zero log lines in 4,326 lines of third-party networking | lines | C |
| 60 | R20 | reader | silent `try?` in seven files | fn | C |
| 61 | S19 | surface | no `Logger` in App/Settings/Shared/DesignSystem/widget | lines | C |
| 62 | PS-D1 | persistence | 13 silent `try?` on DB calls | lines | C |
| 63 | L3 | library-ui | continuations failure kind never logged | line | C |
| 64 | D4 | discovery | `RecentlyViewedRow` swallows store failures | line | C |
| 65 | D5 | discovery | `reactedIDs` failure → skipped series resurface, unlogged | line | C |
| 66 | D6 | discovery | saved lenses vanish silently on a decode failure | line | C |
| 67 | L2 | library-ui | `relationships(for:)` discards the `APIError`; no countdown possible | fn | C |
| 68 | E14 | editions | cancelled wait keeps the shared Open Library slot; compounds across pages | fn | L |
| 69 | DT10 | detail | pager neighbour pays a cold open on a partial drag | lines | W |
| 70 | E5 | editions | publisher inheritance on Open Library rows ignores language | line | L |
| 71 | E7 | editions | ~3,000 regex compiles per Apple store answer | fn | C |
| 72 | E8 | editions | Apple title shapes rejected (FR/DE/JP); tests hand-typed | fixtures | W |
| 73 | W13 | wire | `DisplayTitle.choose` reads locale + lock per call, 68 callers | fn | C |
| 74 | W14 | wire | 2,686-entry dictionary rebuilt per tag per query | lines | C |
| 75 | S4 | surface | BlurHash decode on main at first sight; no cosine tables | fn | L |
| 76 | S9 | surface | `arrives` + `enterScale` stacked at ten sites | line each | W |
| 77 | S10 | surface | a 0.7 s spring per drag sample | line | L |
| 78 | S21 | surface | `RootView.body` re-evaluates on every library page | lines | L |
| 79 | PS7 | persistence | Stack blend sends blocked tags under a different key than Mix | line | W |
| 80 | PS9 | persistence | VACUUM on main at launch after any 1 MB delete | measure | W |
| 81 | PS14 | persistence | sync GRDB in actors serialises Discover's four reads | measure | W |
| 82 | S22 | surface | `finishOpening` moves run every launch after completion | fn | W |
| 83 | W4 | wire | no service type / task priority reaches URLSession | lines | W |
| 84 | W15 | wire | `tags(limit:)` clobbers a bigger in-flight fetch | 2 lines | C |
| 85 | W16 | wire | pulse `load()` has no in-flight guard | lines | C |
| 86 | W12† | wire | `SeriesWork.Image`/`Trim` typed without a payload | measure | C |
| 87 | E13 | editions | cache hit indistinguishable from fetch for two legs | fn×2 | C |
| 88 | E16 | editions | Apple's `isNovel` and Google's disagree | line | C |
| 89 | E9 | editions | ANN `(Novel n)` filed as print | line | W |
| 90 | E18 | editions | ISBN-10 never matches ISBN-13 | fn | W |
| 91 | R12 | reader | Webtoons cache probe for any linked series | line | C |
| 92 | R13 | reader | GigaViewer decodes the magazine file once per series | fn | C |
| 93 | R14 | reader | eight `UserDefaults` dictionaries rewritten per pass | fn | C |
| 94 | DT8† | detail | "Started" range in a column sized for a year | lines | L |
| 95 | DT9 | detail | gallery uses `AsyncImage` in a lazy row (the documented failure) | fn | L |
| 96 | DT12† | detail | "Publisher page" has no 44 pt target | line | C |
| 97 | DT14 | detail | relative-date formatter per news item; `stats` ×4 per pass | lines | C |
| 98 | DT15 | detail | `others` ×4 per hero pass while measurers mounted | line | C |
| 99 | DT19 | detail | `refreshDerived` groups the previous page's tags | line | C |
| 100 | D3 | discovery | two `DateFormatter`s per `body` in offline `StaleBar` | line | C |
| 101 | S6 | surface | nine `URL`s rebuilt per `CoverImage` pass | line | C |
| 102 | S13 | surface | `wantsAccountFocus` never cleared; keyboard raised on every Settings visit | line | C |
| 103 | S5 | surface | `CoverImage.onLoaded` declared, documented, never passed | line/fn | C |
| 104 | S16 | surface | `textPrimary`/`textEmphasis` within 4% of `.label`, not semantic | 2 lines | C |
| 105 | R17 | reader | `ReadingWrapped.decades` tested, never presented | line | C |
| 106 | R18† | reader | `rowIdentity(of:)` has no caller after today's `ndl:` change | line | C |
| 107 | PS10 | persistence | `requireFresh: true` branch dead | lines | C |
| 108 | PS11 | persistence | three dead items incl. `TestClock` in the app target | lines | C |
| 109 | DT17 | detail | `CoverGallery.selection` dead state | line | C |
| 110 | L4 | library-ui | `hasAccount` alias describes phantom callers | line | L |
| 111 | DT18 | detail | `nativeTitle` two ways | fn | W |
| 112 | PS8 | persistence | cache-hit path never releases the page observer | line | C |
| 113 | PS13 | persistence | `limit=6`, 3 600 / 1 800 s, `pageCap` unlabelled | word each | C |
| 114 | R19 | reader | `within: 12`, taste weights 4/3/2/1, `60` unlabelled | line each | C |
| 115 | DT16 | detail | `< 10_000`, `prefix(4)`, glide constants unlabelled | comments | C |
| 116 | E10 | editions | `merge` on main — < 1 ms, do **not** move | none | L |
| 117 | E12 | editions | double dedupe in `NDLClient.Query.rows` | line | C |
| 118 | E15 | editions | `PartialDate.utc` builds a `Calendar` per call | line | C |
| 119 | E17 | editions | `VolumeShelf.merge` per body pass | fn | C |
| 120 | E19 | editions | ANN parse keeps every `<manga>`'s releases, first id only | line | C |
| 121 | D7 | discovery | Stack refill under a full gate with ≤2 cards shows nothing (renderer exists at `StackView.swift:488`, empty-queue only) | small view | W |
| — | L5–L7 | library-ui | jump index / edit-sheet chips vs system controls; sort per keystroke bounded | redesign / fn / none | notes |

---

## 9. Verdict per slice

- **wire — fix in place.** Two functions in the gate, a line in `perform`, priority threaded through five entry points. The comments carry nine live measurements; a rewrite would lose them for nothing.
- **persistence — fix in place.** PS1 is a wrong entry in a right table (`CacheScope`), which is the design working. The one refactor worth its cost: collapse the 11 protocol overloads (~70 lines) — after the priority parameter exists everywhere.
- **reader — fix in place.** R1–R3 are today's rewrite half-landed, not a design fault. `ReleaseReminders` needs a `Logger` and a real three-pass test before anything else.
- **editions — fix in place, plus one merge.** The six file caches and five 429 branches into one client base is the only structural change; the clients' measurements (764 KB page, TCP-refusal numbers) stay in the callers' comments.
- **library-ui — leave alone.** The best-shaped slice; one line (L1) and one signature change owned by persistence.
- **discovery-ui — fix in place.** D2 is a function; the rest are lines. Nothing to refactor.
- **detail — fix in place, one split.** `SeriesDetailView` is 1,800 lines across nine files for one screen's state machine; that is the size of the state, and the comments are the page's history (items 30, 32, 55, 64, 66). Split `fetchExtras` (DT1); do not redesign the page.
- **surface — fix in place; one motion merge.** `Motion.arrives` vs `enterScale` should become one; the cover pipeline changes are functions inside `CoverStore`. The hand-rolled kit is mostly justified by its own tables (`Typography`); the tab-root navigation bar is a design call, not a fix.

No slice earns "replace". The argument against rewriting anywhere: 30-odd dated measurements in comments found four of the eight slices' top findings.

---

## 10. What the review could not determine

| Question | What settles it |
|---|---|
| How long the hero waits under DT1 on a real window | `print(Date())` at `SeriesDetailView.swift:612, 628` after a Discover fling; or the `gate wait` signpost |
| Is 180/min ever approached on a cold launch (decides whether W2 is ever hit; SUMMARY U9 still open) | `NetworkLedger.byPath` bucketed per minute over one cold launch on the 937-series account |
| How often a mid-flight cancel refunds a counted slot (W3); does `didFinishCollecting` fire for a cancelled task | one `print` in the cancel branch while typing; a `URLProtocolStub` delayed 1 s, cancelled at 100 ms |
| One decode's cost on the actor (W7); is `JSONDecoder` `Sendable` here | `Signposts.measure` around `decodeEnvelope` over a library walk; mark it `nonisolated` and let the compiler answer |
| `readCacheWithDate` + `write` for a 30-row page; `writeDetailCache` for 204 KB (PS6); VACUUM at launch (PS9); sync GRDB (U10) | the four cache signposts in section 6 + one Instruments run of a cold Discover open and one series open; control = "Database open" |
| `feedEntry`/`series` size on the real file (PS2) | `SELECT COUNT(*), SUM(LENGTH(payload))` via `sqlite3` |
| `tag_not` vs `blocked_tag` on `/v1/series/mix` (PS7) | two live requests with one blocked tag, diff the DNA |
| Does the API send `on_hiatus` (R9); a Webtoons finale without a season number (R8) | one captured library page with such a series; one live feed |
| `TimelineView(.animation)` at opacity 0 holds 120 Hz (DT4/S7/L1) | Instruments → Display on a settled series page and an open Wrapped card |
| Frame time of a 30-card fling with and without the two blurs and with thumbnail decode (S1–S3); `CoverStore` evictions | Core Animation FPS + Color Offscreen-Rendered, three runs, control = shadow off; the `NSCacheDelegate` |
| 160 blur layers on shelf mount (DT5) | Animation Hitches, open ONE PIECE (377), watch the shelf land |
| Does `LazyHStack` build the pager neighbour on a partial drag (DT10) | `print("load", series.id)` at `:556`, one drag-and-release |
| Wall-clock of a cold editions leg; Open Library publisher-less original-language rows (E5); Apple title shapes per storefront (E8); ANN novel-in-manga entries (E9); ISBN-10 in `/works` (E18); `images` shape in works (W12) | one signpost per leg; one capture each — `/works/…/editions.json` for One Piece, one Apple answer for GB/FR/JP, `curl /v1/series/377/works?limit=50` |
| Stall length of the next swipe while `refill` is awaited (D2); whether a refill 429 is ever visible (D7) | a test with a slow `feed()` stub asserting the Save button's state; a device run with the conditioner on and one card left |
| Whether any consumer of cached extras assumes rating-filtered content (PS1's "likely") | grep found none under `Features/Detail`; the detail slice found nothing reading `richTags` unfiltered — considered settled unless someone names one |
| Whether `.label` differs visibly from white @ 0.96 (S16); "Started" truncation (DT8); the hero gap re-opening on a webtoon (DT7) | one screenshot pair each |
| Does "Database open" on a settled device exceed 10 ms (S22) | the signpost exists; one cold launch |
| The `.task(id:)` re-run on pop-back (full2 item 32) — reader slice did not re-check | `print` at the top of `loadReleases`, one pop-back |

---

## 11. Regressions from today's work (HEAD `1f5e632`)

These go first. Each was introduced or re-introduced on 2026-09-15.

1. **DT1** — the `.background` move made the hero wait for the bottom of the page (`SeriesDetailView.swift:606-630`, `SeriesRepository.swift:959`). Fix: #1.
2. **R1 / R2** — "back from hiatus" cannot fire for any series that enters hiatus after first sighting; a sent `back-` repeats on day 61 (`ReleaseReminders.swift:263-265`). Fix: #3.
3. **R3** — `announced`, `lastKnownEpisode`, `notifiable`, the episode baseline and `title(for:in:fallback:)` left dead by the rewrite (`NotificationPolicy.swift:111`); `RootView+Session.swift:396` still fetches to fill one of them. Fix: #3/#4.
4. **DT6** — item 30 back: a cancelled `.background` feed writes "Cancelled" into the similar/also rows (`SeriesDetailView.swift:614-623`).
5. **DT7** — item 66 back: `originalRun` mounts a hero line the `MeasureKey` does not know about (`DetailHero.swift:81-85, 275`).
6. **DT4 / S7** — `LoadingLine` (new today) ticks at display rate for the life of every series page (`LoadingLine.swift:36, 49`). Fix: #6.
7. **DT2** — `LoadingLine` says "done" while a throttled covers retry is pending (`+Covers.swift:40-41, 130-133`).
8. **DT11** — works last page (new today) is `try?`-swallowed and awaited inside the foreground leg (`+Works.swift:39-41`). Fix: #7.
9. **DT8** — "Started" became a 17-character range in a ~60 pt column (`DetailStatsStrip.swift:67-71, 156-160`).
10. **DT12** — "Publisher page" button (new today) has no 44 pt target (`DetailEditions.swift:77-86`).
11. **R18** — `OwnedVolumes.rowIdentity(of:)` orphaned by today's `ndl:` change (`+Reconcile.swift:50-52`).
12. **W12** — `SeriesWork.Trim` non-optional and `Image.image: Cover?` typed from three rows of one series with `images: []` (`SeriesWork.swift:37-52`); a differently-shaped row is one silently dropped volume.

Half-landed today rather than regressed: **E4** — the spin-off-as-vol.-1 bug fixed for NDL with `workTitle` was not applied to ANN (`ANNRelease.swift:92-109`). Stale numbers left behind: "nine requests" in three comments (`+Editions.swift:12-13`, `SeriesPager.swift:32`, `LoadingLine.swift:6`) against the budget doc's eight; "3 s / 36 s" for the Open Library pass (`+Store.swift:212-216`, `SeriesDetailView.swift:181-182`) against a 4 s gate; `StackModel.swift:216-219` says `isVisible` is "not yet wired" — it is.

`otherMentions` isolation (named in the brief) was flagged by no slice; `LinksSection.swift:137` is `nonisolated static` and the detail slice read the file. Nothing to fix that this review found.

---

## 12. Fix batch — 2026-09-15 evening (uncommitted at time of writing)

Everything in §2 and §11 except the measure-first items, in one working tree:
- Gate: foreground waits ≤10 s (guess) instead of throwing; background waits
  through a 429 up to 90 s (guess); cancelled requests keep their slot;
  `priority:` on `getRoot`/`getResults`/`mix`/`relationships`. Counters
  (`localRefusalCount`, `serverRateLimitCount`, `backgroundWaitTotal`) in
  `NetworkLedger`, shown in Settings → Data used.
- Series page: `extras(for:hero:)` draws the hero from `full` + works page
  one before the `.background` tail; a partial answer is cached with
  `missingLegs` and only those are re-asked; the works last page is its own
  background leg; cancelled feeds show no card; `LoadingLine` counts the
  covers retry and the tail, and pauses at opacity 0.
- Notifications: status baseline recorded every pass; `back-` and `finale-`
  advance it; `on_hiatus` counts; `announced`/`lastKnownEpisode` gone with
  the launch calendar and follow-search requests.
- Launch: walk → library → widget (off main) → reminders; profile at
  `.background` with a log line.
- Caches: rating/blocked-tag toggles no longer discard the detail cache;
  per-series feeds age out at 7 d (guess); silent writes log.
- Editions: shelf draws stored answer first, then each leg as it lands;
  partial shelves say "first N of M"; ANN spin-offs get their own shelf;
  a `Logger` per leg.
- Plus the per-slice items the six fix agents reported (their reports are
  in the session transcript; each names what it skipped).

Measure-first, deliberately not changed: cover decode size (S1), row blurs
(S2), visible-load cap (S3), BlurHash on main (S4), feed write cost (PS6),
decode inside the client actor (W7), VACUUM at launch (PS9). Each has a
Signpost now; one Instruments run on a device settles them.
