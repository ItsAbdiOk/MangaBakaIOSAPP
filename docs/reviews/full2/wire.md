# Second-pass review — slice 2: the wire and everyone else's servers

2026-09-14. Read-only. HEAD `fee95b0`. This file is the only thing written; no source
edits, no build, no test run, no simulator.

Scope: `MangaBaka/Core/Networking/**`, `Core/Model/**`, `Core/Characters/**`,
`Core/Volumes/**`, `Core/Schedule/**`, `Core/Intents/**`, `MangaBakaWidgets/**`.

**How much of the slice I actually read.** ~12,180 lines across 69 files. Read in full:
`APIClient.swift`, `RateLimitGate.swift`, `ThirdPartySession.swift`, `RequestSpacing.swift`,
`LossyArray.swift`, `AppUserAgent.swift`, `MangaUpdatesClient.swift`, `UpcomingWork.swift`,
`Int+Clamped.swift`, `WidgetSnapshotData.swift`, `SeriesWidgetEntry.swift`,
`CoverLoader.swift`, plus `WidgetSnapshot.swift` and `WidgetSnapshotTests.swift` and
`APIClientCacheAndPrivacyTests.swift` and `GeneralRateLimitWindowTests.swift` from
neighbouring slices because the brief named them. Read in the relevant part:
`ReleaseCalendar.swift`, `ReleaseFeedService.swift`, `ReleaseFeedProvider.swift`,
`WebtoonsFeed.swift`, `Cadence.swift`, `CatalogueService.swift`, `NetworkLedger.swift`,
`AppIntents.swift`, the 429 branch of all six third-party clients. **Grepped, not read**:
`AniListClient.swift` (557), `CharacterProfile`/`SeriesCharacter`/`ShikimoriDescriptionParser`/
`CharacterService`, `AppleBooksVolume`, `Series.swift` (419), `APIError.swift` (357),
`SeriesWork`, `SeriesExtras`, `TagTaxonomy`, `ReadingPlatforms`, `Cover.swift`, the bodies
of `WebtoonsFeedClient`/`GigaViewerFeedClient`, most of `ReleaseSchedule.swift` (558).
Call it **~50% read closely, 100% swept for the specific patterns below**. Anything I did
not read, I have not claimed anything about.

Two live `curl`s were spent, both against `/v1/works/upcoming`, both recorded below with
their date and time.

---

## Ranked top ten

| # | Finding | Value / effort | Confidence |
|---|---|---|---|
| 1 | W1 — The widget's own `URLSession` sends no User-Agent, to a host documented as answering 403 without one | High / a line | Certain |
| 2 | W2 — `NetworkLedger.Entry.droppedRows` is written by 14 sites and read by nothing; `LossyArray`'s whole justification is inert | High / a function | Certain |
| 3 | W3 — `GoogleBooksClient` is the one of nine 429 sites the shared `Retry-After` function never reached | High / 3 lines | Certain |
| 4 | W4 — `/v1/works/upcoming` is still decoded strictly, and one bad row discards every page after it | High / a line | Certain |
| 5 | W5 — The widget contract test asserts `due` is *absent*, which is the one field that changed yesterday | High / a function | Certain |
| 6 | W6 — Naver's removal left a whole unreachable branch: `TranslationGap` is now always `.none`, and twelve tests pass against a wiring production does not have | High / a file | Certain |
| 7 | W7 — `reserveSlot`'s doc comment says general-family paths reserve nothing; item 31 made that false the same day | Medium / a line | Certain |
| 8 | W8 — The new 180/min general cap is enforced against a number nobody has measured (U9), and refuses a user-initiated request outright | Medium / a function | Worth checking |
| 9 | W9 — `resourceFetchType == .localCache` may also be reported for a URLCache *revalidation*, in which case the refund gives back a slot for a request that did reach MangaBaka | Medium / a measurement | Worth checking |
| 10 | W10 — `CatalogueService.genres()` decodes `[Genre]` strictly while its sibling `tags()` is lossy; one bad row costs the whole vocabulary | Medium / a line | Certain |

---

## Part 1 — Yesterday's changes, checked first

### The cache refund — does the metric arrive before the code reads it?

**Verdict: the ordering is almost certainly correct, and the test suite is honest about
what it cannot prove. One residual risk is real and unmeasured.**

`APIClient.swift:204` reads `metricsDelegate.wasServedFromCache` immediately after
`session.data(for:delegate:)` returns at `:155`. The value is written in
`ClientRequestDelegate.urlSession(_:task:didFinishCollecting:)` at `:741-750`.

The agent's own unsure (`APIClient.swift:722-728`) is that the two are not documented as
strictly ordered. Reading the code, I think the ordering holds for a reason the comment
does not state: both `didFinishCollecting` and `didCompleteWithError` are delivered on the
session's delegate queue, which for `URLSession(configuration:)` is a serial
`OperationQueue`, and `data(for:delegate:)` resumes its continuation from
`didCompleteWithError`. Metrics are delivered before completion, on the same serial queue,
so the `NSLock`-guarded write at `:747-749` has happened-before the read at `:204`. I am
calling this **likely**, not certain — I did not build or run anything.

The suite `APIClientCacheRefundTests` (`APIClientCacheAndPrivacyTests.swift:67-169`) is
genuinely good work and worth naming as such: it has a control
(`refundIsNotUnconditional`, `:137`), it pins its own measurement
(`#expect(CachingStubProtocol.loadCount == 2)`, `:120`) so the test's entitlement to its
claim is itself asserted, and its doc comment states plainly what the stub can and cannot
prove (`:76-88`). That is the standard CLAUDE.md asks for, actually met.

**W9 — the residual the fix introduced, which nobody has looked at.**
- **What.** `ClientRequestDelegate` treats `transactionMetrics.last?.resourceFetchType ==
  .localCache` as "the request never left the device". CFNetwork also reports
  `.localCache` for a load served out of `URLCache` *after a conditional revalidation* —
  i.e. a request that did reach MangaBaka and did spend a slot of its per-IP budget.
- **Where.** `APIClient.swift:746`; consumed at `:204-212`.
- **Why it matters.** MangaBaka sends `cache-control: public, max-age=60` (measured
  2026-09-13, recorded at `APIClient.swift:546-551`). A search repeated just past 60 s is a
  revalidation, not a cold hit. If the loader labels that `.localCache`, `refund` hands a
  slot back for a request the server counted, so the app's local window under-counts and
  it can walk past 30/min into a real 429 — on a budget shared with strangers behind the
  same IP. This is the exact inverse of the bug the fix was for, and it is the more
  expensive direction.
- **Fix.** Do not key on `resourceFetchType` alone. `URLSessionTaskTransactionMetrics`
  carries `requestStartDate`/`responseStartDate`, which are nil only when nothing went out;
  require `resourceFetchType == .localCache && metrics.transactionMetrics.last?.requestStartDate == nil`.
  Or settle it first (below) and leave the code alone if `.localCache` really is cold-only.
- **Effort.** A line, once measured.
- **Confidence.** Worth checking — I could not run it.
- **Lens.** 6 (load balancing) / 5 (a measurement that measures the wrong thing).
- **The measurement that settles it.** Two `CachingStubProtocol` requests to the same URL
  with `Cache-Control: public, max-age=1`, a 2 s wait between them and the stub answering
  304 on the second; print `resourceFetchType` and `requestStartDate` for the second. No
  live request needed; the existing fixture already has everything.

Two smaller notes on the same fix:
- The refund now applies to **both** families, not just search, because
  `RateLimitGate.refund` at `:232-239` looks the family up from the path. That is correct
  and is *not* what its own doc comment says (see W7).
- `perform` refunds on `.offline` (`:162`) and `.cancelled` (`:172`) but not on the
  generic `.transport` catch at `:174-176`. That is right — a TLS or DNS failure may well
  have reached the host — but it is undocumented, and the next person to read
  `refund`'s doc ("the attempt never left the device at all: `.offline` or `.cancelled`")
  will not know the third case was considered. One sentence.

### The identity-cache eviction — does the replacement actually remove the entry?

**Verdict: yes, the mechanism is real this time. The window is stated honestly. Two
smaller things are wrong.**

`APIClient.swift:200-202` evicts on `session.configuration.urlCache`. The comment's claim
at `:189-190` — that `session.configuration` returns a copied configuration object but
`urlCache` is a reference to the *same* `URLCache` instance — is correct, and it is the
non-obvious fact the fix depends on. `removeCachedResponse(for:)` keys on the request URL,
which is the same URL the store used, so the entry is found. The test
`identityCarryingResponseIsNeverCached` (`APIClientCacheAndPrivacyTests.swift:194-222`)
has a proper control (`publicResponseIsStillCached`, `:227`) proving the client has not
simply stopped caching everything.

**The window, stated precisely** (the comment at `:192-196` says this correctly and should
not be softened): the response bytes are written into the `URLCache` by the loader and
removed again inside the same `perform` call. On a device with a disk-backed
`URLCache.shared`, an identity-carrying response — `/v1/my/library`, `/v1/my/profile` —
is on disk for the interval between the loader storing it and `perform` resuming, which
is one actor hop, so sub-millisecond in the ordinary case but unbounded if the actor is
contended. A crash, a `jetsam` kill, or a device seizure inside that window leaves the
reader's library in the shared on-disk cache with no one to evict it. This cannot be
closed with the current API and should be recorded rather than fixed.

**W11 — a comment that now lies, in the test file.**
- **What.** The suite doc comment still credits the inert mechanism as the fix.
- **Where.** `MangaBakaTests/APIClientCacheAndPrivacyTests.swift:178-179`:
  "`ClientRequestDelegate.willCacheResponse` now refuses to cache such a response
  regardless of what headers it carries." That method no longer exists, and the test
  method's own comment nine lines below (`:186-193`) correctly says it was never delivered
  and was replaced by post-load eviction.
- **Why it matters.** CLAUDE.md: a comment describing code that no longer exists is worse
  than none. This one specifically describes the *inert fix* as if it shipped, in the file
  whose job is to prove it did not.
- **Fix.** Replace `:178-179` with the eviction sentence from `:191-193`.
- **Effort.** A line. **Confidence.** Certain. **Lens.** 9.

**W12 — the harder half of the identity rule is untested.**
- **What.** `makeRequest`'s comment at `APIClient.swift:471-477` says the path prefix is
  not sufficient on its own, and that the real test is whether the query carries
  `exclude_user_library` — because `/v1/series/mix` is public *by path* but puts a
  32-character account id in the URL, and the URL is the cache key. Neither test in
  `APIClientIdentityCacheTests` exercises that branch; both use `/v1/my/profile`, the easy
  half.
- **Where.** Rule at `APIClient.swift:434-437` + `:478-481`; tests at
  `APIClientCacheAndPrivacyTests.swift:194` and `:227`.
- **Why it matters.** If someone narrows `identifyingParameters` or drops the
  `carriesIdentity` clause, every test still passes and the reader's account id starts
  being written to a 256 MB on-disk cache.
- **Fix.** A third test: `GET /v1/series/mix?exclude_user_library=<id>`, assert
  `cache.cachedResponse(for:) == nil`, with `/v1/series/mix` and no such parameter as its
  control.
- **Effort.** A function. **Confidence.** Certain. **Lens.** 2 (a test that agrees with
  the bug, by omission).

### `ThirdPartySession` — is it used by all nine, does it refuse cookies, does the UA arrive?

**Cookies: yes, and belt-and-braces.** `ThirdPartySession.swift:38-45` builds on
`.ephemeral`, then sets `httpShouldSetCookies = false`, `httpCookieAcceptPolicy = .never`
and `httpCookieStorage = nil`. That is three independent refusals; any one of them alone
would do. The privacy claim in the doc comment is real.

**Used by all of them: yes — but there are eight, not nine.** Verified by grep across the
whole app target: `MangaUpdatesClient.swift:35`, `GigaViewerFeedClient.swift:34`,
`WebtoonsFeedClient.swift:24`, `AppleBooksClient.swift:23`, `GoogleBooksClient.swift:32`,
`OpenLibraryCovers.swift:38`, `SeriesCharacter.swift:137` (Shikimori),
`AniListClient.swift:38`. `URLSession.shared` appears nowhere in the app target except in
prose. The ninth was Naver, which was deleted the same day — so the doc comment at
`ThirdPartySession.swift:5-6` naming nine clients including Naver is stale. One line.

**User-Agent, and here is the real defect.**

**W1 — the widget's cover fetches send no User-Agent, to a host documented as answering
403 without one.**
- **What.** `CoverLoader` builds its own `URLSession` and never sets
  `httpAdditionalHeaders`, so every cover request from the widget extension goes out with
  CFNetwork's default agent.
- **Where.** `MangaBakaWidgets/CoverLoader.swift:31-37`. Compare
  `ThirdPartySession.swift:54`, which is the line it is modelled on and the line it
  dropped.
- **Why it matters.** `AppUserAgent.swift:14-18`, verified 2026-09-08: "MangaBaka answers
  403 [to an unidentified client] — urllib's default agent is rejected where curl's is
  accepted." The covers `CoverLoader` fetches come from `WidgetSnapshotData.Item.coverURL`,
  which is MangaBaka's own CDN. If the CDN applies the same rule the API does, **every
  cover in both widgets fails, permanently and silently**: the failure is swallowed by
  `try?` at `:47`, a nil image just means the row draws without a cover, and a widget has
  no way to report anything. This is not a hypothetical class of bug — it is the exact
  host, the exact status code, and the exact measurement already written down in this
  repo. `AppUserAgent.swift` is in the app target only, so the widget could not have
  picked it up by accident.
- **Fix.** Either add `MangaBaka/Core/Networking/AppUserAgent.swift` to the
  `MangaBakaWidgets` target's `sources` in `project.yml` (the same one-file-across-the-seam
  trick `project.yml:150` already uses for `WidgetSnapshotData.swift`) and set
  `configuration.httpAdditionalHeaders = ["User-Agent": AppUserAgent.value]`; or, if that
  target should stay dependency-free, copy the literal with a comment pointing at
  `AppUserAgent` as its source of truth. The first is correct by this project's own rule
  against documenting a duplicated constant instead of exposing it at source.
- **Effort.** A line plus a `project.yml` entry.
- **Confidence.** Certain that the header is absent; **likely** that it costs covers —
  what settles it is one `curl -sI` to a cover URL with and without the agent. (I did not
  spend a request on it: the brief's budget went to the two `/v1/works/upcoming` calls, and
  the fix is right either way.)
- **Lens.** 1 (bugs) / 2 (errors swallowed).
- **Also note:** the comment at `CoverLoader.swift:29-30` says "No cookies and no cache for
  the same reasons `ThirdPartySession` gives" — the session sets no `urlCache`, so it gets
  `.ephemeral`'s in-memory one. Not a defect; the comment overclaims by a word.

The two hosts that 403 without an agent are covered **in the app**: MangaBaka via
`APIClient.swift:483`, Shikimori via `SeriesCharacter.swift:153` and `:262`. Both set the
header explicitly on the request as well as inheriting it from the session, which is the
right belt-and-braces given a test may substitute a session — and
`MangaUpdatesClient.swift:28-30` states that reasoning. Good.

### The capped `Retry-After` — does every caller pass through it?

Ten 429 branches exist in the third-party clients. Nine route through
`RequestSpacing.backOff(retryAfterHeader:now:)`. **One does not.**

**W3 — `GoogleBooksClient` still hard-codes a 60-second backoff and never parses
`Retry-After` at all.**
- **What.** The one call site the "nine call sites, one shared function" change missed.
- **Where.** `MangaBaka/Core/Volumes/GoogleBooksClient.swift:106-109`:
  ```swift
  if http.statusCode == 429 {
      spacing.backOff(until: clock.now.addingTimeInterval(60))
      return nil
  }
  ```
  Compare `MangaUpdatesClient.swift:150-152`, `AniListClient.swift:134-136`,
  `SeriesCharacter.swift:173-175` and `:282-284`, `WebtoonsFeedClient.swift:134-136`,
  `GigaViewerFeedClient.swift:148-150`, `AppleBooksClient.swift:144-146` — all seven carry
  the identical three-line shape and the identical comment.
- **Why it matters.** `GoogleBooksClient.swift:13` records that this client "is usually
  rate-limited (HTTP 429, 2026-09-12)" — it is the client that 429s *most*, and it is the
  one that ignores the server's own instruction. Google answering `Retry-After: 3600` gets
  retried 59 times inside the hour it asked to be left alone. The whole point of the shared
  function is that a third party's stated deadline is honoured, capped, and reported.
- **Fix.** Replace with
  `_ = spacing.backOff(retryAfterHeader: http.value(forHTTPHeaderField: "Retry-After"), now: clock.now)`.
  The existing behaviour (60 s when the header is absent) is preserved exactly by
  `RequestSpacing.unstatedBackOff`, which is also 60. Separately, `return nil` collapses a
  429 into "no volumes"; that is the C2 shape already on the work list and I am not
  re-filing it, but the one-line fix above is independent of it.
- **Effort.** Three lines. **Confidence.** Certain. **Lens.** 6 / 3.

**W13 — `RequestSpacing.backOff`'s `cap:` parameter has no caller.**
- **Where.** `RequestSpacing.swift:71` declares `cap: TimeInterval = RequestSpacing.maxHonouredRetryAfter`;
  no call site in the app passes it (verified by grep over all ten 429 branches).
- **Why it matters.** Small, but it is the same shape the brief warns about — a parameter
  added for a call site that never materialised. Either delete it or say in the doc comment
  that it exists for tests.
- **Effort.** A line. **Confidence.** Certain. **Lens.** 3.

**W14 — `AppleBooksClient` reports a hard-coded 60 where `RequestSpacing.unstatedBackOff`
is the named constant.**
- **Where.** `AppleBooksClient.swift:147`: `.rateLimited(retryAfter: retryAfter ?? 60, ...)`.
  `RequestSpacing.swift:51` defines `unstatedBackOff = 60` and `backOff` has already pushed
  the slot out by exactly that.
- **Why it matters.** The two agree today. Change `unstatedBackOff` and the screen tells
  the reader one number while the client waits a different one. CLAUDE.md: never fix a
  duplication by copying the value into a second place.
- **Fix.** `retryAfter ?? RequestSpacing.unstatedBackOff`.
- **Effort.** A line. **Confidence.** Certain. **Lens.** 9.

### The single `MangaUpdatesClient` — one instance, and does the spacing serialise?

**Verdict: yes on both counts in production. There is one loaded gun left.**

`AppServices.swift:85` constructs `let updates = MangaUpdatesClient()` once and assigns it
to the stored property at `:86`. Both consumers get *that* instance:
`ReleaseScheduleService(library:mangaUpdates: updates, ...)` at `AppServices.swift:157-158`,
and the series page via `RootView+Session.swift:435` → `SeriesDetailView.mangaUpdatesCategories`
→ `SeriesDetailView+Categories.swift:22`. There is no other construction in the app target.

The spacing genuinely serialises across both because `MangaUpdatesClient` is an `actor`
and `RequestSpacing.claim` at `MangaUpdatesClient.swift:263` is synchronous *before* the
`Task.sleep` at `:266` — which is the whole reason `RequestSpacing` is a struct and not an
actor (`RequestSpacing.swift:6-11`, with the 96 µs measurement that motivated it). Two
concurrent callers get slots 3 s apart. Correct.

**W15 — `ReleaseScheduleService.init` still defaults to building its own client.**
- **Where.** `MangaBaka/Core/Schedule/ReleaseSchedule.swift:124`:
  `mangaUpdates: MangaUpdatesClient = MangaUpdatesClient()`.
- **Why it matters.** Production passes the shared one, so nothing is broken today. But the
  bug this fixed (two actors, two `RequestSpacing`s, a 429 backoff on one invisible to the
  other, the 3 s MangaUpdates' terms ask for violated by construction) is reintroduced by
  any future call site that omits the argument — silently, with no build error and no test
  failure. The six `ReleaseScheduleService(...)` call sites in `ScheduleServiceTests` all
  pass one explicitly, so removing the default costs nothing.
- **Fix.** Delete the default value at `:124`, making `mangaUpdates:` required.
- **Effort.** A line. **Confidence.** Certain. **Lens.** 9.

Related, and worth someone's judgement rather than a fix: `MangaUpdatesClient.series(number:)`
reads its disk cache *before* claiming a slot (`:187-190`), which is right, but
`releases(seriesNumber:)` has no cache at all (`:109-110` claims a slot unconditionally).
A schedule build of N in-scope series therefore costs N × 3 s of real waiting with nothing
reusable. `ScheduleModel.swift:201` already multiplies `inScope` by `minimumInterval` to
show the reader a wait estimate — that number *is* the finding, written down as a feature.

### The general 180/min window — trace a `.background` request through it

**What is actually `.background`:** four call sites.
`PublisherFollows.swift:126` and `LensCounts.swift:111`/`:164` are search-family.
`DiscoverModel.swift:257` (`repository.feedPage(..., priority: .background)`) is the **only
general-family background request in the app**.

Traced: `feedPage` → `APIClient.perform` → `RateLimitGate.reserveSlot(for:"/v1/series/…",
priority: .background)` at `:185` → `family == .general` → `throwIfBlocked(.general)` →
`waitForBackgroundSlot(.general)` at `:274`. Ticket appended, `backgroundQueue[.general].first == ticket`
is true on the first iteration and there is no `await` before the `return` at `:290`, so in
the common case it claims immediately with no 200 ms poll — I checked this specifically
because a per-request 200 ms tax on Discover prefetch would have been serious, and it is
not there. Under a full window it waits at `:293` in 200 ms steps, honouring cancellation
at `:280` and a 429 earned by anyone behind the same IP at `:283`. The mechanism works.

**Are the limits and reserves labelled guesses?** Partly, and the split is exactly right:
- `Family.limit` (`RateLimitGate.swift:46-49`) is explicitly *not* a guess — "These two
  numbers are the API's". Correct.
- `Family.reserve` (`:59-69`) says **"Both are a guess"** and names which one is new and
  how it was chosen (the same one-third proportion). That is the standard CLAUDE.md asks
  for, met.
- `maxHonouredRetryAfter` (`:131-138`) — labelled GUESS with its reasoning. Good.
- `backgroundPollInterval` (`:157-161`) — labelled GUESS with the cost of the alternative.
  Good.

**W7 — `reserveSlot`'s doc comment was made false by the change directly below it.**
- **What.** The `- Returns:` block still describes the pre-item-31 world.
- **Where.** `RateLimitGate.swift:177-183`, verbatim: "the timestamp just appended to
  `searchTimestamps` … `nil` for a general-family path, which never reserves anything to
  begin with." There is no `searchTimestamps` any more (it is `timestamps: [Family: [Date]]`
  at `:108`), and `:191-196` appends and returns a non-nil `Date` for **both** families.
  `refund`'s doc at `:209` has the same problem ("Hands back a search-window slot").
- **Why it matters.** This is the load-bearing kind of comment in this codebase — someone
  reading it will conclude that general-family requests are uncounted and that
  `APIClient`'s refund calls are no-ops for them, which is the opposite of what item 31
  did. It is also the one comment that would tell a reviewer the refund now covers both
  budgets.
- **Fix.** Rewrite `:177-183` and `:209-211` to say "the timestamp appended to this path's
  family window, for either family".
- **Effort.** Two lines. **Confidence.** Certain. **Lens.** 9.

**W8 — the 180/min cap is now enforced locally against a number nobody has ever
measured, and a user-initiated request over it is refused rather than delayed.**
- **What.** `reserveSlot` throws `APIError.rateLimited` on the 181st general request in a
  rolling minute, for `.userInitiated` too.
- **Where.** `RateLimitGate.swift:189-203`. The 180 comes from
  `Family.limit` (`:53`), documented as MangaBaka's published number.
- **Why it matters.** Two things, and the second is the one I would act on.
  (a) `docs/reviews/full/SUMMARY.md` U9 says outright: "Is the 180/min general cap ever
  approached in practice? … Nothing on record has looked." The change enforces a ceiling
  whose distance from real traffic is unknown. A cold launch fans out a lot of general
  requests — a series page alone fires seven legs (`APIClient.swift:717`), the library walk
  pages, Spotlight reindexes, reminder links resolve. If a legitimate launch ever crosses
  180 in a minute, the app now refuses *itself* where previously the server decided, and
  the reader gets "Too many requests" on a screen they just opened.
  (b) The refusal is total. A `.userInitiated` search over its window at least reopens on a
  known date (`:201` computes the oldest timestamp's expiry), which screens render as a
  countdown — fine. But for the general family the same throw lands on a series page, and
  the failure is indistinguishable to the reader from MangaBaka being down.
- **Fix.** Do not change the limit; change the response at the boundary. Either (i) make a
  `.userInitiated` general request that would be the 181st *wait* for the oldest
  timestamp's expiry rather than throw — the wait is bounded by definition at under 60 s
  and the deadline is already computed at `:201`; or (ii) leave it and settle U9 first.
  Whichever is chosen, record the decision, because this is the kind of thing that gets
  re-proposed.
- **Effort.** A function, or a measurement.
- **Confidence.** Worth checking — I have no number for real launch traffic.
- **Lens.** 6 (load balancing) / 4 (a constant whose *effect* nobody derived, even though
  the constant itself is the API's).
- **The measurement that settles it.** `NetworkLedger.shared.byPath` totals across one
  cold launch on the 937-series reference account, bucketed per minute. That is U9 and it
  costs one launch with a `print`.

`GeneralRateLimitWindowTests.swift` is good: four tests, each with a stated
"expected to fail before item 31 with…" line (`:35-38`, `:94-96`), two of them explicitly
labelled controls (`:64-65`, `:77-79`), a movable clock rather than a sleep. That is
exactly the "prove the test fails without the fix" standard and it is met.

### `LossyArray` — does anything still decode an array strictly?

Fourteen lossy sites, and **three strict ones left**. Two are in my slice.

**W4 — `/v1/works/upcoming` is decoded strictly, and a failure discards every page after
the first bad one.**
- **What.** `let batch: [UpcomingWork] = try await client.get(...)` — one unexpected row
  fails the whole page, and the `catch` `break`s the paging loop and returns `.failed`,
  discarding the pages that already succeeded.
- **Where.** `MangaBaka/Core/Schedule/ReleaseCalendar.swift:75`, with the `catch … break`
  at `:78-81` and `return .failed(failure, stale: nil)` at `:105`.
- **Why it matters.** This is the charter's flagship defect, in the same file it happened
  in. `UpcomingWork.swift:28-32` records it: `price` was modelled as `String`, every real
  response threw, and the announced-releases section — "the difference between a fact and
  an estimate" (`:5-8`) — was empty from the day it was built. The *model* was fixed; the
  *fragility* was not. One bad row in 246 still empties the Schedule screen's only factual
  section, and a bad row on page 2 now also throws away page 1.
- **Fix.** `client.getLossy("/v1/works/upcoming", query: query)` — the function already
  exists, takes the same arguments and returns `[UpcomingWork]`. Separately, change
  `:95-106` to return `.loaded(sorted, fetchedAt:, isPartial: true)` when at least one page
  succeeded before the failure, instead of discarding them.
- **Effort.** A line for the first half, a few for the second.
- **Confidence.** Certain. **Lens.** 1 / 2.

**W10 — `CatalogueService.genres()` is strict while its sibling `tags()` is lossy.**
- **Where.** `MangaBaka/Core/Model/CatalogueService.swift:51`
  (`let fetched: [Genre] = try await client.get("/v1/genres")`), against `:130` and `:208`
  in the same file, both `getLossy`, the latter with the comment "one malformed publisher
  row used to empty the whole result set, which is how this surface failed in production
  once."
- **Why it matters.** One bad genre row means `genres()` returns `.failed`, so every
  screen that renders the genre vocabulary shows nothing rather than 199 of 200 — and this
  is a vocabulary endpoint, so it is on the path of several browse surfaces at once.
- **Fix.** `client.getLossy("/v1/genres")`.
- **Effort.** A line. **Confidence.** Certain. **Lens.** 1.

The third is outside my slice but has a line number so I will state it rather than let it
fall between: `MangaBaka/Core/Library/LibraryService.swift:382`
(`guard let batch: [Tag] = try? await client.get("/v1/tags", ...)`) — a bad row makes
`hiddenTags` return nil, which the comment at `:383-384` says correctly means "unknown, not
empty", so the failure mode is benign but the fix is still one word. `:437`
(`[TopGenre]` via `getResults`) cannot be fixed the same way: **`getResults` has no lossy
variant at all**, which is worth knowing before someone assumes the twelve-site sweep was
complete.

**W2 — the drop count is recorded and never read, which makes `LossyArray`'s own
justification inert.**
- **What.** `NetworkLedger.Entry.droppedRows` is incremented by three `getLossy*` wrappers
  across fourteen call sites and is read by **nothing**: not the Settings "Data use"
  screen, not any test, not any other source file.
- **Where.** Written at `MangaBaka/Core/Telemetry/NetworkLedger.swift:61` (via
  `recordDropped`, `:57`), declared at `:35`. The only rendering of ledger entries is
  `MangaBaka/Features/Settings/DataUseSection.swift:104-118`, which prints
  `entry.requests`, `entry.bytes`, `entry.averageSeconds` and `entry.slowestSeconds` — and
  not `droppedRows`. Grep for `droppedRows` over the whole repo returns exactly the two
  lines inside `NetworkLedger.swift`.
- **Why it matters.** This is charter §3 with the comment attached. `LossyArray.swift:44-48`:
  "The drop count goes to `NetworkLedger` rather than to a log line because the question it
  answers ('is the app quietly showing nineteen of twenty?') is the same shape as the
  request counts already kept there, and because a log line is only read by someone already
  looking." `NetworkLedger.swift:30-37` goes further and says the quiet part out loud:
  after `LossyArray`, a section that used to be empty "will instead be short by one, which
  is better **and also harder to notice**." So the change deliberately traded a loud
  failure for a quiet one, and paid for it with a counter that is not on any screen. Right
  now the app can silently show 29 of 30 search results forever and there is no way for
  anyone — reader or developer — to find out.
- **Fix.** Add one line to `DataUseSection.endpointRow`'s caption: when
  `row.entry.droppedRows > 0`, append `· N rows dropped`. It is the same `SettingsRow`,
  the data is already in hand, and it is the cheapest possible way to make the
  justification true.
- **Effort.** A function (one caption, one conditional).
- **Confidence.** Certain. **Lens.** 3 (computed and discarded) / 2 (errors reported as
  nothing).

### Naver's removal — is the adapter really gone, and is anything reading fields nothing populates?

**The adapter is gone.** No `NaverFeedClient` file exists, nothing builds a
`comic.naver.com` request, and `AppServices.swift:38` wires exactly two providers:
`[WebtoonsFeedClient(), GigaViewerFeedClient()]`. The reasoning is recorded at
`AppServices.swift:30-36` (Q8, the private-API rule), a legacy cache purge exists
(`purgeLegacyNaverCache`, `:277`, called from `RootView+Session.swift:186`), and the
privacy manifest was updated (`PrivacyInfo.xcprivacy:33`). That part was done properly.

**W6 — but the consumer side was left standing, and a whole feature is now unreachable.**
- **What.** `ReleaseFeedService` still contains a Naver-specific branch that can never
  execute in production, and it is the branch that produces `TranslationGap`.
- **Where.**
  - `ReleaseFeedService.swift:75` — `let naver = feeds.first { $0.source == .naverWebtoon }`
    is always nil, because no provider emits that source.
  - `:95` → `:168-169` — `gap(primary:naver:)` opens with
    `guard let primary, let naver else { return .none }`, so **`TranslationGap` is now
    permanently `.none`**. The whole 80-line `TranslationGap.swift` and every UI path that
    renders it are dead.
  - `:82` — `primary ?? naver`, the "Korean-only reader" fallback, is unreachable.
  - `:191`/`:198`/`:203` — `naver.totalCount`, `Cadence.estimate(from: naver.releaseDates)`
    and `originalFinished: naver.finished == true`, all unreachable.
  - `WebtoonsFeed.swift:20-24` — `totalCount` and `finished` are documented **"Naver
    only"**. Verified: `WebtoonsFeedClient` and `GigaViewerFeedClient` are the only
    constructors of `ReleaseFeed` in production (`GigaViewerFeedClient.swift:88` is the
    only `ReleaseFeed(...)` call in either) and neither passes either field. Both are
    permanently nil.
  - `ReleaseFeedProvider.swift:32-35` — the protocol doc names **"three adapters
    (`WebtoonsFeedClient`, `NaverFeedClient`, `GigaViewerFeedClient`)"**. `NaverFeedClient`
    does not exist. `:53-54` and `:59-61` describe a "Naver-finished" notification
    condition that `ReleaseReminders.reschedule` can never satisfy.
  - `MangaBakaTests/ReleaseFeedServiceTests.swift` — roughly twelve tests
    (`:61`, `:74`, `:119-135`, `:137-149`, `:159-172`, `:200-208`, `:211-221`, `:233-241`,
    `:264-270`, `:283-299`, `:325-356`) are built on `StubProvider(source: .naverWebtoon)`.
    They are green and they test a provider configuration production does not have. That is
    charter §2 and §5 at once: passing tests over unreachable code.
- **Why it matters.** Three separate costs. (i) A reader who would have seen "the original
  is N episodes ahead" sees nothing, and nothing in the code says why — the feature looks
  alive. (ii) `TranslationGap` is 80 lines plus its tests plus its UI, maintained for
  nothing. (iii) The twelve green tests make the `naver` branch look load-bearing to the
  next person who reads the file, which is precisely how `ShelfDetailView` survived.
- **Fix.** This needs a product decision before a diff, so state both paths:
  - *If the translation gap is gone for good*: delete `ReleaseFeedService.swift:75`,
    `:78`'s `!= .naverWebtoon` filter (it becomes `feeds.first`), `:82`'s `?? naver`,
    `:95`, and `gap(primary:naver:)` at `:168-206`; delete `TranslationGap.swift`; delete
    `totalCount` and `finished` from `ReleaseFeed` (`WebtoonsFeed.swift:20-24, 33-39`);
    delete `ReleaseSource.naverWebtoon` (`ReleaseSource.swift:17, 30, 72`) and
    `APIError.Party.naver` (`APIError.swift:88, 101`); delete the twelve tests. Fix
    `ReleaseFeedProvider.swift:32-35`, `:53-54`, `:59-61`.
  - *If the gap is meant to come back from a permitted source* (MangaBaka's own
    `/v1/series/{id}` carries the original's chapter count): leave the mechanism, but
    change `ReleaseSource.naverWebtoon` to whatever that source is and fix every comment
    that names a deleted client. Do not leave it as-is.
  - Either way, **fix `ReleaseFeedProvider.swift:32-35` today** — a protocol doc naming a
    non-existent conformer is free to correct and costs nothing to decide.
- **Effort.** A file (plus a product decision).
- **Confidence.** Certain on every line cited. **Lens.** 7 (unreachable code that still
  looks alive) / 2 / 9.

### The widget — does the contract test test it, and is the reload spent on every launch?

**The reload is no longer spent on every launch. Verified.** `WidgetSnapshot.swift:103-105`
computes `changed` from whether either list actually moved (excluding `writtenAt`,
deliberately, and the comment at `:101-102` says so), writes the file unconditionally at
`:114-115` so `writtenAt` stays honest, and then `guard changed else { return }` at `:122`
gates `WidgetCenter.shared.reloadAllTimelines()`. The reasoning at `:117-121` names
WidgetKit's 40–70 reloads/day budget. That fix is real and correctly shaped.
`clear()` at `:143` reloads unconditionally, which is right — an account change must redraw.

**The cross-target contract test is real this time.** `project.yml:150` compiles
`MangaBakaWidgets/WidgetSnapshotData.swift` into `MangaBakaTests`, and
`appBytesDecodeAsWidgetData` (`WidgetSnapshotTests.swift:25-45`) encodes with the app's
encoder and decodes into `WidgetSnapshotData` — the seam is genuinely crossed. It compares
*values*, not just "it decoded" (`:32-34` explains why: a renamed field leaves the list
empty rather than throwing). `encodedKeysAreTheContract` (`:52-71`) pins the wire key names
and the date strategy, and its doc explains the second failure mode it covers (a *matched*
rename meeting an un-updated installed extension). T2 was properly fixed.

**W5 — but the test asserts that `due` is absent, and `due` is the one field that changed
yesterday.**
- **What.** The fixture both contract tests run on never sets `due`, and one of them
  asserts the exact key set *without* it.
- **Where.** `MangaBakaTests/WidgetSnapshotTests.swift:100-115` — `sampleSnapshot` builds
  both `Item`s with the memberwise initialiser and omits `due`, so it takes
  `WidgetSnapshot.Item.due`'s `nil` default (`WidgetSnapshot.swift:44`). Then `:64`:
  ```swift
  #expect(Set(firstItem.keys) == ["seriesID", "title", "subtitle", "coverURL"])
  ```
  — an assertion that the encoded `dueThisWeek` item has **no `due` key**.
- **Why it matters.** `due` is the entire point of the 2026-09-14 change. Before it, the
  weekday was baked into `subtitle` and the `Date` was thrown away, so the widget kept
  saying "Due Thursday" into the following week (`WidgetSnapshot.swift:36-40`). The new
  contract is: the app ships a `Date`, the widget formats the weekday freshly
  (`SeriesWidgetEntryBuilder.subtitle(for:)`, `SeriesWidgetEntry.swift:61-65`) and drops
  rows whose day has passed (`:77-80`). **None of that crosses the seam in any test.**
  Rename `due` on the app side, or change its date strategy, and `WidgetSnapshotData.Item.due`
  decodes as nil for every row — every widget silently reverts to a bare subtitle, past-due
  rows stop being filtered, and all four contract tests still pass. This is T2's exact
  failure mode, reintroduced for the newest field, in the test written to prevent it.
- **Secondary, same fixture:** `:104` gives the `dueThisWeek` item
  `subtitle: "Due Thursday · Webtoons"` — a string the app no longer produces.
  `WidgetSnapshot.Item.subtitle`'s own doc at `:26-27` says "No longer carries the weekday".
  The fixture contradicts the model it is built from, which is charter §2's "a fixture with
  no provenance".
- **Fix.** In `sampleSnapshot`, give the `dueThisWeek` item a real
  `due: Date(timeIntervalSince1970: …)` and change its subtitle to `"Webtoons"` (what the
  app actually writes, per `WidgetSnapshot.swift:184-187`). Then:
  add `#expect(widgetSide.dueThisWeek.first?.due == <that date>)` to
  `appBytesDecodeAsWidgetData`; change `:64` to
  `["seriesID", "title", "subtitle", "coverURL", "due"]`; and keep one `pickBackUp` item
  with no `due` so the "an old snapshot with no key still decodes" promise at
  `WidgetSnapshotData.swift:23-25` is also covered.
- **Effort.** A function. **Confidence.** Certain. **Lens.** 2.

**W16 — `roundTrips()` is the test the file's own comment says proves nothing.**
- **Where.** `WidgetSnapshotTests.swift:117-123` encodes `WidgetSnapshot` and decodes
  `WidgetSnapshot`. The suite comment at `:18-20` says "Until 2026-09-14 this test encoded
  and decoded `WidgetSnapshot` on both sides, which proved nothing about the pair."
- **Why it matters.** Harmless in itself — it still catches a self-inconsistent `Codable` —
  but it reads as a contract test and is not one, and the file has a comment saying so
  eleven lines above it.
- **Fix.** Rename it to `appTypeIsSelfConsistent` or delete it. **Effort.** A line.
  **Confidence.** Certain. **Lens.** 9.

---

## Part 2 — the nine lenses over the rest

### Crash risk — a clean sweep, recorded as a negative result

Swept the whole slice for `try!`, `as!`, `fatalError`, `preconditionFailure`, `.first!`,
`.last!` and trailing `!`. **Seven hits, all the same safe shape**: a `preconditionFailure`
on a hard-coded literal URL that cannot fail to parse — `SeriesCharacter.swift:209`,
`ShikimoriDescriptionParser.swift:202`, `AppleBooksClient.swift:209`,
`GoogleBooksClient.swift:144`, `AniListClient.swift:219`, `MangaUpdatesClient.swift:277`,
plus the regex literal at `CharacterProfile.swift:158` which is not an unwrap at all.
None is reachable from network or keyboard input. **No force-unwrap in the slice.**

`Int(Double)` sweep: every conversion on a server-supplied number goes through
`Int(wholeOrClamped:)` or is bounded by construction. The three raw ones I checked in
detail — `Cadence.swift:174`, `:178`, `:179` — take a median and a spread of `[Int]` day
gaps produced by `Calendar.dateComponents`, filtered to `> 0` at `:155`, with
`gaps.count >= minimumGaps` guarded at `:161`. The input cannot be NaN and cannot overflow.
Safe.

`Int+Clamped.swift:41-55` is correct for all four cases it documents (NaN → 0, ±inf →
`.min`/`.max`, overflow → clamp, otherwise truncate toward zero), and `:15-18` explains
why `Int(exactly:)` alone was not the answer. The doc's list of 27 replaced sites with
file and line is unusually good and should not be deleted.

`WebtoonsEpisode.swift` does a lot of string→`Int` parsing on publisher-supplied titles;
every one is `Int(...)` returning an optional and guarded (`:67`, `:87`, `:108`, `:111`,
`:119`, `:122`, `:129`). Safe.

**This is the charter's "confirm that is still true rather than assuming" item, confirmed
for this slice.**

### Charter §1 — the model against the payload, measured live

**MEASURED 2026-09-14, 07:46 and 07:47 UTC, `GET https://api.mangabaka.org/v1/works/upcoming`,
`limit=3` then `limit=50`, one request each, with the app's own User-Agent.** 50 works:

| field | wire type observed | model declares | verdict |
|---|---|---|---|
| `id` | `str` 50/50 (UUIDv7) | `let id: String` | agrees |
| `price` | `list` 37/50, `null` 13/50; sample `[{"value": 13.99, "iso_code": "usd"}]` | `let prices: [Price]?` via `CodingKeys.prices = "price"` | agrees |
| `sequence_numeric` | `int` 50/50 | `Double?` | agrees (int decodes as Double) |
| `pages` | `int` 49/50, `null` 1/50 | `Int?` | agrees |
| `count_type` | `"main"` 50/50 | `String?` | agrees |
| `series_id` | int | `Int?` | agrees |

So the 2026-09-11 `price` fix is confirmed live, and the `CodingKeys` handling is subtler
than it looks and is correct: `convertFromSnakeCase` rewrites incoming keys *before* they
are matched against `CodingKeys`' raw values, so `price` → `price` matches
`case prices = "price"` while `series_id` → `seriesId` matches `case seriesId`. Worth a
sentence in the file, because the next person to add a field here will get it wrong.

**This also settles U15** (`docs/reviews/full/SUMMARY.md`, "Needs a curl", U15 — "Does
`/v1/works/upcoming` ever include today's date?"). All 50 `release_date` values were
`2026-09-15`, taken at 07:46 UTC on 2026-09-14 — i.e. **tomorrow, with nothing for today**,
matching the single earlier sample of 2026-09-13 23:24 UTC. Two observations, twelve hours
and one date boundary apart, both showing the window starting the following day. That is
not proof the window *never* contains today, but it is now two for two, and it means
`ReleaseCalendar`'s "out today" condition cannot fire from a fresh fetch — only from a list
cached across midnight, which is exactly what the U15 entry predicted. I would call U15
settled enough to act on and record it as such.

### Errors — swallowed, or reported as empty

Beyond W2 and W3, the slice is in better shape than the ledger suggests: `FeedAnswer`
(`ReleaseFeedProvider.swift:16-27`) is a proper three-state answer with the reasoning at
`:5-15`, and `Fetched` carries `failed(error, stale:)`. `ReleaseCalendar.upcoming()`
returns `Fetched` for exactly this reason (`:51-60`) — which makes W4's discarding of
already-fetched pages the odd one out rather than the norm.

One that is not on the work list: `AppIntents.swift:44-46` — `DueThisWeekIntent.perform`
answers "Open MangaBaka first, then ask again." when `IntentBridge.shared.services` is nil.
That is correct and well-judged. The comment at `:31-38` recording *why*
`maxFeedFetches = 8` was deleted — "eight candidates was up to 56 seconds and Siri gives up
long before that while the requests carry on spending the publishers' budget on an answer
nobody hears" — is the best single comment I read in this slice. It records a negative
result with its reason, which is the thing CLAUDE.md asks for and almost nobody does.

### Optimisation and speed

Nothing new beyond what is already filed. Two things I checked and found *not* to be
problems, recorded so they are not re-proposed:
- **`waitForBackgroundSlot` does not tax the happy path.** I expected a 200 ms poll per
  background request and there is none: `RateLimitGate.swift:279-291` has no suspension
  point before its `return`, so an uncontended background request claims immediately.
- **`APIClient.isoFormatterWithFraction`/`isoFormatterPlain`** (`:666-671`) are correctly
  hoisted to `static let`, with the cost of the old per-value construction measured and
  labelled a guess at `:651-665`. The `nonisolated(unsafe)` spelling is justified in the
  comment rather than hidden. Correct.

### What this slice does well

Named with the same evidence standard, because an all-negative report would be wrong:

1. **The 429 handling is genuinely one rule now, nine times out of ten.** Seven third-party
   clients carry the identical three-line `spacing.backOff(retryAfterHeader:now:)` shape
   with the identical comment. `RequestSpacing.swift:37-45` records *why* the cap exists
   with the actual failure mode measured on device (`TimeInterval("nan")` parses
   successfully, a NaN `nextAllowed` makes `guard wait > 0` false forever). That is a
   constant with a derivation attached.
2. **`ThirdPartySession` closed a real privacy hole and said what it closed.**
   `:10-16` names the specific cookies (Webtoons' five including a one-year `locale`,
   Shikimori's three `__ddg`) and why storing them contradicted the privacy note. Three
   independent cookie refusals, not one.
3. **`RequestSpacing` being a struct rather than an actor, with the reason and the
   measurement.** `:6-11`: claim-before-wait, "measured at 96 µs apart before this existed.
   Three clients had that bug from the same copied function; now there is one." That is the
   whole CLAUDE.md standard in four lines.
4. **`GeneralRateLimitWindowTests` and `APIClientCacheRefundTests` both ship controls and
   both state their pre-fix failure.** `APIClientCacheRefundTests` goes further and pins its
   own measurement (`loadCount == 2`) so the test's entitlement to its claim is itself
   asserted, and its doc says plainly what the stub cannot prove. That is rarer than it
   should be.
5. **The crash-risk surface is clean and stayed clean.** Seven `preconditionFailure`s, all
   on hard-coded literals; every wire number through `Int(wholeOrClamped:)`.
6. **Comments carry dates and methods.** "verified 2026-09-08", "MEASURED 2026-09-13
   against api.mangabaka.org", "246 works in the window", "50 of 50 works were `main` on
   2026-09-13". Both of my live `curl`s were only possible to *interpret* because an
   earlier one was written down.

### What I could not determine

| # | Question | The one thing that settles it |
|---|---|---|
| 1 | Does CFNetwork report `resourceFetchType == .localCache` for a URLCache *revalidation* (W9)? | Two `CachingStubProtocol` loads to one URL with `max-age=1`, 2 s apart, the second answered 304; print `resourceFetchType` and `requestStartDate`. No live request. |
| 2 | Does `didFinishCollecting` really precede `data(for:delegate:)` returning on device? | One `print` in each, one request, read the order in the console. This is the agent's own unsure and it is still open. |
| 3 | Does MangaBaka's cover CDN 403 an agentless client (W1)? | `curl -sI` one `cdn.mangabaka.dev` cover URL with and without `-A`, compare status. |
| 4 | Is 180/min ever approached on a real cold launch (W8, = U9)? | `NetworkLedger.shared.byPath` totals bucketed per minute across one cold launch on the reference account. |
| 5 | Is `price` ever a bare object rather than a list? | 37 of 37 non-null samples were lists on 2026-09-14. Not proof; W4's `getLossy` makes it not matter. |
| 6 | Is the translation gap meant to return from a permitted source, or is it gone (W6)? | Not a measurement — a product decision. It blocks the delete. |
