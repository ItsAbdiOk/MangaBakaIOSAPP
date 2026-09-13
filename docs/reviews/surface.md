# Surface slice — deep review, 2026-09-13

Read-only. No build, no lint, no test run, no edits outside this file. Focus for
this run: data-shape assumptions that fail on real inputs, then charter 6.

## Scope

**Reviewed in full (read line by line):** `Detail/DetailStatsStrip.swift`,
`DetailCredits.swift`, `ReadRow.swift`, `LinksSection.swift`, `PublisherView.swift`,
`TrackerScores.swift`, `ReleaseSection.swift`, `VolumesSection.swift`,
`AppleVolumesRow.swift`, `AlternativeTitles.swift`, `DetailHero.swift`,
`DetailBarTitle.swift`, `DetailEditions.swift`, `DetailOnwardRows.swift` (rows only),
`SeriesDetailView+Covers.swift`, `SeriesDetailView+Store.swift`,
`SeriesDetailView+Releases.swift`, `CharacterProfileView.swift` (load/translate/facts),
`CharacterRow.swift` (top half), `Shared/ScrollEdge.swift`, `SearchClearButton.swift`,
`EdgeSwipeToDismiss.swift`, `InlineSearchField.swift`, `DesignSystem/TapTarget.swift`,
`Motion.swift` (top half), `App/RootView.swift` (publisher route only).

**Read because the views depend on them (Core, outside the slice, cited where the
defect lives there):** `Core/Model/Series.swift`, `SeriesExtras.swift` (SeriesLink),
`ReadingPlatforms.swift`, `LanguageFlag.swift`, `SeriesWebLink.swift`,
`CatalogueService.findPublisher`, `SearchQuery` (publisher/staff), `SeriesWork` (dates),
`ReleaseSummary.summarise`, `ReleaseFeedService.report`, `TranslationGap`,
`NaverFeedClient.date`, `SeriesImage.preferredCover`.

**Grepped only, not read:** `Detail/CoverGallery.swift`, `DetailTagSections.swift`,
`DetailScheduleBlock.swift`, `DetailSynopsis.swift`, `LibraryControl.swift`,
`DetailBackdrop.swift`, all of `Settings/`, the rest of `Shared/` and `DesignSystem/`,
`App/AppServices.swift`, `RootView+Session.swift`. The grep was for `Int(`, `Double(`,
`split(`, `components(`, `first`, `max(by`, `hasPrefix`, `contains(`, formatters,
`try!`, `as!`, `fatalError`, `TODO/FIXME/TEMP`. Settings and App produced no
data-shape hits worth reading in context; that is a statement about the grep, not a
clean bill.

**Not reviewed:** `fork/`, GRDB, `MangaBaka/Apple/`, tests except
`NonsenseGuardTests.swift:8-40`.

**Live requests (3 of 3 used):**
1. `GET https://api.mangabaka.dev/v1/series/3397/full` → HTTP 500, body: "api.mangabaka.dev
   is deprecated and no longer serves traffic — switch to https://api.mangabaka.org".
   The app already uses `.org`; the `.dev` host in the brief is dead.
2. `GET https://api.mangabaka.org/v1/series/3397/full` → 149 KB, saved to the scratchpad.
   Shapes used below: `anime: {"start": "Chap 0 (S1) / Chap 46 (S2)", "end": "..."}` with
   **no `exists` key** and a sibling `has_anime: true`; `authors: ["Chu-Gong"]`,
   `artists: ["Seong-Rak Jang"]`; 18 publishers incl. `"Panini Manga México "` (trailing
   space), `type: "Other"` with `note: "Portuguese"`, `note: ""` and `null` both present;
   `total_chapters: "201"`, `final_volume: "15"` (strings); `rating_count: null`;
   `titles` carry four entries with the `native` trait (`ko`, `ko-Latn`, `ja-Latn`, `ja`);
   `links_v2` has 13 webplatform links including `piccoma.com` (ja) and
   `tw.kakaowebtoon.com` labelled `ko`; `source.anime_planet.rating = 4.6` with
   `rating_normalized = 92`; `source.anime_news_network.rating = null`.
3. `GET https://api.mangabaka.org/v1/publishers/search?q=Ize%20Press%20(Yen%20Press)&limit=10`
   → `[]`. Zero hits for the name exactly as the series credits it.

Already established in `SUMMARY-2026-09-11.md` and not re-derived: S-F1 (`shown` vs
`series`, fixed), S-F5 (`heroTitleTravel` fitted to one size), S-F8, S-F17, S-F20,
S-F22, S-F23b. Nothing below repeats them.

## Findings, ordered by value

### 1. "Anime adaptation: None listed" for a series that has one, on the v1 shape

- **What** — the credits row reads `anime.exists == true ? "Yes" : "None listed"`, and the
  v1 `anime` object has no `exists` key; the fact is a sibling field `has_anime`.
- **Where** — `MangaBaka/Features/Detail/DetailCredits.swift:77-78`;
  `Series.AnimeAdaptation` at `Core/Model/Series.swift:71-76` decodes `exists`, `start`,
  `end` and nothing else; `has_anime` is not modelled.
- **Why it matters** — measured today on `/v1/series/3397/full`: Solo Leveling arrives as
  `anime: {start: "Chap 0 (S1)…", end: "…"}`, `has_anime: true`. `exists` decodes nil, so
  the row prints "None listed" for a series with two anime seasons — the exact
  "claim, not a shrug" the comment above it forbids. The page's own fill is
  `/v1/series/{id}` (`SeriesRepository.swift:683`), and `filling(gapsFrom:)` takes
  `anime ?? other.anime` (`Series.swift:214`), so any series whose front copy carries no
  `anime` (every library entry, per `NonsenseGuardTests.swift:38-40`) gets the v1 object
  and the wrong answer. Charter 2 applies: `NonsenseGuardTests.swift:30` fixes
  `{"exists": true}`, the model's shape, so the suite passes against a payload v1 does not
  send.
- **Effort** — a line in the view (`exists == true || start != nil`) is the stopgap; the
  fix is one decoded field (`hasAnime`) read by the row.
- **Confidence** — certain for `/full`; likely for the non-`/full` `/v1/series/{id}` the
  page actually calls (not fetched — request budget).

### 2. Volume release dates rendered in the device zone after being parsed as UTC midnight

- **What** — `SeriesWork.date` parses `"2021-03-02"` as UTC midnight and provides
  `utcYear(of:)` precisely so the year is read back in UTC; the views ignore that and read
  the date through `Calendar.current` / `formatted(...)`.
- **Where** — `MangaBaka/Features/Detail/VolumesSection.swift:75` (spine year via
  `Calendar.current.component(.year, from:)`), `:90` (VoiceOver month/year), `:151`
  (sheet's full date). The parser and its warning: `Core/Model/SeriesWork.swift:89-106`.
- **Why it matters** — every reader west of UTC (all of the Americas) sees each volume
  dated one day early: a 1 January release shows as 31 December of the previous year on
  the spine and in the sheet. The model's own comment names this hazard; the fix was
  applied to `editionLabels` (`SeriesWork.swift:156,166`) and not to the view.
- **Effort** — three lines; `utcYear` is `fileprivate` and needs exposing, or format with
  `.timeZone(.gmt)`.
- **Confidence** — certain.

### 3. "Story & art" credits the author with the art when a separate artist exists

- **What** — the authors row is always labelled "Story & art"; the artists row is added
  beneath it when the arrays differ.
- **Where** — `MangaBaka/Features/Detail/DetailCredits.swift:54-59`.
- **Why it matters** — on 3397 the table reads "Story & art: Chu-Gong" then "Art: Seong-Rak
  Jang". Chu-Gong wrote it and did not draw it. Every author/artist split series (most
  manhwa) states the wrong credit in the top row. Also `artists != series.authors` at `:58`
  is an ordered array compare, so `["A","B"]` vs `["B","A"]` produces a duplicate Art row.
- **Effort** — a line: "Story" when artists differ, "Story & art" when they match or are
  absent; `Set` compare.
- **Confidence** — certain.

### 4. Publisher lookup: composite names never match, and the fallback is "first result wins"

- **What** — `findPublisher(named:)` searches the directory for the credit string, takes
  the case-insensitive exact match, else **`hits.first`**. The AppleBooksMatch pattern.
- **Where** — `Core/Model/CatalogueService.swift:119-123` (root); consumed at
  `MangaBaka/Features/Detail/PublisherView.swift:261-264`; the name comes untouched from
  `DetailCredits.swift:134,169`.
- **Why it matters** — measured today: `q=Ize Press (Yen Press)` returns `[]`, so the
  publisher page for Solo Leveling's English print edition has no record, no links, no
  description, although Yen Press is in the directory (82 `yenpress.com` links in the
  09-12 sample). For short credits ("Kakao", "Daum", "Manta") the `?? hits.first` branch
  can decorate the page with a different publisher's description and social links — a
  wrong header under the right series list. Not verified which short names misfire;
  budget spent.
- **Effort** — a function: try the parenthetical and the pre-parenthetical halves; drop
  `?? hits.first` or require a prefix match.
- **Confidence** — certain for the empty result; likely for the wrong-record case.

### 5. `ReleaseSection` lists episodes keyed by their timestamp; same-day batches collide

- **What** — `ForEach(entries.prefix(5), id: \.published)`. `ReleaseEntry` has no id.
- **Where** — `MangaBaka/Features/Detail/ReleaseSection.swift:62`;
  `Core/Schedule/WebtoonsEpisode.swift:10-20` (no `Identifiable`);
  `Core/Schedule/NaverFeedClient.swift:120-133` builds every Naver date at noon Seoul with
  no time-of-day, so two Naver episodes on one day are `==`.
- **Why it matters** — `.recent` is exactly the new-series case (`ReleaseSummary.swift:73`:
  two-plus episodes, too few for a cadence), and a Webtoons/Naver launch drops episodes
  1–3 on the same day. Duplicate `ForEach` ids: SwiftUI logs and drops or mis-diffs the
  rows, so a three-episode launch can render as one.
- **Effort** — a line: `id: \.title` or `Array(enumerated())`.
- **Confidence** — likely (mechanism certain; needs a launch-day feed to reproduce).

### 6. Release dates print without a year, and nothing guards a finished series

- **What** — `shortDate` is `day().month(.abbreviated)`, used for `.rhythm`, `.recent` and
  `.lastSeen`; `ReleaseSummary.summarise` and `ReleaseFeedService.report` never look at
  `series.status` or the age of the latest episode.
- **Where** — `MangaBaka/Features/Detail/ReleaseSection.swift:111-113` (no year), `:50-56`
  and `:66-67` (callers); `Core/Schedule/ReleaseSummary.swift:49-74` and
  `ReleaseFeedService.swift:33-67` (no staleness or status check).
- **Why it matters** — a completed webtoon whose platform feed still lists its last
  episodes gets "Releases · Webtoons / About every 7 days, give or take 1 / Ep. 179 · 21 Dec"
  with no year: it reads as ongoing. "Last episode · 2 Feb" for a one-episode feed is the
  same ambiguity.
- **Effort** — a line to add the year when the date is not this year; a function in Core to
  skip the section when `status == "completed"` or the latest episode is older than a few
  cadence gaps.
- **Confidence** — likely (no completed-series feed fetched to prove it; the code path has
  no guard).

### 7. "First native title wins" picks the language that filters the cover fan and writes the byline

- **What** — `nativeLanguage` is the language of the *first* title carrying the `native`
  trait. Solo Leveling carries four: `ko`, `ko-Latn`, `ja-Latn`, `ja`.
- **Where** — root `Core/Model/Series.swift:240-242`; consumers in this slice:
  `MangaBaka/Features/Detail/SeriesDetailView+Covers.swift:69-73` (`language.hasPrefix($0)`
  against `coverLanguages`), `SeriesDetailView.swift:257-259` (`preferredCover`),
  `DetailHero.swift:301-306` (byline's native title, same first-wins rule).
- **Why it matters** — if the first native entry is `ko-Latn`, `coverLanguages` becomes
  `{"en", "ko-latn"}` and `"ko".hasPrefix("ko-latn")` is false: every Korean cover is
  dropped from the fan, and the byline shows the romanisation instead of the Hangul. On
  3397 the Hangul entry happens to come second in the array, so it works today by order,
  not by rule. The API's title order is not documented as stable.
- **Effort** — a function: prefer a native title whose tag has no `-latn` script, else
  strip the script subtag before comparing.
- **Confidence** — likely.

### 8. `ReadingPlatforms` hides Piccoma and admits user-content roots

- **What** — the allowlist has no `piccoma.com`; it does have `naver.com`, `daum.net`,
  `kakao.com`, `pixiv.net`, `nicovideo.jp`, `bilibili.com` as suffix matches.
- **Where** — `Core/Model/ReadingPlatforms.swift:38-42` (suffix rule), `:64-95` (lists);
  effect in this slice at `ReadRow.swift:29` and `LinksSection.swift:28`.
- **Why it matters** — measured: 3397's only Japanese reading link is
  `webplatform | ja | piccoma.com`, Kakao's official Japanese platform, and it is hidden
  outright. The other direction: `blog.naver.com`, `cafe.daum.net`, `space.bilibili.com`
  and any `*.pixiv.net` pass the suffix test, so a contributor-added aggregator link on a
  Naver blog is offered as "Read it". The allowlist's stated reason (5.2.3) is weakened by
  its own six broadest roots.
- **Effort** — a line for Piccoma; a function to allow only specific subdomains for the
  six portal roots (`comic.naver.com`, `webtoon.kakao.com`, `page.kakao.com`,
  `manga.bilibili.com`, `comic.pixiv.net`, `seiga.nicovideo.jp`, `webtoon.daum.net`).
- **Confidence** — certain for Piccoma; worth checking for the portal roots (no
  aggregator seen in the 09-12 sample, by the file's own account).

### 9. Publisher names reach the API and the navigation title untrimmed

- **What** — the credit string is passed verbatim as `publisher=` and as the title.
- **Where** — `DetailCredits.swift:134,169` → `RootView.swift:302` →
  `PublisherView.swift:89,233`; `SearchQuery.swift:25` does not trim.
- **Why it matters** — 3397 credits `"Panini Manga México "` with a trailing space. The
  request goes out as `publisher=Panini%20Manga%20M%C3%A9xico%20`; whether the server
  trims is unknown, and if not the page says "MangaBaka lists nothing under this name
  yet" for a publisher it lists. The bar title carries the space too.
- **Effort** — a line at the route.
- **Confidence** — worth checking (the server's behaviour is the unknown).

### 10. TrackerScores: the "5" in the verdict is a stale copy of `agreedSpread`

- **What** — `"Every tracker agrees, within 5 points"` is a literal; the rule is
  `agreedSpread = 5.0`.
- **Where** — `MangaBaka/Features/Detail/TrackerScores.swift:118` vs `:30`.
- **Why it matters** — the charter's duplicated-constant pattern: tune one, the sentence
  lies. Also `:43-44`: `scored` is built from a `Dictionary`, so a tie for highest or
  lowest is broken by hash order and the named tracker can change between launches.
- **Effort** — a line (`Int(agreedSpread)`); a line to sort `scored` by name first.
- **Confidence** — certain / worth checking (tie).

### 11. The hero kicker prints "Oel" for OEL

- **What** — `series.type?.capitalized`; the app already owns the right label.
- **Where** — `MangaBaka/Features/Detail/DetailHero.swift:278`; the source of truth is
  `Core/Settings/FormatPreferences.swift:27` (`case .oel: "OEL"`). Same defect at
  `Features/Discovery/DiscoverView.swift:262` (not this slice).
- **Why it matters** — "Oel · Releasing" on every original-English series; an initialism
  rendered as a word.
- **Effort** — a line: map through `FormatPreferences.Format(rawValue:)?.title`.
- **Confidence** — certain.

### 12. `AppleVolumesRow.countLine` compares a count with a number

- **What** — "N of M" fires when `expected > volumes.count`; nothing checks which numbers
  the shelf holds.
- **Where** — `MangaBaka/Features/Detail/AppleVolumesRow.swift:77-82`.
- **Why it matters** — a shelf of 15 volumes numbered 1–14 and 30 reads "15" beside a
  `final_volume` of 15 (complete), and a shelf with an omnibus counted as a volume can
  exceed `expected` and print no "of". Same family as today's cumulative-vs-per-season gap.
- **Effort** — a line: compare `Set(volumes.map(\.number))` coverage of `1...expected`.
- **Confidence** — worth checking (needs a store shelf with a gap to show it).

### 13. `DetailStatsStrip.compact` prints "1000.0k"

- **What** — the `>= 1_000` branch rounds to one decimal, so 999,950–999,999 formats as
  "1000.0k" rather than "1.0m".
- **Where** — `MangaBaka/Features/Detail/DetailStatsStrip.swift:132-133`.
- **Why it matters** — cosmetic and rare; listed because it is a one-line off-by-rounding
  in a function whose whole purpose is the order of magnitude.
- **Effort** — a line (round before choosing the suffix).
- **Confidence** — certain.

### 14. Publisher choice sheet keyed by name

- **What** — `ForEach(series.publishers ?? [], id: \.name)`.
- **Where** — `MangaBaka/Features/Detail/DetailCredits.swift:168`.
- **Why it matters** — a publisher listed twice with different `type` (an Original and an
  English entry under one name) is a duplicate id. Harmless in effect — both buttons open
  the same name — but it is the same shape as finding 5. Not seen on 3397.
- **Effort** — a line (`Array(enumerated())`).
- **Confidence** — worth checking.

### 15. `LanguageFlag.name` hands ICU a lowercased script code

- **What** — the tag is lowercased before `localizedString(forScriptCode:)`, so `"zh-Hant"`
  asks for `"hant"`.
- **Where** — `Core/Model/LanguageFlag.swift:17,24`; shown at `LinksSection.swift:93` and
  `AlternativeTitles.swift:122`.
- **Why it matters** — if ICU does not canonicalise case, the qualifier comes back nil and
  the row reads "Chinese" for both Traditional and Simplified. Not verified on device; the
  regional branch (`"br"`) is known to work from the file's own examples.
- **Effort** — a line (capitalise the script subtag).
- **Confidence** — worth checking.

### Charter 6 — hand-rolled controls, one line each

- `ScrollEdge` (`Shared/ScrollEdge.swift`): the system provides it via `.navigationTitle`
  on a `NavigationStack` screen; this exists only because the four tab roots have no bar.
  Already S-F4/S-F20; the detail page correctly uses `.scrollEdgeEffectStyle(.hard)`
  (`SeriesDetailView.swift:135`) instead.
- `DetailBarTitle` (`DetailBarTitle.swift:16-68`): the system fades a *large* title into
  the bar; there is no system fade for an inline title beside a hero, so this is
  justified — the file says why at `:11-15`.
- `SearchClearButton` (`Shared/SearchClearButton.swift`): `.searchable` provides a clear
  button; a plain `TextField` does not. Justified for `InlineSearchField`; the Search tab
  itself could use `.searchable` and lose the control.
- `TapTarget` (`DesignSystem/TapTarget.swift`): SwiftUI has no minimum-target modifier;
  justified. S-F7 (height only) still stands.
- `Motion` (`DesignSystem/Motion.swift`): the system gives
  `@Environment(\.accessibilityReduceMotion)`; the wrapper is justified by non-view call
  sites (`:16-20`), and S-F6 (no invalidation) still stands.
- `EdgeSwipeToDismiss` (`Shared/EdgeSwipeToDismiss.swift`): the system provides the
  back-swipe for a *pushed* screen. This re-implements it on sheets. The platform answer
  is to push the tag/seed pickers instead of presenting them; the gesture is the cost of
  choosing a sheet.
- `InlineSearchField` (`Shared/InlineSearchField.swift`): `.searchable` provides a field,
  clear button, cancel and keyboard handling; hand-built here for the mockup's styling.
- `FlowLayout` (`Shared/FlowLayout.swift`): no system flow layout; justified.
- `Skeleton`/`Shimmer` (`Shared/Skeleton.swift`): `.redacted(reason: .placeholder)` is the
  system placeholder; the shimmer is an addition, not a replacement — fine.
- `Toast` (`Shared/Toast.swift`): no system toast; S-F2 (VoiceOver never hears it) is the
  open cost.

### Re-verified claims

- **Force-unwraps reachable from real input**: none. Grep over the slice for `!` unwraps,
  `try!`, `as!`, `fatalError` — zero hits in production files.
- **Unreachable views** (charter 7): every type in the slice with no reference outside its
  file is reached through its own modifier (`scrollEdge()`, `rowAmbient()`,
  `detailBarTitle()`, `VolumeSheet` via `.sheet(item:)` at `VolumesSection.swift:56-60`).
  Nothing dead found here.
- **`TEMP`/`TODO`/`FIXME`**: none in the slice.

## What this slice does well

- Measurements are recorded with dates and the series that produced them, which is what
  made findings 1, 3 and 8 checkable in an hour: `DetailCredits.swift:71-76` (anime,
  2026-09-10, The Greatest Estate Developer), `LinksSection.swift:9-10` (3397's link
  counts), `SeriesExtras.swift:174-178` (ONE PIECE's five MANGA Plus links),
  `ReadingPlatforms.swift:13-23` (450 series, 1,631 links, 132 hosts — and a **negative
  result recorded**: no aggregator in the sample).
- `DetailStatsStrip.swift:44-47`: a rated-0 series is treated as unrated, with the
  screenshot-level reason written down. `:11-12`: absent stats are dropped, not dashed.
- `SeriesLink.safeURL` (`SeriesExtras.swift:23-30`) and `SafeLink.web` (`:104-112`):
  every contributed URL is scheme-and-host checked before `openURL`, in one place, and
  `LinksSection.swift:85`, `ReadRow.swift:61`, `NewsSection` (`:128`) and
  `PublisherView.swift:147,153` all go through it.
- `SeriesLink.primarySubtag` (`SeriesExtras.swift:192-199`) with the reasoning at
  `:169-172`: "pt-br" vs "pt" is handled deliberately, with the trade-off stated.
- `DetailHero.form` (`DetailHero.swift:84-99, 125-139`): measured off-screen instead of
  `ViewThatFits`, and the comment says why `ViewThatFits` is wrong inside a `ScrollView`.
  The rule is a pure `static func` and testable.
- `TrackerScores.swift:25-30`: the three thresholds are labelled `GUESS` with their
  provenance — exactly what CLAUDE.md asks for.
- `AppleVolumesRow.swift:75-82`: "15 of 27" rather than a silent short shelf.
- `SeriesWork.swift:89-106`: the date-zone hazard is understood and solved at the model;
  finding 2 is the view not using it, not a missing idea.
- `PublisherView.swift:282-288`: a known paging gap is left in with the reason and the
  alternative, rather than patched with a second copy of the search loop.
- `DetailEditions.swift:70-73`: "Official" only when the API says true; no "Unofficial"
  invented from a missing flag.
- `ReleaseSection.swift:9-15`: `.none` and loading both render nothing, with the reason
  ("a placeholder box reads as an answer").
- `CharacterProfileView.swift:150-163`: the TestFlight 64 crash is guarded at the exact
  call and the reasoning references the crash report.

## Open questions

- Which endpoint returned `{"exists": false}` on 2026-09-10 (`DetailCredits.swift:73`)?
  If it was v2, both shapes are live and `AnimeAdaptation` needs both `exists` and
  `has_anime`. One `GET /v2/series/3397` would settle it.
- Does `/v1/publishers/search` trim `q`, and does `/v2/series/search` trim `publisher=`?
  Decides whether finding 9 is a bug or a nuisance.
- Is the `titles` array order stable per series, and what orders it? Decides whether
  finding 7 is latent or live somewhere in the catalogue.
- For finding 8, whether MangaBaka's `webplatform` links have ever carried a
  `blog.naver.com` / `*.pixiv.net` URL — the 09-12 sample says no, but 450 of a
  catalogue of tens of thousands is the denominator.
- `NonsenseGuardTests.swift:30` is a fixture built from the model (charter 2). Worth a
  fixture pasted from `/v1/series/3397/full` beside it, so the suite fails the way the
  screen does.
