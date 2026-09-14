# Second pass — slice 5: the shell, the shared controls, and the tests that guard them

Reviewed at `fee95b0`, 2026-09-14. Read-only; no build, no test run, no edits outside this file.

**Denominator.** Read in full: every file under `MangaBaka/App/` (9), `MangaBaka/Features/Shared/` (19),
`MangaBaka/Features/Settings/` (13), `MangaBaka/DesignSystem/` (10), `.githooks/pre-push`, `ci_scripts/*`,
`project.yml`, `Configs/Info.plist`, `Configs/*.xcconfig`, `Scripts/check-credentials.sh`,
`pick-simulator.sh`, `run-ui-tests.sh`, `install-device.sh` (first 60 lines), `MangaBakaUITests/FlowAffordanceUITests.swift`.
Tests read in full (16 of 214 files): `AppShellRoundThreeTests`, `SessionTests`, `LaunchPathDeferralTests`,
`AppDatabaseResetTests`, `DatabaseCorruptionScopeTests`, `RepositoryWiringTests`, `ExclusionInvalidationTests`,
`SpotlightIndexTests`, `AppGroupParityTests`, `ToastRepeatTests`, `AppTabSymbolTests`, `TokenStoreCacheTests`,
`TokenStatusTests`, `SourceTree`, `SourceTestGuardTests` (to line 187), and the three diffs in `5e5964f`.
Production read outside the slice where a shell claim needed it: `TokenStore.swift`, `TokenProvider.swift`,
`AppDatabase.swift` (full), `LibrarySnapshot.swift` (lines 1–145, 240–430), `LibraryModel.swift` (95–420),
`TasteProfile.swift` (95–200), `WidgetSnapshot.swift` (95–150), `IntentBridge.swift`, `APIClient.swift:415–430`,
`APIError.swift:129–150`, `LibraryService.swift:230–244`. Not reviewed: `AccessibilityAuditTests.swift` beyond
a grep for skips; the other ~198 test files beyond the greps recorded below; `MangaBakaPerformanceTests`.
`Scripts/` and `scripts/` are one directory on this case-insensitive disk; git tracks `Scripts/` only.

---

## Ranked top ten (value against effort)

| # | Finding | Effort | Confidence |
|---|---|---|---|
| 1 | **S1 — `TokenStore`'s new memo is per instance, and the app holds three instances.** Settings writes the token into one, the API client reads a stale "no token" from another, `hasCredentials` reads a third. On a Release build a freshly pasted token is validated unauthenticated, 401s, and is deleted as "rejected"; "Remove token" keeps sending the removed token until relaunch. Invisible on Abdi's Debug builds because `MB_PAT` authenticates the client regardless. | a line + one test | certain (by reading; the mechanism cannot not fire) |
| 2 | **S2 — Every "Open <series>" from Siri, a widget or a web link cancels itself.** `.task(id: bridge.pendingSeriesID)` sets the id to nil inside its own body, which restarts the task; gap 76's `Task.isCancelled` guards then return before navigating. Library series still open (that branch has no guard); anything else is a silent dead tap after a spent request. Two fixes, right alone, wrong together. | a function | likely (cannot run; the ordering argument is in the finding) |
| 3 | **S4 — The shipped version is `1.0 (1)` whatever `project.yml` says.** `Configs/Info.plist` carries literal `CFBundleShortVersionString`/`CFBundleVersion`; `MARKETING_VERSION 0.1.0` and the CI's `CURRENT_PROJECT_VERSION` sed never reach the bundle. Confirmed, as the brief asked; I could not find where yesterday's agent recorded it. | two lines in `project.yml` | certain for the strings; worth checking whether ASC has already accepted build "1" |
| 4 | **S3 — `hasCredentials` and the API client disagree about who is signed in.** The closure reads the Keychain only; the client also honours the build-time `MB_PAT`. On every Debug build with `Secrets.xcconfig` the Library tab says "No account" while Discover's personalised rows, the stack's seed pool and Settings' token check all authenticate. | lines | certain |
| 5 | **S6 — ~165 of ~1,958 tests never run on Xcode Cloud, and nothing reports it.** 91 `SourceTree.isAvailable` gates across 48 files; the cloud's green is ~1,790, and the difference is printed nowhere. | a file (bundle the tree) or a script | certain about the gates; the count is a regex estimate ±5 |
| 6 | **S5 — The archive memo goes stale three ways.** The stamp omits the toolchain (the SIL-verifier crash it exists to catch is compiler-specific), omits `Package.resolved` (inside the excluded `.xcodeproj`), and records HEAD's hash for an archive that compiled the working tree. | lines | certain for the omissions; the third needs a dirty tree to bite |
| 7 | **S11 — Signing in mid-session never rebuilds what signing out clears.** Sign-out clears ten things; a successful token check rebuilds none of them, so Spotlight, the widget, the reminders and the stack's ranker stay empty until relaunch. | a function | certain |
| 8 | **S10 — `Countdown` mounted after its deadline never fires `onReachZero`.** `.onChange` does not fire for an initial value, so a stale bar for a 429 that lapsed while the app was in the background reads "Retrying now…" forever and never retries. | a line (`initial: true`) | likely |
| 9 | **S9 — Item 33's release is half inert.** `CoverImage.load()` assigns the decoded bitmap after an `await` that outlives the view's `.task` cancellation, so a row that scrolled off mid-download gets its ~70 MB-class state back. | a line | likely |
| 10 | **S12 — A `/v1/my/profile` request on every signed-out cold launch** and again after "Remove token": `applyStoredExclusion` and `forgetPreviousAccount` ask for a profile id nothing can have. | two lines | certain |

---

## Q1 — Do the tests still mean anything?

**The three machine-dependence fixes (`5e5964f`), reasoned through.**

- `APIClientTests.swift:205-222` — `NetworkLedger.shared.totalRequests` delta → per-path `byPath[path]?.requests`
  delta on a UUID path. Still asserts the intent ("a write that gets a response is counted"): remove the ledger
  write for POST and `after == before` fails. Legitimate.
- `DiscoverReloadTests.swift:9-40` — bare `+= 1` → `OSAllocatedUnfairLock`. The assertion (`feedCalls == 4`, etc.)
  is unchanged; only the counter stopped losing updates. Legitimate, and the right shape.
- `ReminderTests.swift:337-348` — the fixture's `release_date` is now printed in `Calendar.current.timeZone`
  rather than UTC. This *agrees* with production (`UpcomingWork.localDay`, which the comment says is deliberate),
  so it is the fixture that was wrong, not the rule. But it means the suite now passes in every zone by
  construction and can no longer detect a production regression to UTC-day parsing unless the runner's zone is
  west of UTC at the moment of the run. Not a rewrite-to-pass; a rewrite that narrowed what the suite can
  catch. U11 in `SUMMARY.md` §7 is still the one measurement that settles the east-of-UTC half.

**Tests rewritten to agree with a change, checked against the commit's stated intent (`d16ba50`).**

- `SessionTests.swift:100-118` (`RootViewWiringTests.useAsSeedGuardsNilModel`) — the `#expect` flipped from
  "has a nil guard" to "has no optional chain". Item 61 removed the nil case, so the new assertion is right —
  but the `@Test` title still reads *"Use as seed does not confirm success when there is no mix model"*, which
  is now the opposite of what the body asserts. A future reader finds a test named for a guarantee the code no
  longer makes. Rename (finding S8).
- `SessionTests.swift:43-49`, `:86-94`, `SpotlightIndexTests.swift:127-131` — string pins re-aimed at the moved
  lines (`stackModel?.ranker` → `stackModel.ranker`, `guard walk.failure == nil else { return }` →
  `... else {`). Legitimate; they assert the same shape. They remain source pins that a same-named stub
  satisfies — already recorded in `tests.md` §2, not re-filed.
- `AccessibilityTests` / `ScrollEdgeTravelTests` (`d16ba50`) — assertions moved from source text to pure
  functions (`ScrollEdge.travel(forOffset:)`). Better, not weaker.

**Tests that pass for the wrong reason (new yesterday).**

- `TokenStoreCacheTests.swift:25-69` — all three tests use one `TokenStore()` instance, so they prove the cache
  works *within* an instance and say nothing about the case the app actually has (three instances). They are
  green over S1. The missing test is a two-instance one (see S1's fix).
- `AppShellRoundThreeTests.swift:64-66` claims a kill criterion — "delete any one line from `AppServices.wire`
  and exactly one expectation fails" — that is false for two of the five lines: `library.updateContentRatings`
  and `library.updateFormats` (`AppServices.swift:216, 220`) are never asserted; the test builds a real
  `LibraryService` (`:45-52`) and reads nothing back from it. Finding S7.
- `TokenStatusTests.swift:22-24, 49-51` — "expected to fail before the fix with: a compile error". These are
  the "compile-error failure" shape the brief names. Here it is honest (the enum case and the property
  genuinely did not exist) and each test also asserts a value, so they are not inert; recorded, not filed.
- `LaunchPathDeferralTests.swift:57-66` states plainly what it cannot prove (that `AppServices`' stored
  properties still use the factories) and why the compiler holds that half. This is the honest version.

**Suite-level gates hiding behaviour tests.** `0c4f940` moved the gates per-test in the suites it touched, but
91 gate sites remain (`grep -c 'enabled(if: SourceTree.isAvailable)'` over `MangaBakaTests` = 91). A script
counting `@Test` declarations inside gated `@Suite`/nested-suite chunks or carrying a per-test gate gives
**~165 of ~1,958** in 48 files. Suites still gated whole where a behaviour test sits beside a source read:
`SessionTests.swift:13` (all source), `SpotlightIndexTests.swift:101`, `RatingSegmentsTests.swift:39`,
`LensTests.swift:447,469,496,569`, `AppGroupParityTests.swift:28` (nested, source-only — fine). The local/cloud
count difference is still reported nowhere: `ci_pre_xcodebuild.sh` runs no tests and reads no xcresult; the
hook greps only failures (`pre-push:75`); only `run-ui-tests.sh:47-81` counts skips, and only for the UI
scheme. Finding S6.

---

## Q2 — Does the shell still start correctly? `startSession` end to end

**Before the first frame (synchronous, main thread).** `MangaBakaApp.init` (`MangaBakaApp.swift:15-24`):
`enlargeImageCache()` opens the 256 MB `URLCache` index; then `AppServices()` (`:13`, signposted "Services"):
`MangaUpdatesClient`, `TokenStore` (no Keychain read yet), `APIClient` with a **second** `TokenStore`
(`TokenProvider.swift:31` default), `makeDatabase` — two SQLite opens, two migrations, the one-time
split/salvage, signposted (`AppServices.swift:307-322`); three `UserDefaults` stores; `SeriesRepository`,
`ShelfStore`, `HistoryStore`, `LibraryService`, `LibrarySnapshot` (with `hasCredentials` reading the first
`TokenStore`), `ReleaseScheduleService`, `TasteProfile`+`TasteLedger`, `CatalogueService`, `ReleaseCalendar`;
`wire`; `applyStoredExclusion` starts an unstructured `Task` that will call `/v1/my/profile` (`:358-362`);
`startBackgroundWarmup` detaches the taxonomy decode and the Naver purge (`:262-267`); `SessionModels` builds
`RecentlyViewedModel`, `LensCounts`, `LibraryModel`, `CommunityPulseService`. Eager property initialisers:
`CharacterService`, `AppleBooksClient`, `GoogleBooksClient`, `ReleaseFeedService` (2 providers),
`EmbeddingIndex`, `OfflineCatalogue`, `OpenLibraryCovers`, `ReleaseReminders`, `OnboardingState`. Deferred
(unbuilt): `lenses`, `recents`, `publisherFollows` (`:54, 62, 65`). Then `RootView.init` builds seven more
(`RootView.swift:232-255`): `ContinuationsModel`, `SearchModel`, `BrowseModel`, `MixModel`, `DiscoverModel`,
`TagAudience`, `StackModel`.

**First body pass.** `TabView` with Discover selected; `DiscoverView`'s own `.task` fires the feed requests;
`tabs`' `.task` (`RootView+Tabs.swift:155-161`) asks `taste.ranker()`, which absorbs `snapshot.all()` — a
library walk if signed in, deduplicated with `startSession`'s by `LibrarySnapshot.inFlight`; `RootView`'s
`.task { await startSession() }` (`RootView.swift:282`) starts.

**`startSession` (`RootView+Session.swift:194-283`).** (1) reset toast if `databaseWasReset` — now only for
`.reset`, not `.unopened` (`AppServices.swift:316-321`, `AppDatabase.swift:146-190`): correct. (2) onboarding
covers via `repository.feed(.rising)` on a fresh install — the first request of the process, and the one that
populates the client's `TokenStore` cache with "no token" (S1). (3) `refreshReminders()`: with reminders off
(the default) it reschedules `[]` and returns (`:347-350`); on, it walks the library through `seriesIDs()`,
walks again through `load()` (cached), checks publisher follows, batches the cached links (item 64, signposted),
reschedules. (4) `librarySnapshot.load()` — signed out, `LibrarySnapshot.swift:136-141` purges the disk cache
once and answers `noAccount`; the shell then clears the widget, Spotlight and the taste ledger (`:243-269`) and
returns. Signed in: `session.library.load()` (item 7 — fixed, the model reads the cached walk),
`spotlight.reindex`, `history.lastOpenedDates`, `WidgetSnapshot.write` (which now skips the reload when
nothing changed, `WidgetSnapshot.swift:101-122` — F3 fixed). This part is right.

**On a token appearing** (`SettingsView.save()`, `:339-368`): `store.write` on the **third** `TokenStore`;
`onAccountChanged` → `forgetPreviousAccount()` (`RootView+Session.swift:133-187`): ten clears, including
`repository.updateLibraryExclusion(userID: await library.profileID())`, which makes a `/v1/my/profile`
request through the client's stale instance (unauthenticated in Release); then `check()` → `validateStoredToken`
→ `client.verifiedProfile()` through the same stale instance → S1. Even with S1 fixed, nothing after
`.accepted` rebuilds the library model, Spotlight, the widget, the reminders or `stackModel.ranker`
(`:153-156` admits "until the next relaunch") — S11.

**On a token disappearing** (`SettingsView.swift:238-250`): `store.clear()` on the third instance;
`forgetPreviousAccount()`; `session.library.forget()`; the Library tab's own `.task` then calls `load()` →
`snapshot.load()` → `hasCredentials()` on the first instance, whose cache still says *token present* → the walk
runs through the client's instance, which still *sends* the removed token → the previous account's library is
re-fetched and re-cached to disk. "Remove token" is cosmetic until relaunch — S1(c).

**Built twice:** `TokenStore` ×3 (`AppServices.swift:87`, `TokenProvider.swift:31`, `SettingsView.swift:97`) —
the only one that matters. `PublisherFollows()` defaults at `SettingsView.swift:56, 91` and
`RemindersSection.swift:15` would be second instances if ever taken; today `RootView+Session.swift:107` passes
the shared one, so they are not — but the `RemindersSection` comment says the opposite (S14).
**Never built / never read:** `AppServices.tokenStore` (`:75, 88`) is stored and read by nothing
(`grep '\.tokenStore'` over `MangaBaka` and `MangaBakaTests`: no hits) — S15. Nothing else on the path is
dead; `Deferred` values are reached from exactly the callers their comments name.

---

## The pre-push memo (`.githooks/pre-push:82-123`)

Checked: can the memo skip an archive it should have run?

- **Yes — toolchain change.** `SOURCE_STAMP` (`:96`) is four tree hashes. The archive exists because
  *"Swift 6.3.3's SIL verifier"* died on code that Debug compiled fine (`:82-86`). An Xcode update with an
  unchanged tree skips exactly the run that would catch the next verifier regression. Fix: fold
  `xcodebuild -version | tr '\n' ' '` (or `swift --version | head -1`) into the stamp. One line.
- **Yes — `Package.resolved`.** It lives at `MangaBaka.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/`
  (committed, `8f9d243`), inside the tree the stamp deliberately excludes; `project.yml` pins GRDB as
  `from: "7.0.0"` (`project.yml:17-20`), so a resolution bump changes only the resolved file. Fix: add
  `HEAD:MangaBaka.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` to `:96`.
- **Yes, narrowly — dirty tree.** `xcodebuild archive` compiles the working directory; the memo records
  HEAD's hashes (`:94-96` says so, for the right reason). An uncommitted fix that makes a broken HEAD archive
  clean writes a memo for the broken HEAD; the next docs-only push of that HEAD skips. Fix: refuse to write the
  memo when `git status --porcelain -- MangaBaka MangaBakaWidgets project.yml Configs` is non-empty, or stamp
  the working tree with `git stash create`'s tree. Two lines.
- **Robustness, not staleness:** under `set -eu` a command substitution that fails aborts the script, and
  `:96` sends `git rev-parse`'s stderr to `/dev/null`. Rename `Configs/` and every push dies silently at the
  memo line with no message. `|| true` on `:96` — the `[ -n "$SOURCE_STAMP" ]` guards at `:98, 117` already
  assume it can be empty. One line. (S17.)
- Not a problem: `--no-verify` pushes leave the memo alone, so the next verified push archives; the memo is
  per-clone in `.git/`; step 3's `xcodegen generate` rewriting the tree is why the stamp reads HEAD, and
  `project.yml` is in the stamp, so a project change cannot hide.

---

## `Configs/` — the version string

Confirmed. `Configs/Info.plist:22-23` — `CFBundleShortVersionString` = literal `1.0`; `:36-37` —
`CFBundleVersion` = literal `1`. `Configs/MangaBakaWidgetsInfo.plist:19-22` — the same two literals.
`project.yml:83-84` sets `MARKETING_VERSION: "0.1.0"` and `CURRENT_PROJECT_VERSION: "1"`; `:126-127` the same
for the widget. With `GENERATE_INFOPLIST_FILE: NO` (`:85`) Xcode substitutes only `$(…)` references, so the
bundle ships `1.0 (1)`. The two plists carry exactly XcodeGen's default key set with these exact default
values, and `CLAUDE.md`'s 2026-09-12 note records `xcodegen generate` rewriting `Configs/Info.plist` — so the
literals are XcodeGen's defaults, regenerated on every `generate`, and a hand edit will not stick.

Consequences: (1) `ci_pre_xcodebuild.sh:43-54` rewrites `project.yml`'s build number per Xcode Cloud build and
regenerates — inert for the bundle, because the regenerated plist still says `1`. App Store Connect refuses a
second upload with the same `(version, build)`; `TranslationSection.swift:9-10` records that build 64 reached
TestFlight, and 69/71/75 died before upload, so the collision may simply not have happened yet. (2) The
do-not-fix entry `SUMMARY.md` §6 item 15 calls the sed "documented, fine"; it is documented and inert.

I could not find where yesterday's agent recorded deliberately not changing this (`grep` over `docs/` for
`CFBundleShortVersionString`, `MARKETING_VERSION`, `version string`, `0.1.0`: no hits). If it was a chat
decision it should be written down here or in `todo-next-week.md`.

**Fix (S4), when Abdi says so:** in `project.yml` under both targets' `info.properties` add
`CFBundleShortVersionString: $(MARKETING_VERSION)` and `CFBundleVersion: $(CURRENT_PROJECT_VERSION)`, run
`xcodegen generate`, commit both plists. **Measurement first:** App Store Connect → TestFlight → build 64's
build string. If it reads `1`, the next archive will be refused as a duplicate and this is urgent; if it
reads `64`, something else (not in this tree) is setting it and the fix is still right but not urgent.

---

## Findings

### S1 — `TokenStore`'s memo is per instance; the app holds three
- **What:** `TokenStore.Cache` is `private let cache = Cache()` (`TokenStore.swift:66`) — one per `TokenStore()`
  call, shared only by *copies* of that value. `write`/`clear` invalidate only their own instance
  (`:103, 128`). Three instances exist: `AppServices.swift:87` (`keychain`, feeding `hasCredentials` at
  `:151` and `:191`), `TokenProvider.swift:31` (`ResolvingTokenProvider`'s default `store: TokenStore()`,
  read on every request at `:40`, constructed at `AppServices.swift:295`), and `SettingsView.swift:97`
  (default `store: any TokenPersisting = TokenStore()`, the only writer, `:341, 239, 364`).
- **Why it matters — three failures from one line:**
  (a) Fresh Release install: onboarding's `repository.feed(.rising)` (`RootView+Session.swift:217`) sends a
  request → instance 2 caches `.some(nil)` (`TokenStore.swift:93`). Reader pastes a token → instance 3 writes →
  `check()` → `verifiedProfile()` (`APIClient.swift:425`) → `authorizationHeader()` reads instance 2 → cached
  nil, `buildTimeToken` nil in Release → unauthenticated `/v1/my/profile` → 401 → `needsAccount`
  (`APIError.swift:211-214`) → `.rejected` → `SettingsView.swift:358-366` **deletes the token** and shows
  "Token rejected". No reader can add an account without relaunching first, and the app tells them their token
  is bad. (b) `hasCredentials` reads instance 1, which cached nil on the launch walk
  (`LibrarySnapshot.swift:136`), so the Library tab stays "No account" and every snapshot ask answers
  `noAccount` after a successful sign-in until relaunch. (c) "Remove token" clears instance 3; instances 1 and
  2 still hold the token, so the Library tab's next `.task` walks *with the removed token* and re-caches the
  library to disk (`LibrarySnapshot.swift:343-363`).
- **Why the walks did not see it:** `Configs/Secrets.xcconfig` is present and defines `MB_PAT` (one `mb-` line;
  value not read), so every Debug build authenticates through `buildTimeToken` (`TokenProvider.swift:40`)
  whatever the Keychain says. The 2026-09-14 comment at `TokenStore.swift:24-28` reasons about copies of one
  value and misses that each `TokenStore()` is a new value; `AppServices.swift:71-74` repeats the mistake.
- **Fix:** make the cache static — `private static let cache = Cache()` — because `service`/`account` are
  constants (`:14-15`) and every instance addresses the same Keychain item, so one memo is the truth. Delete the
  now-wrong sentence at `:24-28`. Then remove the default `TokenStore()` at `SettingsView.swift:97` and
  `TokenProvider.swift:31` and pass `services.tokenStore` (S15 becomes its reason to exist). Test, which fails
  today with `nil`: `let a = TokenStore(); let b = TokenStore(); _ = a.read(); b.write("mb-two-instances-token");
  #expect(a.read() == "mb-two-instances-token"); defer { b.clear() }` — plus the mirror for `clear`.
- **Effort:** a line + two call sites + one test. **Confidence:** certain. **Lens:** 1 bug, 8 (data races are
  not the issue; stale state is).

### S2 — The deep-link task cancels itself
- **What:** `RootView.swift:299-303`: `.task(id: bridge.pendingSeriesID) { guard let id …; bridge.pendingSeriesID
  = nil; await openSeries(id:) }`. Writing nil to the `@Observable` id the modifier is keyed on changes the id;
  SwiftUI cancels the running task at the next update and starts one that returns at the guard.
  `openSeries` (`RootView+Session.swift:295-321`) suspends first on `librarySnapshot.all()` (`:296`), so the
  cancellation lands before `:307` and `:318`, which `return` on `Task.isCancelled`.
- **Why it matters:** a Siri "Open X", a `mangabaka://series/<id>` widget/link, or a mangabaka.org link for a
  series *not* in the library: one `repository.series(id:)` request is spent (`:310`), then `:318` returns —
  no navigation, no toast (gap 61's toast at `:315` is unreachable on this path). Library series still open
  because `:296-300` has no cancellation check. History: the nil-reset dates from the Siri feature
  (`114a43b`); gap 76 added the guards (`d4cd541`) after observing "the cancelled call kept running" — the
  cancellation it observed was almost certainly this self-reset, not a second intent; item 65 (`d16ba50`)
  then routed `onOpenURL` through the same task (`RootView.swift:306-319`). Right alone, wrong together.
- **Fix:** give `IntentBridge` a request rather than a bare id — `struct Open: Equatable { let id: Int; let
  token = UUID() }`, `var pending: Open?` — key the modifier on `bridge.pending?.token`, never clear it inside
  the task (clear it in `openSeries` after the `selection`/path writes, or not at all: a second tap on the same
  series mints a new token, which is the "re-tap re-opens" behaviour a bare id could never give). Then the
  `isCancelled` guards do exactly what gap 76 wanted. Test: none can drive `.task(id:)`; assert instead that
  `AppIntents.swift:19` and `RootView.swift:318` both construct an `Open`, and keep the wiring pin.
- **Effort:** a function. **Confidence:** likely — the ordering (observable mutation → SwiftUI update → cancel
  → continuation resumes cancelled) is how `.task(id:)` is documented to behave, but I could not run it; one
  `print(Task.isCancelled)` at `:307` from a Siri "Open" of a non-library series settles it. **Lens:** 1.

### S3 — Two definitions of "signed in"
- **What:** `hasCredentials` is `{ keychain.read() != nil }` (`AppServices.swift:151, 191`); the client's
  provider treats `store.read() ?? buildTimeToken` as the credential (`TokenProvider.swift:40`).
- **Why it matters:** on every Debug build with `Secrets.xcconfig` and no Keychain token — Abdi's own —
  `LibrarySnapshot` answers `noAccount` (`LibrarySnapshot.swift:136-141`), the Library tab says "No account",
  Spotlight/widget/taste are cleared at every launch (`RootView+Session.swift:243-269`), while
  `/v1/my/recommendations`, the stack's `/v1/my/library` seed pool and Settings' token check all succeed. It
  also means the 2026-09-14 walk's "no token configured" state is not the state a Release reader is ever in.
- **Fix:** put the decision where the credential is: `extension ResolvingTokenProvider { var hasCredentials:
  Bool { store.read() != nil || buildTimeToken != nil } }`, build the provider once in `AppServices.init`, and
  pass `{ provider.hasCredentials }` at `:151` and `:191`. Test: a provider with `infoDictionary: ["MB_PAT":
  "mb-xxxxxxxxxxxxxxxx"]` and an empty store reports `true`. (Written as the
  all-`x` placeholder: the credential scanner reads every tracked file, and a
  token-shaped example in a review report is exactly what it should stop.)
- **Effort:** lines. **Confidence:** certain. **Lens:** 1 (two fixes colliding: item 86 and the PAT path).

### S4 — Version string
See the section above. **Effort:** two lines. **Lens:** 9.

### S5 — Archive memo
See the section above. **Effort:** lines. **Lens:** 2, 9.

### S6 — The cloud runs ~165 fewer tests and nothing says so
- **Where:** `SourceTree.swift:21-23`; 91 gate sites; `ci_pre_xcodebuild.sh` (no test step reads results);
  `pre-push:68-80` greps failures only. Estimate: ~165 `@Test`s of ~1,958 in 48 files (regex over
  `@Suite`/nested-suite chunks; ±5).
- **Why it matters:** "1,954 green" is two different numbers on two machines and the smaller one is the release
  gate. The SafeLink allow-list case in `0c4f940` is the shape: a security rule that only ran on the laptop.
- **Fix (better way):** stop gating — ship the source to the test bundle. In `project.yml` under
  `MangaBakaTests.sources` add `- path: MangaBaka` with `buildPhase: resources` and `type: folder` (and the
  same for `Configs`, `MangaBakaWidgets`), then `SourceTree.root` = `Bundle(for: Marker.self).resourceURL` when
  `#filePath`'s tree is absent. Every source-reading test then runs on Xcode Cloud, `SourceTestGuardTests`
  becomes unnecessary, and the count converges. Cost: ~45k lines of Swift copied into a test bundle (a few MB;
  test-only, never shipped). **Fallback (a script):** a `Scripts/run-unit-tests.sh` mirroring
  `run-ui-tests.sh:47-81` that prints the skipped count, called by the hook and by `ci_pre_xcodebuild.sh`, and
  a one-line `SKIPPED=n` in the commit message rule.
- **Effort:** a file, or a script. **Confidence:** certain. **Lens:** 9, 5 (a metric whose denominator nobody
  stated).

### S7 — `everyStoreIsWired`'s kill criterion is overstated
- **Where:** `AppShellRoundThreeTests.swift:64-66` (the claim), `:79-90` (asserts `repository.ratings/formats/
  blocked` only); `AppServices.swift:214-224` has five lines, two of which update `LibraryService`.
- **Why it matters:** delete `await library.updateContentRatings(ratings)` and the suite stays green; the
  comment tells the next agent the opposite. The library half is the one that filters the reader's own
  recommendations by rating — the case the doc comment at `:202-206` says matters most.
- **Fix:** `wire` takes `library: any LibraryFiltering` (a two-method protocol `LibraryService` adopts), the
  test passes a recording double, asserts both halves; or expose `LibraryService.filtersForTesting`. Then the
  kill-criterion sentence is true. **Effort:** a function + lines. **Confidence:** certain. **Lens:** 9.

### S8 — A test named for a guarantee the code no longer makes
- **Where:** `SessionTests.swift:105` title *"does not confirm success when there is no mix model"*; body
  `:114-115` asserts the addition is unconditional.
- **Fix:** rename to "Use as seed adds unconditionally because the model always exists (item 61)"; the doc
  comment at `:96-99` should lead with item 61, not gap 77. **Effort:** a line. **Lens:** 9.

### S9 — `CoverImage` re-holds the bitmap after its task was cancelled
- **Where:** `CoverImage.swift:141-143` — `guard let image = await CoverStore.shared.image(for: url) …;
  loaded = image` with no `Task.isCancelled` check; `:97-100` releases on disappear; `:78-80` `.task(id:)`
  cancels on disappear. `CoverStore` is documented "deliberately not cancelled" (`SUMMARY.md` §6 item 9), so
  the await returns normally after cancellation.
- **Why it matters:** a fast fling over 513 rows cancels hundreds of in-flight loads; each one still assigns
  its decoded `UIImage` into a row that has left the screen — the exact per-row copy item 33 was written to
  free. Not measured; the item's own number (~70 MB for 513 rows) is the upper bound.
- **Fix:** `guard !Task.isCancelled else { return }` between `:142` and `:143`, and again before the deferred
  `isReady` write at `:155`. **Effort:** a line. **Confidence:** likely. **Lens:** 3, 7.

### S10 — `Countdown` mounted past its deadline never retries
- **Where:** `Countdown.swift:31-35` — `.onChange(of: hasReached(remaining))` without `initial:`; `:44` renders
  "Retrying now…" for that state.
- **Why it matters:** `StaleBar`/`FailureState` mount a `Countdown` whenever `deadline`/`rateLimitDeadline` is
  non-nil, including a 429 whose window lapsed while the app was backgrounded or before the view appeared. The
  text says "Retrying now…" and nothing retries — the exact symptom `fee95b0` fixed for the never-passed
  deadline, from the other side.
- **Fix:** `.onChange(of: hasReached(remaining), initial: true) { … }`. **Effort:** a line. **Confidence:**
  likely (SwiftUI's documented `initial:` default is `false`). **Lens:** 1.

### S11 — Sign-in mid-session rebuilds nothing
- **Where:** `SettingsView.swift:357, 373-376` (`.accepted` → status, name, nothing else);
  `RootView+Session.swift:133-187` (sign-out clears library model, ranker, reminders, Spotlight, widget);
  `:194-283` runs once per launch (`:196-198`); `RootView.swift:141-142, 355-359` refreshes reminders only on a
  background round-trip.
- **Why it matters:** a reader who connects an account from onboarding — the path `RootView+Failures.swift:41-47`
  exists for — has no Spotlight entries, a blank widget, no reminders and an unweighted stack until they
  quit and relaunch. C3 ("the account-change list is maintained by hand") has moved from sign-out to sign-in.
- **Fix:** an `onAccountConnected: () async -> Void` beside `onAccountChanged`, called after `.accepted` in
  `check()` when `save()` is the caller, implemented in `RootView+Session` as the post-guard half of
  `startSession` factored into `rebuildAccountSurfaces()` (`session.library.load()`, `spotlight.reindex`,
  widget write, `refreshReminders()`, `stackModel.ranker = await taste.ranker()`), which `startSession` also
  calls. One list, two callers. **Effort:** a function. **Confidence:** certain. **Lens:** 3, 1.

### S12 — A profile request nobody can answer, on every signed-out launch
- **Where:** `AppServices.swift:358-362` → `LibraryService.swift:233-238` → `client.profile()`;
  `RootView+Session.swift:169` after "Remove token".
- **Why it matters:** one `/v1/my/profile` per cold launch against the shared 180/min budget, guaranteed 401
  for every reader without an account; and `profileID()` caches the nil, so a token added later would need
  `forgetProfile()` — which `forgetPreviousAccount` does call, so that half is fine.
- **Fix:** `guard keychain.read() != nil || PATTokenProvider(infoDictionary: info) != nil else { return }` in
  `applyStoredExclusion` (or pass `hasCredentials` into `LibraryService` and short-circuit `profileID()`), and
  skip `:169` when `hasCredentials()` is false. **Effort:** two lines. **Confidence:** certain. **Lens:** 6.

### S13 — `InlineFailure` hand-rolls `RetryGate`
- **Where:** `InlineFailure.swift:16, 33-41` vs `FailureState.swift:13-25`. Same rule, second copy, and this
  copy resets `isRetrying` on the main actor from an unstructured `Task` the view may have left.
- **Fix:** `@State private var gate = RetryGate()` and `Task { await gate.fire(retry) }`. **Effort:** lines.
  **Lens:** 4.

### S14 — Comments that now lie
- `RemindersSection.swift:13-14` "Not injected from `AppServices` yet — see this feature's report for the one
  line" — it is injected (`RootView+Session.swift:107` → `SettingsView.swift:145`). Delete the sentence and the
  default at `:15`, and the defaults at `SettingsView.swift:56, 91`, so a second `PublisherFollows` cannot come
  back by omission (the reason `LibraryTransferSection.swift:178-185` gives for its own no-defaults rule).
- `RootView.swift:141` "One handle, so two quick foregrounds do not run two walks" — `reminderRefresh?.cancel()`
  (`:358`) cancels a task whose body (`refreshReminders`, `RootView+Session.swift:346-383`) never checks
  cancellation; both runs complete. Harmless because `LibrarySnapshot` shares the in-flight walk, so say that
  instead.
- `TokenStore.swift:24-28` and `AppServices.swift:71-74` — wrong, per S1.
- `LibraryModel.swift:125-126` "the app passes `{ tokenStore.hasToken }`" — no such member; it passes
  `{ keychain.read() != nil }`.
- `RootView+Session.swift:302-303` "a second Open X … cancels this task" — the first Open cancels it (S2).
- **Effort:** a line each. **Lens:** 9.

### S15 — `AppServices.tokenStore` is held for a sentence
- **Where:** `AppServices.swift:75, 88`; no reader. Charter 3. Folds into S1's fix (it becomes the instance
  passed to the provider and to Settings). **Lens:** 9.

### S16 — The stack's ranker task re-runs on every title-preference change
- **Where:** `RootView+Tabs.swift:155-161` is inside `tabs`, below `.id(titleRevision)` (`RootView.swift:260`),
  so the identity bump restarts it. `TasteProfile.ranker()` (`TasteProfile.swift:118-122`) hits `cachedIDs`
  after the first run, so the cost is one `ledger.favoured(limit: 60)` read. Recorded so nobody adds a walk to
  that task without moving it above the `.id`. **Effort:** none now. **Lens:** 3.

### S17 — Hook aborts silently if a stamped path is missing
See the memo section. **Effort:** a line. **Lens:** 2.

### S18 — Credential scan and `looksValid` disagree on token length
- **Where:** `check-credentials.sh:33, 38` require `mb-` + 16 alphanumerics; `TokenStore.swift:143` accepts
  any `mb-` token longer than 12 characters. A real token of 13–18 characters would pass the scanner. I do not
  know MangaBaka's token length (the one in `Secrets.xcconfig` was not read). **Fix:** align both to the real
  length once it is known, or lower the scanner to `{10,}`. **Effort:** a character. **Confidence:** worth
  checking. **Lens:** 9.

### Crash-risk sweep (negative result, recorded)
`grep` over the slice for `try!`, `as!`, `.first!`, `)!`, `]!`, `fatalError`, `preconditionFailure`,
`unsafelyUnwrapped`: only `AppServices.swift:291, 314, 372` — a compile-time URL literal and the in-memory
SQLite fallback, both documented and unreachable from input. `Int(Double)` on a server number: none;
`DataUseSection.swift:127` converts a locally measured sub-second duration; `Countdown.swift:46, 49` are bounded
by `APIError.swift:144-147`'s clamp to `RateLimitGate.maxHonouredRetryAfter`; `RatingSegments.swift:51`
guards `width > 0`. `MainActor.assumeIsolated` once (`Motion.swift:61`), with the trap-over-deadlock reasoning
written down. `DispatchQueue.main.sync` gone (F13 fixed). Nothing to do.

### Previously filed, verified fixed here (not re-reported)
F1 (`RootView+Session.swift:277`), F2 (`SettingsView.swift:100-101`, `LibraryTransferSection.swift:206-208`),
F3 (`WidgetSnapshot.swift:101-122`), F4 (`Toast.swift:40, 74, 185, 198-203`), F5 (`RootView.swift:232-255`),
F6 (`AppServices.swift:117-123`), F7 (`RootView.swift:317-318`, `RepositoryWiringTests:151-167`),
F8 (`RootView+Session.swift:48`), F9 (`:373-374`), F10 (`SettingsView.swift:123, 186`), F11 (`Toast.swift:143-153`),
F12 (`ScrollEdge.swift:45-47, 72-76`), F13 (`Motion.swift:39-62`), F14 (`Typography.swift:56-66`), items 61, 62,
64, 65, 78, 86, 103, 104, 106, 107, 137. Each does what its commit says, with the exception of S2 (65 + gap 76)
and S9 (33).

---

## What the slice does well

- `AppDatabase.swift:206-216, 337-348` names the two SQLite codes that mean corruption and refuses to reset on
  anything else; `DatabaseCorruptionScopeTests.swift:93-109` records exactly what its fixture proves and — in
  writing — what it does not (the salvage). That is the standard.
- `AppDatabaseResetTests.swift:78-97` carries a control ("a good file is not reset") and says why a test without
  it could pass by coincidence.
- `LaunchPathDeferralTests.swift:57-66` states the half it cannot prove and which mechanism (the type system)
  holds it instead of pretending.
- `TokenStore.swift:34-37`: "the review's measure-first threshold was not measured … implemented
  unconditionally rather than gated behind a number nobody has taken." Wrong about instances (S1), honest about
  the number.
- `WidgetSnapshot.swift:101-122` separates the write (always, for `writtenAt`) from the reload (only on change)
  and explains the budget it protects.
- `pre-push:60-67, 88-91` labels its timeout a deadlock guard and a guess, and the memo a per-clone artefact.
- `Metrics.swift:146-163` records that its own derivation of `scrollBottomInset` does not add up, and names the
  screenshot that would settle it.
- `RowAmbient.swift:54-65` keeps a sampled number in the file the number is about, with the reason copying it
  into a test would let it rot.
- `Motion.swift:39-62` deletes the dead off-main branch and says how both directions were checked.
- `SourceTestGuardTests.swift:25-37, 103-119` is a test that found two holes in itself and wrote them down.

---

## What I could not determine

- **S1 on a real device without `MB_PAT`.** One Release (or Debug with `Secrets.xcconfig` moved aside) run on
  a fresh simulator: finish onboarding, paste a valid token, read the card. Expect "Token rejected" and an
  empty Keychain. This is the single most valuable measurement in this report.
- **S2.** `print(Task.isCancelled)` at `RootView+Session.swift:307`, then Siri "Open <a series not in the
  library>". Expect `true`.
- **S4.** App Store Connect → TestFlight → the build string on build 64. `1` means the next upload is refused.
- **S6's exact count.** `xcodebuild test … -resultBundlePath` then `xcrun xcresulttool get test-results
  tests` filtered for `"result": "Skipped"` under `TZ=UTC` with the source tree renamed aside — the cloud's
  number, locally. My 165 is a regex.
- **S9's size.** Memory graph after a 513-row fling with and without the guard; the item-33 number is the
  ceiling, not a measurement.
- **S10.** A `StaleBar` given `deadline: .now - 1` in a preview; expect no retry today.
- **Whether `xcodegen generate` rewrites `Configs/Info.plist`** — inferred from `CLAUDE.md`'s 2026-09-12 note
  and the plist matching XcodeGen's default key set; one `xcodegen generate` followed by `git diff -- Configs`
  after hand-editing the version settles it (needs a write; not done here).
- **The real token length** (S18).
