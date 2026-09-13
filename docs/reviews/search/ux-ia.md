# Search — UX and information architecture

Slice: the Search tab's screens and wiring. Read-only; nothing was built or run.
Every line number below was read at HEAD (1f118cd, tree clean) on 2026-09-13.

Files read in full: `SearchView.swift`, `SearchEmptyState.swift`, `SearchIdleView.swift`,
`FilterPanel.swift`, `FilterSheet.swift`, `SaveLensSheet.swift`, `SearchLens.swift`,
`SearchModel.swift`, `LensCounts.swift` (incl. `RecentSearches`), `Core/Model/SearchQuery.swift`,
`SearchClearButton.swift`; the search wiring in `RootView.swift:236-325`,
`RootView+Session.swift:313-372`, `BrowseDestination.swift`; the relevant tests in
`SearchModelTests.swift`, `SearchScreenTests.swift`, `LensTests.swift`.

Counts: 14 findings — 10 certain, 3 likely, 1 worth checking. Done well: 7.

---

## Findings, ranked by reader impact

### 1. Tapping any filter chip on the idle screen makes the whole panel disappear

- **What** — On the idle screen, the first tap on a Type/Status/Sort chip, a rating segment, a year digit, or a picked tag replaces the inline `FilterPanel` with the "Nothing matched these filters" empty state. The panel the reader is building in vanishes under their finger; "Show results" is never reachable.
- **Where** —
  - `SearchView.swift:241-243` shows `SearchIdleView` only for `contentKind == .idle`.
  - `SearchEmptyState.swift:27-31` decides `.idle` solely from `isQueryEmpty`; with nothing searching, no failure and no results it returns `.empty` (line 30).
  - `SearchEmptyState.swift:36` feeds it `model.query.isEmpty`, and `SearchQuery.swift:52-57` counts `types`, `statuses`, `sort`, `tags`, `minimumRating`, `publisher`, `yearFrom/To` as non-empty.
  - `FilterPanel.swift:58,67,79,346,357` mutate `query` directly through the binding; `SearchIdleView.swift:135-142` passes `$query`, which is `$model.query` (`SearchView.swift:247`).
  - No `queryDidChange()` or `search()` runs on a chip tap — only the field's text triggers one (`SearchView.swift:143`), and `SearchModelTests.swift:99-121` documents that as intended.
  - Side effects of the same flip: the "Filters" button appears in the bar (`SearchView.swift:162`), and the heading reads "0 shown" (`SearchView.swift:52,368-372`) above "Nothing matched these filters / One filter is still applied / Clear filters / Random with these filters" (`SearchEmptyState.swift:95-137`).
- **Why it matters** — This is the headline feature of yesterday's commit (`d344224`: "the filters I like — manga vs manhwa, the year — on the main page"), and the one path a first-time reader is meant to take. Input that triggers it: open Search, tap "Manga". The panel is gone. "Clear filters" brings it back (query becomes empty → `.idle`), so it reads as a screen that refuses filters.
- **Tests that agree with the bug (charter #2)** — `SearchScreenTests.swift:197-203` asserts a non-empty query with no results and no failure is `.empty`, and `SearchModelTests.swift:109-121` asserts chips do not search. Each is right alone; together they specify exactly this. Neither test covers "chip tapped while idle".
- **Effort** — a function. `contentKind` needs a fourth input — "has the reader asked yet". Either the model carries `hasAsked` (set in `search()`, cleared when the text empties), or `.idle` is `query.text` empty *and* `results.isEmpty && failure == nil && !isSearching`. Then "Show results" is the ask, as the panel's doc comment already says (`FilterPanel.swift:36-38`). Add one test: `contentKind(isQueryEmpty: false, hasAsked: false, …) == .idle`.
- **Confidence** — certain from code. Not run (brief forbids it); the live-walk agent should tap one chip on a fresh install to confirm.

### 2. "Browse offline" is on, and the panel still sends a network request per filter change

- **What** — With the Offline toggle on, every settled filter change still fires the preview count to `/v2/series/search`.
- **Where** — `FilterPanel.swift:281-294` guards only on `canShow` and `previewCount`; the `preferOffline` binding it holds (line 31) is never read there. `previewCount` is `LensCounts.count` (`SearchView.swift:116,261`) → `LensCounts.swift:142-144` → `SeriesRepository+Count.swift:17-30`, a network call at `.userInitiated` priority. `SearchModel.swift:63-67` promises "Zero requests in that mode".
- **Why it matters** — The toggle's own copy says "no requests" (`FilterPanel.swift:104-107`); the reader on a metered or dead connection gets a request per chip anyway, and the search window (30/min, shared) is spent on a preview nobody sees while #1 stands. `OfflineCatalogue.count(...)` already exists (`OfflineCatalogue.swift:187`) and answers the same question locally.
- **Effort** — a line to gate, a function to route the count to the offline index when the toggle is on.
- **Confidence** — certain.

### 3. The Year filter is drawn as a first-class control and does nothing online

- **What** — Year From/To sit in the inline panel between Rating and Narrow-by, but the query never sends them; online results ignore the range, the preview count ignores it, and the empty state then blames it.
- **Where** — `SearchQuery.swift:20-28` ("Offline-only for now … GUESS: never sent to the wire"); `SearchQuery.swift:84-115` builds no year item; `FilterPanel.swift:354-361` draws it with no hint; `SearchQuery.swift:66-72` counts it in `activeFilterCount`, so `SearchEmptyState.swift:87-93` says "One filter is still applied" about a filter that was never applied.
- **Why it matters** — Abdi named "the year" as one of the two filters he wants on the main page. A reader sets 2020–2024, taps Show results, sees a 1997 title on row one, and has no way to know why. A silent control is this project's characteristic defect (charter #3).
- **Effort** — a line to hide or caption it while online; a function once someone checks the live endpoint's parameter names and adds the query items.
- **Confidence** — certain that it is not sent; the API's parameter name is the open question.

### 4. A year-only lens is saved as "Everything"

- **What** — `SearchLens.describe` omits `yearFrom`/`yearTo`, so a lens built only from the Year fields (which `isEmpty` accepts) gets the generated name "Everything", the rule "Everything", and the Save sheet's "What it stores" box says "Everything".
- **Where** — `SearchLens.swift:98-117` (no year branch); `SearchLensStore.save` accepts it at `SearchLens.swift:65`; `SaveLensSheet.swift:20,96` show the same string.
- **Why it matters** — The lens row (`SearchIdleView.swift:241-244`) then falls back to that rule until a count lands, and a lens whose subtitle claims to match everything is exactly what `save()`'s own comment says must not exist.
- **Effort** — a line.
- **Confidence** — certain.

### 5. After "Surprise me", the × in the field never takes you back to the idle screen

- **What** — Clearing the text after a random search runs another random search instead of returning to Recent/Filters.
- **Where** — `SearchView.swift:145-153` clears text and calls `queryDidChange()`; `SearchModel.swift:133-135` drops `sort == "random"` only when the text is non-empty; with text empty and sort still set, `query.isEmpty` is false (`SearchQuery.swift:55`), so line 145 schedules a search. Result: "30 shown · Random" (`SearchView.swift:368-372`).
- **Why it matters** — × is the reader's "start over". The same holds for any leftover filter: × with a type chip set runs a type-only search rather than showing the panel. For sort that is clearly wrong (nothing on screen says "Random" is set); for filters it is arguable but surprising, and the only route back to the panel is the empty state's "Clear filters" or the sheet's "Clear all".
- **Effort** — a line: clear a random sort when the text empties; decide whether × clears the whole query.
- **Confidence** — certain for sort; likely (a product call) for filters.

### 6. The hand-rolled field forgoes what `Tab(role: .search)` + `.searchable` would give (charter #6)

- **What** — The Search tab is the system search tab (`RootView.swift:240-246`), but its field is a `TextField` in a rounded box (`SearchView.swift:123-177`) with a hand-built clear button (`SearchClearButton.swift`). Nothing in the app uses `.searchable` except `BlockedTagsSection.swift:182`.
- **What the platform would add** — tapping the search tab focuses the field and morphs it out of the tab bar next to the thumb; a Cancel button that restores the previous state; `.searchScopes` for Manga/Manhwa/Manhua (the "manga vs manhwa" ask, one tap, no panel); `.searchSuggestions` for Recent, which then needs no section of its own and disappears when typing starts; `.searchable(text:tokens:)` so a picked tag, genre or publisher is a visible, individually removable token *in the field* — today the only sign a tag is set is a badge on a button in a panel that #1 hides; `dismissSearch` for after a result is opened. `SearchScreenTests`' "hand-built search clear button" is called out in the charter as the pattern's cost.
- **Why it is hand-rolled** — the root screens draw no navigation bar (`ScrollEdge.swift:93-95`; `SearchView.swift:13-17`), and `.searchable` needs one. That trade was made for all four tabs; Search is the tab where it costs most, because search is the one system surface iOS 26 redesigned around this tab role.
- **Effort** — a redesign of this one screen (give Search a navigation bar; it has no title to lose). Worth a prototype before deciding.
- **Confidence** — certain it is hand-rolled; likely it would be better; worth checking that the tokens API suits multi-tag `tag_mode`.

### 7. Ten headers at one weight — no hierarchy on the idle screen

- **What** — "Recent", "Filters", "Your lenses" (`SearchIdleView.swift:61,132,151`) and, inside Filters, "Type", "Status", "Sort", "Minimum rating", "Year", "Narrow by", "Offline" (`FilterPanel.swift:298-305,338,164,98`) all use `typeSubsectionHeader()` — 15pt semibold (`Typography.swift:118-120`). The section and its subsections are the same size.
- **Why it matters** — A first-time reader sees a flat list of ten equal labels and cannot tell that seven of them belong to "Filters". Discover and Library head their rows with `typeSectionHeader()` (20pt bold, `Typography.swift:112-114`; e.g. `CommunityPulseCard.swift:50`), so Search is also the odd tab out.
- **Effort** — a line each: the three idle sections to `typeSectionHeader()`, or the panel's to `typeEyebrow()`.
- **Confidence** — certain.

### 8. The first-time reader's screen, and the wrong sentence in the Save sheet

- **What** — With no recents and no lenses, the idle screen is: an empty field, "Browse" and "Surprise me", then "Filters" straight into six chip rows, two disabled buttons ("Clear all", "Show results"), and the footnote "The bookmark saves this as a lens. Greyed until a filter is set." (`FilterPanel.swift:255-261`) — the first mention of a lens on a screen that has none. `SaveLensSheet.swift:30` then says "Lenses sit at the top of Search"; they sit at the bottom (`SearchIdleView.swift:46-49`), below the panel.
- **Why it matters** — Not a dead end (every chip is live, modulo #1), but nothing on the screen invites a first search — no prompt, no example, no "try…". The lens footnote explains a control before its concept exists, and the one sentence that does explain lenses is wrong about where they go.
- **Effort** — a line for the sheet copy; a line to hide the footnote until a lens exists or a filter is set.
- **Confidence** — certain for the copy; likely for the "feels empty" judgement (not rendered).

### 9. Preview count spends the shared search window at foreground priority, per settled change

- **What** — Every filter change, 350 ms after the last, sends one count request at `.userInitiated`, on the same 30/min `.search` window as typed searches; "Show results" is then a second request for the same query.
- **Where** — `FilterPanel.swift:277-294`; `LensCounts.swift:142-144`; `SeriesRepository+Count.swift:17-19` (`.userInitiated` default); `LensCounts.swift:95-99` shows the lens walk was deliberately moved to `.background` for exactly this reason on the same day.
- **Why it matters** — Five chips with a pause between each is five requests before the reader has searched; a reader who builds a filter slowly can 429 their own first search. While #1 stands, the count is never even displayed.
- **Effort** — a line (`.background`); a product line on whether the live preview earns its cost or "Show results" alone is enough.
- **Confidence** — likely (the window family for `/v2/series/search` counts was not traced into `RateLimitGate` in this slice).

### 10. Recents under-record how the reader actually searches

- **What** — A term is recorded only on the keyboard's Search key (`SearchView.swift:140`) and "Show results" (`SearchView.swift:258`). A reader who types "berserk", waits 300 ms, and taps a result never gets "berserk" in Recent. Tapping a recent row does not move it to the front (`SearchView.swift:253-255` → `apply`, no `record`). One-character titles are dropped (`RecentSearches.record`, `LensCounts.swift:183`, `count > 1`). Filters are never part of a recent (text only, by design — fine).
- **Dedupe / delete / privacy** — Case-insensitive dedupe to the front (`LensCounts.swift:184-185`), 6 stored / 4 shown (`163-169`), per-row × (`192-195`) and Clear (`197-200`), `UserDefaults` on-device only, nothing sent anywhere. All good.
- **Why it matters** — The section meant to be "the fastest way back to something you already typed" (`SearchIdleView.swift:5-6`) misses the most common way a search ends: tapping a cover.
- **Effort** — a line: record in `resultsGrid`'s button (`SearchEmptyState.swift:47-51`) or when a search returns results; a line for the recent-row tap.
- **Confidence** — certain.

### 11. Two doors to the same vocabulary, with different semantics, side by side

- **What** — "Browse" (header chip, `SearchView.swift:204-213`) pushes `BrowseView` and *replaces* the query (`SearchModel.applyBrowse`, `SearchModel.swift:390-406`, sets `popularity_asc`). "Tags / Genres / Publishers" (`FilterPanel.swift:162-179`) open sheets over the same `CatalogueService` and *add* to the query. "Surprise me" (`SearchView.swift:215-218`) and the "Random" sort chip (`FilterPanel.swift:75-83`; `SeriesRepository.swift:208`) do the same thing, but one is undone by the next keystroke (`SearchModel.swift:133-135`) and the other is a sticky filter.
- **Why it matters** — On one screen a reader has two "pick a genre" affordances that behave differently after the pick, and two "random" affordances that behave differently after the next keystroke. A power user has to learn which is which; a first-time reader picks one at random.
- **Effort** — a product decision, then a file: either Browse is the sole picker (and adds rather than replaces), or the header chip goes.
- **Confidence** — certain about the behaviours; the judgement that it confuses is likely.

### 12. Saved lenses: no rename, silent overwrite, and a doc that describes an edit path that does not exist

- **What** — A lens can be run or deleted (`SearchIdleView.swift:171-233`); there is no rename or edit. Saving under an existing name replaces the old lens without a word (`SearchLens.swift:71`). `LensCounts.invalidate`'s comment (`LensCounts.swift:119-122`) is written for "an edited lens"; nothing edits one. `SearchLens.isOwn` (`SearchLens.swift:28-33`) claims `SaveLensSheet`/`SearchIdleView` read it; neither file references it (grep, whole target).
- **Zero-result lens** — "0 now" is shown when the count is 0 (`SearchIdleView.swift:242-243`); tapping runs it, the empty state offers "Clear filters", which empties the query and returns to idle. Not a dead end.
- **Why it matters** — A reader who saves "Seinen" twice with a tweak loses the first silently. Small.
- **Effort** — a line for a "Replaced 'Seinen'" toast; a line to delete the stale comments.
- **Confidence** — certain.

### 13. "0 shown" above "Nothing matched"

- **What** — In the `.empty` state the heading is "0 shown" (`SearchView.swift:368-372` with `count: 0`) directly above the empty state's own sentence.
- **Effort** — a line (`guard count > 0`).
- **Confidence** — certain.

### 14. Stale claim in `FilterSheet`'s doc

- **What** — `FilterSheet.swift:12-14`: "so Search and Mix both get it". Only `SearchView.swift:108` presents `FilterSheet`; `SeedPickerSheet` does not (grep). Harmless, but it is the kind of comment that sends the next reader looking for a caller that is not there (charter #7).
- **Effort** — a line.
- **Confidence** — certain.

---

## Questions from the brief, answered

- **Idle order for a first-timer** — Recent and lenses are both hidden when empty (`SearchIdleView.swift:38-49`), so the first-timer sees Filters only. Order is fine; the problems are #1 (the panel breaks on first tap), #7 (flat headers) and #8 (nothing invites a search; lens copy before lenses exist).
- **Are filters shared between the two hosts?** — Yes, correctly: both bind `$model.query` (`SearchView.swift:109,247`), one source of truth. A filter set inline survives typing (text change only debounces a search; filters ride along, `SearchModel.swift:113-150`). `contentKind` transitions: `idle → (chip tap) → empty` is #1; `idle → (type) → skeleton → results|empty|failure`; `results → (×) → idle` only if no filter/sort remains, else a filter-only search (#5). The Filters button is hidden while idle (`SearchView.swift:160-175`) — right, but because of #1 it appears the moment a chip is tapped.
- **`.searchable`** — #6.
- **Recents** — #10. Nothing per keystroke; nothing leaves the device.
- **Lenses** — #4, #8, #12. Discoverable only after the first save; the save affordance is a bookmark icon whose meaning is explained by a footnote (#8).
- **Empty and failure** — Wording is good and names the filters (`SearchEmptyState.swift:85-93`, measured 2026-09-10 in `SearchQuery.swift:61-65`). 429 with nothing on screen → `FailureState(autoRetry: true)` with a live `Countdown` (`SearchView.swift:274-281`, `FailureState.swift:80-82`); 429 with results → `StaleBar` with `failure.countdown` (`SearchView.swift:298-305`). Handled.
- **Consistency** — #7 (header weight vs Discover). Rows use a hard-coded `cornerRadius: 14` four times (`SearchIdleView.swift:107,110,203,206`) where the rest of the tab uses `Metrics.radiusCard`/`radiusChip`; `StackSections.swift:212` and `BlendDNAView.swift:164` carry the same literal — a candidate `Metrics.radiusRow`. Chip style matches Browse (`Palette.surfaceChip`/`accent`, `Metrics.headerPill`).

---

## Done well

- **One query, two hosts.** `FilterPanel` is genuinely one view; `FilterSheet` is 25 lines of chrome (`FilterSheet.swift:30-53`). No duplicated controls, and the source-text tests in `LensTests.swift:361-373` at least pin that.
- **No request per keystroke.** 300 ms debounce with the explicit-apply guard (`SearchModel.swift:113-150`), `appliedText` to stop the double request on a lens tap (lines 92-94, 123-126), and a test that counts requests (`SearchModelTests.swift:90-97`).
- **Failure never blanks the grid.** `results` untouched on a blocking error (`SearchModel.swift:205-226`), `StaleBar` over the last good grid, countdown auto-retry only on this screen (`SearchView.swift:268-281`). The page-2 failure is kept distinct from the search failure (`SearchModel.swift:42-49`).
- **Empty state names the cause.** "3 filters are still applied" with a measured justification (`SearchQuery.swift:59-65`, live 2026-09-10) and a one-tap "Clear filters" (`SearchEmptyState.swift:106-119`).
- **Recents are removable one at a time**, with the design reason recorded (`SearchIdleView.swift:84-87`), and never leave the device.
- **Lens counts are budgeted**: idle-only, once per session, spaced, `.background`, stop on first refusal, and the fallback (drop the counts) is written down with who chose it (`LensCounts.swift:10-23,95-110`).
- **Comments carry dates and measurements** — `popularity_asc` vs `_desc` (`SeriesRepository.swift:201-205`), `+Anima` encoding (`SearchQuery.swift:88-96`), random-sort leak (`SearchModel.swift:128-132`). These made #3 and #5 findable in minutes.

---

## Not reviewed

- `TagPickerSheet.swift` (494 lines) and `PublisherBrowser` — the pickers' own UX.
- `RateLimitGate`'s family assignment for `/v2/series/search` counts (assumed `.search` in #9).
- `BrowseView` itself; only its hand-off into Search (`BrowseDestination.swift`, `RootView.swift:257-270`).
- `OfflineCatalogue` matching quality and the `EmbeddingIndex`; the offline `StaleBar` copy was read, not its behaviour.
- Dynamic Type / VoiceOver on the panel beyond the labels present in the files read.
- Anything rendered. No simulator, no build — every "what the reader sees" above is inferred from the view code.

## Unsure

- #1 is certain from the code but has not been tapped through; if the live walk shows the panel surviving a chip tap, something outside these files is intercepting `contentKind` and I have missed it.
- #9's rate-limit family: if counts go through a different window than typed searches, the cost is real but not self-inflicted.
- #6 is a recommendation to prototype, not a defect; the nav-bar trade was made deliberately for all tabs and reversing it for one needs Abdi's call.
