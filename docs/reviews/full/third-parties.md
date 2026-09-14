# Deep review, slice 4 — everyone else's servers, plus the extensions (2026-09-14)

Read-only. No build, no lint, no test run, no edits outside this file. HEAD `99a1124`.

## Scope and denominator

Read in full, every line:

- `MangaBaka/Core/Characters/` — all 8 files (2,030 lines).
- `MangaBaka/Core/Volumes/` — all 6 files (986).
- `MangaBaka/Core/Intents/` — all 3 files (318).
- `MangaBakaWidgets/` — all 7 files (307), plus `Core/Library/WidgetSnapshot.swift`,
  both `.entitlements`, `MangaBakaWidgetsInfo.plist`, and the widget block of `project.yml`.
- Release-feed and MangaUpdates clients in `Core/Schedule/`: `ReleaseFeedService`,
  `ReleaseFeedProvider`, `ReleaseSource`, `WebtoonsFeedClient`, `WebtoonsFeed`,
  `WebtoonsEpisode`, `NaverFeedClient`, `GigaViewerFeedClient`, `ReleaseSummary`,
  `TranslationGap`, `MangaUpdatesCategories`, `MangaUpdatesClient` (12 files, 2,054).

Read for context (callers): `Features/Detail/SeriesDetailView+Store.swift`, `+Releases.swift`,
`+Categories.swift`, `SeriesDetailView.swift:425-526`, `App/AppServices.swift`,
`App/MangaBakaApp.swift`, `App/RootView.swift:150-185`, `App/RootView+Session.swift:120-230`,
`Features/Schedule/ScheduleModel.swift:320-400`, `Core/Library/SpotlightIndex.swift`,
`Core/Library/LibrarySnapshot.swift:81-125`, `Core/Model/SeriesWebLink.swift`,
`Core/Networking/RequestSpacing.swift`, `Features/Detail/VolumesSection.swift:168-180`.

Not reviewed: `Features/Detail/ReleaseSection.swift`, `ReadRow.swift`, `CharacterRow.swift`
(grep only), `CharacterProfileView.swift`, `Core/Notifications/NotificationPolicy.swift`,
`Core/Schedule/ReleaseSchedule.swift` and `Cadence.swift`, every test file (grep only).

Already established and **not re-filed**: `docs/reviews/third-parties.md` (T1–T14) and the
services half of `docs/reviews/failures-services.md` (F15–F18, fixes 5/15/16/17/18/19/22/23).
Every one of those was checked against HEAD; the status table at the end says which are closed.
Two remain open and are listed there, not re-argued.

Live requests, all HEAD, 3 of 3, sent 2026-09-13 23:25 UTC (server `date`), Safari UA:

1. `HEAD https://www.webtoons.com/en/x/y/list?title_no=95` (the placeholder-lookup shape
   `WebtoonsFeedParser.lookupURL` builds) → `HTTP/2 301`, `content-length: 0`,
   `location: /en/fantasy/tower-of-god/list?title_no=95`, five `set-cookie`s
   (`locale=en`, `needGDPR=true`, `needCCPA=false`, `needCOPPA=false`, later `countryCode=GB`),
   `cache-control: no-cache, no-store`.
2. Same URL again to capture `location` (the first capture cut the header list short).
3. `HEAD https://www.webtoons.com/en/fantasy/tower-of-god/rss?title_no=95` → `200`,
   `application/rss+xml`, `cache-control: no-cache`, **no `ETag`, no `Last-Modified`**,
   same cookies plus `countryCode=GB`.

Request 1/2 settles finding 9 (the redirect can be read without downloading the page).
Request 3 settles the `If-Modified-Since` lens for Webtoons: the feed carries no validator, so
conditional revalidation is impossible there and the seven-day file cache is the right tool.

## Ranked top ten — value against effort

| # | Finding | Where | Effort | Confidence |
|---|---|---|---|---|
| 1 | "Due this week" widget goes stale and says "Due Thursday" for a Thursday that passed | 1 | function ×2 files | certain |
| 2 | Signing out leaves the previous account's library on the Home Screen | 2 | a line + a function | certain on mechanism |
| 3 | Siri's "what's due" spends up to 9 network requests, serialised at 3.5 s, inside Siri's budget | 3 | a function | likely |
| 4 | Third-party clients share `URLSession.shared`: 60 s timeout, cookies accepted and replayed | 4 | a file + 9 default args | certain |
| 5 | The cast is the only third-party call with no cache — two requests per page open, again on every revisit | 5 | a function | certain |
| 6 | `Retry-After` is honoured uncapped, in nine copies; a NaN breaks a client's spacing for the session | 6 | a function + 9 edits | certain |
| 7 | The launch-time AniList health check has lost the reason it existed | 7 | deletion | certain |
| 8 | Widget cover decode has no size cap and no timeout; a `raw` cover can exceed the extension's memory | 8 | a few lines | likely / worth checking |
| 9 | Placeholder Webtoons lookup downloads a whole HTML page to read a redirect HEAD answers in 0 bytes | 9 | 3 lines | certain (measured) |
| 10 | Surname-plus-initial name rule drops siblings from the cast union | 10 | a line + a test | likely |

Then 11–19 below, each small.

## Findings

### 1. The "Due this week" widget cannot tell that its week is over

- **What** — the widget renders a baked string ("Due Thursday") with no date behind it, never
  reads `writtenAt`, and is only rewritten when a schedule build finishes — so it shows the
  last build's week indefinitely.
- **Where** — subtitle baked at `MangaBaka/Core/Library/WidgetSnapshot.swift:126` and `:145`
  with the `Date` dropped at `:152`; `writtenAt` decoded and never read in
  `MangaBakaWidgets/WidgetSnapshotData.swift:27` and `SeriesWidgetEntry.swift:37-40`; the
  only writer of `dueThisWeek` is `Features/Schedule/ScheduleModel.swift:357-359`, inside
  `followBuild()`, i.e. only at the end of a manual build; the hourly reload at
  `SeriesWidgetEntry.swift:26-30` re-reads the same file.
- **Why it matters** — a reader builds the schedule on Monday; Chainsaw Man reads "Due
  Thursday". On the following Monday the widget still reads "Due Thursday" — now pointing at
  a day that has passed, presented as upcoming — and will until the next build. The hourly
  reload gives the appearance of freshness with none of the substance. Charter 5: the timer
  measures nothing.
- **Fix** — add `let due: Date?` to `WidgetSnapshot.Item` and to the mirror in
  `WidgetSnapshotData.Item` (the `WidgetSnapshotTests.roundTrips` test will hold the two
  together); in `SeriesWidgetEntryBuilder.makeEntry` drop items whose `due` is before
  `Calendar.current.startOfDay(for: .now)` and, when `writtenAt` is older than
  `DueThisWeek.window` days, return a placeholder whose text says "Open MangaBaka to refresh"
  rather than the fresh-install one. Format the weekday in the provider from `due`, not in the
  app. Also write `dueThisWeek` from `ScheduleModel.load()` when a snapshot already exists on
  disk, not only after a build.
- **Effort** — a function in each target plus a test that ages `writtenAt` with `TestClock`.
- **Confidence** — certain.
- **Lens** — bugs (1), measurement (charter 5).

### 2. Signing out does not clear the widgets

- **What** — the sign-out path forgets the library, the ranker, the reminders and the
  Spotlight index, and leaves `widget-snapshot.json` untouched; the next launch's walk fails
  unauthenticated and so never rewrites it.
- **Where** — the forget block at `MangaBaka/App/RootView+Session.swift:120-141` (Spotlight
  cleared at `:140`, no widget call); the only `pickBackUp` writer is `:184-186`, behind
  `guard walk.failure == nil else { return }` at `:181`; an unauthenticated
  `libraryPage` throws (`Core/Library/LibrarySnapshot.swift:96-110` sets `result.failure`
  and breaks), so the guard returns.
- **Why it matters** — a reader who removes their token, or hands the phone to someone who
  enters their own, keeps "Pick back up: <title> · Ch. 88 of 120" from the previous account
  on the Home Screen, with tappable deep links into series that are no longer theirs. Same
  class as gap 59 (Spotlight) and R1/R8 (reminders) which were both fixed; the widget was
  added after those fixes and did not inherit them.
- **Fix** — add `static func clear()` to `WidgetSnapshot` (write an empty snapshot, then
  `reloadAllTimelines()`), call it beside `spotlight.clear()` at `RootView+Session.swift:140`.
  Consider also writing `pickBackUp: []` when the walk fails with `needsAccount`, so a
  signed-out launch tidies up even if the sign-out path was bypassed.
- **Effort** — a function and a line.
- **Confidence** — certain on the mechanism (traced through `LibrarySnapshot.load`); the
  on-device result is not verified.
- **Lens** — bugs, privacy.

### 3. `DueThisWeekIntent` spends network inside Siri's time budget

- **What** — one Siri question fires up to eight `ReleaseFeedService.report` calls plus one
  MangaBaka request (`calendar.mine`), where every Webtoons candidate is serialised behind one
  actor at 3.5 s and a placeholder link costs a lookup request first.
- **Where** — `MangaBaka/Core/Intents/AppIntents.swift:40` (`maxFeedFetches = 8`, labelled a
  guess), `:48` (MangaBaka request), `:89-108` (task group → `feeds.report`);
  `Core/Schedule/WebtoonsFeedClient.swift:114-119` and `:170-175` (one `RequestSpacing`
  for lookup and feed, so eight series with placeholder links = 16 slots = up to 56 s).
- **Why it matters** — an App Intent's `perform` is expected to return in seconds; a
  first-time ask on a library whose feeds are not yet cached takes tens of seconds and Siri
  gives up with a generic error, and the requests still complete after the reader has stopped
  listening. It also contradicts the standing rule from `0fb8457` ("background work never
  costs the reader a request"). Charter: `cachedFeeds` (`ReleaseFeedService.swift:122-135`)
  exists for exactly this shape and is used by the reminders path
  (`RootView+Session.swift:273`) — the intent hand-rolled the network variant instead.
- **Fix** — in `feedDueWorks`, replace `feeds.report(for:links:)` with
  `provider.cachedFeed(for:links:)` in provider order (or add
  `ReleaseFeedService.cachedReport(for:links:)` that runs `summarise` over the cached feed);
  drop `maxFeedFetches`. Keep `calendar.mine` (one request, cheap) or gate it on a cached copy.
  Test: `URLProtocolStub.requests.isEmpty` after `perform()` with an empty feed cache.
- **Effort** — a function.
- **Confidence** — likely (Apple does not publish the in-process intent budget; the serialised
  wait is arithmetic from the code).
- **Lens** — load balancing (6), better way (4).

### 4. Nine third-party clients ride `URLSession.shared`: no timeout, and cookies in, cookies out

- **What** — every client outside `APIClient` defaults to `.shared`, which keeps the 60 s
  request timeout and the default cookie policy (accept and replay).
- **Where** — `AniListClient.swift:38`, `SeriesCharacter.swift:132`, `AppleBooksClient.swift:23`,
  `GoogleBooksClient.swift:32`, `OpenLibraryCovers.swift:38`, `WebtoonsFeedClient.swift:24`,
  `NaverFeedClient.swift:25`, `GigaViewerFeedClient.swift:34`, `MangaUpdatesClient.swift:31`.
  `APIClient.swift:34-36` already builds a 20 s configuration, MangaBaka only. `timeoutInterval`
  has no other hit in `MangaBaka/` or `MangaBakaWidgets/`.
- **Why it matters** — a hung `itunes.apple.com` holds `isLoadingVolumes` (the shelf skeleton,
  `SeriesDetailView+Store.swift:50-79`) for a full minute; a hung Webtoons holds the release
  row the same. And the app is a stateful client to three publishers: Webtoons sets five
  cookies on every answer (measured above, including `locale` for a year and `countryCode`),
  Shikimori's edge sets three `__ddg` cookies (measured 2026-09-13), and `HTTPCookieStorage.shared`
  replays them on the next request. Nothing identifies the reader, but "the app sends nothing
  it did not choose to" is a claim the privacy note makes and this quietly breaks.
- **Fix** — one `ThirdPartySession.make() -> URLSession` in `Core/Networking/`:
  `URLSessionConfiguration.default` with `timeoutIntervalForRequest = 20` (match APIClient's
  guess, say so), `httpShouldSetCookies = false`, `httpCookieAcceptPolicy = .never`,
  `urlCache = nil` for the feed clients (they cache their own JSON; the RSS carries no
  validators anyway). Use it as the default argument at the nine sites. Test: a stub that never
  answers → `.transport`/nil within 25 s (prove it hangs first).
- **Effort** — a file and nine one-line edits.
- **Confidence** — certain.
- **Lens** — bad practice (9), errors (2), privacy.

### 5. The cast is fetched from two third parties on every page open, and never cached

- **What** — `CharacterService.characters` asks AniList and Shikimori live each time; every
  other third-party answer on the page (Apple, Google, Open Library, the three feeds,
  MangaUpdates categories, cadence) is cached on disk or in the database.
- **Where** — `MangaBaka/Core/Characters/CharacterService.swift:120-143`;
  `AniListClient.swift:105-167`; `SeriesCharacter.swift:144-183`. No `cache` symbol in the
  three files.
- **Why it matters** — paging between series (`e6022f2`) and reopening a page from the stack
  each cost two third-party requests. AniList's 90/min and Shikimori's 5/s are far off, but the
  0.7 s AniList slot means a reader swiping through six pages waits behind their own earlier
  swipes; and it is the one place the request log at a third party sees a reader's browsing
  path in full, twice, with no reason.
- **Fix** — an in-actor `[CacheKey: (CharacterCast, Date)]` with a 24 h life (a guess — label
  it) keyed on `(aniListID, shikimoriID, limit)`, cleared by `clearOutageMemory()`; or a
  file cache shaped like `AppleBooksClient`'s with a versioned key. Do not cache a cast whose
  every asked source failed. Test: two calls, one request per source.
- **Effort** — a function.
- **Confidence** — certain.
- **Lens** — optimisation (3), load balancing (6).

### 6. `Retry-After` is honoured without a cap, nine times over

- **What** — each client parses `Retry-After` as a bare `TimeInterval` and backs its spacing
  off by exactly that; `RateLimitGate` caps MangaBaka's at 15 minutes
  (`maxHonouredRetryAfter`), the third parties get no cap and no finiteness check.
- **Where** — `AniListClient.swift:130-134` and `:392-396`; `SeriesCharacter.swift:164-168`
  and `:269-273`; `MangaUpdatesClient.swift:142-146` and `:200-204`;
  `WebtoonsFeedClient.swift:130-134`; `NaverFeedClient.swift:64-68`;
  `GigaViewerFeedClient.swift:144-148`. `RequestSpacing.backOff(until:)` at
  `Core/Networking/RequestSpacing.swift:29-31` takes whatever it is given.
- **Why it matters** — a `Retry-After: 86400` from any of them makes the next caller of that
  client `Task.sleep` for a day (`AniListClient.swift:201`), which on a series page is a cast
  row that spins until the app is killed. `Retry-After: nan` (no server sends it; the parser
  accepts it) makes `RequestSpacing.claim` compute `max(nan, now)` → `nan`, and every later
  `claim` returns `nan`, `guard wait > 0` fails, and the client never spaces again for the
  session — no trap, but the politeness the terms require is silently gone. Nine identical
  copies of the same block is also the shotgun-surgery shape the charter names.
- **Fix** — `mutating func backOff(retryAfterHeader: String?, now: Date, cap: TimeInterval = 900)`
  on `RequestSpacing`: parse, `guard seconds.isFinite`, clamp to `0...cap`, default 60; call it
  from the nine sites. Cite `RateLimitGate.maxHonouredRetryAfter` as the sibling and label the
  cap a guess as that one does. Test: `"nan"`, `"1e9"`, `"-5"`, `"60"`.
- **Effort** — a function plus nine two-line edits.
- **Confidence** — certain.
- **Lens** — crash risk (8, a silent break rather than a trap), bad practice (9).

### 7. The AniList health check at launch no longer has a job

- **What** — a POST to `graphql.anilist.co` on every launch, whose stated purpose was to keep
  the first series page from paying AniList's timeout "before falling back to Shikimori".
  Since `5b0d508`/the union change, both sources are asked concurrently and a slow AniList
  delays nothing but its own half.
- **Where** — `MangaBaka/App/RootView.swift:148` (`.task { await characters.primeAniListHealth() }`);
  `Core/Characters/CharacterService.swift:195-218` (doc still says "before falling back");
  `AniListClient.swift:511-559`.
- **Why it matters** — one request to a third party per launch from every reader, including
  those who never open a series page, for a memory (`aniListDownUntil`) that
  `fetchAniList` would set itself on the first real 403 (`CharacterService.swift:166-169`) at
  the cost of one failed request. Its own comment (`:203-207`) already argues that a transport
  failure at launch tells you nothing. It also holds one of the 0.7 s slots at the moment the
  first page's real cast request wants it. The comment quotes Abdi's ask — that ask was made
  for the fallback design and is worth re-confirming rather than silently deleting.
- **Fix** — delete `primeAniListHealth`, `healthCheck`, `healthCheckQuery` and the `.task`;
  keep `isAniListOutage`. Update `CharacterSourceTests` accordingly. Practical impact: one
  fewer host contacted at launch; nothing on screen changes.
- **Effort** — deletion (three functions, one line, tests).
- **Confidence** — certain that it is unreachable-in-purpose; the decision is Abdi's.
- **Lens** — load balancing (6), charter 7 (a rationale that no longer runs).

### 8. Widget cover loading: no size cap, no timeout, and a `raw` fallback

- **What** — the extension decodes up to four covers with `UIImage(data:)` from whichever URL
  the app wrote — `x250 ?? x350 ?? raw` — and fetches them through `URLSession.shared` with the
  default 60 s timeout inside `getTimeline`.
- **Where** — `MangaBakaWidgets/CoverLoader.swift:23-27`; URL choice at
  `Core/Library/WidgetSnapshot.swift:146` and `:188`; the timeline `Task` at
  `DueThisWeekWidget.swift:12-17` and `PickBackUpWidget.swift:12-17`.
- **Why it matters** — a widget extension runs under a memory ceiling in the low tens of MB
  and a completion budget of seconds; either overrun kills the extension, which is the
  Home-Screen crash the brief warns about and nothing in the app can catch. Four `raw`
  covers at a typical 1,200×1,800 decode to ~8 MB each. `x250` is nil only when the API sent
  no variants, so the common path is safe; the fallback is the risk. A hung CDN request makes
  `getTimeline` miss its window and the widget keeps its last entry — not a crash, but the
  hourly reload is then a no-op.
- **Fix** — in `CoverLoader`, `UIImage(data:)?.preparingThumbnail(of: CGSize(width: 96, height: 132))`
  (3× the 32×44 frame at `SeriesWidgetView.swift:78`); build the session with
  `timeoutIntervalForRequest = 10`; in `WidgetSnapshot` drop the `raw` fallback (nil cover
  beats a jetsam). Also skip cover fetches when `context.isPreview` in `getSnapshot`
  (`DueThisWeekWidget.swift:7-10`) — the gallery should not wait on the network.
- **Effort** — a few lines.
- **Confidence** — likely on memory (the ceiling is not published; measure with Instruments'
  widget target and a snapshot whose items carry only `raw`), worth checking on the budget.
- **Lens** — crash risk (8).

### 9. The Webtoons placeholder lookup downloads a page to read a header

- **What** — `resolveFeedURLs` sends a GET to `/en/x/y/list?title_no=N`, discards the body, and
  reads `response.url`. A HEAD to the same URL answers `301`, `content-length: 0`,
  `location: /en/fantasy/tower-of-god/list?title_no=95` (measured above).
- **Where** — `MangaBaka/Core/Schedule/WebtoonsFeedClient.swift:176-181`;
  `WebtoonsFeed.swift:132-138`.
- **Why it matters** — 84% of library Webtoons links are placeholders (`WebtoonsFeed.swift:117-120`),
  so most first opens of a Webtoons series download a full listing page (HTML, hundreds of KB,
  `no-store`) purely to be redirected, and the made-up `/en/x/y/` path is what Webtoons sees
  in its logs from this app. HEAD keeps the app on the "we read feeds, not pages" side of the
  line the roadmap draws.
- **Fix** — `var request = URLRequest(url: lookup); request.httpMethod = "HEAD"`, then
  `session.data(for: request)`; `URLSession` follows the redirect for HEAD and `response.url`
  is the landed URL as before. Test: the stub sees `HEAD`.
- **Effort** — three lines.
- **Confidence** — certain (measured; one HEAD from a Mac, not a phone).
- **Lens** — optimisation (3), the "would embarrass in the request log" test.

### 10. The surname-and-initial rule merges siblings, which drops a character

- **What** — rule 2 of `CharacterNameMatch` treats "same last token and same first-letter
  of the first token" as the same person. Siblings share both.
- **Where** — `MangaBaka/Core/Characters/CharacterNameMatch.swift:57-60`; the doc at `:36-38`
  says the rule exists for "an abbreviated first name"; the test at
  `MangaBakaTests/CharacterNameMatchTests.swift:24-25` checks different surnames, never the
  same surname with a different first name.
- **Why it matters** — Abdi accepted duplicates and rejected drops (`:11-13`). This rule's
  failure is a drop: if AniList's top 20 carries "Jinwoo Sung" and Shikimori's carries
  "Jinah Sung" (his sister, a real Solo Leveling character) in the same name order, Jinah is
  discarded from the union. "Itachi Uchiha"/"Izumi Uchiha", "Sasuke"/"Sakura Uchiha" are the
  same shape. Shikimori's romaji is given-name first ("Luffy Monkey D.",
  `SeriesCharacter.swift:227`) like AniList's `full`, so the orders do line up.
- **Fix** — fire rule 2 only when one side's first token is an abbreviation:
  `firstTokenA.count <= 2 || firstTokenB.count <= 2` (the raw string ending in "." is lost by
  `normalizedTokens`; token length is the surviving signal). Add
  `siblingsWithSameInitialDoNotMerge` and keep `surnameAndInitialMatches` green.
- **Effort** — a line and a test.
- **Confidence** — likely. One `GET shikimori.io/api/mangas/<Solo Leveling id>/roles` would
  settle the name order; not spent here (budget went to Webtoons).
- **Lens** — bugs (1). This does not re-litigate the fuzzy policy; it narrows one rule to what
  its own comment says it is for.

### 11. Open Library is asked once per missing cover, sequentially, with no cap

- **What** — `loadOpenLibraryCovers` loops every ISBN whose MangaBaka volume has no cover,
  one HEAD each, 3 s apart, and `loadOnward` awaits it.
- **Where** — `Features/Detail/SeriesDetailView+Store.swift:117-122`;
  `Core/Volumes/OpenLibraryCovers.swift:24` (3 s), `:51-77`;
  `Features/Detail/VolumesSection.swift:171-180` returns every numbered volume.
- **Why it matters** — a 40-volume series whose `/works` rows carry ISBNs but no art is 40
  requests over two minutes on first open — most of them for spines below the fold — and the
  "Detail complete" signpost (`SeriesDetailView.swift:434`) now measures Open Library's
  politeness delay rather than the page (charter 5). Cached 30 days afterwards, so it is a
  first-open cost per series, but the roadmap wording for this feature was "lazy per visible
  spine".
- **Fix** — cap the pass to the first N numbers needing covers (N = the row's visible spines,
  say 8, labelled a guess) and fetch the rest on demand from the spine's `onAppear`; or move
  the whole pass out of `loadOnward`'s tuple so the signpost measures the page again.
- **Effort** — a function.
- **Confidence** — certain on the mechanism; how many series have many coverless ISBNs is
  data the library query would answer.
- **Lens** — load balancing (6), speed (7), measurement (charter 5).

### 12. Widget and Siri disagree about what is due, despite a comment saying they never can

- **What** — `dueThisWeekItems(dated:feedWorks:)` merges feed-sourced dates ahead of estimates;
  its only caller passes no `feedWorks`, and feed items it would build carry `coverURL: nil`.
- **Where** — `Core/Library/WidgetSnapshot.swift:103-131` (comment at `:106-107`: "so the
  widget and Siri never disagree"); caller `Features/Schedule/ScheduleModel.swift:357-359`
  passes `dated:` only; `:127` writes `coverURL: nil`.
- **Why it matters** — charter 3: a parameter, a sort rule and a test
  (`WidgetSnapshotTests.feedAndEstimateMerge`) for a path production never takes. Siri says
  "Tower of God, Thursday (real dates from Webtoons)"; the widget says the MangaUpdates
  estimate for the same series. Fixing 3 (cached-only feeds) makes this cheap to wire.
- **Fix** — after 3, call the cached `feedDueWorks` in `followBuild` and pass it; carry the
  series cover through `FeedDueWork` (add `coverURL`) so the row is not grey. Or delete the
  parameter and the comment.
- **Effort** — a few lines.
- **Confidence** — certain.
- **Lens** — charter 3.

### 13. "Apple Books couldn't be reached" when it was reached and had nothing

- **What** — after a successful empty answer from the reader's store, a failed Japanese-store
  fallback sets `appleUnreachable`.
- **Where** — `Features/Detail/SeriesDetailView+Store.swift:58-62`: `answer` is overwritten by
  `japaneseVolumes` at `:59`, then `appleUnreachable = answer == nil` at `:62`.
- **Why it matters** — the shelf note blames Apple for a store that answered; the reader
  retries a request that will answer `[]` again.
- **Fix** — keep the first answer: `let readerStore = await …; appleUnreachable = readerStore == nil`
  and only then fall back.
- **Effort** — a line. **Confidence** — certain. **Lens** — errors (2).

### 14. One User-Agent string, two copies, and one client that sends none

- **What** — `"MangaBakaIOS/1.0 (+https://github.com/ItsAbdiOk/MangaBakaIOSAPP)"` is declared
  twice; Open Library, whose covers policy asks clients to identify themselves, gets the
  default `CFNetwork` UA; so do Webtoons, Naver and the GigaViewer hosts.
- **Where** — `Core/Characters/SeriesCharacter.swift:117` and `Core/Schedule/MangaUpdatesClient.swift:27`
  (duplicated constant); no `User-Agent` in `OpenLibraryCovers.swift:68-69`,
  `WebtoonsFeedClient.swift:121`, `NaverFeedClient.swift:58`, `GigaViewerFeedClient.swift:138`.
- **Why it matters** — CLAUDE.md: expose a duplicated value at its source. And an
  identifiable UA is the cheapest thing the app can do for a publisher reading its logs.
- **Fix** — `enum AppUserAgent { static let value = … }` in `Core/Networking/`, used by the
  session in finding 4's factory (`httpAdditionalHeaders`) so every third-party request
  carries it without per-client code.
- **Effort** — a line each. **Confidence** — certain on the duplication; Open Library's
  requirement is "worth checking" against their current docs. **Lens** — bad practice (9).

### 15. Naver dates: an out-of-range month or day rolls over instead of failing

- **Where** — `Core/Schedule/NaverFeedClient.swift:161-167`: `guard parts.count == 3,
  parts[0] < 100` then `calendar.date(from:)`, which normalises month 13 to January of the
  next year rather than returning nil.
- **Why it matters** — a malformed `serviceDateDescription` becomes a plausible wrong date and
  feeds the cadence. Never observed (60 articles, all `YY.MM.DD`); a one-line guard.
- **Fix** — `guard (1...12).contains(parts[1]), (1...31).contains(parts[2])`.
- **Effort** — a line. **Confidence** — worth checking. **Lens** — bugs (1).

### 16. The union cast has no ceiling

- **Where** — `Core/Characters/CharacterService.swift:126-131` appends every unmatched
  Shikimori character after AniList's 20; `CharacterRow.swift` has no `prefix` (grep).
- **Why it matters** — up to 40 portrait fetches for one row; Solo Leveling's Shikimori cast is
  95 rows with 20 kept, so 40 is reachable.
- **Fix** — a decision for Abdi: cap the merged list (e.g. 30, a guess) or keep it unbounded
  because the union was the ask.
- **Effort** — a line. **Confidence** — certain on the count; the choice is product.
  **Lens** — speed (7).

### 17. `getSnapshot` fetches covers for the widget gallery

- **Where** — `MangaBakaWidgets/DueThisWeekWidget.swift:7-10`, `PickBackUpWidget.swift:7-10`
  call the same `makeEntry` as the timeline.
- **Why it matters** — WidgetKit asks for a snapshot in the gallery and expects it fast; four
  network fetches is not that. Folded into 8's fix (`context.isPreview` → no covers).
- **Effort** — a line. **Confidence** — certain. **Lens** — better way (4).

### 18. Google's `intitle:"…"` still breaks on a title containing a quote

- **Where** — `Core/Volumes/GoogleBooksClient.swift:86`. Prior finding T11 fixed the comment
  (`:87-91`) and left the interpolation.
- **Fix** — strip `"` from `term` before interpolating. **Effort** — a line.
  **Confidence** — certain. **Lens** — bugs (1). Listed for completeness, not re-argued.

### 19. Shotgun surgery across the six file caches

- **Where** — `AppleBooksClient.swift:131-164`, `GoogleBooksClient.swift:108-133`,
  `OpenLibraryCovers.swift:85-115`, `WebtoonsFeedClient.swift:189-220`,
  `NaverFeedClient.swift:171-201`, `GigaViewerFeedClient.swift:170-200`,
  `MangaUpdatesClient.swift:222-246`: seven copies of `Cached { storedAt; payload }`,
  `file(_:)`, `readCache`, `readCacheIgnoringAge`, `writeCache`.
- **Why it matters** — F16 (expose `storedAt`) had to be applied file by file and reached
  only Apple and Google; the feed clients' `readCache` still drop it. The next cache rule —
  a StaleBar, a purge on sign-out, a size cap — is seven edits.
- **Fix** — `struct VersionedFileCache<Payload: Codable>` in `Core/Persistence/` with
  `read(key:) -> (Payload, storedAt)?`, `readIgnoringAge`, `write`; each client keeps its
  key and its life. Not urgent; do it the next time one of the seven changes.
- **Effort** — a file plus seven small edits. **Confidence** — certain. **Lens** — bad
  practice (9).

## The nine lenses, answered directly

- **Per-party rate limiting and outage memory** — every client spaces through `RequestSpacing`
  (claim-before-wait, `RequestSpacing.swift:7-11`), honours 429 by sleeping the next caller,
  and only AniList has an outage memory (15 min, labelled a guess,
  `CharacterService.swift:79-84`; 403/5xx only, `:235-237`). Gaps: 6 (uncapped
  `Retry-After`), and Shikimori/MangaUpdates/Apple have no outage memory — a 5xx from them is
  retried on the next page open, which is fine at these volumes.
- **Fan-out when a series page opens** — `loadCore` is 4 MangaBaka calls (extras is six legs,
  so 9 requests); `loadOnward` (`SeriesDetailView.swift:469-484`) fans to AniList 1,
  Shikimori 1, MangaUpdates 1–2 (cadence + categories on one 3 s actor), Apple 1–2, Google 0–1,
  Open Library 0–N (finding 11), Webtoons 1–3, Naver 0–1, GigaViewer 0–1. Bounded by each
  actor's spacing, not by any concurrency limit; the only unbounded count is Open Library's.
  Worst case on a first open: ~20 requests to eight hosts.
- **One source degrading another** — none found. The cast union (`CharacterService.swift:121-124`)
  and the feed group (`ReleaseFeedService.swift:60-67`) are concurrent and independent; a
  Webtoons 429 returns immediately without touching Naver/GigaViewer
  (`WebtoonsFeedClient.swift:89-93`). Apple→Google→Open Library is sequential by design
  (gap-fill). The one coupling is cadence and categories sharing MangaUpdates' 3 s actor,
  which is correct (same host).
- **`If-Modified-Since`** — implemented for MangaBaka feeds (`APIClient.swift:446-540`).
  Impossible for Webtoons (no validators, `cache-control: no-cache`, measured); not attempted
  for GigaViewer RSS or Naver JSON (unmeasured — one HEAD each would settle it). The file
  caches make it moot at their lives.
- **Caching TTLs** — Apple/Google/Webtoons/Naver/MangaUpdates-series 7 d, GigaViewer 24 h,
  Open Library 30 d, cadence in SQLite, cast none (finding 5), widget snapshot no expiry
  (finding 1). Every key is versioned and every bump names its reason.
- **The name match** — deliberate, tolerates duplicates; finding 10 is the one rule that can
  produce a wrong *merge*, and a merge is a drop.
- **Timezone and locale in feed dates** — sound. Webtoons and GigaViewer parse RFC 822 in
  `en_US_POSIX`/GMT with a verified French fallback (`WebtoonsFeed.swift:205-229`); Naver
  pins Asia/Seoul noon with the guess labelled (`NaverFeedClient.swift:147-152`); MangaUpdates
  reads UTC midnight (`MangaUpdatesClient.swift:86-93`); Siri and the widget format weekdays
  through the device calendar (`AppIntents.swift:198-206`, `WidgetSnapshot.swift:202-204`).
  Finding 15 is the only hole.
- **Widget timeline** — hourly, one entry, labelled a guess (`SeriesWidgetEntry.swift:20-30`);
  cost is 4 cover fetches per widget per reload plus a JSON read; stale by construction
  (finding 1); crash surface is the cover decode (finding 8). A decode failure of the
  snapshot is a placeholder, not a crash (`WidgetSnapshotData.swift:38-46`).
- **App Intents / Siri** — `LibrarySeriesEntity` exposes id, title and
  "Reading · chapter 53 of 120" (`LibrarySeriesEntity.swift:13-26`), enumerable by any
  Shortcut through `entities(matching:)` and `suggestedEntities` (reading state, first 10).
  `DueThisWeekIntent` returns a sentence naming series and days. Both are the reader's own
  data on their own device, no more than Spotlight already indexes; a Shortcut can forward
  the text anywhere, which is how Shortcuts works. The one thing a reader would not expect:
  asking Siri sends their series ids to Webtoons/Naver/GigaViewer (finding 3). Nothing in
  the intents reaches the token, the Keychain, or the account id.

## What the slice does well

- **Refused vs answered-nothing is now the rule, not the exception.** `CharacterCast.failed`
  (`CharacterService.swift:62-69`) is true only when every asked source failed;
  `FeedAnswer` has three shapes with each one's meaning written down
  (`ReleaseFeedProvider.swift:5-19`); Apple's nil-vs-`[]` contract (`AppleBooksClient.swift:34-35`).
- **Payload provenance is dated and specific**: `AniListClient.swift:5-14` (the 403 outage
  and its re-verification), `:241-251` (profile shape, ids 138789/40882), `SeriesCharacter.swift:65-67`
  (98 rows, 95 with a character), `ShikimoriDescriptionParser.swift:14-20` (nine ids, and
  which tags were *not* seen), `NaverFeedClient.swift:111-113` (`no` = 654 vs episode 235),
  `ReleaseFeedService.swift:143-162` (Tower of God's 653), `GoogleBooksVolume.swift:110-119`
  (bytes per image parameter), `OpenLibraryCovers.swift:7-12`.
- **Guesses are labelled as guesses**, nearly everywhere: `CharacterService.swift:83`,
  `AppleBooksClient.swift:10-11`, `GoogleBooksClient.swift:18-21`, `OpenLibraryCovers.swift:18-30`,
  `WebtoonsFeedClient.swift:11-13`, `NaverFeedClient.swift:12-14,149`, `GigaViewerFeedClient.swift:19`,
  `ReleaseSummary.swift:35-40`, `TranslationGap.swift:36-44`, `MangaUpdatesCategories.swift:53-70`,
  `WidgetSnapshot.swift:155-160`, `SeriesWidgetEntry.swift:20-24`, `AppIntents.swift:31-40`,
  `ReleaseSource.swift:46-47`.
- **Cache keys move with the rules** and say why: `v5-` (`AppleBooksClient.swift:42-45`),
  `v2-` Google (`:52-56`), `v4-` Webtoons (`:56-61`, naming `5bb36b8`), `v2-naver-`
  (`NaverFeedClient.swift:37-43`). F18 was closed properly.
- **The two id spaces cannot be crossed**: `CharacterProfileRequest`
  (`CharacterProfile.swift:315-344`) is the only door, and both parsers document the hazard
  at the request site (`AniListClient.swift:362-366`, `SeriesCharacter.swift:243-248`).
- **Cancellation is honoured after every spaced wait** (`AppleBooksClient.swift:85-93`,
  `GoogleBooksClient.swift:76-81`, `OpenLibraryCovers.swift:56-62`, `WebtoonsFeedClient.swift:114-119,170-175`,
  `NaverFeedClient.swift:51-55`, `GigaViewerFeedClient.swift:131-135`) and typed as
  `.cancelled` where the client throws (`AniListClient.swift:197-210`, `SeriesCharacter.swift:185-195`,
  `MangaUpdatesClient.swift:250-260`). F15 closed at all six sites.
- **The feeds never download what must not be rendered**: GigaViewer drops `<description>`
  and `<enclosure>` (`GigaViewerFeedClient.swift:205-210`, `:272-273`), Webtoons forwards only
  `title_no` (`WebtoonsFeed.swift:106-111`), and the per-episode JSON was tried and rejected
  with the reason recorded (`:6-11`).
- **Google's branding terms are treated as a constraint, not a courtesy**
  (`ShelfVolume.swift:16-19`, `:64-68`); Apple wins every collision by a stated rule (`:32-36`).
- **The widget's data shape is deliberately tiny and mirrored** (`WidgetSnapshotData.swift:3-15`)
  with a round-trip test holding the two copies together; `Completion`'s `@unchecked Sendable`
  says exactly what promise it is carrying (`SeriesWidgetEntry.swift:51-57`).
- **Every hard-coded URL is unwrapped through a named `preconditionFailure` helper** rather
  than `!`; no `try!`, `as!`, `.first!` or `fatalError` in the slice (grep, 2026-09-14).
- **`TranslationGate.swift:5-26`** records a crash, the wrong gate, and the cost of the right
  one, in twenty lines.

## Status of the prior findings against HEAD

| Prior | Status at `99a1124` | Evidence |
|---|---|---|
| T1 Kodansha bracket numbering | fixed | `AppleBooksVolume.swift:261` |
| T2 empty cast = outage | fixed | `CharacterService.swift:235-237`, `AniListClient.swift:161-166`, test `CharacterSourceTests.swift:239` |
| T3 Google matcher / language | fixed | `GoogleBooksVolume.swift:88-95` |
| T4 untagged novel fills comic gap | fixed | `AppleBooksVolume.swift:182-190` |
| T5 `shikimori.one` | fixed | `SeriesCharacter.swift:131`, `ShikimoriDescriptionParser.swift:50-51` |
| T6 unlisted/nested BBCode | fixed; nested same-tag spoiler still splits early (documented) | `ShikimoriDescriptionParser.swift:151-159` |
| T7 AniList dialect | fixed | `CharacterProfile.swift:182-194` |
| T8 "(Graphic Novel)" | fixed | `AppleBooksVolume.swift:206` |
| T9 `releaseDate` sinks the envelope | fixed | `AppleBooksVolume.swift:28`, `AppleBooksClient.swift:124-128` |
| T11 Google 40/200 comment, `"` in title | comment fixed; quote still open (finding 18) | `GoogleBooksClient.swift:86-92` |
| T14 birthday format | fixed | `AniListClient.swift:574-591` |
| F15 swallowed sleep cancellation ×6 | fixed | listed above |
| F16 expose `storedAt` | fixed for Apple/Google; not for the four feed/MU caches (finding 19) | `AppleBooksClient.swift:151`, `WebtoonsFeedClient.swift:200-205` |
| F17 Apple 403 backoff | fixed | `AppleBooksClient.swift:115-123` |
| F18 Webtoons `v4-`, Naver `v2-naver-` | fixed | `WebtoonsFeedClient.swift:62`, `NaverFeedClient.swift:44` |
| F5/22/23 timeout, offline codes, empty cast | 22/23 fixed; timeout fixed for MangaBaka only (finding 4) | `AniListClient.swift:227-231`, `APIClient.swift:34-36` |

## What I could not determine, and what would settle each

- **Finding 2 on a device**: whether the sign-out path is the only way to lose the token
  (a revoked token also makes the walk fail and would leave the widget standing). One run:
  sign out, reload the widget from the Home Screen.
- **Finding 3's budget**: Apple does not publish the in-process `perform` limit. Measure:
  clear `Caches/webtoons`, ask Siri with a library of ≥8 placeholder-linked Webtoons series,
  time to the error.
- **Finding 8's ceiling**: the widget extension's memory limit. Instruments on the widget
  target with a snapshot whose four items carry only `raw`.
- **Finding 10's premise**: whether Shikimori's `roles` romaji is given-name-first for Korean
  names as it is for Luffy. `GET https://shikimori.io/api/mangas/<Solo Leveling>/roles`, look
  for "Sung Jin-Ah" or "Jinah Sung".
- **Finding 9 from a phone**: the HEAD was sent from a Mac with a Safari UA; whether Webtoons
  answers HEAD the same way to CFNetwork's UA is one HEAD from the simulator.
- **Whether GigaViewer's `/rss` or Naver's `/api/article/list` send `ETag`/`Last-Modified`** —
  one HEAD each; decides whether the daily magazine fetch can be a 304.
- **Naver's `/api/article/list` under the "no private APIs" rule.** It is the JSON the site's
  own page calls, undocumented, and the survey's rule set admitted that shape explicitly
  (`docs/release-sources-2026-09-13-survey.md`, "JSON the publisher's own web page fetches
  with no token"). The brief's standing constraint says "no private APIs". Those two rules
  disagree on this one endpoint; it is a policy call, not a code finding, and it should be
  written down either way before an App Store submission.
- **How many library series would trip finding 11** — one query over cached `/works` rows:
  count of numbered volumes with an ISBN and no cover, per series.
