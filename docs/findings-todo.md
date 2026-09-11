# Every finding, 2026-09-11

From five passes: the iOS design review (static + real device), Apple's
accessibility audit, /health, /cso, device performance traces, and the two-axis
code review.

Ordered by what to do first. Each item names its evidence.

## A. Correctness — the app is telling the reader something untrue

- [x] **A1. "Waiting for you" counts series you never opened.**
      `ReadingInsights.swift:36` takes `read = progressChapter ?? 0` with no
      `read > 0` guard, under a heading that says "chapters published since you
      stopped". On the device five of eight visible rows were `ch 0` — "The
      Devil Butler, ch 0 of 889, 889 behind". Require a started series; test it.
- [x] **A2. The season threshold is an underived guess and misreads volume splits.**
      `SeasonReading.swift:47`: `currentLowest < previousHighest / 2`. A print
      volume ending at chapter 20 followed by one starting at 9 is called a new
      season. CLAUDE.md requires an underived constant be labelled a guess; the
      comment explains the intent but never says the number was not derived.
      Either derive it against real MangaUpdates data or label it honestly.
- [x] **A3. "Original language" can silently show English.** `DisplayTitle.matching`
      falls through when a series has no native-tagged title, with nothing on
      screen saying the preference could not be honoured.

## B. It looks unfinished the moment anyone scrolls

- [x] **B1. Nothing in the app has a scroll edge.** Content runs under the status
      bar, the Dynamic Island and the navigation bar with no blur and no scrim.
      Three sightings on the phone: a Library row title cut in half by the
      Dynamic Island with the clock over the words; the series detail's large
      title and nav title rendered on top of each other with cover art through
      both; a row ghosting behind the "Your reading" title. Cause: the four tab
      roots draw their own title inside the ScrollView with a flat 24pt padding
      and no navigation bar (`DiscoverView:76`, `SearchView:57`, `MixView:56`,
      `LibraryView:93`); the pushed screens have bars but no `toolbarBackground`.
      Highest-leverage fix in the whole list.
- [x] **B2. The series page shows two titles at once** — the inline navigation
      title and the large title, before any scrolling.
- [x] **B3. Library rows end in a dim em dash** for an unrated series: invisible
      at `textQuaternary`, and meaningless on its own.
- [x] **B4. The disabled Blend button is the live one at 40% opacity**
      (`MixView:194`) — Apple's audit reports it as an outright contrast failure.
- [x] **B5. The schedule's first run is a dead screen**: "Not measured yet",
      "0 ESTIMATED OF 0 IN SCOPE", and 60% empty. Nothing says what Measure will
      do or that MangaUpdates is rate-limited to one request every three seconds.
- [x] **B6. The tag-breadth bar has no legend.** A 44x3pt orange bar per row; a
      reviewer looking straight at it concluded it was a broken slider.
      VoiceOver is told what it means and a sighted reader is not.
- [x] **B7. Three same-weight accent links** on Search idle: "Browse",
      "Surprise me", "Clear" — no hierarchy between them.
- [x] **B8. "Clear all" wipes every filter with no undo and no confirmation.**

## C. Accessibility — 86 issues from Apple's own audit

- [x] **C1. Contrast.** 47 issues. `textQuaternary` measures **2.52:1** on the
      app's ground, which fails AA even for large text, and it is used at
      10.5-12.5pt in 26 places. Clearing 4.5:1 needs alpha >= 0.49 against 0.32
      today. NEEDS A DECISION: collapsing the tiers changes the mockup's look.
- [ ] **C2. Text clipped at its CURRENT size** (not just large type): the meta
      line under every cover card, "Manga · 7.0", "Manhwa · 8.7". 4 on Discover.
- [x] **C3. Dynamic Type only partially supported** on 15 elements. Cause not yet
      understood: they use `typeGridMeta`, which IS declared relative to
      `.caption2`. Investigate before changing anything.
- [x] **C4. Hit areas under 44pt**, named by Apple: the six Library state chips
      ("Reading, 71 series" … "Dropped, 429 series"), "Sort by Recently updated",
      the state legend, and the token field. All pinned to `Metrics.headerPill`
      = 30pt. NEEDS A DECISION: 30pt is the mockup's number.
- [x] **C5. The mix seed "+" and "x" carry no VoiceOver label**, and are 41pt and
      roughly 17pt.
- [x] **C6. Reduce Motion is honoured by 1 of 15 animating surfaces** (the swipe
      stack). The gallery glide, tag expand, toast, library shape change and
      settings disclosures all ignore it.

## D. Tests — the weakest part of this week's work

- [x] **D1. `FlowAffordanceTests` are source greps, not tests.**
      `#expect(source.contains("SearchClearButton"))` proves a call site exists;
      a stub would pass. Copy-artwork, clear-button, edge-swipe and seed-picker
      are effectively untested. Replace with behavioural tests.
- [ ] **D2. `ReleaseSchedule.swift` is 10.6% covered across 312 lines** — the
      cadence estimator that prints "38 days overdue" on series pages.
- [x] **D3. `TagSearch.swift` 15.4%** — only the pure merge is covered; the
      debounce and the failure path are not.
- [ ] **D4. `TasteProfile` 47.7%, `ReleaseReminders` 54%.**

## E. Release compliance

- [x] **E1. `PrivacyInfo.xcprivacy` declares nothing while 11 files use
      UserDefaults.** App Store Connect answers ITMS-91053 on upload; Apple has
      said it becomes a rejection. Add `NSPrivacyAccessedAPICategoryUserDefaults`
      with reason `CA92.1`. Verified: no other required-reason API is used.

## F. Performance

- [ ] **F1. Cold launch ~900 ms** (867/932 cold, 217 warm) against Apple's 400 ms
      guidance. 598-634 ms of it is framework and linker work before
      `didFinishLaunchingWithOptions`, which took 0.08 ms. The lever is needing
      less at launch, not running our launch code faster.

## G. Code quality — judgement calls, none blocking

- [x] **G1.** `TagPickerSheet` and `BlockedTagsSection` each bootstrap `TagSearch`
      and carry the same empty-state copy.
- [x] **G2.** `waiting`/`nearlyFinished` repeat the same chapter maths;
      `chaptersRead`/`hoursRead` each re-derive the completed-series rule.
- [x] **G3.** `SeedPickerSheet` writes the same `Binding(get:set:)` twice.
- [x] **G4.** Four forwarding properties in `ReadingInsightsView`.
- [x] **G5.** `Metrics.gutterStatus` and `Metrics.backButton` have zero uses.

---

## H. The six unknowns — ALL SIX ANSWERED

Full write-ups with evidence in `docs/unknowns-2026-09-11.md`.

- [x] **H1. Six screens never audited.** Four are now IN the audit rather than
      looked at once (blocked tags, cover gallery, Library with search results,
      a mid-drag Stack card); Settings already was. The sixth, shelf detail,
      cannot be audited because nothing in the app opens it — see below.
      Adding them found that the series-detail audit had never been on the
      series page: it tapped the first button on Discover, which is the "Open
      the stack" card. Commit b157689.
- [x] **H2. Why series titles fail contrast.** Reproduced by recording each
      issue's frame AND the screen as the audit saw it, then sampling the
      pixels. Most failures are elements that are off-screen — "Hidden gems" is
      at y=861 on an 852pt screen — where the sampler finds no text at all.
      The real ones are text passing under the tab bar's glass. The "raise 76
      places off textQuaternary" plan was answering the wrong question.
      Commit 4d111b1.
- [x] **H3. Dynamic Type "partially" unsupported.** `UIFontMetrics` returns the
      same value for `.caption2` at extraSmall, small, medium AND large, so a
      caption2-anchored style does not move across the bottom third of the
      range. Measured, not guessed. Every style under 14pt now anchors to
      `.subheadline`. Audit issues 15 -> 0. Commit 459c926.
- [x] **H4. On-device memory.** Allocations records nothing through `xctrace`
      in Xcode 16 — reproduced twice, with and without `MallocStackLogging` —
      and that is recorded as a negative result rather than chased. Activity
      Monitor gives the number instead: 44.8 MB peak physical footprint on the
      real phone, settling at 42.8 MB. Nothing to fix. Commit f1e0b1e.
- [x] **H5. Dead code.** Periphery installed, 105 findings, every one checked
      by hand. Deletions in 0c4f114; the two classes of false positive are
      recorded there so nobody deletes a protocol requirement on its say-so.
      It also found two REAL bugs that looked like dead code: a token change
      never forgot the previous account's taste profile (3beb3bb), and
      `CoverImage.accessibilityText` was set everywhere and never applied, so
      every bare cover was silent to VoiceOver (b157689).
- [x] **H6. Does the tab bar restore on scroll-up?** Yes. A slow upward drag
      does not bring it back; a flick does. That is iOS's own behaviour for
      `.onScrollDown`, not anything this app sets. Two sessions saw "it does
      not come back" before pushing hard enough.

---

## Still open, deliberately

- [ ] **C2. "Text clipped".** Checked and withdrawn as a defect. One of the two
      renders in full inside its frame (the audit compares intrinsic
      single-line width against a `lineLimit(2)` box and always loses); the
      other is a 56-character title truncating with an ellipsis in a 112pt
      card, which is what the App Store's own grid does. No change.
- [ ] **D2. `ReleaseSchedule.swift` coverage.** The number misled: the
      estimator is in `Cadence.swift` and is well covered, and the scope rules
      are covered in `CharacterTests.swift`. What is genuinely untested is the
      actor's own I/O, which needs a database fixture and a fake MangaUpdates
      client. Left with the reason written down.
- [ ] **D4. `TasteProfile` 47.7%, `ReleaseReminders` 54%.** Not attempted.
- [ ] **F1. Cold launch ~900 ms.** 598-634 ms of it is framework and linker
      work before any of our code runs (`didFinishLaunchingWithOptions` took
      0.08 ms). The lever is needing less at launch — fewer linked frameworks,
      less work in `AppServices.init` — which is a real project rather than a
      fix.
- [ ] **Shelf detail is unreachable.** A whole screen with no route into it.
      Delete it or wire it back up; that is a product decision. See
      `docs/unknowns-2026-09-11.md`.
