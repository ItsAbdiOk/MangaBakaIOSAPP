# Deep review — Library, Schedule and Discovery screens

2026-09-13. Read-only. Nothing built, run, or edited. Focus: data-shape assumptions
that fail on real inputs (formatters, parsed strings, sort/group keys, first-match
picks, count-derived rules), plus the charter's rate-limit and reachability notes.

## Scope

Slice: `Features/{Library,Schedule,Discovery,Search,Mix,Stack,Browse,Shelf,Onboarding}`
— 52 files, 9,063 lines.

**Grepped: all 52** for `Int(`, `Double(`, `split(`, `components(`, `hasPrefix`,
`first(where:)`, `.first`, `max(by:)`, `sorted(`, `String(format:`, `uppercased()`,
`onChange`, `Task {`, `debounce`, `hasMore`, `.count >=`. Every hit in the list below
was then read in context.

**Read in context (27):** `LibrarySort`, `LibraryList` (lines 1-60, 120-297),
`LibraryModel` (140-200, 236-343), `LibraryEditSheet` (25-40, 95-150, 225-268),
`LibraryView` (100-160), `WrappedView` (60-195), `PickBackUp` (85-97),
`ReadingInsightsView` (165-270), `ScheduleRow` (40-124), `AnnouncedSection` (60-122),
`ScheduleModel` (20-60, 100-225), `DiscoverModel` (60-184), `DiscoverView` (255-270),
`SearchModel` (20-185), `SearchView` (60-70, 195-293), `SearchLens` (120-134),
`LensCounts` (whole), `TagPickerSheet` (380-406), `BrowseModel` (20-71),
`PublisherBrowser` (85-116), `MixModel` (50-155), `MixFilterStrip` (145-170),
`BlendDNAView` (78-95), `StackModel` (130-200, 300-360), `StackSections` (34-80,
120-142), `StackHeader` (grep only), `ShelfStore` (64-68).

**Not read beyond grep (25):** `OnboardingView`, `ScheduleView`, `SearchIdleView`,
`FilterSheet`, `SaveLensSheet`, `SearchEmptyState`, `SeedPickerSheet`, `MixView`,
`MixResults`, `StackView`, `StackHint`, `StackResetMenu`, `BrowseView`, `ShelfCard`,
`WrappedShapes`, `LibraryShape`, `LibraryRouteCards`, `ContinuationsRow`,
`CommunityPulseCard`, `RecentlyViewedRow`, `WhatsNew`, `ShelfDetailView`,
`LibraryRouteCards`, `SearchLens` (1-119), `TagPickerSheet` (1-379). Their grep hits
were labels with no parsing or arithmetic; nothing there matched the focus.

Core files were opened only to verify a type or a payload: `LibraryEntry.swift`,
`Series.swift` (lenientDouble, rating doc), `UpcomingWork.swift`, `ReadingInsights.swift`,
`ReadingWrapped.swift`, `ReadingWrappedYear.swift`, `BlendDNA.swift`,
`Continuations.swift`, `SeriesRepository.swift:662`, `MangaUpdatesClient.swift:14`,
`RootView+Session.swift:25-43`, `design/briefs/api-samples.json` (name_path),
`MangaBakaTests/Fixtures/mix.json` (dna weights).

Already on record and not re-found: L7 (jump index at 20×13pt), D-A2 (DNA strand taps,
since debounced at `MixModel.swift:121-131`), D-A3 (filter chips re-blend, a judgement
call), D-A4, L6/L3 (shelf), periphery's `ShelfCard` unused struct.

---

## Findings, by value

### 1. The A–Z rail emits duplicate letters, which is a duplicate `ForEach` id

- **What** — `indexLetter` and the title comparator disagree on what a letter is, so
  one letter can appear in the rail twice, and the rail keys its rows on the letter.
- **Where** — `LibrarySort.swift:82-85` (`indexLetter`: `first.isLetter` then
  `String(first).uppercased()`); `LibrarySort.swift:43-51` (title sort uses
  `localizedCaseInsensitiveCompare`); `LibraryModel.swift:155-161` (`jumpTargets`
  dedupes only against `seen.last`); `LibraryList.swift:196` (`ForEach(..., id:
  \.element.letter)`).
- **Why it matters** — `localizedCaseInsensitiveCompare` collates "Ōoku" among the
  O's ("Oshi no Ko" < "Ōoku" < "Ouran"), but `indexLetter` files it under "Ō". The
  sorted list therefore reads O, Ō, O and `jumpTargets` yields `[O, Ō, O]`. Two rows
  with id "O" in a `ForEach` is undefined rendering plus a runtime warning; the rail
  drag maths (`LibraryList.swift:243-249`) then divides the rail over a count that
  includes the phantom. Romanised Japanese titles with macrons (Ō, Ū) are ordinary in
  a manga library, as are É/È in French-licensed ones. Same family: "ß".uppercased()
  is "SS" (a two-character letter), and every kana/hanja-leading title gets its own
  rail row — a 200-entry library with 40 Japanese titles grows a rail of 40 extra
  13pt cells. Only shows past 200 entries sorted by title (`LibraryModel.swift:171`),
  which is exactly the reference library.
- **Effort** — a line: fold diacritics in `indexLetter`
  (`folding(options: [.diacriticInsensitive, .caseInsensitive], locale:)`) and map
  non-Latin scripts to one bucket; or key the `ForEach` on the target id.
- **Confidence** — certain that a diacritic-leading title produces the duplicate;
  likely that a real library has one.

### 2. "+1" on the chapter field traps on a large number

- **What** — `chapterText` calls `Int(value)` on a `Double` that came from user text;
  `Int(Double)` is a fatal error outside ±9.2e18.
- **Where** — `LibraryEditSheet.swift:120` (`Double(chapter) ?? 0).rounded(.down) + 1`
  → `chapterText`); `LibraryEditSheet.swift:233-235` (`String(Int(value))`).
- **Why it matters** — twenty digits on the number pad ("99999999999999999999") parse
  as 1e20; `1e20.rounded() == 1e20` is true; `Int(1e20)` crashes the app. Also
  reachable by pasting "inf". CLAUDE.md's "no force-unwraps reachable from real input"
  standard — this is the same class of trap under a different spelling.
- **Effort** — a line: clamp before converting, or format with
  `value.formatted(.number.precision(.fractionLength(0...1)))`.
- **Confidence** — certain.

### 3. Text the chapter field cannot parse silently clears the reader's progress

- **What** — an unparseable chapter string becomes `nil`, `nil != entry.progressChapter`
  counts as a change, and Save sends `progress_chapter: null`.
- **Where** — `LibraryEditSheet.swift:242-244`.
- **Why it matters** — `Double("12,5")` (a European decimal, pasted or from a hardware
  keyboard), `Double("١٢")` (Arabic-Indic digits, which the Arabic keyboard's number
  pad emits), or a stray character all return nil. The Save button lights up because
  `changes` is non-empty, and the reader's "Ch 112" becomes nothing, with no message.
  The sheet's own comment (`:29-31`) records the care taken not to overwrite 12.5
  unasked; this path overwrites it with null.
- **Effort** — a function: parse with a locale-aware formatter and treat a non-empty,
  non-parsing field as invalid (disable Save, say why) rather than as "clear".
- **Confidence** — certain about the nil path; likely about the keyboards that reach it.

### 4. Profile-recommendation exclusions send the 60 highest ids, not the 60 most recent

- **What** — the exclusion list is `reacted.sorted().suffix(60)`, i.e. the sixty
  numerically largest series ids, while the comment says it "covers a long session;
  anything older is still filtered locally".
- **Where** — `StackModel.swift:333` and `:357-360`; `ShelfStore.swift:64-68`
  (`reactedIDs()` returns an unordered `Set` with no timestamp).
- **Why it matters** — series ids are catalogue ids, so this excludes the sixty most
  recently *catalogued* things the reader ever swiped, not the sixty most recently
  swiped. A reader with 300 reactions whose last session was all older series sends
  none of them; the recommender returns them again; `:354` filters them locally and
  the page of twenty arrives as a page of a few — the exact waste the comment at
  `:329-332` says the exclusions exist to prevent. Second-order: the exclusion set
  changes as reactions land while `recommendationPage` keeps counting up (`:326`), so
  the server's page window shifts under the client and items are skipped.
- **Effort** — a function: `SELECT seriesId FROM shelfEntry ORDER BY rowid DESC
  LIMIT 60` (or by `reactedAt` if the table has it) and pass that.
- **Confidence** — likely. Certain that the code sends the highest ids; whether
  MangaBaka's ids ascend with catalogue time is an open question below.

### 5. The Wrapped "critic" caveat names the wrong series as "furthest apart"

- **What** — the caveat always uses `facts.loved.first`, the reader's largest
  *positive* disagreement, even on the "tough crowd of one" card where the gap is
  negative.
- **Where** — `WrappedView.swift:177-178`; `facts.loved` built at `:77` with
  `liked: true` only; `ReadingWrapped.swift:178-191` (`disagreements` filters by sign).
- **Why it matters** — a harsh critic (mean gap −0.8 stars) sees "Furthest apart on X —
  +0.3 stars against the crowd": X is their mildest disagreement in the wrong
  direction, while the −2.5-star one that drove the headline is never named. If they
  rated nothing above the crowd, `loved` is empty and the caveat vanishes although the
  furthest-apart series plainly exists.
- **Effort** — a function: compute `disagreements(liked: false)` too and pick the larger
  absolute gap, or pick by sign of `critic.gap`.
- **Confidence** — certain by construction for any reader whose largest |gap| is
  negative.

### 6. The Continuations walk restarts on every library page

- **What** — `.task(id: model.entries.map(\.id))` re-runs `continuations.load` each
  time a page of the library lands, and `load` neither checks cancellation nor
  records `loadedFor` until it finishes.
- **Where** — `LibraryView.swift:138-140`; `LibraryModel.swift:249-251` (a partial
  apply per page, 100 per page per `LibrarySnapshot.swift:22`);
  `Continuations.swift:107-129`.
- **Why it matters** — a 939-entry library arrives in ten pages, so the id changes ten
  times and ten walks start. Each walk fetches relationships for up to eight
  "most recently finished" series (`Continuations.swift:30-44`), and that set shifts
  as later pages bring more recent finish dates, so the in-memory cache
  (`SeriesRepository.swift:662-669`) does not absorb it; a cancelled fetch returns nil
  via `try?` and is not cached either. Worst case is tens of `/relationships`
  requests during one library load, against the 180/min limit shared with the
  schedule build and the taste ledger's own walk.
- **Effort** — a line: key the task on `model.isComplete` (it already exists,
  `LibraryModel.swift:38`), or return early from `load` until the snapshot is complete.
- **Confidence** — likely. Not measured; the count depends on how many finish dates
  each page shifts.

### 7. Chapter progress is truncated in every list but preserved in the editor

- **What** — four formatters print `Int(progressChapter)`, dropping the half chapter
  the editor takes pains to keep.
- **Where** — `LibraryList.swift:142`, `PickBackUp.swift:95`,
  `ReadingInsightsView.swift:174`, `ShelfDetailView.swift:229,237`; contrast
  `LibraryEditSheet.swift:29-31`.
- **Why it matters** — a reader at 12.5 sees "Ch 12 / 179" in the list, opens the
  editor and sees 12.5. Small, but it is the same number shown two ways on the same
  screen, and `ReadingInsights.chaptersLeft` (`ReadingInsights.swift:78`) truncates
  the difference too, so 99.5 of 100 reads as "nothing left".
- **Effort** — a line each: reuse `LibraryEditSheet.chapterText`.
- **Confidence** — certain; low reach.

### 8. "three seconds apart" is a copy of `MangaUpdatesClient.minimumInterval`

- **What** — the explanation hard-codes the interval the estimate beside it derives.
- **Where** — `ScheduleModel.swift:140-141` (literal "three seconds apart");
  `ScheduleModel.swift:129-135` (`firstRunEstimate` uses
  `MangaUpdatesClient.minimumInterval`, currently 3.0 at `MangaUpdatesClient.swift:14`).
- **Why it matters** — the charter's duplicated-constant pattern (`pageSize`/`pageCap`).
  Change the client's spacing to 3.5 like the other three feed clients already are
  (`GigaViewerFeedClient.swift:20`, `NaverFeedClient.swift:14`,
  `WebtoonsFeedClient.swift:13`) and the screen says "three seconds" next to "about 4
  minutes" computed at 3.5.
- **Effort** — a line: interpolate the constant.
- **Confidence** — certain.

### 9. Volume progress hides chapter progress in the list row

- **What** — any `progressVolume > 0` wins over `progressChapter`.
- **Where** — `LibraryList.swift:134-142`.
- **Why it matters** — a reader who once set "Vol 1" on the website and has tracked
  chapters since sees "Vol 1 / 30" instead of "Ch 112 / 179"; the more specific number
  is the one hidden. The `Behind`/`PickBackUp` maths use chapters only, so the row and
  the nudge beneath it disagree about where the reader is.
- **Effort** — a line: prefer chapters when both are set, or show both.
- **Confidence** — worth checking against a real library's `progress_volume` values.

### 10. Filter chips in Mix fire a blend per tap, undebounced

- **Where** — `MixFilterStrip.swift:156,161,168` (`Task { await model.run() }`) versus
  strand taps at `MixModel.swift:121-131` which were given a debounce for exactly this.
- Already on record as D-A3 (judgement call) in `docs/todo-next-week.md:161`. One
  line here for completeness: three quick chip taps are three `/v1/series/mix`
  requests; `generation` handles the ordering but not the spend. Effort: a function —
  route through `blendAfterEdits`. Confidence: certain about the request count.

### 11. Stack caption shows the first three tags in wire order

- **Where** — `StackSections.swift:68-70` (`tags.prefix(3)`); `Series.swift:123`
  (`tags` is the flat list, unsorted); `Series.swift:61,170` (`tagsV2` carries
  core/defining/recurrent/incidental weights, used only by `TasteRanker.swift:29-50`).
- **Why it matters** — the card exists to let a reader judge in one glance, and it
  shows whatever three the API listed first. If the flat list is not weight-ordered,
  Solo Leveling's 146 tags open with something incidental while "core" tags exist in
  the same payload. Not verifiable here: no recorded payload has both lists populated
  (`mix.json` has `"tags": []`).
- **Effort** — a function: prefer `richTags` sorted by importance when present.
- **Confidence** — worth checking. Open question below.

### Reachability (charter 7)

`ShelfDetailView` is **now reachable**: `LibraryView.swift:106` → `onOpenShelf` →
`RootView+Session.swift:28,36-42` (re-wired 2026-09-11 per `todo-next-week.md:158`).
Nothing else in the slice is unreachable: every other view type has a presenter in
another file, checked by name. `ShelfCard` (`ShelfCard.swift:5`) remains unused, as
periphery already reports.

### Rate limit (charter)

Per-keystroke paths, each verified: Search (`SearchView.swift:111` →
`SearchModel.swift:36-74`, 300 ms cancel-and-replace), publishers
(`PublisherBrowser.swift:91-115`, 350 ms), tag picker (`TagPickerSheet.swift:88` →
`TagSearch`, proven elsewhere), seed picker (`SeedPickerSheet.swift:77` → the same
`SearchModel`). Nothing fires per keystroke. Per-tap without spacing: finding 10.
Per-page: finding 6.

### Not findings, checked and cleared

- `BrowseModel.swift:48` splits `name_path` on `" > "` — confirmed against
  `design/briefs/api-samples.json:153`.
- Rating scales: series `rating` 0-100 shown `/10` (`DiscoverView.swift:263`,
  `StackSections.swift:128`); entry `rating` 0-100 shown `/20`
  (`LibraryList.swift:157`, `LibraryEditSheet.swift:33`, `ReadingWrapped.swift:191`).
  `criticGap` subtracts two 0-100 numbers (`ReadingWrapped.swift:166-168`). Consistent.
- `SearchLens.swift:130` `rating / 10` integer division — steps are multiples of ten
  (`RatingSegments.swift:18`), so exact.
- `TagPickerSheet.swift:399-405` rank-based breadth handles ties by first index; all
  tied tags get one step, which is the intent.
- `Int(Double)` on decoded values (`LibraryList.swift:137-142`,
  `LibraryEditSheet.swift:141`, `ReadingInsightsView.swift:174-175`): `lenientDouble`
  (`Series.swift:342-346`) would pass `Double("inf")` through, but JSONDecoder rejects
  non-finite numbers and the API has not been seen sending the string. Not reachable
  on recorded payloads.

---

## What this slice does well

- `SearchModel.swift:36-74` — the debounce is a real cancel-and-replace, the double-fire
  on `apply` is handled with `appliedText` and the reason written down, and the
  `sort == "random"` reset cites a measurement ("32 series and ONE PIECE is not among
  them … 411 with it first, 2026-09-10").
- `SearchModel.swift:130-183` — `loadMore` dedupes ids, takes `hasMore` from the API's
  own `pagination.next` rather than the filtered count, and caps empty pages at three
  with the 30 req/min arithmetic stated. The "Isekai never got past 30" note is the
  kind of evidence the charter asks for.
- `DiscoverModel.swift:157-166` — reload-generation guard for a page that lands after a
  pull-to-refresh, with the comment recording that the `page`-based check was tried
  first and failed a test.
- `LensCounts.swift:10-23` — the cost of the design is stated, the fallback is named,
  and the note says to tell Abdi rather than change it quietly. `:44-50` explains why
  "asked" is set on answer, not on start.
- `ReadingWrappedYear.swift:72-74` — `busiestMonth` returns nil on a tie instead of
  picking one, so "More than any other month" (`WrappedView.swift:129`) is never false.
- `BlendDNA.swift:12-15` — the weight scale is documented from a real blend
  ("0.161 down to 0.065"), and `BlendDNAView.swift:92` matches it; checked against
  `Fixtures/mix.json:532-542`.
- `LibrarySort.swift:24-64` — every sort has a stable tiebreak; nil dates go last with
  the reason; `.dateAdded` says what it actually uses.
- `LibraryEditSheet.swift:29-31` — keeps 12.5 as 12.5, with the bug it fixed recorded.
- `LibraryModel.swift:163-171` — the jump index is gated on sort and count with the
  design board's own caption quoted as the derivation.
- `LibraryList.swift:122-127` — the `.id(entry.seriesId)` comment records the identity
  bug it fixed and its symptom.
- `ScheduleModel.swift:122-135` — `firstRunEstimate` is derived from the client constant
  and says so (half of finding 8 is already right).
- `PublisherBrowser.swift:91-92` — debounced, with the rate-limit reason on the line.
- `TagPickerSheet.swift:380-388` — the switch from magnitude to rank cites what was seen
  on device ("eight identical bars in a row").

## Open questions

1. Do MangaBaka series ids ascend with catalogue insertion time? If not, finding 4's
   exclusion set is effectively random rather than "newest catalogued"; either way it is
   not "most recently swiped".
2. Is the flat `tags` array weight-ordered on the wire? No recorded payload has both
   `tags` and `tags_v2` populated. One `/v1/series/{id}` capture would settle finding 11.
3. Which keyboards the chapter field actually sees. The Arabic-locale number pad and
   hardware keyboards are the inputs that reach finding 3; the standard English pad
   cannot type a comma or a letter, only the twenty-digit crash in finding 2.
4. How many `/relationships` requests a real ten-page library load issues (finding 6).
   A count from a signpost or the client's request log would turn "likely" into a number.
