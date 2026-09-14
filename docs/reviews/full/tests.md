# Full review — slice 9: the tests and the tooling

2026-09-14. Read-only: nothing built, run, edited or fetched. Charter pattern 2 (tests that
agree with the bug) is the target; the nine lenses applied on top.

## Denominator

- **Helpers read in full (7):** `SourceTree`, `FixtureLoading`, `URLProtocolStub`,
  `SourceTestGuardTests`, `XcconfigAssertions`, `SeriesFactory` (head), `PriorityRecordingRepository` (not opened — grep only).
- **Test files read in full (12):** `ScheduleServiceTests`, `ExclusionInvalidationTests`,
  `FlowAffordanceTests`, `FlowAffordanceUITests`, `AccessibilityAuditTests`, `WidgetSnapshotTests` (1–55),
  `ContentPreferencesTests` (145–234), `LibrarySnapshotTests` (63–136), `LibraryModelPagingTests` (85–105),
  `SearchTokenTests` (100–150), `NotificationPolicyTests` (11–60), `GigaViewerFeedTests` (50–70).
- **All 160 unit files at grep level** (fixture loads, `try?`, sleeps, `Task {`, `.serialized`,
  `@MainActor`, `UserDefaults.standard`, `Date()`), and **every source-reading file (43) at
  assertion level** — every `SourceTree.read` and every `contains(` pinned, test names included.
  Bodies of the other ~105 files were not read.
- **Production read where a claim needed it:** `ReleaseSchedule.swift` (full), `LibrarySnapshot.swift`
  (full), `SeriesRepository+Cache.swift:40-135`, `AppIntents.swift` + `IntentBridge.swift` (full), the
  seven `MangaBakaWidgets/*.swift`, `NotificationPolicy.swift`/`ReleaseReminders.swift` (signatures),
  `MangaUpdatesID.swift:24-36`, `AppServices.swift:110-125`.
- **Tooling in full:** `.githooks/pre-push`, `ci_scripts/*`, `project.yml`, `Scripts/*.py|sh`,
  `.claude/skills/deep-review/{SKILL,charter,slices}.md`, both performance test heads.

Already established and not repeated: `docs/reviews/tests.md` (2026-09-13, 19 findings — F2 and
F11 are fixed, F19's first row is fixed at `DetailFidelityTests.swift:374`, F1 is half-fixed by
`ScheduleServiceTests.swift:125-133`) and `docs/reviews/search/tests.md` (13 findings — #6 fixed at
`LensTests.swift:128-137`; #3 still open, `RateLimitTests.swift:155,266,283` still `try?`).

Counts: 1,740 `@Test` attributes, 3,443 `#expect`, 57 `Issue.record`, 60 `.serialized` suites,
59 `@MainActor` suites, 66 `AppDatabase.inMemory()`, 43 files reading the source tree.

---

## Ranked top ten (value against effort)

1. **The widget's JSON contract has no test that can fail** — `WidgetSnapshotTests.swift:16-42`
   round-trips `WidgetSnapshot` with itself; the extension decodes a *separate* type that no test
   target compiles (T2). A few lines.
2. **`.detail` and `.images` cache invalidation are untested**, and `apply` swallows the detail
   discard with `try?` — the exact gap-74 shape the same file fixed for feeds (T3). Two tests.
3. **`LibrarySnapshot.invalidate()` mid-walk caches the stale walk anyway**, and the only test
   invalidates after completion (T5). One guard line in source, one gated test.
4. **The pre-push hook picks the simulator by name** — with two "iPhone 17 Pro" devices booted it is
   ambiguous, which is the SIGTERM flake; it also has no timeout, so a hung poll hangs the push (T14).
   A shell function.
5. **`FlowAffordanceUITests.testSeedPickerDoesNotReturnYouToYourLastSearch` skips every run** —
   it looks for a `textField` the file itself says became a `searchField` (T19). One token.
6. **`check-api-contract.py` is run by nothing** — the one script built for charter #1 has no
   caller (T15). A hook step or a schedule.
7. **Real sleeps with sub-debounce keystroke gaps** (`RequestBudgetTests:138`, `TagSearchTests:144,163`)
   turn a 220 ms stall into a failure; a `Clock` on the four debouncing models removes all ~13.5 s of
   sleep (T13). A function per model.
8. **`ReleaseScheduleService` swallows every cache read and write** and no test drives a throwing
   database; an unparseable MangaUpdates id is "pending" forever (T6, T7). A file of tests, a few
   source lines.
9. **`AppServices` wiring of preference → repository is asserted nowhere** — each half is tested,
   the join is not; the n−1 pattern in the place it has already bitten (T4). One test.
10. **The performance target decodes with a decoder the app never uses** — the F2 bug, reproduced in
    the other target (T18). One line.

---

## 1. Fixture provenance

`docs/reviews/tests.md` covered the release-feed and catalogue fixtures; `docs/reviews/search/tests.md`
covered the search-adjacent ones. This is the rest, plus the files added since (all 2026-09-13).

| Fixture | Recorded? | Endpoint + date | Where the provenance is written |
|---|---|---|---|
| `control.json` | **No — hand-built by design** | "known by construction" | `SeriesDecodingTests.swift:5-7`. Correct: it is the control, not a claim about the wire |
| `rising.json` | Yes | `GET /v2/series/discover/rising?limit=3`, 2026-09-08 | `SeriesDecodingTests.swift:44`; `check-api-contract.py:21` compares live against it |
| `mix.json` | Yes | `GET /v1/series/mix`, 2026-09-09 | `APIShapeContractTests.swift:47-51` |
| `library.json` | Yes, **then hand-extended** | `/v1/my/library`, 2026-09-09; two entries added 2026-09-13 "redacted the same way … never live-recaptured" | `LibraryDecodingTests.swift:5-6, 18-23`. Honest, and exactly the charter-2 risk: the two added rows are the model's idea of a completed/rated entry |
| `search-solo-leveling.json` | Yes | `/v2/series/search?q=solo%20leveling&limit=1`, 2026-09-13 20:27 UTC | `RequestBudgetTests.swift:122-126` |
| `tags-page1.json` | Yes, sliced | `/v1/tags?limit=500`, 2026-09-13, 24-row slice of 500 | `CatalogueTests.swift:551-553` |
| `tags-search-2026-09-13.json` | Yes | `/v1/tags?q=isekai&limit=5`, 2026-09-13 22:33 UTC | `CatalogueTests.swift:129-132` |
| `genres-2026-09-13.json` | Yes | `/v1/genres`, 2026-09-13 22:33 UTC | `CatalogueTests.swift:17-21` |
| `publishers-search-2026-09-13.json` | Yes | `/v1/publishers/search?q=Kodansha&limit=5`, 2026-09-13 22:33 UTC | `CatalogueTests.swift:202-204` |
| `mangaupdates-berserk.json` | Yes, redacted | MangaUpdates `GET /v1/series/51239621230`, 2026-09-13 | `MangaUpdatesDecodingTests.swift:148-149` |
| `anilist-character-media.json` | Yes | AniList character 40882, 2026-09-13 | `CharacterAppearancesTests.swift:9-10` |
| `knight-only-lives-today.rss` | Yes, verbatim | Webtoons feed, 2026-09-12 | `WebtoonsFeedTests.swift:7-11` |
| `estate-developer-fr.rss` | Yes | Webtoons `/fr/` feed | `WebtoonsFeedTests.swift:4` (dated via `docs/reviews/reader.md`, 2026-09-13; the test file itself carries no date or URL) |
| `tonarinoyj.rss` | Yes | `tonarinoyj.jp/rss`, 2026-09-13 | `GigaViewerFeedTests.swift:297` |

Hand-built payloads inline in tests (charter 2 by construction): 15 files carry ten or more
`Data("""…""")` literals — `SeriesExtrasTests` (18), `RecommendationQualityTests` (18), `APIClientTests`
(18), `LibraryTests` (17), `WireNullabilityTests` (16), `SearchAndMixTests` (16), `LibraryWriteTests` (14),
`CatalogueTests` (14), `LibraryDecodingTests` (12), `LibraryModelTests` (10), `CharacterSourceTests` (10).
Not each is wrong — most exercise one field's nullability — but none of `SeriesExtras`,
`PersonalRecommendation`/`RecommendationStatus` (`RecommendationQualityTests.swift:254-452`) or
`LibraryChange` writes has a recorded counterpart in `Fixtures/`. The recommendation status shape is the
one worth a capture: it is the swipe stack's gate and it has never been decoded from a response.

- **What** — `PersonalRecommendation`/`RecommendationStatus` are decoded only from hand-built JSON.
- **Where** — `RecommendationQualityTests.swift:254, 274-452`; no `Fixtures/*recommend*` file.
- **Why it matters** — charter 2; this endpoint is authenticated, so the sweep (`Scripts/api-shape-sweep.py:24-33`)
  does not cover it either. A shape change here empties the stack silently, the way `library()` once did.
- **Fix** — one captured `/v1/my/recommendations?limit=2` (redacted like `library.json`), one decode test.
- **Effort** — a fixture. **Confidence** — certain that it is unrecorded. **Lens** — 1, 9.

Also: the sweep's `MODELLED` list (`api-shape-sweep.py:71-78`) is a hand-typed copy of `Series`'s
fields — the duplicated-constant pattern. `APIShapeContractTests.swift:95-121` derives the endpoint list
from source but not the field list. Fix: emit `Series.CodingKeys` from a test into a JSON the script reads.
Effort: a function. Confidence: certain. Lens: 9.

---

## 2. Source-text assertions — the full inventory, and what a stub does to each

43 files read the checkout via `SourceTree`; ~125 `SourceTree.read` calls; every one gated by
`.enabled(if: SourceTree.isAvailable)` (`SourceTestGuardTests` enforces it; no ungated read found).
`docs/reviews/tests.md` F19 listed the ones convertible to value tests; `search/tests.md` #13 listed the
Search ones. The rest fall into three kinds:

**(a) Absence checks — keep.** A stub cannot satisfy "this is gone". `AccessibilityTests.swift:244, 270,
293, 329, 367, 370, 428, 469, 523, 536-539`; `CatalogueTests.swift:516-517`; `TokenStatusTests.swift:88,
119, 126`; `FlowAffordanceTests.swift:29`; `ReleaseFeedCachedFeedsWiringTests.swift:35, 49`;
`CharacterProfileTests.swift:265`; `TranslationOfferTests.swift:25, 51-52`; `PublisherPageTests.swift:181`;
`ChromeReachabilityTests.swift:50`; `DetailFidelityTests.swift:355, 396, 462, 537`.

**(b) Whole-tree scans — keep.** They answer "anywhere at all", which no value test can:
`DesignTokenTests.swift:44-59` (every token used), `PrivacyManifestTests.swift:89-93` (every listed host
referenced), `AccessibilityTests.swift:424-428` (no imperative haptic), `MotionTests.swift:144-155` (every
push marks a zoom source), `StateFamilyTests.swift:152-153` (only the stale bar uses amber),
`APIShapeContractTests.swift:99-121` (sweep covers every endpoint).

**(c) Call-site pins — a stub of the same name passes every one.** These are the bulk. Each line below
would be satisfied by a function of that name whose body is empty:

| Suite | Lines | Pinned text (examples) | A stub named the same… |
|---|---|---|---|
| `SessionTests` | 31-33, 46-47, 57, 75-77, 88-90, 107-110, 120-121 | `await session.library.apply(change, to: seriesId)`, `toasts.show("Saved")`, `guard walk.failure == nil else { return }` | passes; a `func apply` that does nothing passes "patches locally" |
| `SpotlightIndexTests` | 106-136 | `"selection = .library\n        shelfPath = [series]"` (whitespace-exact) | passes; a re-indent fails it |
| `DueThisWeekTests` (Intent wiring) | 240-243 | `"bridge.pendingSeriesID = nil\n                await openSeries(id: id)"` | passes; an `openSeries` that opens nothing passes |
| `PublisherPageTests` | 117-134, 178-180 | `case .publisher: query.publisher = name`, `.navigationDestination(item: $openPublisher)` | passes |
| `TokenStatusTests` | 87, 94-96, 102-104, 110-111, 117-118, 125 | `status = .notStored`, `recheckInterval: TimeInterval = 60 * 60`, `onReplace: { status = .idle }` | passes; the `60 * 60` is a literal copied from source (charter 4) |
| `OnboardingTests` | 17-31, 49-55, 108-120 | `Button("Skip", action: onFinish)`, five copy strings, `isLoadingCovers: isLoadingCovers` | passes; copy edits fail it |
| `ChromeReachabilityTests` | 18-26, 39-42 | `onOpenSettings: { showsSettings = true }`, `SettingsView(` | passes |
| `AccessibilityTests` | 53-54, 62, 70, 94-113, 126, 149-150, 215, 230, 254, 267-268, 291-299, 308, 332, 340-345, 364-365, 382-383, 416, 436-437, 456, 465-468, 504, 521-522 | `accessibilityAction(named: "Save")`, `frame(minHeight: 63)`, `allowsHitTesting(false)`, `EmptyState(` | passes; `frame(minHeight: 63)` is a literal, not the token (`Metrics.headerPill` is used two tests later at 126 — inconsistent) |
| `AppleBooksTests` | 468-472, 477-479, 484-490 | `answer = await appleBooks.japaneseVolumes(for: shown)` | passes (F19 row 3, still open) |
| `DetailFidelityTests` | 192-238, 353, 394, 449-471, 535 | `onOpenTag:`, `UIPasteboard.general.string = series.displayTitle`, `"Copied"` | passes |
| `TranslationOfferTests` | 29, 39, 49-50, 62 | `TranslationGate.allows(`, `prepareTranslation` | passes |
| `CharacterProfileTests` | 240-245, 254-255, 266 | first statement of `load()` is `state = .loading` | passes |
| `ReleaseSectionWiringTests` | 13-22 | `loadReleases()` | passes |
| `InlineSearchTests` | 65, 74-75 | `InlineSearchField(`, `shelf.entries.count >= 12` | passes; the 12 is a literal copied from `ShelfDetailView` — a screen nothing presents (charter 7; `AccessibilityAuditTests.swift:244-261` says so) |
| `LibraryTransferTests` | 316 | `LibraryTransferSection()` | passes |
| `AppleVolumesRowTests` | 52-53 | `.opacity(volume.link == nil ? 0.6 : 1)` | passes; `0.6` copied |
| `CoverGalleryTests` | 176 | `clampedHeight` | passes |
| `BlockedTagsTests` | 222-238 | `"Blocked tags"`, `blockedTags.toggle`, `"Unblock"` | passes |
| `CoverLayoutTests`, `DetailHeroFormTests`, `ReadRowTests`, `SeriesWebLinkTests`, `SafeLinkTests`, `TasteRankerTests`, `LibraryControlTests`, `LibraryTests`, `DynamicType*Tests` | (see inventory) | frame/modifier text | passes |

The honest reading: roughly 90 of the ~125 reads are kind (c). They are not worthless — they
document intent at a line — but they are counted among the 1,739 and they prove wiring only until a
rename. Two facts make the count itself misleading (charter 5):

- **They test the checkout, not the binary.** `SourceTree.root` is derived from `#filePath`
  (`SourceTree.swift:15-18`), so with a dirty tree they assert on uncommitted text while the app under
  test was built from something else.
- **They do not run on Xcode Cloud** (`SourceTree.swift:5-13`). The cloud's green is ~1,600 tests,
  not 1,739, and nothing reports the difference.

- **Fix** — three moves, in order of return. (1) The four whitespace-exact multi-line pins
  (`SpotlightIndexTests:136`, `DueThisWeekTests:242`, `SessionTests:75-77`, `LensTests:326`) become
  `contains` on two separate lines each, or die at the first re-indent. (2) The wiring suites
  (`SessionTests`, `SpotlightIndexTests` wiring, `ChromeReachabilityTests`, Intent wiring,
  `ReleaseFeedCachedFeedsWiringTests`, `ReleaseSectionWiringTests`) each get one `FlowAffordanceUITests`
  case that presses the thing — the file's own header (`FlowAffordanceUITests.swift:3-13`) is the
  argument. (3) Copied literals (`60 * 60`, `0.6`, `63`, `12`) move to a `static let` and are asserted
  as values, the way `DetailFidelityTests.swift:374` now does for `pageCap`.
- **Effort** — (1) lines; (2) a file; (3) a line each. **Confidence** — certain. **Lens** — 9, 4.

---

## 3. Tests that cannot fail, or fail for the wrong reason

### T-A. `tokenChangeReasksAfterAnAsk` yields once and asserts zero
- **What** — `model.filtersDidChange()` then a single `await Task.yield()` then `#expect(searchCount == 0)`.
  `filtersDidChange` is a synchronous main-actor function that spawns a `Task` (`SearchModel.swift:212`);
  one yield does not guarantee that task ran and reached the repository, so a regression that *did* fire
  a search would still read 0 here — the same shape as search review #6, which `LensTests:128-137` fixed.
- **Where** — `SearchTokenTests.swift:106-110`.
- **Fix** — the same fix: sleep past the debounce (`600 ms`) or poll with a deadline as the second half
  of the same test already does (`:117-118`).
- **Effort** — a line. **Confidence** — likely. **Lens** — 9.

### T-B. `returningResumesFollowing`'s comment describes a `build()` that does not exist
- **What** — "`measure()` awaits `service.build()` to completion" (`ScheduleServiceTests.swift:89-91`);
  `build()` returns as soon as the task is scheduled (`ReleaseSchedule.swift:265-281`). The assertion at
  `:93` is right for a different reason (`progress.isRunning = true` is set synchronously at `:275`).
  `:99` (`isMeasuring` after `load()`) relies on the *real* 3 s MangaUpdates spacing — the service is
  built with `SystemClock` (`:122-124`) — to keep the second of two requests in flight. On an idle
  machine it is safe; the test's own comment at `ReleaseSchedule.swift:273-274` records that the busy
  hook machine is the one that flips timing.
- **Fix** — inject `TestClock()` into `MangaUpdatesClient` here (as `MangaUpdatesSpacingTests.swift:42`
  does) and gate the second request; correct the comment.
- **Effort** — lines. **Confidence** — certain about the comment; likely about the flake. **Lens** — 9.

### T-C. `secondRetryDuringOneInFlightDoesNothing` is a real-time race by design
- **Where** — `StateFamilyTests.swift:83-92` (200 ms hold, 50 ms sleep). The comment records "a failure
  one run in three" under the previous shape. The current shape still passes *more* easily under load
  (the first retry is still running), so it cannot false-fail, but a `RetryGate` that let the second tap
  through only after 150 ms would pass. Acceptable; noting the direction.
- **Confidence** — certain. **Lens** — 9.

### T-D. `descriptionDropped` keeps its no-op assertion
- **Where** — `GigaViewerFeedTests.swift:66` `#expect(!items.isEmpty)` after the F11 fix added real
  assertions at `:64-65`. Harmless; redundant. **Effort** — delete the line.

### T-E. `try?` where the comment names an assertion — still open from the search review
- **Where** — `RateLimitTests.swift:155, 266, 283` (`try? await gate.reserveSlot`) — search review #3.
  Not fixed; `STATUS.md` does not list the test findings, so nothing says whether it was declined.
- **Fix** — `await #expect(throws: Never.self) { … }`. **Effort** — three lines. **Confidence** — certain.

No `#expect(true)` or `Bool(true)` equivalents were found. The other `try?` uses in tests are either
stub plumbing (`(try? await libraryPage(…)) ?? []` at `LibrarySnapshotTests:117` etc.), cleanup
(`AppDatabaseResetTests:27-43`), or `try? await Task.sleep` inside tests whose assertions follow — fine.

---

## 4. Coverage of the dangerous surfaces

| Surface | Verdict | Evidence, and the gap |
|---|---|---|
| **`ReleaseSchedule` actor I/O** | **partial** | Covered: failed walk → `libraryFailure` (`ScheduleServiceTests:10-18`), undecodable payload → pending (`:23-53`), resume-following (`:58-108`), `cadence(for:)` season and `.failed` (`:123-190`), offline stops the loop (`:198-240`); scope rules (`CharacterTests:168-222`). **None:** a throwing `readCache` (`ReleaseSchedule.swift:197, 305, 400` — `try?` turns a DB error into "everything pending" and a full re-measure, 55 × 3 s); a throwing `write` (`:346, 358, 407, 412` — a measured cadence that never persists); `.rateLimited` stop (`:362`); `refresh: true` (`:312`); re-entrant `build()` (`:266`); `cancelBuild` mid-request; the unparseable-id loop (T6 below). |
| **The library walk** | **covered, two holes** | `LibrarySnapshotTests` (share one walk, failed walk not cached, disk cache, stale, short cache, patch) and `LibraryModelPagingTests` (partial failure, page cap, >1,000, reload). **Holes:** `observePages`/`onPage` (`LibrarySnapshot.swift:70-74, 88, 103, 127`) — zero tests mention it; negative clock age (`:146-147`); and `invalidate()` during an in-flight walk (T5). |
| **Cache invalidation on every preference change** | **feeds covered; detail/images none; wiring none** | Feeds: content (`ContentPreferencesTests:175-197`), format (`FormatPreferencesTests:168`), blocked tags (`BlockedTagsTests:146`), exclusion id both directions (`ExclusionInvalidationTests`). **None** for `.images`/`.detail` (T3) or for `AppServices.swift:110-125` connecting store → repository (T4). |
| **Notification policy** | **covered** | `NotificationPolicyTests` (11 rules incl. no cadence path, baselines, season, Naver finished flag) and `ReminderTests` (permission, once-only, 3/day, 24 h per series, forget, cancel, trigger time). One timezone hazard (T20). `LiveNotificationCentre` (`ReleaseReminders.swift:389-419`) is untestable by design and swallows `add` errors with `try?` (`:412`) — a scheduling failure is silent; out of this slice's remit to fix, noted. |
| **Offline paging** | **covered** | `OfflineCatalogueTests:182-200` (disjoint, contiguous), `SearchModelTests:398-496` fallback suite, `LibraryModelPagingTests`. The content-rating gap is search review #4 (open). |
| **Widget timeline** | **none for the extension** | No test target compiles `MangaBakaWidgets` (`project.yml:138-181`). `SeriesWidgetEntryBuilder.makeEntry`, `CoverLoader.covers` (has a `session:` parameter — testable), `WidgetRefresh.nextReload`, `WidgetSnapshotData.read` — zero tests. App-side list rules are covered (`WidgetSnapshotTests:55-127`); the JSON contract is T2. |
| **App Intents** | **partial** | `DueThisWeek.sentence` (`DueThisWeekTests:19-65`) and `feedDueWorks` (`:147-220`) covered. `OpenSeriesIntent.perform` / `IntentBridge` source-text only (`DueThisWeekTests:237-244`); `LibrarySeriesEntity` (67 lines, the Siri query) — zero tests; `DueThisWeekIntent.perform`'s `services == nil` branch (`AppIntents.swift:44-46`) — none. |

### T2. The widget contract test decodes with the encoder's own type
- **What** — `roundTrips` encodes `WidgetSnapshot` and decodes `WidgetSnapshot`. The extension decodes
  `WidgetSnapshotData` — a separate `Codable` in a target no test links — and its doc comment says the
  app-side test "round-trips the real type through the same field names" (`WidgetSnapshotData.swift:12-15`).
  No test names a field. Rename `dueThisWeek` on either side and both targets build, the test passes, and
  every widget shows "Open MangaBaka to load" (`:35-37`) forever.
- **Where** — `WidgetSnapshotTests.swift:16-42`; `WidgetSnapshotData.swift:16-27`; `project.yml:138-146`.
- **Fix** — either add `MangaBakaWidgets/WidgetSnapshotData.swift` to `MangaBakaTests`'s `sources:` in
  `project.yml` and decode the app's bytes with it, or assert the encoded JSON's key set literally
  (`["dueThisWeek","pickBackUp","writtenAt"]`, item keys `["seriesID","title","subtitle","coverURL"]`) and
  that `writtenAt` is an ISO-8601 string. The first is the real test; the second is one line.
- **Effort** — lines. **Confidence** — certain. **Lens** — 1, 9 (charter 2).

### T3. Content-rating change never proven to discard the detail or image cache
- **What** — `ContentFilterCacheTests` asserts feeds refetch; no test calls `readDetailCache`/`cachedImages`
  after `updateContentRatings`. `apply` at `SeriesRepository+Cache.swift:87` wraps `discardDetailCache()` in
  `try?` — the same "every caller spent `try?` on this and moved on" that `:110-133` fixed for feeds.
- **Where** — `ContentPreferencesTests.swift:175-197`; `SeriesRepository+Cache.swift:85-87`;
  `SeriesRepository.swift:604`.
- **Why it matters** — the doc at `:47-58` says this is the invalidation that "never" happened before; a
  regression to `.feeds` passes 1,739 tests and a reader who turns erotica off keeps seeing the tags for six
  hours.
- **Fix** — `writeDetailCache` (`:35`) a `SeriesExtras`, change ratings, `#expect(readDetailCache == nil)`;
  same for `cachedImages`; a control that a format change (`.feeds` only, `:611`) leaves detail intact.
  Make `discardDetailCache` return `Bool` like its sibling and log.
- **Effort** — two tests, two lines. **Confidence** — certain. **Lens** — 2, 9.

### T4. The join between preference stores and the repository is untested
- **Where** — `AppServices.swift:110-125` (`blocked.onChange`, `store.onChange`, `formatStore.onChange`);
  tests: `BlockedTagsTests:61`, `FormatPreferencesTests:72`, `ContentPreferencesTests:85` (store fires),
  `ContentPreferencesTests:175`, `FormatPreferencesTests:168`, `BlockedTagsTests:146` (repository discards).
- **Why it matters** — `XcconfigAssertions.swift:6-13` names "a correct rule applied n−1 times out of n" as
  this project's characteristic defect; the three `onChange` lines are exactly n copies of one rule with no
  test on any of them.
- **Fix** — one test that builds `AppServices` (or extracts the three lines into a `static func wire(…)`)
  with a recording repository, flips each store, and asserts the matching `update*` was called with the
  new value. **Effort** — a function. **Confidence** — likely (depends on `AppServices` being constructible
  in a test; not read). **Lens** — 9.

### T5. `invalidate()` during a walk leaves the stale walk cached, and no test can see it
- **What** — `invalidate()` cancels and nils `inFlight` (`LibrarySnapshot.swift:241-242`) but the walk's
  loop never checks cancellation (`:94-112`), and on completion `:119-121` writes `cached` and the disk
  from a `Task` the actor already disowned. Sequence: sign-out → `librarySnapshot.invalidate()`
  (`RootView+Session.swift:116`) while a walk is mid-page → the previous account's library lands in memory
  and on disk after the invalidation.
- **Where** — `LibrarySnapshot.swift:92-128, 232-243`; the only test, `LibrarySnapshotTests.swift:63-77`,
  invalidates after `all()` returns.
- **Fix** — source: capture `task` and `guard inFlight === task` before caching; `if Task.isCancelled { break }`
  in the loop. Test: a gated library (the `GatedRepository` shape at `SearchScreenTests:132-141`), start
  `load()`, `invalidate()`, release the gate, assert `cached == nil` and `libraryEntry` empty.
- **Effort** — a function. **Confidence** — certain by reading. **Lens** — 1 (cross-slice: persistence).

### T6. An unparseable MangaUpdates id is pending forever
- **What** — `measureOne` counts it done and writes nothing (`ReleaseSchedule.swift:335-341`); `snapshot()`
  then finds no row and counts it pending (`:221-225`); the next `build()` includes it again (`:313`).
  `MangaUpdatesID.number(from:)` returns nil for any character outside `[0-9a-z]` (`MangaUpdatesID.swift:36`).
- **Why it matters** — "Reading 54 of 55 … 1 still to do" for the life of the account; whether the API ever
  sends such an id is unknown (the sweep does not cover `source.manga_updates.id` values).
- **Fix** — treat unparseable as `.notOnMangaUpdates` at `:215` and `:309-310` (or record a settled failure
  string), and a test with `id: "not-an-id!"` expecting `undated` with that reason.
- **Effort** — lines + one test. **Confidence** — certain about the loop; worth checking whether the input
  occurs. **Lens** — 1, 3.

### T7. No test drives `ReleaseScheduleService` with a throwing database
- **Where** — `ReleaseSchedule.swift:197, 305, 346, 358, 400, 407, 412` (seven `try?`); `ScheduleServiceTests`
  uses `AppDatabase.inMemory()` throughout.
- **Fix** — an `AppDatabase` wrapper whose `writer.write` throws (GRDB: open read-only, or a `DatabaseQueue`
  on a path removed after init) — two tests: snapshot reports `pending == inScope` with a
  `libraryFailure`-style field rather than silently, and a measured cadence whose write failed is
  reported, not "done". This is also a product question: what should the screen say when the cache is
  unwritable? **Effort** — a file. **Confidence** — certain that it is untested. **Lens** — 2.

### T20. Notification policy tests format the day in GMT and decide it in the local calendar
- **Where** — `NotificationPolicyTests.swift:13-22` (`TimeZone(secondsFromGMT: 0)`, `now` fixed at
  1_757_000_000 = 2025-09-04 15:33 UTC); `NotificationPolicy.swift:95` (`Calendar.current.startOfDay`).
- **Why it matters** — on a simulator east of UTC+8:27 the local "today" is 09-05 while the fixture says
  09-04, and "dated today is confirmed; tomorrow it is not, yet" (`:61-68`) flips. Not Abdi's machine, so
  invisible; a flake for anyone else.
- **Fix** — build the fixture day with `Calendar.current` (as `:14` already does for the offset) and format
  with `.current`'s zone, or give `decide` a `calendar:` parameter and pass UTC in tests.
- **Effort** — a line. **Confidence** — worth checking (depends on `UpcomingWork.localDay`, not read). **Lens** — 9.

---

## 5. Speed and flakiness

**What dominates the ~70 s: not determinable by reading.** By construction the suite's own work is small:
`OfflineIndex.json.gz` is decoded once (`OfflineCatalogueTests.swift:27`, `static let`); `EmbeddingIndex()`
is built four times (7 MB each, `EmbeddingIndexTests`); 66 in-memory databases; no unit fixture over 250
rows (`LibraryListTests:100`); the 1,000-row libraries live only in the performance target. The whole-tree
scans (`DesignTokenTests:44`, `AccessibilityTests:424`, `MotionTests:144`, `StateFamilyTests:152`,
`PrivacyManifestTests:89`) read ~45k lines each, a few ms. The likely answer is build + install + launch,
which no test change will move. The one measurement: `xcodebuild test … -resultBundlePath /tmp/mb.xcresult`
then `xcrun xcresulttool get test-results tests --path /tmp/mb.xcresult` and sort by `duration`.

**Real sleeps — the list.** Summed wall-clock ≈ 13.5 s if serialised; most sit in `.serialized`
`@MainActor` suites, so they overlap only with other suites.

| File:line | Sleep | Risk on a loaded machine |
|---|---|---|
| `SearchModelTests.swift:39, 59, 67, 93, 313` | 600 ms ×5 | upper bound only; safe direction |
| `SearchTokenTests.swift:136, 147` | 600 ms ×2 | safe direction |
| `SearchAskedStateTests.swift:79` | 600 ms | safe direction |
| `TagSearchTests.swift:120, 147, 186, 200, 212, 232, 243` | 750 ms ×7 | safe direction |
| **`TagSearchTests.swift:144, 163`** | 100 ms between keystrokes vs 250 ms debounce | **a 150 ms stall fires the debounce early → `queries == ["sol"]` fails** |
| **`RequestBudgetTests.swift:138`** | 80 ms ×6 between keystrokes vs 300 ms debounce | **a 220 ms stall spends an extra request → count assertions fail** |
| `RequestBudgetTests.swift:141` | 700 ms | safe direction |
| `LensTests.swift:137, 252` | 600, 400 ms | safe direction (both assert "no more calls") |
| `MixModelTests.swift:266` | 600 ms | safe direction |
| `RateLimitTests.swift:271, 289, 316` | 150, 80, 50 ms | search review: shaped to pass under load |
| `StateFamilyTests.swift:90, 92` | 200, 50 ms | T-C above |
| `DiscoverTests.swift:196` | 20 ms | "give the first load a chance to register" — the one that most deserves a gate instead |
| `ScheduleServiceTests.swift:234` | 10 ms poll | fine |

- **Fix (better way)** — the repository layer already takes `clock: any Clock` (`TestClock` in 30+
  tests). Give `SearchModel` (`:146`), `TagSearch` (`:35`), `LensCounts` (`:34`), `MixModel`
  (`strandDebounce`) and `FilterPanel` (`:288`) the same, and sleep with `Task.sleep(for:clock:)`. Every
  600 ms sleep becomes `clock.advance(by: .milliseconds(301))`; the two dangerous ones become
  deterministic; the debounce lower bound (search review #7) becomes testable for free.
- **Effort** — a function per model, then a mechanical sweep of ~25 sleeps. **Confidence** — certain.
  **Lens** — 7, 9.

**Serialisation.** 60 `.serialized` suites and 59 `@MainActor` suites. Since `URLProtocolStub` is keyed per
test (`URLProtocolStub.swift:26-43`), `.serialized` is load-bearing only where a suite shares mutable
state outside the stub — `UserDefaults.standard` (`ExclusionInvalidationTests`, `BlockedTagsTests`,
`DisplayTitleTests`) and the `MangaUpdatesClient` actor. The other ~55 could drop it. Not measured; the
xcresult durations above would say whether it matters.

**Shared `UserDefaults.standard`.** `ExclusionInvalidationTests.swift:13, 32-37` and `BlockedTagsTests`
write the app's real defaults on the simulator and restore in `defer`; `:31` records it "has already
polluted a simulator once". A crash mid-test leaves `cache.libraryExclusionUserID` set for the next
real launch. The repository takes `defaults` (`SeriesRepository+Cache.swift:97-101`) — pass
`UserDefaults(suiteName: "test-\(UUID())")`. Effort: lines. Confidence: certain. Lens: 9.

**`Date()` in assertions.** `ScheduleModelTests.swift:38-39` builds due dates from `Date()` and groups by
day; a test straddling midnight can move a row between "this week" and "later". Low probability; the
fix is the fixed `now` that `WidgetSnapshotTests:12` and `NotificationPolicyTests:38` already use.

---

## 6. The hook, CI, scripts and the skill

### T14. `.githooks/pre-push` — simulator choice, and no timeout
- **What** — the simulator is chosen by *name* (`:56-60`) and passed as `name=$SIM` (`:71`). Two devices
  named "iPhone 17 Pro" (one from Xcode, one from a runtime download or a clone) make the destination
  ambiguous: xcodebuild warns, picks one, and when the other is mid-shutdown the test host is killed —
  the SIGTERM flake. There is no timeout on either `xcodebuild` (`:68-82, 90-104`); a hung poll
  (`waitUntil`-style loops in `LensTests`, `SearchScreenTests`) hangs the push indefinitely.
- **Robust to two booted same-name simulators now?** No. Nothing in the hook or the docs mentions it.
- **Fix** — pick a UDID: `xcrun simctl list devices available -j | python3 -c '…'` preferring a device with
  `"state": "Booted"`, else the newest `iPhone … Pro`; pass `-destination "platform=iOS Simulator,id=$UDID"`.
  Add `-test-timeouts-enabled YES -default-test-execution-time-allowance 120` to the test step.
- **Effort** — a shell function. **Confidence** — likely for the cause (cannot run `simctl` here); certain
  for the missing timeout. **Lens** — 9, 8.

**Redundant?** Lint runs in the hook (`:36`) and in `ci_pre_xcodebuild.sh:38-44` — cheap, fine. The token
grep is written twice (`pre-push:17-27` and `ci_pre_xcodebuild.sh:20-27`) with *different* scopes (the CI
copy lacks the all-tracked-files check that `pre-push:22-25` says was added after a real paste into
`Secrets.example.xcconfig`) — the n−1 pattern in the security check. Fix: one `Scripts/check-credentials.sh`
called from both. Effort: a file. Confidence: certain. Lens: 9.

**Misses anything that has broken a build?** The archive step (`:76-104`) now covers the SIL crash of builds
69–71. Still uncovered: (a) the widget extension is built only as an embedded dependency in Debug — a
Release-only widget failure would surface in the archive, so fine; (b) `XCTSkip` counts as pass, but the UI
target is out of the hook anyway; (c) **T15 below**.

**Speed (~10 min).** The archive is the only lever: skip it when no Swift file changed since the last
successful archive (hash `git rev-parse HEAD:MangaBaka HEAD:MangaBakaWidgets` into `/tmp/mb-prepush-archive/last`).
Docs-only pushes drop to ~4 min. Effort: a function. Confidence: likely. Lens: 7.

**Side effect.** `xcodegen generate` (`:45`) rewrites the working tree during a push; with unrelated
uncommitted `.xcodeproj` changes the sync check (`:46`) fails for the wrong reason. Acceptable, but say so
in the failure message. Effort: a line.

### T15. `Scripts/check-api-contract.py` has no caller
- **Where** — `README.md:71` is the only reference; not in the hook, not in `ci_scripts/`, no schedule.
  It checks one endpoint (`rising`) against one fixture (`:21-22`).
- **Why it matters** — charter 1 is the pattern that has cost the most, and the one tool built to notice
  it runs when someone remembers. `api-shape-sweep.py` (the better tool: eight endpoints, type
  divergence) needs `MB_TOKEN` and has no caller either.
- **Fix** — a weekly `launchd`/cron job that runs both and writes `docs/api-contract-<date>.txt`; or a
  hook step that runs the contract check with a 10 s timeout and *warns* (exit 2 is already "could not
  reach"). Extend the contract check to every fixture with a dated endpoint in §1.
- **Effort** — a function. **Confidence** — certain. **Lens** — 1, 9.

### T16. A `.pyc` is tracked
- **Where** — `git ls-files` → `Scripts/__pycache__/asc.cpython-314.pyc`. **Fix** — `git rm --cached`,
  add `__pycache__/` to `.gitignore`. **Effort** — a line. **Confidence** — certain. **Lens** — 9.

### T17. The deep-review skill points at files that no longer exist
- **Where** — `.claude/skills/deep-review/SKILL.md:32-36` ("Confirm `docs/findings-todo.md` … exist") —
  `docs/findings-todo.md` does not exist (`ls` confirms; `unknowns`, `periphery`, `ios-design-review` do).
  `:40` and the description say six Opus agents; this run is nine slices, and CLAUDE.md's routing rule says
  the cheapest model that can do the job. `slices.md:3` still says six.
- **Fix** — point step 1 at `docs/reviews/SUMMARY.md` and `FAILURES-SUMMARY.md`; make the slice count a
  parameter; say which agent tier per slice (the grep-heavy slices do not need Opus).
- **Effort** — lines. **Confidence** — certain. **Lens** — 9.

### T18. The performance target decodes with a decoder the app never uses
- **Where** — `MangaBakaPerformanceTests/JourneyPerformanceTests.swift:133-138` (`JSONDecoder.performance`
  = `convertFromSnakeCase` only); `FixtureLoading.swift:28-35` records why the unit target stopped doing this.
- **Why it matters** — the sort/filter timings are measured on entries decoded without the app's date
  strategy; charter 5, same as F2.
- **Fix** — `APIClient.makeDecoder()`. **Effort** — a line. **Confidence** — certain. **Lens** — 5, 9.

### T19. UI tests: a permanent skip, and live traffic
- **What** — `testSeedPickerDoesNotReturnYouToYourLastSearch` queries `app.textFields.firstMatch` (`:63`)
  for a field that `:24-27` and `:31` say is now a `searchField`; `:64` throws `XCTSkip("no search field")`
  every run, and a skip reads as green. This is the test for "that endless cycle" (`:55-56`).
- **Where** — `MangaBakaUITests/FlowAffordanceUITests.swift:63-65`; `:105` has the same `textFields` for the
  sheet's field (may be right — the sheet's field was not read).
- **Also** — every UI test launches the real app against the live API with no stub: `typeText("berserk")`
  (`:68`) spends a search-family request per run, the audit's five tabs spend ~10 general requests, and an
  offline machine turns every case into `XCTSkip`. Nothing counts skips.
- **Fix** — `app.searchFields.firstMatch`; a launch argument that routes `APIClient` to a bundled fixture
  server (the `URLProtocolStub` already exists; register it in the app under `-UITesting`); grep the
  result bundle for `skipped` in the (manual) audit run.
- **Effort** — a token; then a function. **Confidence** — certain for the skip (by reading; a run would
  confirm in a minute). **Lens** — 5, 6, 9.

### Scripts — smaller notes
- `api-shape-sweep.py:26-33` covers `/v1/my/library` with `x-api-key` (matches `TokenProvider.swift:41`) —
  good; it does not cover `/v1/my/recommendations`, `/v1/series/{id}` (the v1 detail fetch that
  `DetailFidelityTests:270-303` says fills tags and year) or `/v1/series/{id}/releases`. Add the three.
- `install-device.sh:44-45` builds into `/tmp/mangabaka-device-build`; `pre-push:80, 94` into `/tmp/mb-prepush*`;
  `AccessibilityAuditTests:39, 51` into `/tmp/mb-a11y-*`. Four `/tmp` roots, none cleaned; with CLAUDE.md's
  disk warning, one `Scripts/clean-tmp.sh` or a shared `MB_TMP` is worth a line each.
- `ci_pre_xcodebuild.sh:47` rewrites `project.yml`'s build number with `sed` then regenerates — the CI
  deliberately breaks the hook's "project matches yml" rule; documented at `:44-46`, fine.

---

## Done well (same evidence standard)

- **The stub is keyed per test and says why.** `URLProtocolStub.swift:26-35` records the cross-suite
  contamination ("a MangaUpdates request from the schedule suite as its first request") that forced it.
- **The decoder is the app's.** `FixtureLoading.swift:28-35` — F2 fixed, with the reason kept.
- **A test on the tests, that guards its own accessor.** `SourceTestGuardTests.swift:5-19, 76-82` names
  builds 16 and 21; the guard cannot be renamed out of existence.
- **A helper that exists because the same assertion was written twice.** `XcconfigAssertions.swift:6-13`
  names the n−1 defect in its own header and removes the copy.
- **Provenance is dated with an endpoint and a timestamp on 12 of 14 fixtures** (§1). `LibraryDecodingTests:18-23`
  says plainly which two rows were hand-added and never recaptured — the honest version of charter 2.
- **"Expected failure before the fix" written into the test**, including the case where the honest answer
  is "none": `GigaViewerFeedTests.swift:51-55`, `ScheduleServiceTests.swift:110-122, 156-161, 192-197`,
  `SearchTokenTests.swift:122-125`.
- **A proof that did not fully reproduce is recorded as such.** `LibraryModelPagingTests.swift:85-88`.
- **Gated continuations instead of sleeps for races**: `SequencedRepository` (`DiscoverTests:187-200`),
  `GatedRepository` (`SearchScreenTests:132-141`), and `LensTests:128-137` fixing search review #6 with the
  reasoning inline.
- **Slow targets kept out of the test action, with the reason and the command** (`project.yml:148-153,
  165-169, 200-209`).
- **The hook's comments carry build numbers and dates** (`pre-push:76-81`, `ci_pre_xcodebuild.sh:2-7`).
- **`Fixture.data` throws on a missing file** (`FixtureLoading.swift:6-15`) so a missing fixture cannot pass.
- **The whole-tree scans** (§2b) do something no value test can, and each says what it is for.

## Could not determine

1. **What the 70 s is spent on.** One run with `-resultBundlePath`, then `xcrun xcresulttool get
   test-results tests` sorted by duration; and the same run with `-parallel-testing-enabled NO` to see what
   `.serialized`/`@MainActor` cost.
2. **Whether two same-name simulators exist on this Mac now.** `xcrun simctl list devices | grep -c "iPhone 17 Pro"`.
3. **Whether T19's skip is real.** `xcodebuild test -scheme MangaBakaAccessibility -only-testing:MangaBakaUITests/FlowAffordanceUITests/testSeedPickerDoesNotReturnYouToYourLastSearch`
   and read whether it reports skipped.
4. **Whether T20 flips.** Set the simulator to `Asia/Tokyo` (Settings → General → Date & Time on the
   booted device) and run `NotificationPolicyTests`.
5. **Whether `AppServices` is constructible in a test** (T4) — `AppServices.swift` was not read past
   `:110-125`.
6. **Whether MangaBaka ever sends a non-base-36 `source.manga_updates.id`** (T6) — one sweep run with
   `MB_TOKEN` over the library, counting `MangaUpdatesID.number(from:) == nil`.
7. **Which of the search review's test findings (#1, #3, #7, #9, #10, #11) were declined** — `STATUS.md`
   tracks the 60 screen findings, not the 13 test ones. #6 is fixed; #3 is not; the rest were not re-checked.
