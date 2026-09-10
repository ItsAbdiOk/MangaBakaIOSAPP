# Every finding, 2026-09-11

From five passes: the iOS design review (static + real device), Apple's
accessibility audit, /health, /cso, device performance traces, and the two-axis
code review.

Ordered by what to do first. Each item names its evidence.

## A. Correctness — the app is telling the reader something untrue

- [ ] **A1. "Waiting for you" counts series you never opened.**
      `ReadingInsights.swift:36` takes `read = progressChapter ?? 0` with no
      `read > 0` guard, under a heading that says "chapters published since you
      stopped". On the device five of eight visible rows were `ch 0` — "The
      Devil Butler, ch 0 of 889, 889 behind". Require a started series; test it.
- [ ] **A2. The season threshold is an underived guess and misreads volume splits.**
      `SeasonReading.swift:47`: `currentLowest < previousHighest / 2`. A print
      volume ending at chapter 20 followed by one starting at 9 is called a new
      season. CLAUDE.md requires an underived constant be labelled a guess; the
      comment explains the intent but never says the number was not derived.
      Either derive it against real MangaUpdates data or label it honestly.
- [ ] **A3. "Original language" can silently show English.** `DisplayTitle.matching`
      falls through when a series has no native-tagged title, with nothing on
      screen saying the preference could not be honoured.

## B. It looks unfinished the moment anyone scrolls

- [ ] **B1. Nothing in the app has a scroll edge.** Content runs under the status
      bar, the Dynamic Island and the navigation bar with no blur and no scrim.
      Three sightings on the phone: a Library row title cut in half by the
      Dynamic Island with the clock over the words; the series detail's large
      title and nav title rendered on top of each other with cover art through
      both; a row ghosting behind the "Your reading" title. Cause: the four tab
      roots draw their own title inside the ScrollView with a flat 24pt padding
      and no navigation bar (`DiscoverView:76`, `SearchView:57`, `MixView:56`,
      `LibraryView:93`); the pushed screens have bars but no `toolbarBackground`.
      Highest-leverage fix in the whole list.
- [ ] **B2. The series page shows two titles at once** — the inline navigation
      title and the large title, before any scrolling.
- [ ] **B3. Library rows end in a dim em dash** for an unrated series: invisible
      at `textQuaternary`, and meaningless on its own.
- [ ] **B4. The disabled Blend button is the live one at 40% opacity**
      (`MixView:194`) — Apple's audit reports it as an outright contrast failure.
- [ ] **B5. The schedule's first run is a dead screen**: "Not measured yet",
      "0 ESTIMATED OF 0 IN SCOPE", and 60% empty. Nothing says what Measure will
      do or that MangaUpdates is rate-limited to one request every three seconds.
- [ ] **B6. The tag-breadth bar has no legend.** A 44x3pt orange bar per row; a
      reviewer looking straight at it concluded it was a broken slider.
      VoiceOver is told what it means and a sighted reader is not.
- [ ] **B7. Three same-weight accent links** on Search idle: "Browse",
      "Surprise me", "Clear" — no hierarchy between them.
- [ ] **B8. "Clear all" wipes every filter with no undo and no confirmation.**

## C. Accessibility — 86 issues from Apple's own audit

- [ ] **C1. Contrast.** 47 issues. `textQuaternary` measures **2.52:1** on the
      app's ground, which fails AA even for large text, and it is used at
      10.5-12.5pt in 26 places. Clearing 4.5:1 needs alpha >= 0.49 against 0.32
      today. NEEDS A DECISION: collapsing the tiers changes the mockup's look.
- [ ] **C2. Text clipped at its CURRENT size** (not just large type): the meta
      line under every cover card, "Manga · 7.0", "Manhwa · 8.7". 4 on Discover.
- [ ] **C3. Dynamic Type only partially supported** on 15 elements. Cause not yet
      understood: they use `typeGridMeta`, which IS declared relative to
      `.caption2`. Investigate before changing anything.
- [ ] **C4. Hit areas under 44pt**, named by Apple: the six Library state chips
      ("Reading, 71 series" … "Dropped, 429 series"), "Sort by Recently updated",
      the state legend, and the token field. All pinned to `Metrics.headerPill`
      = 30pt. NEEDS A DECISION: 30pt is the mockup's number.
- [ ] **C5. The mix seed "+" and "x" carry no VoiceOver label**, and are 41pt and
      roughly 17pt.
- [ ] **C6. Reduce Motion is honoured by 1 of 15 animating surfaces** (the swipe
      stack). The gallery glide, tag expand, toast, library shape change and
      settings disclosures all ignore it.

## D. Tests — the weakest part of this week's work

- [ ] **D1. `FlowAffordanceTests` are source greps, not tests.**
      `#expect(source.contains("SearchClearButton"))` proves a call site exists;
      a stub would pass. Copy-artwork, clear-button, edge-swipe and seed-picker
      are effectively untested. Replace with behavioural tests.
- [ ] **D2. `ReleaseSchedule.swift` is 10.6% covered across 312 lines** — the
      cadence estimator that prints "38 days overdue" on series pages.
- [ ] **D3. `TagSearch.swift` 15.4%** — only the pure merge is covered; the
      debounce and the failure path are not.
- [ ] **D4. `TasteProfile` 47.7%, `ReleaseReminders` 54%.**

## E. Release compliance

- [ ] **E1. `PrivacyInfo.xcprivacy` declares nothing while 11 files use
      UserDefaults.** App Store Connect answers ITMS-91053 on upload; Apple has
      said it becomes a rejection. Add `NSPrivacyAccessedAPICategoryUserDefaults`
      with reason `CA92.1`. Verified: no other required-reason API is used.

## F. Performance

- [ ] **F1. Cold launch ~900 ms** (867/932 cold, 217 warm) against Apple's 400 ms
      guidance. 598-634 ms of it is framework and linker work before
      `didFinishLaunchingWithOptions`, which took 0.08 ms. The lever is needing
      less at launch, not running our launch code faster.

## G. Code quality — judgement calls, none blocking

- [ ] **G1.** `TagPickerSheet` and `BlockedTagsSection` each bootstrap `TagSearch`
      and carry the same empty-state copy.
- [ ] **G2.** `waiting`/`nearlyFinished` repeat the same chapter maths;
      `chaptersRead`/`hoursRead` each re-derive the completed-series rule.
- [ ] **G3.** `SeedPickerSheet` writes the same `Binding(get:set:)` twice.
- [ ] **G4.** Four forwarding properties in `ReadingInsightsView`.
- [ ] **G5.** `Metrics.gutterStatus` and `Metrics.backButton` have zero uses.

---

## H. The six unknowns — investigate, then fix, BEFORE the final push

Decided 2026-09-11: these are not deferred. Each is investigated until the cause
is known, then fixed like any other finding. An investigation that ends without
an answer is recorded as a negative result with the reason, per CLAUDE.md.

- [ ] **H1. Six screens were never audited on the device**: shelf detail, the Library
      : shelf detail, the Library
      inline search with results, the cover gallery, Settings, the blocked-tags
      screen, and a mid-drag Stack card.
- [ ] **H2. Why series titles fail contrast.** Apple flags "ONE PIECE", "Solo Leveling",
   "RUNAWAY FAMILY" — all `textPrimary`, which measures 18:1 against the ground.
   The audit is evidently measuring against what is really behind them. Reproduce
   before touching it.
3. **Why Dynamic Type is only "partially" supported** on those 15 elements.
4. **On-device memory.** `xctrace --template Allocations --launch` recorded no
   allocation tables; that instrument needs Instruments' own launch config. The
   99.3 MB peak figure is from the simulator.
5. **Dead code.** No Periphery installed, so the only dead code found was two
   metrics spotted by hand.
6. **Whether the tab bar restores on scroll-up.** It did not under mouse-wheel
   scrolling through the mirror, which is likely an artefact. Needs a finger.
