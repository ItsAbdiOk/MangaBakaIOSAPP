# Search — results presentation, motion, accessibility

Slice of the Search page deep review (brief: scratchpad `search-review-brief.md`).
Read-only; nothing built or run. Every line number below was read, not guessed,
against the tree at HEAD on 2026-09-13.

Files read in full: `SearchView.swift`, `SearchEmptyState.swift`, `SearchModel.swift`,
`CoverImage.swift`, `CoverQuickActions.swift`, `CopyableArtwork.swift` (head),
`Skeleton.swift`, `FailureState.swift` (40–179), `InlineFailure.swift`, `Countdown.swift`,
`Motion.swift`, `MotionModifiers.swift`, `Haptics.swift`, `PressStyle.swift`,
`ZoomRoute.swift`, `SeriesPager.swift`, `RootView+Session.swift` (325–420),
`SeriesRepository+Paging.swift`, `AccessibilityAuditTests.swift` (1–165, 236–260),
`FlowAffordanceUITests.swift` (20–48), `DynamicTypeLeftoversTests.swift` (70–95),
`SearchScreenTests.swift` (170–220), `AccessibilityTests.swift` (130–200).

Answers to the brief's direct questions come first, then the findings, then what is
done well, then what was not reviewed.

## Direct answers

- **What a card shows.** Title (2 lines, 4 at AX sizes), then "Manhwa · 8.6" — type and
  score only (`DiscoverView.swift:310-315`, reused at `SearchEmptyState.swift:56`). No
  year, no status, no author. `Series.year`, `.status`, `.authors` all exist
  (`Series.swift:20,23,52`) and are not shown.
- **Grid.** Three columns, not two: `SearchView.swift:30-33`. Cards are a hard 111pt
  (`SearchEmptyState.swift:54`) inside `.flexible()` columns.
- **Cover aspect.** Always 2:3 (`CoverImage.swift:28`, `Metrics.coverAspect`), artwork
  cropped with `scaledToFill` (`CoverImage.swift:52`). BlurHash placeholder is real and
  cached (`CoverImage.swift:32-35,95-98`). Fade only when the load took ≥16ms
  (`CoverImage.swift:131-141,153`), instant on a cache hit.
- **Loading.** Skeleton, not spinner, for page 1 (`SearchView.swift:263-267`); a
  `ProgressView` footer for page 2+ (`SearchView.swift:321-325`). The skeleton replaces
  the previous results on every debounced request — see F1.
- **"Searching" vs "no results".** Visually distinct (skeleton vs "Nothing matched").
  For VoiceOver they are not: the skeleton is `accessibilityHidden` (`Skeleton.swift:100`)
  and nothing is announced — see F7.
- **Paging.** Trigger at 6 items from the end (`SearchEmptyState.swift:76-83`), page size
  30 (`SearchQuery.swift:41`). Footer: spinner / `InlineFailure` / "Stopped early" line.
  No visible end-of-results signal; only a haptic (`SearchView.swift:78-80`) — see F10.
  Duplicate ids: page 2+ is deduplicated (`SearchModel.swift:358-359`); page 1 is not
  (`SearchModel.swift:227`) — see F12.
- **Motion applied.** `.arrives(index:)` per card (`SearchEmptyState.swift:63`),
  `.blurReplace` on each content kind (`SearchView.swift:267-287`), `Motion.settle` keyed
  on `contentKind` (`SearchView.swift:68`), `.press` on cards, `.symbolEffect(.pulse)` on
  the magnifier while searching (`SearchView.swift:130`), `countsNotCuts` on the heading.
  Not used: `.enterScale()`, `.parallax()`. Reduce Motion is honoured on every one of
  these paths (`MotionModifiers.swift:23`, `Motion.swift:79-83`, `Skeleton.swift:16`).
- **Zoom.** `.zoomSource("search", id)` and `zoomRoute.source` agree
  (`SearchEmptyState.swift:48,59`; destination `RootView+Session.swift:429`). Correct.
- **Keyboard dismissal.** No `.scrollDismissesKeyboard` set; the `ScrollView` default on
  iOS 16+ is "dismiss on scroll", which is the right behaviour. But the field itself is
  inside the scroll content (`SearchView.swift:36-39`), so after a scroll it is off
  screen — see F5.
- **Quick actions.** Search cards get "Copy cover" via the system context menu
  (`CoverImage.swift:274`). `CoverQuickActions` (Save / Mark read / Open pill) is wired
  nowhere in the app — see F3. Discover uses the same `CoverCard`, so the two are
  consistent, both lacking it.
- **Accessibility.** Cards are one element, "Title, Manhwa · 8.6", button trait
  (`CoverImage.swift:296-305`). No result-count announcement, no heading trait, no
  `accessibilityAction`s on a result, no focus management, no keyboard shortcut (the app
  is iPhone-only, `project.yml:91,132`, so a shortcut matters little). Hit targets: four
  controls in this slice are under 44pt — see F8.
- **Charter #5.** The accessibility audit never visits Search at all — see F2.

## Findings

### F1 — Results vanish into a skeleton on every debounced keystroke, then re-animate
- **What.** `isSearching` is set true at the top of `search()` and `contentKind` maps
  any `isSearching` to `.skeleton`, so the grid the reader is looking at is removed and
  replaced by six shimmering placeholders for the whole round trip, then the grid comes
  back with `.blurReplace` and every card's `.arrives` stagger re-runs from scratch.
- **Where.** `SearchModel.swift:171`; `SearchEmptyState.swift:28` (`if isSearching {
  return .skeleton }`); `SearchView.swift:263-267,285-287`; `MotionModifiers.swift:23-36`
  (`@State hasArrived` is fresh state because the grid was removed from the tree).
- **Why it matters.** Type "one piece" with a pause after "one " and after "piece": each
  pause is grid → blur out → skeleton (RTT, 300–800ms) → blur in → cards rising with up
  to 270ms stagger. Roughly a second of motion per pause, on results that are mostly the
  same series. The comment at `SearchView.swift:293-296` ("the last good results stay on
  screen … rather than the grid vanishing out from under the reader on every throttled
  keystroke") is only true *after* the failure lands; during the request the grid is
  gone. The model comment at `SearchModel.swift:201-204` promises the same and the view
  does not deliver it. Also the heading goes nil in flight (`SearchView.swift:368-369`),
  so the header row reflows too.
- **Fix shape.** Keep `.results` while `isSearching && !results.isEmpty` (skeleton only
  when there is nothing to show), dim the grid or pulse the magnifier as the "working"
  signal (the magnifier already does — `SearchView.swift:130`). `contentKind` is pure and
  tested (`SearchScreenTests.swift:187-193`) so the change is one branch plus one test
  that must flip from `.skeleton` to `.results` for the non-empty case — prove it fails
  first.
- **Effort.** A function (`contentKind`) plus its test.
- **Confidence.** Certain (read the state machine; no device needed).

### F2 — The accessibility audit "over every screen" never opens Search
- **What.** `testTabsPassTheAudit` iterates `["Discover", "Stack", "Mix", "Library"]`.
  Search is not in the list, and no other test audits the Search tab, idle or with
  results. The file header says "run over every screen".
- **Where.** `MangaBakaUITests/AccessibilityAuditTests.swift:3,121-136`. The only
  search-named audit is `testLibrarySearchResultsPassTheAudit` (`:222-234`), which is
  the Library tab's inline field.
- **Why it matters.** Charter #5 exactly: a green audit run says nothing about this
  screen, and F8 (four sub-44pt targets), F6 (a fixed-height field that clips at AX
  sizes) and F4 (cards overflowing their columns at AX sizes) are all things the
  `.hitRegion`, `.textClipped` and `.dynamicType` audits would report. `FlowAffordanceUITests.swift:27` shows `app.tabBars.buttons["Search"]` is tappable, so
  adding it is not blocked by the `.search` tab role.
- **Effort.** A line (add "Search" to the array) for idle; a function for a results
  audit (type, wait for a card, audit).
- **Confidence.** Certain.

### F3 — `CoverQuickActions` is a complete feature nothing presents
- **What.** The long-press Save / Mark read / Open pill, its haptic, its VoiceOver
  custom actions and its tests all exist. No production call site passes
  `quickActions:` to `CoverImage`; the only reference is the default `nil`.
- **Where.** `CoverQuickActions.swift:1-182` (whole file); `CoverImage.swift:24,66`;
  grep for `quickActions:` / `coverQuickActions(` outside those two files returns only
  `MangaBakaTests/CoverImageTests.swift:30-42`, which test the pure `visibleActions`.
- **Why it matters.** Charter #7 (a view with no presenter) and #2 (tests that pass
  against code that never runs). For Search specifically: the one thing a reader wants
  from a result besides opening it is "save this to my library", and the gesture that
  would do it is built, tested and unreachable. Long-press on a result today offers
  only "Copy cover" (`CoverImage.swift:274`).
- **Effort.** Wiring: a line per screen (pass an `Actions(save:)` closure) — but
  `CoverImage` has both `.coverQuickActions` and the card's `.contextMenu` on the same
  press, so the two gestures need reconciling first (`CopyableArtwork.swift:10-14`
  already warns about press competition). Or delete it. Product call, not mine.
- **Confidence.** Certain that it is unreachable.

### F4 — At accessibility text sizes the three fixed columns cannot hold the widened cards
- **What.** `CoverCard.scaledWidth` is `width * 1.5` at AX sizes (166.5pt), designed for
  horizontal rows. The Search grid keeps three `.flexible()` columns regardless of type
  size, so three 166.5pt cards plus two 12pt gaps need 523pt inside 357pt (393pt screen
  minus two 18pt gutters). Cards overlap the next column; the third runs off the edge.
- **Where.** `CoverImage.swift:255-260,293`; `SearchView.swift:30-33` (column count is a
  `let`, never read against `dynamicTypeSize`); `SearchEmptyState.swift:45,54`.
- **Why it matters.** Any reader on AX1–AX5 gets an unreadable, overlapping grid. The
  test that guards this — `cardsWidenWithText` (`AccessibilityTests.swift:131-136`) —
  asserts the *source contains* `scaledWidth` and so passes while the grid breaks:
  charter #2. `MixResults.swift:101-102` and `PublisherView.swift:82-83` share the same
  shape and the same defect (out of slice; noting so it is fixed once).
- **Effort.** A function: derive the column count from `dynamicTypeSize` (2 at AX) or
  switch to `.adaptive(minimum:)` and drop the hard width — see F11.
- **Confidence.** Certain by the arithmetic; not seen on a device.

### F5 — After scrolling, the search field is gone, and a new query lands mid-list
- **What.** The field is a plain `TextField` inside the `ScrollView`'s content, not
  `.searchable`. Scroll down two rows and the field is off screen; the keyboard has
  dismissed (the ScrollView default). To refine the query the reader scrolls back to
  the top. Separately, nothing resets the scroll offset on a new search: a long grid →
  short skeleton → long grid sequence leaves the offset wherever the clamp put it, so a
  new query's results can open partway down.
- **Where.** `SearchView.swift:36-39,123-177`; no `ScrollViewReader`/`.scrollPosition`
  anywhere in the file; the tab is declared `role: .search` (`RootView.swift:240-245`)
  which is what makes iOS 26's tab bar morph into a search field — with `.searchable`,
  which this screen does not use.
- **Why it matters.** Charter #6 — the platform gives a pinned field, cancel button,
  scroll-to-top on focus, suggestions, and the iOS 26 search-tab morph; the hand-rolled
  field forfeits all of it and inherits the scroll-away problem. The field/IA is the
  other agent's slice; flagged here because the scroll-position symptom is mine.
- **Effort.** A redesign of the bar (other slice). The scroll-reset alone is a function:
  `.scrollPosition` bound to a `ScrollPosition` and set to `.top` when `generation`
  changes.
- **Confidence.** Likely for the mid-list landing (needs a device to see where the
  clamp settles); certain for the field scrolling away.

### F6 — The Search field is a fixed 40pt; the "fixed 40pt search field" fix landed on the other field
- **What.** `.frame(height: Metrics.field)` (40) on the Search tab's field. The Dynamic
  Type leftover noted in `docs/todo-next-week.md:212` ("a fixed 40pt search field") was
  fixed in `InlineSearchField.swift` (Library) and tested there
  (`DynamicTypeLeftoversTests.swift:77-84`, "The library search field has no fixed
  height"). The Search tab's own field kept the fixed 40.
- **Where.** `SearchView.swift:156` (field), `:170` (Filters button, also 40).
- **Why it matters.** 40 < 44 hit target; and at AX5 the 14pt body text scales to ~43pt,
  taller than the frame, so the typed query clips. The test's name says "search field"
  and audits a different screen's field — charter #5 in miniature.
- **Effort.** A line each (`minHeight: Metrics.tapTarget`).
- **Confidence.** Certain for the height; likely for the clipping (not seen).

### F7 — VoiceOver hears nothing when results land, or when none do
- **What.** No `AccessibilityNotification.Announcement`, no `.isHeader` trait, no focus
  move when a search completes. The skeleton is hidden from VoiceOver, the heading
  ("30 shown · Relevance") is a plain `Text`, the empty state is two plain `Text`s.
- **Where.** `SearchView.swift:185-192` (heading), `Skeleton.swift:100`,
  `SearchEmptyState.swift:95-104`. Project-wide grep: the only announcement in the app
  is the toast (`Toast.swift:77`).
- **Why it matters.** A VoiceOver reader types, waits, and has no signal that anything
  happened; "searching" and "no results" are indistinguishable by ear. Compare the
  toast, which does announce.
- **Effort.** A function: post an announcement on `contentKind` change to `.results`
  ("N results") and `.empty` ("Nothing matched"); add `.accessibilityAddTraits(.isHeader)`
  to the heading so the rotor can jump to it.
- **Confidence.** Certain.

### F8 — Four tap targets in the results header are under 44pt
- **What.** "Browse" and "Surprise me" are `minHeight: Metrics.headerPill` (30pt); the
  field and "Filters" are 40pt (F6).
- **Where.** `SearchView.swift:209,417` (30pt), `:156,170` (40pt); `Metrics.swift:62`
  defines `tapTarget = 44` beside them.
- **Why it matters.** The audit's `.hitRegion` check would fail all four — and would
  have, had it run (F2). `SearchClearButton.swift:34-36` shows the house fix: keep the
  glyph, widen the hit frame.
- **Effort.** A line each.
- **Confidence.** Certain.

### F9 — The rate-limit bar over live results shows a frozen countdown and never auto-retries
- **What.** With results on screen, a 429 renders `StaleBar(detail: failure.countdown
  ?? …)`. `APIError.countdown` is a `String` computed once at render ("Retrying in 30 s.")
  and never ticks — the exact bug `Countdown` was written to fix for `FailureState`
  (gap 24). And `autoRetry: true` is only on the `FailureState` branch (results empty);
  the stale-bar branch has a manual Retry only.
- **Where.** `SearchView.swift:298-305`; `APIError.swift:314-321` (`countdown` is a
  one-shot string); `Countdown.swift:1-11` (why that is wrong); `SearchView.swift:274-279`
  (auto-retry only here). `SearchModel.swift:213-214` says "the network answer is
  seconds away and auto-retry will fetch it" — for this branch, nothing does.
- **Why it matters.** The reader keeps the old query's grid ("one piece", heading "30
  shown") under a bar that says "Retrying in 30 s" forever, while the field says
  "berserk". Nothing names which query the grid belongs to, the number never moves, and
  the retry the comment promises never fires. Charter #1's cousin: the model's comment
  disagrees with the view.
- **Effort.** A function: give `StaleBar` a `Countdown` (with `onReachZero` → retry) when
  the error is `.rateLimited`, and say whose results these are ("Still showing 'one
  piece'").
- **Confidence.** Certain for the frozen string and the missing auto-retry; the
  wording point is a judgement.

### F10 — No visible end of results; the "end" haptic also fires on a short first page and on "stopped early"
- **What.** Reaching the last page shows nothing — the grid just ends above 124pt of
  inset. The only signal is `Haptics.settled` on `hasMore` true→false. `hasMore` is not
  reset when a new search starts, so a prior query with more pages followed by a
  one-page query fires the "end of feed" haptic as the new results land. `stoppedEarly`
  also sets `hasMore = false`, so the haptic says "that's all" while the line beneath
  says "more of this may exist".
- **Where.** `SearchView.swift:76-80`; `SearchModel.swift:171-179` (no `hasMore` reset),
  `:234` (set from page 1), `:383-384` (stopped-early sets it false).
- **Why it matters.** A reader with haptics off, or using VoiceOver, cannot tell "all 32
  shown" from "page 2 quietly never came". And the comment on the haptic ("nothing on
  screen says which until now") is literally true — a haptic is not on screen.
- **Effort.** A line for the trailing "That's all N" text; a line to reset `hasMore`
  at the top of `search()`; a line to exclude `stoppedEarly` from the trigger.
- **Confidence.** Certain.

### F11 — 111 is a hard-coded width in four places, derived for one screen width
- **What.** `(393 − 2×18 − 2×12) / 3 = 111` — the card width is the 393pt phone's
  column width, written as a literal, not derived. On a 375pt phone the columns are
  105pt and each card overhangs its column by 6pt; on 430pt they are 123pt and each card
  leaves 12pt of dead space to its right, so the right gutter reads 30pt against 18 on
  the left.
- **Where.** `SearchEmptyState.swift:54`, `Skeleton.swift:85`, `MixResults.swift:137`,
  `PublisherView.swift:313`. No `Metrics` token; no "guess" or derivation comment.
- **Why it matters.** Charter #4 and "duplicated constants". The grid is `.flexible()`
  precisely so the platform can size the columns, and then the card ignores that.
- **Effort.** A file: let `CoverCard` take the column width (a `GeometryReader`-free
  option is `.adaptive(minimum:)` columns and `maxWidth: .infinity` on the card), or a
  `Metrics.coverGridWidth(for: containerWidth)` used by all four.
- **Confidence.** Certain for the maths; the visual severity at 430pt is "worth checking"
  on a device.

### F12 — Page 1 is not deduplicated; the skeleton does not match the grid it stands in for
- **What.** (a) `results = result.series` on page 1 with no id dedup, while page 2+ is
  deduplicated with a comment that duplicates are "the normal outcome" under
  `sort_by=random`. A duplicate id within one page gives `ForEach` two views with one
  id — not a crash, but broken identity, a missed zoom source and a console warning.
  (b) `CoverSkeletonGrid` uses `.adaptive(minimum: 111)`, 16pt gaps and no horizontal
  gutter; the real grid uses 3 × `.flexible()`, 12pt gaps and an 18pt gutter. The
  skeleton's first column starts at x≈5, the results at x=18.
- **Where.** (a) `SearchModel.swift:227` vs `:354-359`; (b) `Skeleton.swift:88` vs
  `SearchView.swift:30-33` and `SearchEmptyState.swift:45,72`; `SearchView.swift:63-68`
  (`content` carries no horizontal padding).
- **Why it matters.** (a) Only under `random` sort, and only if the API repeats within
  one page — I could not confirm it does. (b) The skeleton's stated purpose is "so
  nothing jumps when they land" (`SearchView.swift:264-265`); today every placeholder jumps 5–13pt right and the gaps
  change width when results arrive.
- **Effort.** (a) A line (`Array(uniqueBy id)`), (b) a line each: give the skeleton the
  same `columns` and gutter.
- **Confidence.** (a) Worth checking — no payload evidence either way; (b) certain.

### F13 — The API's total result count is fetched and thrown away; the heading says "shown" to cover for it
- **What.** `SeriesRepository.search` returns `total: pagination?.count`. `SearchModel`
  reads `.series`, `.hasMore` and `.blockingError` and never `.total`. The heading then
  says "30 shown" and the doc comment explains that "results" would be wrong because
  the count changes as you scroll — which is only a problem because the real total is
  discarded.
- **Where.** `SeriesRepository+Paging.swift:66`; `SearchModel.swift:188-239` (no
  `result.total`); `SearchView.swift:360-373`.
- **Why it matters.** Charter #3. "30 shown" answers a question nobody asked; "411
  results" is what a reader wants when deciding whether to refine. `LensCounts` spends a
  separate `count()` request per lens for a number the search response already carries.
- **Effort.** A function: store `total`, heading "N results" (falling back to "shown"
  when the API omits it).
- **Confidence.** Certain that it is discarded; the API sending `count` is per the
  repository's own comment, not re-verified by me against a payload.

### F14 — Later cards wait 270ms to appear as they scroll into view
- **What.** `.arrives(index:)` delays each card by `min(index, 6) × 45ms`. In a
  `LazyVGrid` a card's `onAppear` fires when it scrolls into view, so every card past
  the sixth is invisible (opacity 0, blurred, 8pt low) for 270ms after entering the
  viewport, then springs for 450ms. Search is the only grid in the app that staggers
  per cell — `MixResults` and `PublisherView` do not.
- **Where.** `SearchEmptyState.swift:61-63`; `Motion.swift:60-69`;
  `MotionModifiers.swift:21-37`.
- **Why it matters.** Fast scroll through page 2 shows a band of blank cells at the
  bottom that fill in late — the opposite of what BlurHash placeholders were added for.
  The comment "the grid assembles rather than queuing" is true for the first screen and
  wrong for every screen after it.
- **Effort.** A line: stagger by `index % 6` (position within the visible rows) or only
  for `index < 9`.
- **Confidence.** Likely — the mechanism is certain, the perceived severity needs a
  device.

### F15 — The card does not show why it matched, or what would tell two matches apart
- **What.** The placeholder says "Title, author, or tag"; an author search returns
  cards with no author on them. Two series with the same title (a 1990s original and a
  2019 remake, a spin-off with the parent's name) show identical cards. Titles truncate
  at the tail, where "Season 2" / "(2019)" / the subtitle usually sits.
- **Where.** `SearchEmptyState.swift:52-57` with `DiscoverView.swift:310-315`;
  `CoverImage.swift:277-291` (title `lineLimit(2)`, default tail truncation, meta is
  type + score only). `Series.swift:20,23,52` has `authors`, `status`, `year`.
- **Why it matters.** The brief's question — "is this the one I meant" — is answered by
  year and status more than by score. Reusing Discover's meta (built for browsing, where
  score is the point) on a disambiguation surface is the wrong borrow.
- **Effort.** A function: a `SearchView.meta(for:)` of "Manga · 2019 · Ongoing" (score
  can stay if it fits at AX sizes; `lineLimit(1)` on meta will truncate otherwise).
- **Confidence.** Likely — a product judgement with a concrete input.

### Minor
- `shouldPrefetch` does an O(n) `firstIndex` per cell appearance while the `ForEach`
  already has `index` in hand (`SearchEmptyState.swift:46,66-68,78-83`). A line.
- Search does not prefetch the covers of the page just received; Discover does
  (`DiscoverView.swift:295`). The 21 off-screen covers of a fresh page start loading
  only on scroll. A line after `results = result.series`.
- `SeriesPager` neighbours are a snapshot (`SearchEmptyState.swift:49`); paging to the
  30th result stops there with no way to load page 2 from inside the pager. Expected,
  just noting it is a dead end the grid does not have.
- The card carries `.accessibilityAddTraits(.isButton)` (`CoverImage.swift:298`) inside
  a `Button` — harmless, but the trait belongs to the wrapper.

## Done well

- The whole state machine for the content area is one pure function with a test per
  branch (`SearchEmptyState.swift:17-41`, `SearchScreenTests.swift:177-220`). F1 is a
  one-branch change *because* of this.
- Reduce Motion is honoured everywhere in this slice, including the symbol pulse, the
  shimmer, the stagger and the press scale (`SearchView.swift:130`, `Skeleton.swift:16`,
  `MotionModifiers.swift:23`, `PressStyle.swift:74-84`). The doc comment at
  `Motion.swift:4-14` records why ("vestibular … one place out of fifteen has not
  honoured it").
- Every animation constant is labelled a guess where it is one (`Motion.swift:39-53`,
  `CoverImage.swift:144-153`, `Skeleton.swift:9`, `CoverGloss` opacities at
  `CoverImage.swift:196-197`).
- The cache-hit fade rule is a pure, tested decision with a stated threshold and the
  reason it is a guess (`CoverImage.swift:144-159`).
- Page 2+ dedup with the reason recorded and the `sort_by=random` measurement
  (`SearchModel.swift:354-359`, `:128-132`).
- Page failure, stopped-early and true end are three distinct states with three
  distinct footers (`SearchView.swift:321-341`, `SearchModel.swift:42-56`).
- Clear button is a 44pt target around a 16pt glyph, with the contrast measurement
  written down (`SearchClearButton.swift:28-36`).
- `CoverImage.accessibilityText` is now actually applied, with the Periphery finding
  recorded at the site (`CoverImage.swift:67-78`).
- Smart Invert exclusion on artwork (`CoverImage.swift:53-56,98`).
- Zoom source ids are `row#series` so a series in two rows cannot collide
  (`ZoomRoute.swift:13-16,26`).
- The audit test file records its own past mistake and the screenshot that caught it
  (`AccessibilityAuditTests.swift:140-148`).

## Not reviewed

- `SearchIdleView`, `FilterPanel`, `FilterSheet`, `TagPickerSheet`, `SaveLensSheet`,
  `LensCounts`, `RecentSearches` — other agent's slice.
- `CoverStore` internals, `BlurHashCache`, `Cover.url(forHeight:scale:)` variant choice.
- `OfflineCatalogue.matches` beyond confirming it slices a sorted array
  (`OfflineCatalogue.swift:167-181`); whether its rows are unique by id.
- `MixResults` and `PublisherView` grids beyond the shared-constant and column-count
  observations in F4/F11.
- `RootView+Session.swift` outside 325–420; `SeriesDetailView`.
- Anything on a device or simulator: no screenshots, no VoiceOver run, no AX-size
  render. Every "certain" above is certain from source; "likely" means the mechanism is
  read and the severity is not.
- `EnterScale`/`Parallax` modifiers (read, unused by Search).
