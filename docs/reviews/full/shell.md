# Deep review — slice 8: the shell, shared controls, Settings, DesignSystem

Read-only, 2026-09-14, against HEAD `99a1124`. Nothing built, run or tested. Line numbers are as read.

**Coverage:** all 50 files in the slice read in full — `MangaBaka/App/**` (8 files, 1,258 lines), `Features/Shared/**` (19, 2,077), `Features/Settings/**` (12, 2,162), `DesignSystem/**` (9, 1,077) = 6,574 lines. Read in part, only to settle a question the slice raised: `Core/Auth/TokenStore.swift` (whole), `Core/Model/SeriesWebLink.swift` (whole), `Core/Library/WidgetSnapshot.swift` (whole), `Core/Intents/IntentBridge.swift` (whole), `Core/Telemetry/Signposts.swift`, the `init`/`load` of `DiscoverView`, `StackView`, `MixView`, `BrowseView`, `ScheduleView`, `LibraryModel`, `LibrarySnapshot`, `SeriesRepository.init`, `APIClient.init`, `CharacterService.primeAniListHealth`, `SpotlightIndex.reindex`, both `.entitlements`, `project.yml` lines 78-135, and `docs/apple-experiment/README.md` on `apple-idiomatic`.

Already recorded elsewhere and **not re-filed**: `SwitchIndicator` should be a real `Toggle` once un-nested from its `Button` (SUMMARY-2026-09-11 S-F21/L11 — still unfixed in code, see §Charter 6); `ScaledFont` computes leading from the unscaled size (S-F14, `Typography.swift:28` — still present); `Motion` cannot invalidate a view (S-F6); the reminders switch reading On after a system denial (failures-shell) — now fixed at `RemindersSection.swift:36`; corrupt-database fallback (failures-shell gap 3) — now fixed at `AppServices.swift:174-184`; `primeAniListHealth` hanging up to 60 s (failures-services F4) — I file only the launch-cost angle below.

---

## Ranked top ten (value against effort)

| # | Finding | Effort | Confidence |
|---|---|---|---|
| 1 | F1 — Discover's "Pick back up" row and chapters-read figure are empty on every cold launch until the Library tab is visited: `LibraryModel` only subscribes to the walk inside its own `load()`, and nothing on the launch path calls it | line | likely |
| 2 | F2 — Opening Settings walks the whole library (13 requests, ~25 MB on a real account per gap 88) through a private, uncached `LibrarySnapshot`, for an export button nobody has tapped, on every push of Settings | function | certain |
| 3 | F3 — Every launch rewrites the widget file and calls `WidgetCenter.reloadAllTimelines()` even when nothing changed, spending the daily widget-refresh budget | line | certain (reload) / likely (budget) |
| 4 | F4 — A second toast with the same text ("Saved" then "Saved") gives no haptic and no animation: both are keyed on the message string | function | certain |
| 5 | F5 — `RootView` holds five `@Observable` models that are not the ones on screen: the first body pass builds a throwaway, the tab view's `@State` keeps it, and the `.task` then stores a second instance nobody shows | function | certain (double instance) / worth checking (visible harm) |
| 6 | F6 — `applyStoredFilters` applies the reader's ratings/formats/blocked tags in an unstructured `Task` that races the first feed request; the repository's `init` already accepts them | function | worth checking |
| 7 | F7 — `mangabaka://` links run `openSeries` in an unstructured `Task`, so two rapid links reintroduce gap 76; negative ids reach the API | line ×2 | certain |
| 8 | F8 — `Int($0.activeSeriesCount)` on a server `Double`, the exact pattern the brief bans | line | certain |
| 9 | F9 — `refreshReminders` does 939 sequential actor hops + SQLite reads on the launch path for feed links that are almost never cached | function | certain |
| 10 | F10 — `SettingsView.init` hits the Keychain (`store.read()`) on every `RootView` body pass while Settings is open | line | likely |

---

## Findings

### F1 — Discover's in-progress row is empty until the Library tab is visited
- **What:** `session.library.entries`/`inProgress` are only populated by `LibraryModel.load()`, which only `LibraryView`'s `.task` calls; Discover reads them on launch and gets `[]`.
- **Where:** `RootView.swift:208` (`inProgress: session.library.inProgress`) and `:212` (`chaptersRead(in: session.library.entries)`); `LibraryModel.swift:328` (`observePages` registered inside `load()`), `:338`; `LibraryView.swift:167` (the only `.task { await model.load() }`); `RootView+Session.swift:180` walks `librarySnapshot`, not the model.
- **Why it matters:** a reader with 300 in-progress series opens the app to Discover and "Pick back up" is absent and the chapters-read figure is 0, every cold launch, until they tap Library. The walk itself already happened in `startSession` — the data is cached and unused (charter 3).
- **Fix:** in `startSession`, after `guard walk.failure == nil`, add `await session.library.load()` — it returns the cached snapshot, no request. Or pass `walk.entries` into `session.library` directly.
- **Effort:** a line. **Confidence:** likely (I did not find any other path that fills `entries`; a screenshot of Discover on a cold launch settles it). **Lens:** 1 bug / 3 optimisation.

### F2 — Opening Settings costs a full library walk for an untapped export
- **What:** `LibraryTransferSection()` is built with no arguments, so it makes its own `LibraryService` + `APIClient` and an uncached `LibrarySnapshot(library:)` (no `database`, so no disk cache), and its `.task` walks the whole library on appearance.
- **Where:** `SettingsView.swift:134`; `LibraryTransferSection.swift:148-161` (`defaultLibrary` is a `static var` — a new service per access), `:152` (`LibrarySnapshot(library: library).all()`), `:190` (`.task { loadEntriesIfNeeded() }`); `LibrarySnapshot.swift:54-62` (`database: nil`).
- **Why it matters:** every push of Settings (rebuilt fresh each time, per the gap-121 note at `SettingsView.swift:170-172`) fires ~13 paged requests against the 180/min shared budget and downloads ~25 MB, in the background, whether or not the reader exports. On a metered connection this is the most expensive screen in the app and it looks like a settings page. The file's own comment (`:140-147`) knows.
- **Fix:** `SettingsView` takes `library: LibraryService` and `loadExisting: () async -> [LibraryEntry]`; `RootView+Session.swift:79-93` passes `library` and `{ await librarySnapshot.all() }` (cached, zero requests after launch). Then move the load off appearance: replace the two `ShareLink`s with a `Button` that awaits `loadEntriesIfNeeded()` and only then presents a sheet holding the `ShareLink`, so the walk (if uncached) happens on the tap.
- **Effort:** a function. **Confidence:** certain. **Lens:** 6 load balancing / 7 speed.

### F3 — Widget reload every launch, changed or not
- **What:** `startSession` always calls `WidgetSnapshot.write(pickBackUp:)`, which always rewrites the file and calls `WidgetCenter.shared.reloadAllTimelines()`.
- **Where:** `RootView+Session.swift:184-186`; `WidgetSnapshot.swift:81-87`.
- **Why it matters:** WidgetKit budgets reloads per widget per day (Apple documents "roughly 40-70"); an app that reloads on every foreground launch spends that budget on no-ops, and the one reload that matters (a real change from the schedule build) can then be deferred by the system. `WidgetSnapshot` is already `Equatable`.
- **Fix:** in `write`, compare the merged snapshot's `dueThisWeek`/`pickBackUp` with `read()`'s and return before writing/reloading when equal (ignore `writtenAt`). One `guard`.
- **Effort:** a line. **Confidence:** certain that it reloads every launch; the budget cost is Apple's documented behaviour, not measured here. **Lens:** 6 load balancing.

### F4 — A repeated toast is silent
- **What:** `ToastOverlay` keys its haptic, its animation and its transition on `centre.message: String?`. Two consecutive toasts with identical text leave the value unchanged, so no haptic fires, nothing animates, and the reader sees the old capsule sit there (its timer silently restarted).
- **Where:** `Toast.swift:66-68` (`self.message = message`, no revision), `:168` (`.animation(value: centre.message)`), `:174-179` (`sensoryFeedback(trigger: centre.message)`).
- **Why it matters:** "Saved" is the confirmation for every library write (`RootView+Session.swift:306`); saving two series in a row inside two seconds gives the second save no confirmation at all — exactly the "indistinguishable from one that missed" the file's own header warns about. `ToastTests` cannot catch it: the message value is the same.
- **Fix:** add `private(set) var revision = 0` to `ToastCentre`, `revision += 1` in `show()`, and use `revision` as the trigger for both `sensoryFeedback`s and as the `.id()` of the `Text` so the transition replays; keep `.animation(value:)` on `message != nil`. Test: two `show("Saved")` calls → `revision` increments twice.
- **Effort:** a function. **Confidence:** certain. **Lens:** 1 bug.

### F5 — Five models are built twice; RootView keeps the one nobody shows
- **What:** `discoverModel ?? DiscoverModel(...)` runs on the first body pass with `discoverModel == nil`, builds instance A, and `DiscoverView` captures A in `@State` (`_model = State(initialValue:)`). The `.task` then stores a fresh instance B in `RootView`. `@State` keeps A. B is the one `RootView` can reach; A is the one on screen.
- **Where:** `RootView.swift:207, 222, 233, 257, 269` (the `??` fallbacks), `:299-310` (the `.task` that builds the second set); `DiscoverView.swift:36`, `StackView.swift:69`, `MixView.swift:43`, `BrowseView.swift:22` (all `State(initialValue:)`).
- **Why it matters:** For Discover (the initial tab) this is certain: two `DiscoverModel`s live for the session, one idle. For Stack/Mix/Browse it depends on whether the tab's content closure first runs before or after the `.task` — the tab closures are lazy and the `.task` fires right after the first frame, so they usually get B, which is why `useAsSeedTapped` (`RootView+Failures.swift:14-22`) and `stackModel?.ranker = ...` (`RootView.swift:312`) usually land. "Usually" is the problem: a reader who taps Stack in the first frame gets A, and the taste ranker and `forgetPreviousAccount`'s `stackModel?.ranker = nil` (`RootView+Session.swift:126`) go to B. The comment at `RootView.swift:86-91` says the models "survive" `.id(titleRevision)`; they do, but the survivor is B, which never loaded — the tab's `.task` re-runs on identity change, so it reloads, and the stack's queue *is* reset on a title change, the thing that comment says it prevents.
- **Fix:** give `RootView` an `init` that builds the six models once — `_discoverModel = State(initialValue: DiscoverModel(repository: repository))` etc. — make the properties non-optional, delete the `??` fallbacks and the nil checks in the `.task` (keep only `stackModel.ranker = await taste.ranker()`). `useAsSeedTapped`'s guard becomes unnecessary. `SessionModels` already does exactly this for four other models and says why (`SessionModels.swift:18-24`).
- **Effort:** a function. **Confidence:** certain for the double instance; the user-visible effects are worth checking (log `ObjectIdentifier` of the model in `StackView.task` and in `RootView.task`). **Lens:** 3 optimisation / 8 crash-risk-adjacent (state lands on the wrong object).

### F6 — Stored filters are applied in a Task that races the first feed
- **What:** `applyStoredFilters` fires an unstructured `Task` that awaits four repository actor calls in sequence. `DiscoverView.task` → `repository.feed(...)` can interleave after the first await.
- **Where:** `AppServices.swift:217-225`; `SeriesRepository.swift:441-445` (`init(client:database:clock:contentRatings:formats:defaults:)` already takes ratings and formats).
- **Why it matters:** a reader with novels turned off or a blocked tag can get a first Discover feed fetched under defaults, and that response is cached under the feed's `cacheKey` (`SeriesRepository+Cache.swift:231-234`) — if the key does not include formats/blocked tags the wrong rows persist for the cache TTL. The window is microseconds; it is the kind of race that shows up once a month as "novels came back".
- **Fix:** pass `contentRatings: store.preferences.queryValues, formats: formatStore.preferences.queryValues` into `SeriesRepository.init` at `AppServices.swift:72`, add a `blockedTags:` parameter, and do the same for `LibraryService.init` (it already takes `contentRatings`). Keep only `updateLibraryExclusion` in a Task (it genuinely needs the profile id). Delete `applyStoredFilters`.
- **Effort:** a function. **Confidence:** worth checking (whether `cacheKey` folds in formats/blocked ids decides how bad it is — Persistence slice). **Lens:** 1 bug / 3 optimisation.

### F7 — `onOpenURL` bypasses the cancellation path and accepts negative ids
- **What:** the URL handler spawns `Task { await openSeries(id:) }`; the intent path goes through `.task(id: bridge.pendingSeriesID)` and gets cancellation. `seriesID(from:)` returns any `Int`, including `-5` and `0`.
- **Where:** `RootView.swift:160-164`; `SeriesWebLink.swift:44-48`; `RootView+Session.swift:211, 222` (`Task.isCancelled` guards that never trip for the URL path).
- **Why it matters:** two widget taps in quick succession can land the older series on top (gap 76, re-opened for links). `mangabaka://series/-5` costs one request against the shared 180/min budget and a "not available" toast — harmless, but free to close.
- **Fix:** `onOpenURL { url in if let id = SeriesWebLink.seriesID(from: url) { bridge.pendingSeriesID = id } }` — one entry point for Siri, widgets and links; and `guard id > 0` in `seriesID(from:)` (`SeriesWebLinkTests` gets one case).
- **Effort:** a line each. **Confidence:** certain. **Lens:** 1 bug / 6 load balancing.

### F8 — `Int(Double)` on a server number
- **Where:** `RootView+Session.swift:54` — `Int($0.activeSeriesCount)`; `CommunityPulse.swift:17` declares it `Double`.
- **Why it matters:** `Int(_: Double)` traps on NaN, ±inf and anything above 2⁶³; `Int(wholeOrClamped:)` exists for exactly this (`Int+Clamped.swift:41`) and the brief names it.
- **Fix:** `Int(wholeOrClamped: $0.activeSeriesCount)`. **Effort:** a line. **Confidence:** certain by standard (the API is unlikely to send it; the rule is the rule). **Lens:** 8 crash risk.

### F9 — 939 sequential actor hops on the launch path for links that are rarely cached
- **What:** `refreshReminders` loops every library entry and awaits `repository.cachedExtras(for:)` one at a time — each an actor hop plus a SQLite read and JSON decode (`SeriesRepository.swift:783-785`, `try? readDetailCache`).
- **Where:** `RootView+Session.swift:268-271`.
- **Why it matters:** the detail cache only holds series opened in the last six hours, so on a typical launch this is ~939 misses. Even at 0.2 ms each it is ~200 ms of the app's ~300 ms own launch share, on the main task chain ahead of the Spotlight reindex. Not measured — the file has no signpost around it.
- **Fix:** add `cachedExtrasLinks(for ids: [Int]) -> [Int: [SeriesLink]]` to the repository: one actor hop, one `SELECT ... WHERE seriesId IN (...)`. Wrap the call in `Signposts.measure("Reminder links")` so the before/after is a number.
- **Effort:** a function. **Confidence:** certain that it is 939 hops; the ms cost is a guess until signposted. **Lens:** 7 speed.

### F10 — Keychain read on every RootView body pass while Settings is open
- **Where:** `SettingsView.swift:108` (`State(initialValue: store.read() != nil)` — the initialiser runs every time the view is constructed even though `@State` keeps the first value); `RootView+Session.swift:78-94` (the `navigationDestination(isPresented:)` closure rebuilds `SettingsView` on each `RootView` body evaluation while presented).
- **Why it matters:** `SecItemCopyMatching` is an IPC round trip (~1 ms). `RootView` re-evaluates on every toast, path or selection change. Not a crash, a hitch source that scales with how often the root redraws.
- **Fix:** initialise `storedTokenExists` to `false` and set it in the existing `.task` (`:167`) before the guard. **Effort:** a line. **Confidence:** likely. **Lens:** 7 speed.

### F11 — Glass shadow computed, then clipped away
- **What:** `Glass.floating` adds a `.shadow(radius: 17, y: 14)` (`Glass.swift:30`); the toast puts it in `.background` and then `.clipShape(Capsule())` on the composed view, which clips the background's shadow to the capsule — i.e. removes it.
- **Where:** `Toast.swift:135-136`; `Glass.swift:26-31`. `WhatsNew.swift:125` and `StackView.swift:415` use the same helper (not checked for a following clip).
- **Why it matters:** a 17pt-radius shadow is rendered offscreen on every toast frame and never seen (charter 3). Also `.glassEffect` already draws its own rim; the extra 0.5pt `strokeBorder` and the shadow are hand-rolled on top of the system's material (charter 6).
- **Fix:** drop `.clipShape` on the toast (`glassEffect(in:)` already shapes the surface), or drop the shadow from `Glass.floating` and let the system material carry depth. Check on device which the mockup wants.
- **Effort:** a line. **Confidence:** likely (clipShape clips the whole modified view including background). **Lens:** 3 optimisation / 6 hand-rolling.

### F12 — `ScrollEdge` walks the window hierarchy per scroll sample
- **Where:** `ScrollEdge.swift:36-42` (`windowTopInset` iterates `connectedScenes`/`windows` on every read), `:74, :81` (read twice per `scrim` evaluation), `:61-63` (`withAnimation` per scroll geometry callback — a new animation transaction for every sample even after `travelled` is past 12pt and the opacity is pinned at 1).
- **Why it matters:** `scrim` re-evaluates every time `travelled` changes, which is every scroll tick. The safe-area inset does not change while scrolling. Small, but it is on the hot path of the three busiest screens.
- **Fix:** read `windowTopInset` once into `@State` in `onAppear`; in the geometry action, `guard min(offset, fadeIn) != min(travelled, fadeIn)` before animating so nothing runs once the scrim is fully in.
- **Effort:** a function. **Confidence:** certain. **Lens:** 7 speed. (See §Charter 6 for whether this file should exist.)

### F13 — `Motion.isReduced` and `DispatchQueue.main.sync`
- **Where:** `Motion.swift:27-36`.
- **Is the off-main path reachable?** In production: no. Every caller is a view body, a modifier, an `onAppear`/`onChange`, or a default argument evaluated at a main-actor call site (`MotionModifiers.swift:23, 96, 125, 160`; `WrappedShapes.swift:117, 157`; `LibraryControl.swift:402`; `DetailBackdrop.swift:47`). The only off-main caller is `MotionTests.swift:52`, which is what the branch was written for.
- **What happens if it is reached:** `DispatchQueue.main.sync` from a cooperative-pool thread blocks that thread until the main queue drains. Deadlock only if the main thread is itself synchronously waiting on that pool thread — nothing in the app does that. So: not a crash, a latent hazard that exists to make a test convenient.
- **Fix:** make `isReduced` `@MainActor` and drop the `Thread.isMainThread`/`sync` branch; the two defaulted parameters (`arrival(index:isReduced:)`, `reduced(_:isReduced:)`) become `@MainActor` too, or lose the default and take an explicit `isReduced:` (tests already pass it). Better still, follow the four modifiers that already read `@Environment(\.accessibilityReduceMotion)` (`Motion.swift:109, 133`, `PressStyle.swift:15`, `Skeleton.swift:12`) — the platform's value, observed, no UIKit — so there is one mechanism, not two.
- **Effort:** a file. **Confidence:** certain. **Lens:** 9 bad practice / 4 better way.

### F14 — `ScaledFont` type-erases every text style in the app
- **Where:** `Typography.swift:31-39` — `AnyView(styled.lineSpacing(...))` / `AnyView(styled)`.
- **Why it matters:** every `Text` in the app goes through this modifier; `AnyView` defeats structural identity and can force fuller re-diffing under it. Unmeasured; the fix is free.
- **Fix:** `@ViewBuilder func body(content:)` with `if let lineSpacing, lineSpacing > 0 { styled.lineSpacing(lineSpacing) } else { styled }`.
- **Effort:** a function. **Confidence:** certain that it is avoidable; the cost is worth checking with Instruments. **Lens:** 7 speed.

### F15 — Colours that duplicate what the platform already resolves to
- **What:** the app pins `.preferredColorScheme(.dark)` (`RootView.swift:316`), so semantic colours resolve to their dark values everywhere. Several `Palette` entries are those exact values: `textSecondary` = `#EBEBF5` @ 0.60 is `UIColor.secondaryLabel` (dark) bit-for-bit (`Palette.swift:38`); `switchOff` `#2C2C2E` is `systemGray5` (dark) (`:68`); `textPrimary` white @ 0.96 is a hair off `.label` (white @ 1.0). Others are deliberately different (`textTertiary` 0.45 vs system 0.30; `textQuaternary` 0.32 vs 0.18; `ground` `#08080B` vs `.systemBackground` black).
- **Why it matters:** where the values coincide, `Color(.secondaryLabel)` costs the mockup nothing and gains Increase Contrast, Smart Invert and Differentiate Without Colour for free. Where they differ, the mockup wins and the token stays.
- **Fix:** replace `textSecondary` with `Color(.secondaryLabel)`, `switchOff` with `Color(.systemGray5)`; leave the rest. Record in `Palette.swift` which tokens are intentional departures from the system ramp and by how much.
- **Effort:** lines. **Confidence:** certain on the values. **Lens:** 6 hand-rolling.

### F16 — A failed history count reads as "Nothing viewed yet"
- **Where:** `HistorySection.swift:107` (`(try? await history.count()) ?? 0`), `:100` (0 → "Nothing viewed yet", and the button disables).
- **Fix:** keep `held` as `Int?`; on `nil` show "Couldn't read the list" and leave the button enabled. **Effort:** a line. **Confidence:** certain. **Lens:** 2 errors.

### F17 — The previous account's display name survives sign-out
- **Where:** `SettingsView.swift:207-219` removes `lastCheckedAtKey` (`:212`) but not `lastCheckedNameKey`; same at `:346-348` on rejection.
- **Why it matters:** the name is a plain `UserDefaults` string, not a secret, but it is account-scoped data left behind after "Remove token" — the one thing `forgetPreviousAccount`'s comment says the list is for.
- **Fix:** remove both keys in both places (a `forgetCheck()` helper next to `rememberCheck`). **Effort:** a line. **Confidence:** certain. **Lens:** 9 bad practice (privacy).

### F18 — `FlowLayout` measures every chip three times per pass
- **Where:** `FlowLayout.swift:14-21` and `:29-34` both call `arrange` (`:56-62`), which calls `subviews[i].sizeThatFits(.unspecified)` for every subview; `placeSubviews` then measures each again at `:34`. The `cache: inout ()` is unused.
- **Fix:** use the `Layout` cache to hold the measured sizes; `makeCache`/`updateCache`. **Effort:** a function. **Confidence:** certain. **Lens:** 3 optimisation (tag groups on the series page are the widest user; chips ≤ ~40, so small).

### F19 — Unlabelled constants
- `SettingsRow.swift:87` `minHeight: 63` — no derivation, no guess label (charter 4). `Metrics.scrollBottomInset = 124` (`Metrics.swift:139-149`) is derived from "the bar is about 62pt and sits ~22pt from the bottom" for the *hand-drawn* capsule that no longer exists (`RootView.swift:284-293` says the system bar is used now). See F20.
- **Fix:** label 63 a guess or derive it (row padding 24 + two lines of the ramp); re-derive 124 against the system bar. **Effort:** lines. **Confidence:** certain. **Lens:** 9.

### F20 — Bottom inset may now be doubled under the system tab bar — worth checking
- **What:** a `ScrollView` inside a `TabView` already receives the tab bar as a bottom safe-area inset on iOS 26. Sixteen sites add `Metrics.scrollBottomInset` (124pt) on top (`Metrics.swift:139-149`; used in `DiscoverView`, `LibraryView`, `MixView`, `ScheduleView`, `SettingsView`, `ShelfDetailView`, `ReadingInsightsView`, `WrappedView`). Neither Discover nor Library ignores the bottom safe area (grep found no `ignoresSafeArea` there).
- **Why it matters:** if both apply, every screen ends with ~100pt of blank ground below its last row — the mockup does not draw that. If the scroll content ignores the safe area somewhere I did not read, the 124 is right.
- **Fix:** one screenshot of the bottom of Discover scrolled to the end; if doubled, delete the padding on the eight scroll views and keep it only on the toast (`Toast.swift:159`, which is an overlay on the `TabView` and does need it).
- **Effort:** lines. **Confidence:** worth checking. **Lens:** 6.

### F21 — "Settings" drawn twice — worth checking
- **Where:** `SettingsView.swift:114` (36pt `typeScreenTitle` in content) and `:149-150` (`.navigationTitle("Settings")` with `.inline`).
- **Why it matters:** an inline bar title plus a large in-content title is the screen name twice on one screen. If the pushed siblings do the same, it is a convention worth deciding once; if not, drop one.
- **Fix:** keep the bar title (it gives the system scroll edge, which `:148` asks for) and delete the in-content `Text`. **Effort:** a line. **Confidence:** worth checking (screenshot). **Lens:** 6.

### F22 — `AniList` is contacted on every launch before the reader does anything
- **Where:** `RootView.swift:149` (`.task { await characters.primeAniListHealth() }`); `CharacterService.swift:208-218`; `AniListClient.swift:528-535` (a POST to graphql.anilist.co).
- **Why it matters:** one third-party request per cold launch, for a feature (cast lists) most launches never reach; the reader's IP goes to AniList whether or not they open a series. The privacy manifest question is the owner's (CLAUDE.md "Open questions"), but at minimum it is launch work spent on first-use data.
- **Fix:** move the prime to the first `characters.cast(for:)` call (the outage memory is 15 minutes; the first cast fetch pays the timeout once instead of every launch paying a request). **Effort:** a function. **Confidence:** certain about the request; the privacy weight is a judgement. **Lens:** 3 optimisation / privacy.

### F23 — Per-body work in `RootView`
- `RootView.swift:212` — `ReadingInsights.chaptersRead(in: session.library.entries)` reduces ~939 entries on every `RootView` body pass (every toast, selection or path change). `:136-139` builds two `Set`s per pass. Microseconds each; listed so nobody adds a third.
- **Fix:** compute `chaptersRead` inside `LibraryModel` when `entries` changes and expose it. **Effort:** a line. **Confidence:** certain. **Lens:** 3.

### F24 — `CoverFrame`'s per-cover shadow — worth checking
- **Where:** `CoverImage.swift:178` (`.shadow(color: .black.opacity(0.5), radius: 10, y: 8)` on every cover, after `.clipped()` and `.clipShape`).
- **Why it matters:** `CoverGloss`'s comment (`:184-186`) argues it costs the same on sixty cards as on one because it samples nothing; the shadow beneath it does not have that property — a `.shadow` forces an offscreen render per view. Sixty covers in a Discover row is sixty offscreen passes per frame while scrolling.
- **Fix:** measure first (Instruments → Core Animation, "Color Offscreen-Rendered"); if it shows, draw the shadow as a second `RoundedRectangle` in the `background` with `.compositingGroup()` or drop `y: 8`.
- **Effort:** a line. **Confidence:** worth checking. **Lens:** 7 speed.

### F25 — `handlePicked` reads the import file synchronously on the main actor
- **Where:** `LibraryTransferSection.swift:80` (`Data(contentsOf: url)` in a `@MainActor` method). A multi-megabyte MAL XML hitches the sheet. **Fix:** read in a detached task. **Effort:** a line. **Confidence:** certain. **Lens:** 7.

---

## Charter 6 — the hand-built list, one by one

Does iOS 26 provide it, and what does the system version cost the mockup?

| Hand-built | System equivalent on iOS 26 | Cost to the mockup | Verdict |
|---|---|---|---|
| Scroll edge scrim — `ScrollEdge.swift` (102 lines, a window walk, a scroll observer, a gradient, `ScrollEdgeTests`) | The scroll edge effect on any `ScrollView` under a navigation bar or toolbar; `.scrollEdgeEffectStyle(.hard/.soft, for: .top)` tunes it. Settings already uses it (`SettingsView.swift:148`). **Not** provided for a bar-less `ScrollView`, which is what the three tab roots are | A real bar. With `.navigationTitle` in `.large` mode the title becomes the system's 34pt bold, not the mockup's 36pt/-1.2 tracking; with `.inline` and the mockup's title left in content, an empty ~44pt bar band sits above the 24pt `scrollTopInset`. Unverified alternative: a zero-height `.safeAreaInset(edge: .top)` may be enough to trigger the effect with no visible bar — the one experiment worth an hour | Take the bar. The README is right that this is the biggest free upgrade; F12 shows the hand version also costs per scroll tick |
| Title fade — `DetailBarTitle.swift` (Detail slice; 55 lines, own observer) | `.navigationTitle` + `.navigationBarTitleDisplayMode(.large)`: large title collapses to inline as you scroll | The large title style is the system's; the hero layout below it is untouched. Detail is a pushed screen and already has a bar | Take it |
| Clear button — `SearchClearButton.swift` | Free inside `.searchable` (which `BlockTagPicker` uses, `:182`). SwiftUI's plain `TextField` has no `clearButtonMode` | Only if the three inline fields (`LibraryView:287`, `ShelfDetailView:80`, `PublisherBrowser:27`) move into the navigation bar, which the mockup does not draw | Keep. Correctly hand-built for an inline field |
| 44pt targets — `TapTarget.swift` | `List`/`Form` rows are 44pt; a `.bordered` button with `.controlSize(.large)` is ≥44 visually. There is no system modifier that grows the hit area without growing the control | The mockup's 30pt chips would become 44pt pills | Keep. The 19-line modifier is the right tool for "look 30, hit 44" |
| Reduce Motion — `Motion.swift` | `@Environment(\.accessibilityReduceMotion)`; SwiftUI does **not** auto-suppress `withAnimation`, so a `reduced()` helper is genuinely needed | None | Keep the helper; drop the UIKit static and the `DispatchQueue.main.sync` (F13). Four modifiers already use the environment; make it five for five |
| Glass — `Glass.swift` | `.glassEffect(.regular, in:)` — already used | None; the system material *is* the mockup's ask (`Glass.swift:5-9`) | Keep, minus the extra stroke and shadow (F11) |
| Switch — `SwitchIndicator` (`SettingsRow.swift:108-149`) | `Toggle` with `.tint(Palette.accent)`. 51×31 is the system's own metric, as the file says | None — once the row stops being a `Button` (S-F21's root cause). `Toggle(isOn:) { SettingsRow(...) }` makes the whole row the label and tappable | Already recorded; still unfixed at `SettingsView.swift:275-296`, `FormatSection.swift:50-62`, `RemindersSection.swift:23-41`. Gains: `.isToggle` trait, system haptic, Increase Contrast |
| Tab bar | Already the system's (`RootView.swift:284-293`) with `TabRole.search` | — | Done; the file records why. Good |

**On `docs/apple-experiment/README.md`:** its argument is sound where it says the wins come from the containers, not the colours. Two places I disagree:
1. "There is no light mode and there cannot be one without redoing the palette." Half true — but because the app *pins* dark, semantic colours would resolve to dark values everywhere and cost nothing (F15). The README frames semantic colours as a light-mode enabler; their real, immediate value here is Increase Contrast and Smart Invert on the pinned dark scheme.
2. "`.font(.caption)` would have been correct the whole time." `Typography.swift:61-81` measured that `.caption2` stalls across four content sizes; `.caption` (`caption1`) stalls across three of them by that same table. The README's alternative has the defect the ramp was built to avoid; the ramp is right and the README is wrong on this line.

The honest middle it proposes — real navigation bars on the tab roots, everything else custom — I agree with, with one addition: the bar is also what makes `ScrollEdge.swift` and its per-tick work (F12) deletable.

---

## Launch — what runs, what it costs, what could wait

Cold launch ~900 ms, 598-634 ms framework/linker (owner's number). The app's own share ~300 ms. Nothing below was measured by me; the signposts that exist are named so the next person can.

**Before the first frame (`MangaBakaApp.swift:13` → `AppServices.init`, signpost "Services"):**
- `URLCache.shared = URLCache(memory: 32 MB, disk: 256 MB)` — `AppServices.swift:190-195`. Creating a disk `URLCache` opens its SQLite index synchronously. Deferrable? No — it must precede the first image request; but it could be set in `MangaBakaApp.init` off the signposted path so the signpost measures only the app's objects.
- `AppDatabase.onDiskResettingIfCorrupt()` — signpost "Database open" (`:178`). Unavoidable, unbounded on a migration.
- Eleven `UserDefaults`/file decodes in initialisers: `SearchLensStore` (`SearchLens.swift:57-60`), `RecentSearches`, `BlockedTagsStore`, `ContentPreferencesStore`, `FormatPreferencesStore`, `ReleaseReminders`, `PublisherFollows` (`PublisherFollows.swift:63` reads a file), `OnboardingState`. Each is small; together they are the "Services" number. Deferrable: `SearchLensStore`, `RecentSearches` (Search tab only), `PublisherFollows` (Settings/reminders only) — make them `lazy` on `AppServices` or build them in the Search tab's own `.task`.
- `EmbeddingIndex()`, `OfflineCatalogue()` — lazy per their comment (`:34-37`). Good.
- `applyStoredFilters` — an unstructured Task (F6); zero cost if folded into `init`.

**After the first frame (`RootView.swift:141-149, 299-313`, `RootView+Session.swift:148-187`):**

| Step | Where | Cost | Defer to |
|---|---|---|---|
| Six model constructions + `taste.ranker()` (walks the library, cached after the first walk) | `RootView.swift:299-313` | one library walk if uncached; otherwise a DB read | Move construction to `init` (F5); keep the ranker fetch |
| `primeAniListHealth` | `RootView.swift:149` | one POST to AniList, up to 20 s timeout in the background | First cast fetch (F22) |
| Onboarding covers fetch | `RootView+Session.swift:160-162` | one feed request, only pre-onboarding | Fine |
| `refreshReminders` when disabled | `:248-251` | `reschedule(announced: [])` — cheap | Fine |
| `refreshReminders` when enabled | `:253-279` | `calendar.mine` (one request), `librarySnapshot.load()` (walk or disk cache), `publisherFollows.check` (up to one **search** per follow per day — the 30/min budget), 939 `cachedExtras` hops (F9), `reschedule` | Everything after the walk could run at `.utility` off the launch chain; the follows check should wait for `scenePhase == .active` + a few seconds |
| Second `librarySnapshot.load()` | `:180` | free (cached) | Fine |
| `spotlight.reindex` | `:182` | measured 84 ms, detached `.utility` (`SpotlightIndex.swift:42-44`) | Fine — already off the main actor |
| `history.lastOpenedDates()` + `WidgetSnapshot.write` | `:183-186` | one DB read, one file read+write, one WidgetKit reload | Skip when unchanged (F3) |
| **Missing:** `session.library.load()` | — | free after the walk | Add (F1) |

The one measurement that would order this list: a `Signposts.measure` around each `startSession` step, one cold launch, read in Instruments. Every step above except Spotlight has no interval today.

---

## The rest of the nine lenses, briefly

- **Composition root and lifetimes** (`AppServices.swift`): everything is a `let`, built once, main-actor. `IntentBridge.shared` is the only singleton and its comment justifies it (`IntentBridge.swift:9-10`). `CoverStore.shared`, `BlurHashCache.shared`, `NetworkLedger.shared` are reached from `Features/Shared` directly (`CoverImage.swift:29, 112`; `CopyableArtwork.swift:54`; `DataUseSection.swift:137-140`) rather than through `AppServices` — acceptable for caches, but it means `AppServices`' "nothing reads from it at runtime" (`:10-11`) is true only because those four bypass it.
- **Environment in a hot path:** `CoverImage.swift:21` reads `displayScale` per body — fine. `ZoomSourceMark` reads the namespace per cover — fine. `RootView.swift:131-139` writes three environment values per body pass; `TagAudience` is rebuilt (two `Set`s) each time — see F23.
- **Toast centre:** one instance, `@State` at the root, also in the environment (`RootView.swift:294-298`); every reader treats it as optional. Good. Bug: F4.
- **Token/Keychain:** no `print`, `Logger`, `NSLog` or `dump` anywhere in the slice or in `Core/Auth` (grepped). The token is entered in a `SecureField` (`AccountCard.swift:250`), cleared from `@State` on acceptance (`SettingsView.swift:344`), stored `AfterFirstUnlockThisDeviceOnly` (`TokenStore.swift:48`), only cleared on a real rejection (`SettingsView.swift:327-336`). The one leak is the display name (F17). The Debug PAT path is in `Configs`, not this slice.
- **Export/import:** F2 (cost on open), F25 (sync read). The preview and the confirmation name the consequence (`LibraryTransferSection.swift:279-290`). The apply loop spaces requests (`LibraryImport.swift:426`) — I did not read the spacing value; see "could not determine".
- **Force-unwraps reachable from input:** none in the slice. The two `preconditionFailure`s guard compile-time literals (`AppServices.swift:234-238`, `LibraryTransferSection.swift:166-171`). `Int(...)` on text: `SeriesWebLink.swift:47, 53` — `Int.init(String)` returns nil on overflow, no trap. `Int(remaining.rounded())` in `Countdown.swift:46, 49` is bounded by the `< 60` branch and a finite check. F8 is the one exception.
- **Unbounded memory:** none owned by this slice (`URLCache` capped; `CoverStore` is an `NSCache`).
- **Unreachable code that looks alive:** `SettingsView.init`'s `publisherFollows` default (`:84`) and `RemindersSection.publisherFollows` default (`RemindersSection.swift:15`) both construct a file-reading `PublisherFollows()` — only when the argument is omitted, which `RootView` never does; previews would. Not dead, but two defaults that silently make a *second* follows store if anyone forgets to pass one. Worth a `// previews only` comment or removing the default.
- **Tests that agree with the bug:** `ToastTests` cannot see F4 (same value both times); `ScrollEdgeTests` tests `opacity(forTravel:)`, not the window walk. Neither is wrong; both are narrower than the behaviour.

---

## Widget App Group and the `mangabaka://` scheme

- **Entitlement:** `Configs/MangaBaka.entitlements` and `Configs/MangaBakaWidgets.entitlements` both carry `group.dev.abdirahmanmohamed.mangabaka`; `WidgetSnapshot.appGroupID` (`WidgetSnapshot.swift:46`) is the same string; `project.yml:102, 135` wire each file to its target. Consistent. `containerURL` nil (unprovisioned profile) is handled by returning silently (`:80, :95`) — the widget shows its placeholder, the app says nothing; the comment at `:39-45` records that the signing side is unverified. Nothing to fix; one thing to confirm on a device build (see below).
- **Scheme:** registered at `project.yml:79-81`; parsed at `SeriesWebLink.swift:44-48` — scheme match, host must be `series`, first numeric path component. Non-numeric, missing, oversized (`Int` overflow → nil) and traversal-shaped paths all return nil. A crafted link can therefore do exactly one thing: open the series with that id, costing one `/v1/series/<id>` request and, on failure, a toast (`RootView+Session.swift:214-221`). Safari asks the user before opening a custom scheme, so a web page cannot fire it in a loop. Nothing is written, nothing is trusted from the URL beyond an integer. **Residual:** negative/zero ids reach the API (F7); and the `https://mangabaka.org/...` branch (`:49-53`) accepts any numeric path such as `/user/12345`, but it is dormant until the association file exists (`:14-17`).
- **Verdict:** cannot be abused beyond one wasted request per user-confirmed tap. Add `guard id > 0`.

---

## What the slice does well

- `RootView.swift:284-293` and `Glass.swift:5-9`: the tab bar and the glass are the system's, and each file records what hand-drawing them had cost. That is the charter-6 discipline applied, not just described.
- `AppServices.swift:165-184` closes failures-shell gap 3 exactly as proposed, and `RootView+Session.swift:153-159` tells the reader in one sentence what was lost and what was not.
- `RootView+Session.swift:113-141`: every account-scoped store is forgotten in one place, with the history of how the list was assembled — the comment *is* the test that the list is complete.
- `Typography.swift:61-81`: a measured table (four anchors, every content size) behind a ramp decision, with the cost at the top of the range stated. This is why the README's `.caption` claim can be checked in thirty seconds.
- `Toast.swift:40-53`: a `.failure` cannot be overwritten by a `.success` inside its window, and the 4 s is labelled a guess with the reason.
- `SettingsView.swift:308-336`: a token is deleted only on MangaBaka's own rejection; offline, 429 and 500 leave it alone. `TokenStatus` has the fourth and fifth states (`unverified`, `notStored`) that make that possible, each with the gap number that earned it.
- `SeriesWebLink.swift:44-54`: the parser is total — every input returns `Int?`, none traps — and `SeriesWebLinkTests` exists.
- `SpotlightIndex.swift:41-51`: the one launch step with a measurement (84 ms, 941 entries, 2026-09-11) is also the one already moved off the main actor.
- No logging of any kind in App, Shared, Settings, DesignSystem or Auth (grepped: zero hits for `print(`, `Logger`, `NSLog`, `debugPrint`, `dump(`).

---

## What I could not determine

1. **Whether Discover's in-progress row is really empty on a cold launch (F1).** One screenshot of Discover, cold, with an account that has in-progress series; or a breakpoint on `LibraryModel.load`.
2. **Whether the first feed can be cached under default filters (F6).** Read `FeedKind.cacheKey` (`SeriesRepository.swift:237`) — if it folds in formats and blocked ids, the race only costs one wrong fetch; if not, it caches.
3. **The ms cost of the 939 `cachedExtras` hops (F9)** and of `startSession` overall. One `Signposts.measure` per step, one cold launch on the 16 Pro simulator.
4. **Whether the bottom inset is doubled (F20)** and **whether "Settings" renders twice (F21).** Two screenshots.
5. **Whether the shadow on every cover shows in Core Animation's offscreen-render overlay (F24).** One Instruments run scrolling Discover.
6. **Whether a zero-height top `safeAreaInset` triggers the iOS 26 scroll edge effect on a bar-less `ScrollView`.** One build on a branch; it decides whether `ScrollEdge.swift` can go without taking a visible bar.
7. **Import request spacing.** `LibraryImport.swift:426` sleeps `requestSpacing` between writes; I did not read the value. A 312-entry import at less than 333 ms spacing exceeds 180/min. Library slice.
8. **App Group provisioning on a device/Xcode Cloud build** (`WidgetSnapshot.swift:39-45`). One archive; if `containerURL` is nil the widget is permanently a placeholder and the app never says so.

---

## Proposed fixes, by file (for the synthesis)

**MangaBaka/App/RootView.swift** — build the six models in `init` as non-optional `@State` (F5); delete the `??` fallbacks at 207/222/233/257/269 and the nil checks at 302-310; route `onOpenURL` through `bridge.pendingSeriesID` (F7); move `primeAniListHealth` out (F22); hoist `chaptersRead` into `LibraryModel` (F23).
**MangaBaka/App/RootView+Session.swift** — `Int(wholeOrClamped:)` at 54 (F8); add `await session.library.load()` after 181 (F1); batch the 268-271 loop into one repository call (F9); signpost each `startSession` step.
**MangaBaka/App/AppServices.swift** — pass stored ratings/formats/blocked ids into `SeriesRepository.init` and `LibraryService.init`; delete `applyStoredFilters` except the exclusion call (F6); make `SearchLensStore`, `RecentSearches`, `PublisherFollows` lazy.
**MangaBaka/Core/Library/WidgetSnapshot.swift:81-87** — `guard merged != existing` before write + reload (F3).
**MangaBaka/Core/Model/SeriesWebLink.swift:47, 53** — `guard id > 0` (F7).
**MangaBaka/Features/Shared/Toast.swift** — `revision` counter as the haptic/transition trigger (F4); drop `.clipShape` at 136 or the shadow in `Glass.floating` (F11).
**MangaBaka/Features/Shared/ScrollEdge.swift** — cache `windowTopInset`; stop animating once past `fadeIn` (F12); or delete the file once the tab roots have bars.
**MangaBaka/Features/Shared/FlowLayout.swift** — use the layout cache (F18).
**MangaBaka/Features/Shared/CoverImage.swift:178** — measure the shadow, then decide (F24).
**MangaBaka/Features/Settings/SettingsView.swift** — inject `library`/`loadExisting` into `LibraryTransferSection` (F2); `storedTokenExists` set in `.task` not `init` (F10); clear `lastCheckedNameKey` at 212 and 348 (F17); drop the in-content title if the bar's is visible (F21); `Toggle`-ify the three row types (S-F21, already recorded).
**MangaBaka/Features/Settings/LibraryTransferSection.swift** — load on tap, not on appear (F2); read the picked file off the main actor (F25).
**MangaBaka/Features/Settings/HistorySection.swift:107** — `Int?` with a failure line (F16).
**MangaBaka/DesignSystem/Motion.swift:27-36** — `@MainActor isReduced`, no `DispatchQueue.main.sync`; prefer the environment (F13).
**MangaBaka/DesignSystem/Typography.swift:31-39** — `@ViewBuilder`, no `AnyView` (F14); fix S-F14's leading while there.
**MangaBaka/DesignSystem/Palette.swift:38, 68** — `Color(.secondaryLabel)`, `Color(.systemGray5)`; annotate the deliberate departures (F15).
**MangaBaka/DesignSystem/Metrics.swift:139-149** — re-derive `scrollBottomInset` against the system bar (F19/F20).
**MangaBaka/Features/Settings/SettingsRow.swift:87** — label or derive 63 (F19).
