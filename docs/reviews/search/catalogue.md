# Search review — catalogue slice (tags, genres, publishers, type chips)

Date 2026-09-13. Read-only. Files read in full: `TagPickerSheet.swift`, `FilterPanel.swift`,
`CatalogueService.swift`, `Catalogue.swift`, `TagSearch.swift`, `TagTaxonomy.swift`,
`SeriesTag.swift`, `BlockedTagsSection.swift`, `ContentPreferences.swift`, `BrowseModel.swift`,
`PublisherBrowser.swift`, `SearchQuery.swift`; partial: `BrowseView.swift`, `SearchModel.swift`,
`SeriesRepository.swift` (`filterQuery`), `OfflineCatalogue.swift` (tag filter), `SearchLens.swift`,
`SearchEmptyState.swift`, `BrowseDestination.swift`, `RootView(+Session).swift`,
`docs/schemas/mangabaka_openapi.json`, `Resources/TagTaxonomy.json`.

Live measurements below were taken today against `api.mangabaka.org` with `limit=1`
(16 search requests, 1 tags request). Control: bare `/v1/series/search?limit=1` answers
`count: 304696`, which agrees with the 304,096 recorded on 2026-09-10 in
`PublisherBrowser.swift:6` to within three days of growth.

## Findings

### 1. "Match any" is "Match all" — the app never sends `tag_mode=or`, and the API ignores it anyway
- **What** — the tag picker's "Match any" button sets `mode = nil`; `SearchQuery` only sends `tag_mode` when non-nil; the API's default is `and`. So both buttons produce an AND query.
- **Where** — `TagPickerSheet.swift:190-191` (`modeButton("Match all", value: "and")`, `modeButton("Match any", value: nil)`); `SearchQuery.swift:102-104`; API default `tag_mode: and` (`docs/schemas/mangabaka_openapi.json`, `/v1/series/search`). Offline path agrees: `OfflineCatalogue.swift:299-305` treats anything but the literal `"or"` as AND. Mix uses the correct vocabulary (`MixFilterStrip.swift:183` toggles `"and"`/`"or"`), so the same `TagPickerSheet` presented from Mix (`MixView.swift:76-79`) writes `nil` into a field Mix expects to be `"or"`, and `MixFilterStrip.swift:176-177` patches `nil` back to `"and"`.
- **Also measured** — even sending `or` explicitly changes nothing: `tag=Isekai&tag=Regression` → 164; `…&tag_mode=or` → 164; `…&tag_mode=and` → 164. `tag=isekai` alone is 7,116, so OR should be ≫ 164. Same for `tag=action&tag=romance` with/without `tag_mode=or`: 669 both. Either the parameter is dead server-side or wants a shape nobody has found.
- **Why it matters** — a reader who picks Isekai + Regression and taps "Match any" expecting ~8,000 results gets 164 with no explanation, and the lens summary at `SearchLens.swift:108` prints them comma-joined (reads as "either") while the request is AND. Tests agree with the bug (charter #2): `SearchAndMixTests.swift:297,317` only ever set `"and"`; nothing asserts that "any" sends `or`.
- **Effort** — one line to send `"or"`; but the button should be removed (or the offline path made the only place it works) until the API honours it. A function.
- **Confidence** — certain (app side: read; API side: three live measurements today).

### 2. Genres are sent as `tag=`, which finds a fraction of what `genre=` finds
- **What** — picking a genre (Genres sheet, Browse chips, or `applyBrowse(genre:)`) puts the genre *value* into `query.tags`, so it goes to the wire as `tag=slice_of_life`. The API has a separate `genre` parameter and a separate 46-value vocabulary.
- **Where** — `FilterPanel.swift:129` (`GenrePickerSheet(… selected: $query.tags)`); `FilterPanel.swift:151-153` doc says "a genre *is* a tag as far as the query is concerned"; `SearchModel.swift:396` (`if let genre { next.tags = [genre] }`); `SearchQuery.swift:101` sends `tag=`; the schema lists `genre`/`genre_not` beside `tag`/`tag_not`.
- **Measured today** — `tag=slice_of_life` → 2,017; `genre=slice_of_life` → 34,220. `tag=romance` → 14,065; `genre=romance` → 100,947. So "Romance" via the Genres button shows 14% of the romance catalogue, and "Slice of Life" 6%. (The API is matching the tag whose name happens to fold to the genre value; the tag "Romance" carries 109,065 series in the bundled taxonomy, so the 14,065 is probably the *safe-rated* subset of the tag — the request had no `content_rating`. Either way it is not the genre.)
- **Offline** — worse: `OfflineCatalogue.swift:319-326` resolves `query.tags` names against bundled tag names, so `"slice_of_life"`, `"school_life"`, `"martial_arts"`, `"boys_love"`, `"girls_love"`, `"gender_bender"`, `"avant_garde"`, `"award_winning"`, `"mahou_shoujo"`, `"shoujo_ai"`, `"shounen_ai"` resolve to nothing and the filter is silently dropped — a genre-only offline search returns the whole index. `"romance"`, `"sci-fi"` happen to match by case-folding.
- **Why it matters** — the Genres door is the coarsest, most-tapped filter for a first-time reader and it under-reports by 7–17×; the "Show 2,017 results" preview makes the wrong number look authoritative. The badge on the "Genres" button and `genresOnlyCount` (`FilterPanel.swift:156-157`) only exist because the two vocabularies were folded into one array.
- **Effort** — a `genres: [String]` field on `SearchQuery`, sent as `genre=`; offline `passesGenre` (the export's `g` array would need checking for genre ids); Genres sheet and `applyBrowse` bind to it. A file plus small edits in three.
- **Confidence** — certain (live, two genres; offline by reading).

### 3. The live tag fetch replaces a better bundled list with a worse one: 17 groups become 4
- **What** — `/v1/tags?limit=500` returns the first 500 tags in the API's own order (root-alphabetical: all of Activities, then Audience Demographics …). The picker loads the bundled taxonomy (2,686 rows, 17 roots) first, then `tags = live` when the fetch lands, so the browse groups shrink from 17 to 4.
- **Where** — `TagPickerSheet.swift:338-345` (`tags = live` unconditionally when non-empty); `TagPickerSheet.swift:243-244` (`roots` derived from `tags`); `CatalogueService.swift:69-101` (limit=500 page one, `isPartial: false` at line 87 although `pagination.next` is present).
- **Measured today** — `/v1/tags?limit=500`: 500 rows, `pagination.count: 7146`, `next: …&page=2`, 115,861 bytes in 0.13s. Roots in the page: Activities, Audience Demographics, Character Archetype, Character Traits — four. Levels: 4 root / 255 level-2 / 241 deeper. No `is_genre`, no `is_spoiler`, no merged tags in the page. Bundled file: 17 roots (Themes, Settings, Relationship, Narrative Tropes, Occupations … all absent from the live page).
- **Why it matters** — online, the picker's browse mode loses Themes, Settings, Relationship, Narrative Tropes — the groups a reader would actually browse — and the placeholder flips from "Search 2,686 tags" to "Search 500 tags" (`TagPickerSheet.swift:158`), which is a *smaller* honest number than a moment ago. The same picker offline is better than online. `BlockTagPicker` has the identical shape (`BlockedTagsSection.swift:213-218`). Browse (`BrowseModel.swift:86`, limit 200) never sees the bundled file at all, so "All tags" there is Activities plus a slice of Audience Demographics, and its subtitle says "200 of the tags beneath them".
- **Effort** — either merge live into bundled by id (keep bundled rows the page did not cover; take live counts where present), or page the endpoint to completion once per process (15 × 115 KB ≈ 1.7 MB, 180/min bucket, CDN-cached 1h per the schema's `x-cache-ttl`) and persist it. A function either way, plus flipping `isPartial` to `next != nil`.
- **Confidence** — certain (measured today; reading).

### 4. Two-thirds of the tag tree is unreachable by browsing, and "N more in search" undercounts it
- **What** — `group(_:)` lists only direct children of a root (`parentId == root.id`), eight of them; deeper levels are never listed. Bundled: 1,879 of 2,686 tags are level ≥ 3 (e.g. "Settings > Fantasy > Isekai", the tag with 8,890 series, is level 3 and never appears under Settings).
- **Where** — `TagPickerSheet.swift:249-251` (children filter), `:282` (`prefix(Self.perGroup)`), `:292` ("\(children.count - perGroup) more in search" counts only level-2 siblings). `perGroup = 8` at `:38` carries no derivation and no `guess` label (charter #4).
- **Why it matters** — a reader who opens "Settings" sees 8 of 33 sub-groups and the note "25 more in search", when the true count beneath Settings is several hundred; Isekai, one of the most-searched tags on the site, is not browsable at all. The `Tag.namePath` the model decodes (`Catalogue.swift:22`) and documents as "useful as a subtitle" is never rendered in the picker or the search matches, so "Fantasy" (a Settings child) and "Fantasy" the genre are indistinguishable rows when both surface in a search.
- **Effort** — show `namePath` minus the leaf as a subtitle on `TagPickerRow` (a line); make groups drill down or count descendants (a function).
- **Confidence** — certain.

### 5. The picker ignores the reader's content rating and spoiler settings; blocked tags are pickable and then return zero
- **What** — `TagPickerSheet` shows every usable tag regardless of `ContentPreferences`; the bundled list has a "Sexual Content" root with 22 direct children, and the live page carried 4 `erotica`-rated rows. Spoiler tags (`isSpoiler`) are hidden by Browse (`BrowseModel.swift:56`) but not by the picker. Blocked tags are not marked or hidden in the picker; picking one sends `tag=X` alongside `tag_not=<id of X>`.
- **Where** — `TagPickerSheet.swift:329,339` (only `.filter(\.isUsable)`); `Tag.contentRating`/`isSpoiler` decoded at `Catalogue.swift:33,36` and read nowhere in Search; `SeriesRepository.swift:731` appends `tag_not` for every search; `SearchEmptyState.swift:88-93` reports "One filter is still applied" with no mention of the block.
- **Measured today** — `tag=Isekai&tag_not=94` → 0 (`tag_not` by id is honoured by search — this also closes the open item P-F10 for the search endpoint; `tag_not=Isekai` by name → HTTP 400 "expected number", so the id/name split in the app is right).
- **Why it matters** — a reader on the default safe+suggestive setting browses "Sexual Content" in a filter picker, and a reader who blocked a tag in Settings can pick it in Search and get "Nothing matched" with advice to loosen a filter they cannot see. The blocked-tag names are already in `BlockedTagsStore` (`BlockedTags.swift:53`), so marking them costs a lookup.
- **Effort** — filter `contentRating` against `ContentPreferences.queryValues` and `isSpoiler` by default (a few lines, once `TagTaxonomy` carries the rating — it sets `contentRating: nil` at `TagTaxonomy.swift:87` because the bundled rows lack it); pass blocked ids into the picker and grey the row (a function).
- **Confidence** — certain for the blocked-then-zero path (measured); certain for the missing rating filter (read).

### 6. `Tag.level` and the test fixture say root is 0; the API says 1
- **What** — model doc "0 is a root", fixture root `level:0`, live root rows are `level: 1` (bundled file agrees: 17 rows at level 1, none at 0). `content_rating` is documented `enum [...] default safe` and is never null on the wire; the fixture sends `null`.
- **Where** — `Catalogue.swift:24-25`; `CatalogueTests.swift:55-57,73` (`#expect(root?.level == 0)`).
- **Why it matters** — nothing reads `level` today (charter #3: decoded and discarded, along with `description`, `isGenre`, `contentRating`, `namePath` in the picker), so it costs nothing yet; it is a fixture with no provenance that will mislead the first person who uses `level` for indentation (charter #1/#2).
- **Effort** — a line each.
- **Confidence** — certain.

### 7. Genres and tags are two vocabularies presented as one — and the Genres count badge depends on a fetch
- **What** — the Genres badge is `query.tags` minus values that match a loaded `[Genre]`; until `catalogue.genres()` lands (or if it fails), every genre counts under "Tags" and "Genres" shows nothing. A saved lens with `tags: ["romance"]` restored before the fetch shows Tags 1 / Genres 0, then flips.
- **Where** — `FilterPanel.swift:154-157,168-169,206-209`.
- **Why it matters** — a small visible inconsistency on the idle screen, entirely caused by finding 2; fixing 2 removes it.
- **Effort** — goes away with finding 2.
- **Confidence** — certain.

### 8. Local tag matching is diacritic-sensitive; offline title matching is not
- **What** — `TagSearch.update` filters loaded tags with `localizedCaseInsensitiveContains` (substring, case-insensitive, diacritic-sensitive). Typing "cafe" does not locally match "Café" (the one accented bundled name); the remote answer may.
- **Where** — `TagSearch.swift:59`; contrast `OfflineCatalogue.swift:312` (`.diacriticInsensitive`).
- **Why it matters** — one tag today; a consistency point, not a reader-facing failure. "isekai" vs "Isekai" is fine (case-insensitive both locally and, measured, on the API).
- **Effort** — a line.
- **Confidence** — certain.

### 9. The schema has no `q` or `limit` on `/v1/tags`; the code sends both on a dated measurement
- **What** — `docs/schemas/mangabaka_openapi.json` declares `/v1/tags` with no parameters ("Get all tags"). The code sends `limit` and `q` and relies on `?q=romance` returning 35 tags (measured 2026-09-10, `CatalogueService.swift:110-114`).
- **Where** — `CatalogueService.swift:76-79,121-127`.
- **Why it matters** — `limit` demonstrably works (today: 500 rows, paginated). `q` was not re-measured today; if it stops working the search path in `TagSearch` degrades to local-only with `didFail` never set (a `[]` from the server is "no match", not failure). Worth one curl when someone is next in there.
- **Effort** — none; record it.
- **Confidence** — worth checking (for `q`).

### 10. Two vocabulary fetches instead of one when Browse opens before the picker
- **What** — Browse asks `tags(limit: 200)`, the picker `tags(limit: 500)`; the cache correctly refuses to serve 500 from 200, so both requests go out. Both are on the 180/min bucket, not the 30/min search bucket, and CDN-cached; cost is one extra ~50 KB request per process.
- **Where** — `BrowseModel.swift:86`, `TagPickerSheet.swift:338`, `CatalogueService.swift:71`.
- **Effort** — collapse to one limit (a line) — moot if finding 3 pages the whole list.
- **Confidence** — certain; low impact.

## Answers to the brief's questions (with lines)

- **Catalogue loading** — fetched on first ask, per process, no TTL, never persisted (`CatalogueService.swift:23-24,44-101`); the API's own cache hint is 1 h CDN / 1 min browser. Live page: 500 rows, 116 KB, 0.13 s; full set 7,146 rows ≈ 1.7 MB. While loading the Tags button is live and the sheet opens instantly on the bundled 2,686 (`TagPickerSheet.swift:329-336`); on failure with bundle present, a footnote (`:105-109`); on failure with no bundle, `FailureState` with retry (`:44-48`); nothing came back at all → `EmptyState` (`:49-61`). Not dead, not disabled, not blank — done well. Genres button: opens the sheet and fetches; a failed fetch shows an empty `FlowLayout` with no message (`FilterPanel.swift:383-429`) — the one blank-sheet path left in this slice.
- **Tag tree** — merged excluded both sources (`CatalogueService.swift:85`, `TagTaxonomy.swift:62`); roots alphabetical, children by `seriesCount`, 8 shown, only level 2 (finding 4). Search-within: local substring case-insensitive (`TagSearch.swift:59`), then API `q=` merged behind it after 250 ms debounce (`:35,62-75`) — one request per settled word, not per keystroke. Mode: finding 1; nothing on screen explains all/any beyond the two labels.
- **Blocked vs search** — finding 5. `tag_not` on search: supported and used (`SeriesRepository.swift:725-731`), honoured live today.
- **Genres vs tags** — two vocabularies in the API (`/v1/genres`, 46 enum values; `genre=` param) collapsed into `query.tags` and sent as `tag=` — finding 2.
- **Publishers** — no list endpoint (`/v1/publishers` absent from the schema; `PublisherBrowser.swift:9-12` records the 503). Search-only, debounced 350 ms after 2+ chars (`PublisherBrowser.swift:95-115`), `limit` 30 (`CatalogueService.swift:196`), API default sort `name_desc` — no client sort, so results arrive Z→A unless the API's relevance overrides; I did not measure this. Picking one in Search sets `query.publisher = name` (`FilterPanel.swift:134-137`), the same thing Browse's chip does via `applyBrowse(publisher:)` (`BrowseDestination.swift:29`, `SearchModel.swift:397`). A publisher tapped on a series page goes to `PublisherView` instead (`RootView+Session.swift:350`). Consistent within Search/Browse; the detail page is a different door, deliberately.
- **Type chips** — list hard-coded at `FilterPanel.swift:49` = `["manga","novel","manhwa","manhua","oel","other"]`, which is exactly the schema's `type` enum on `V1_Series_Default`, `V1_Series_Full`, `SeriesV2`, `SeriesV2Full`. `DetailHero.typeLabel` (`DetailHero.swift:296-302`) gives "OEL" and `.capitalized` for the rest. Charter #1 clean. (Status chips omit `unknown`, which `SearchQuery.swift:9` lists — outside my slice, noted.)
- **Selection counts** — Tags = `query.tags` not in loaded genre values; Genres = the complement; Publishers = 0/1 (`FilterPanel.swift:156-157,168-173`). All three read bindings into `query`, so swipe-dismiss cannot desynchronise them; the only drift is finding 7.
- **Charter #3, computed and never shown** — `Tag.description` (9 of 500 live rows non-empty), `Tag.namePath` (in the picker), `Tag.level`, `Tag.isGenre`, `Tag.contentRating`, `Tag.isSpoiler` (in the picker); `Fetched.isPartial` always `false` for a paginated page; `TagTaxonomy.loadFailed` (`TagTaxonomy.swift:44`) is read by nobody in Search — a missing bundle shows as `.nothing`/`bundledOnly` with no packaging-bug hint. Force-unwraps: none in the files read.

## Done well
- `CatalogueService.tags(limit:)` caches by the limit asked and lets a second caller join an in-flight fetch (`CatalogueService.swift:25-37,71-72`) — the comment records the bug it fixed and why the naive version failed.
- Failures are never cached and never conflated with empty: `Fetched` with `.failed(error, stale: nil)` at `:57,89`; `searchTags`/`searchPublishers` return `nil` not `[]` (`:116-117,134-137`), and `PublisherBrowser.swift:111-113` says "Could not search" vs "No publisher by that name".
- `findPublisher` (`CatalogueService.swift:142-190`) has three dated live measurements and a prefix rule that refuses the reverse match, with the counter-example written down.
- Bundled-first tag picker: opens instantly and offline, labels the bundle's date (`TagPickerSheet.swift:106`), and the three-way `TagPickerStatus` is pure and tested (`:446-461`, `SearchScreenTests.swift:81`).
- `TagBreadth.step` ranks by percentile with the reason the value-scaled version failed on device (`:464-493`), and the sort is hoisted out of the per-row path (`:480-485`).
- `TagSearch` debounces at 250 ms and never replaces local hits with fewer (`TagSearch.swift:57-75`); `PublisherBrowser` at 350 ms after 2 chars; `FilterPanel.scheduleCount` at 350 ms — nothing in this slice fires a request per keystroke.
- `SearchQuery.queryItems` sends repeated keys with the HTTP-400 reason recorded (`SearchQuery.swift:82-83`); `blocked_tag` vs `tag_not` split is documented at its source (`SeriesRepository.swift:716-724`) rather than copied.
- `TagTaxonomy.load` handles the three duplicated paths with `uniquingKeysWith` and says which three (`TagTaxonomy.swift:64-71`).

## Not reviewed
- `FilterPanel` layout/IA, status chips, sort, rating, year, offline toggle (another agent).
- `BrowseView` body beyond the tag/genre/publisher wiring; `PublisherView`; `PublisherBrowseTests`, `BrowseModelTests`, `TagTaxonomyTests` bodies.
- Whether `/v1/tags?q=` still works (finding 9); whether `/v1/publishers/search` results arrive in `name_desc` order as the schema's default implies.
- `MixView`/`MixFilterStrip` beyond the `tagMode` vocabulary mismatch.
- Rendering on device — no simulator run.
