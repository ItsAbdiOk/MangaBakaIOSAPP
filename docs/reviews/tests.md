# Deep review — the test suite

Read-only pass over `MangaBakaTests/**` and `MangaBakaUITests/**`, 2026-09-11.
Nothing was built or run; every claim below comes from reading the code.

## Denominator

- **80 Swift files, 13,431 lines.** All 80 filenames enumerated; the files named
  in findings below were read in full or in the cited range.
- **152 `@Suite`s, 719 `@Test`s, 12 `XCTestCase` methods** (2 UI test files).
- **4 JSON fixtures**, all four read and parsed: `control.json`, `rising.json`,
  `library.json`, `mix.json`.
- **115 `SourceTree.*` call sites** across 22 test files.
- Checked against `docs/schemas/mangabaka_openapi.json` (70 documented paths).

**Not read in full, and therefore not reviewed:** the bodies of
`TasteProfileTests`, `TasteModelTests`, `TasteLedgerTests`, `ReadingWrappedTests`,
`ReadingInsightsTests`, `CommunityPulseTests`, `BlurHashTests`,
`PaginationTests`, `HistoryTests`, `SeriesMergeTests`, `SeriesWorkTests`,
`CadenceTests`, `LinkGroupingTests`, `AlternativeTitleTests`,
`AppTabSymbolTests`, `PublisherBrowseTests`, `SurpriseAndStackTests`,
`ScheduleModelTests`, `SearchModelTests`, `BrowseModelTests`,
`LibraryModelTests`, `LibraryListTests`, `LibrarySnapshotTests`,
`CharacterTests`, `NonsenseGuardTests`, `SeasonReadingTests`,
`APIErrorPresentationTests`, `StackSaveTests`, `TagSearchTests`,
`ReminderTests`, `MotionTests`, `DynamicTypeRampTests`. They were grepped for
the specific patterns in sections 2, 3 and 6, but not reviewed line by line.
Roughly **55% of the slice was read closely**; the rest was pattern-scanned.

---

# 1. Fixture provenance — the priority question

Verdict per fixture. Two are captured, one is a declared control, and one is
captured-then-redacted in a way that disarms part of what it is used for.

## 1.1 `rising.json` — CAPTURED. Good.

`MangaBakaTests/Fixtures/rising.json`, provenance recorded at
`MangaBakaTests/SeriesDecodingTests.swift:44`: *"Recorded from
`GET /v2/series/discover/rising?limit=3` on 2026-09-08."*

Verified by inspection: minified (one line, as a server emits it), three real
series with real CDN URLs, real base64 imgproxy paths, `total_chapters: 201`
as a **number** and `final_volume: 15` as a **number** — the v2 side of the
documented type split. Carries `canonical_url`, which the OpenAPI spec does
**not** document, and `SeriesDecodingTests.swift:60-71` asserts exactly that
undocumented key is still present. This is the right shape for a fixture.

## 1.2 `control.json` — HAND-WRITTEN, and correctly declared as a control.

`MangaBakaTests/Fixtures/control.json`. Values are `"NATIVE"`,
`"ENGLISH OFFICIAL"`, `https://example.invalid/...`, and the description
literally reads *"Control fixture with a known answer."* It is used by
`ControlDecodingTests` (`SeriesDecodingTests.swift:8-40`) whose own doc comment
says *"If the control fails, no other result in this file means anything."*

This is CLAUDE.md's "every measurement ships with a control" done properly, and
it is not a Pattern-2 defect — it does not claim to be a response. **No action.**

One caveat worth writing down: `control.json`'s second entry sets every cover
field to `null` (`"raw": null, "x150": null, ... "width": null`). Nothing
establishes that the API ever sends that object; it is the model's idea of
absence, not a recorded one. The test that consumes it
(`SeriesDecodingTests.swift:28-39`) is a model-robustness test, which is a fair
thing to want — but it should not be mistaken for evidence about the wire.

## 1.3 `library.json` — CAPTURED, then redacted. Provenance recorded. One gap.

`MangaBakaTests/Fixtures/library.json`, provenance at
`MangaBakaTests/LibraryDecodingTests.swift:5-11`: captured from live
`/v1/my/library` on 2026-09-09, with identifying values replaced and the shape
left untouched. The comment is explicit about what was changed and why, which
is the right way to do this.

Shape verified as genuinely v1: the entry nests its series under capitalised
`"Series"` (survives `convertFromSnakeCase`), `cover.raw` is an **object**,
`total_chapters` is the **string** `"87"`, and `source` carries the real
`anilist`/`anime_planet` ids the redaction did not touch. It is a real payload.

**The gap — worth checking.** The redaction collapsed `titles` to a single
entry, `[{"language":"en","traits":["official"],"title":"Placeholder Series 1"}]`,
and set `title`, `native_title` and `romanized_title` to that same string.
A real MangaBaka series carries several titles — `ja`/`native`, `en`/`official`,
`ja-Latn` — and that variety is precisely what `DisplayTitle.matching` and the
"original language" preference operate on (finding A3 in `findings-todo.md`).
So this fixture can never exercise title preference against a real library
payload; `LibraryDecodingTests.swift:50` only asserts
`first.series?.displayTitle != nil`, which one title satisfies.

- **Why it matters:** a change that made `DisplayTitle` pick the wrong entry, or
  that broke multi-title decoding on the v1 shape, passes here.
- **Effort:** a line — re-redact keeping three titles with distinct languages
  and traits.
- **Confidence:** certain that the fixture has one title; likely that this
  leaves real title-preference behaviour untested against a v1 payload.

## 1.4 `mix.json` — CAPTURED, redacted, and **no provenance comment anywhere.**

`MangaBakaTests/Fixtures/mix.json`. It is plainly captured — real AniList ids
(`30707`), real thumbhashes, `total_chapters` as the string `"55"`, the v1
object-shaped cover, and a real `score`/`cosine` pair
(`0.8366701607646725` / `0.5973774194717407`) that nobody types by hand.

But it is the **only fixture with no recorded provenance**. The two tests that
use it are `APIShapeContractTests.swift:48-64`, whose suite comment describes
the sweep generally but never says when `mix.json` was captured or from what
query. `rising` says 2026-09-08 at `SeriesDecodingTests.swift:44`; `library`
says 2026-09-09 at `LibraryDecodingTests.swift:5`; `mix` says nothing.

- **Why it matters:** the charter's tell for Pattern 1 is "a comment that says
  what a field is without saying when it was last checked against a response".
  This fixture has no date at all, so in six months nobody can tell whether it
  is stale or current, and a silent shape change on `/v1/series/mix` — the swipe
  stack's only source — would be invisible until the stack fell back to random
  again.
- **Effort:** a line.
- **Confidence:** certain.

**Two further gaps in `mix.json`'s content:** `shared_tags` is `[]` while
`shared_tags_total` is `45` (the redaction emptied the array but left the
count), and `titles` was collapsed to one entry as in `library.json`. Any code
that reads `shared_tags` to explain *why* a blend matched is exercised against
an empty list by the only real mix payload in the repo.

## 1.5 The endpoint the price bug came from is still not covered by a fixture

`ReleaseCalendarTests.swift` was fixed — `:18` now sends
`"price": [{"value": 1.99, "iso_code": "usd"}, ...]`, and `:127-133` records
the bug, the date and the mechanism. That comment is a model of the standard.

But the fixture is still **hand-written inline** (`:8-22`), not captured, and
`/v1/works/upcoming` appears in **neither** `Scripts/api-shape-sweep.py` nor
the endpoint list at `APIShapeContractTests.swift:82-90`. The one endpoint that
has already shipped a silent decode failure is the one with no recorded
response in the repository.

I checked the hand-written fixture against
`docs/schemas/mangabaka_openapi.json` → `V1_Work_Default`. Two divergences:

**(a) `V1_Price.value` is `["number","null"]` (spec, `V1_Price`), and
`UpcomingWork.Price.value` is a non-optional `Double`**
(`MangaBaka/Core/Schedule/UpcomingWork.swift:35`). A single work priced with a
null value throws the whole page's decode, which `ReleaseCalendar.swift:38`
swallows with `try?` and `break`s the pager — the calendar goes empty again, by
the same mechanism as the original bug. The fixture never contains a null
value, so no test in the suite covers it.
  - **Where:** model `MangaBaka/Core/Schedule/UpcomingWork.swift:35`; fixture
    `MangaBakaTests/ReleaseCalendarTests.swift:18`; swallow
    `MangaBaka/Core/Schedule/ReleaseCalendar.swift:38`.
  - **Effort:** a line in the model, a test.
  - **Confidence:** certain about the type mismatch against the spec; likely
    about whether the API actually sends null in practice.

**(b) `publisherLink` filters on `type == "publisher"`
(`MangaBaka/Core/Schedule/UpcomingWork.swift:103`), and the spec's
`V1_WebLink.type` has default `"store"` with no enum constraining it.** The
fixture at `ReleaseCalendarTests.swift:17` hand-writes `"type": "publisher"`,
so `ReleaseCalendarTests.swift:126` asserts the model's own assumption back to
itself. If the live API emits `"store"`, every buy link is silently nil and
this test stays green — the exact shape of the `price` bug, in the same struct.
  - **Effort:** a line, once somebody looks at one real response.
  - **Confidence:** likely. This needs one live call to settle; I could not make
    one. Flagged as an unsure rather than a verdict.

## 1.6 `APIShapeContractTests` thinness (beyond the known 7-of-17 claim)

The sibling agent's finding on `APIShapeContractTests.swift:78-94` stands, and
the real denominator is worse than 17: the app constructs **29 distinct
endpoint paths** (grep for `"/v1` and `"/v2` under `MangaBaka/`), the sweep
script covers 8, and the test asserts 7 of those 8. Not re-reported.

What is additionally true, and separate:

- **`APIShapeContractTests.swift:40`** — the entire v2 contract test is
  `#expect(series.cover.raw != nil)`. It does **not** check `totalChapters` or
  `finalVolume` on the v2 side, even though the suite's own table at `:12-13`
  names those two fields as the split. Half the documented contract is asserted
  in one direction only (`:62-63` checks them on v1).
  **Effort:** two lines. **Confidence:** certain.
- **`APIShapeContractTests.swift:72`** — the v1 library contract test is
  `#expect(envelope.data?.count == 2)` and nothing else. `LibraryEntry.series`
  is optional, so this passes if the nested `Series` fails to decode entirely —
  which is the exact bug the suite was written for. `LibraryDecodingTests`
  covers it properly at `:46-65`, so nothing is currently unprotected, but the
  test that claims to be the *contract* is the weaker of the two.
  **Effort:** a line. **Confidence:** certain.

---

# 2. Source-grep tests

**115 `SourceTree.*` call sites across 22 files.** 78 individual assertions were
catalogued in detail across the twelve largest files (`AccessibilityTests`,
`BlockedTagsTests`, `ChromeReachabilityTests`, `CoverGalleryTests`,
`CoverLayoutTests`, `DesignTokenTests`, `DetailFidelityTests`,
`FlowAffordanceTests`, `InlineSearchTests`, `LensTests`, `LibraryControlTests`,
`LibraryTests`). Of those 78:

| class | count | verdict |
|---|---|---|
| **STUB** — a stub, a comment or a dead branch satisfies it | 44 | the bulk of the problem |
| **NEGATIVE** — asserts an absence, which cannot be faked | 17 | keep |
| **REAL** — only the real wiring produces the matched text | 12 | keep |
| **RENAME** — fails on a rename, not on a breakage | 5 | low value |

**56% of the source-grep assertions in the reviewed files are stub-satisfiable.**
D1 in `findings-todo.md` is marked done, and `FlowAffordanceTests` itself was
genuinely reduced to two assertions — but the pattern it was closed for is alive
in a dozen other files.

## 2.1 The strongest stub-satisfiable cases

Each of these is a test whose name promises a behaviour and whose assertion is a
substring match that a comment would satisfy.

- **`MangaBakaTests/AccessibilityTests.swift:70`** —
  `#expect(source.contains("accessibilityReduceMotion"))`, under the test name
  *"The stack honours Reduce Motion"*.
  **Why it matters:** declaring `@Environment(\.accessibilityReduceMotion)` and
  never reading it satisfies this. That is charter Pattern 3 exactly — and
  `findings-todo.md` C6 records that Reduce Motion was honoured by 1 of 15
  animating surfaces while this test was green.
  **Effort:** a redesign (needs a UI test or a snapshot).
  **Confidence:** certain.

- **`MangaBakaTests/AccessibilityTests.swift:58-59`** —
  `source.contains("accessibilityAction(named: \"Save\")")` /
  `...\"Skip\"`. The test name is *"The stack exposes save and skip as actions,
  not only as gestures"*. A commented-out line, or an action attached to the
  wrong view, satisfies both.
  **Effort:** a function (this is drivable in `FlowAffordanceUITests`).
  **Confidence:** certain.

- **`MangaBakaTests/DetailFidelityTests.swift:152-155`** —
  `blur(radius: 72`, `saturation(1.7)`, `opacity(0.34)`, `scaleEffect(1.6)`.
  Four literal-value greps. They break when a designer retunes a backdrop and
  do not break when the backdrop stops being drawn.
  **Effort:** a file — these are the clearest candidates for deletion rather
  than replacement; nothing they assert is a correctness property.
  **Confidence:** certain.

- **`MangaBakaTests/AccessibilityTests.swift:492`** —
  `#expect(source.contains("typeSize.isAccessibilitySize") || source.contains("ViewThatFits"))`.
  An OR of two substrings is satisfied by either appearing anywhere in the file,
  including in the comment explaining which one was chosen.
  **Effort:** a line. **Confidence:** certain.

- **`MangaBakaTests/DetailFidelityTests.swift:141`** — the section-order check
  matches bare tokens such as `"actions"` and `"tagSection"` with
  `source.range(of:)`. Those substrings occur in ordinary identifiers and in
  comments; the ordering constraint is the only real signal, and it survives the
  sections being removed as long as the words stay in the file in order.
  **Effort:** a function. **Confidence:** likely.

## 2.2 The negatives are legitimate — name them and keep them

The charter's claim that "two survive deliberately because they assert the
ABSENCE of a route" is an undercount: **17 of the 78 assert an absence**, and
every one of them is defensible, because no stub can create an absence. The best:

- **`MangaBakaTests/LibraryTests.swift:257, 269`** —
  `!includesSecrets(release)` and `!includesSecrets(Base.xcconfig)`. Not a
  substring check: `includesSecrets` is a line scanner that strips comments
  first, specifically so a comment mentioning the secrets file cannot fake it.
  Paired with `:263`, which asserts the include **is** present in
  `Debug.xcconfig`, this is a positive and a negative bracketing the same fact.
  This is the best source-reading test in the suite.
- **`MangaBakaTests/DetailFidelityTests.swift:419`** —
  `!source.contains("\(section)(series: series)")` for each detail section,
  asserting that no section is handed the unmerged `series` instead of the
  merged `shown`. The file's own comment says this form was chosen *because* a
  presence grep could not distinguish them.
- **`MangaBakaTests/AccessibilityTests.swift:347`** —
  `!code.contains(".disabled(isLocked)")`, run against source with comments
  stripped. Same defence, applied deliberately.
- **`MangaBakaTests/AccessibilityTests.swift:388`** —
  `!SourceTree.exists("MangaBaka/Features/Chrome/AppTabBar.swift")`. Verified:
  the directory does not exist. A file's non-existence is unfakeable.
- **`MangaBakaTests/AccessibilityTests.swift:114, 511, 524, 527`**,
  **`ChromeReachabilityTests.swift:42`**, **`FlowAffordanceTests.swift:29`**,
  **`CoverLayoutTests.swift:38`**, **`LensTests.swift:133`**,
  **`BlockedTagsTests.swift:183`**, **`AccessibilityTests.swift:259, 288, 311,
  385, 457`** — all absence assertions on a specific regression that happened.

## 2.3 The twelve REAL ones are real — say why

These pass only when the actual wiring is present, because they match a fully
parameterised call site rather than a name:

- `MangaBakaTests/LibraryControlTests.swift:234` —
  `LibraryControl(series: shown, library: library, store: libraryStore)`. A
  regression that passed `series` instead of `shown` does not match.
- `MangaBakaTests/ChromeReachabilityTests.swift:25` —
  `onOpenSettings: { showsSettings = true }`. The callback *and* the state it
  sets, in one string.
- `MangaBakaTests/LensTests.swift:141` —
  `SaveLensButton(isEnabled: !query.isEmpty)`.
- `MangaBakaTests/DetailFidelityTests.swift:166, 368, 386` —
  `mixModel?.addSeed(series)`, `UIPasteboard.general.string = series.displayTitle`,
  `disabled(series.displayTitle == nil)`.
- `MangaBakaTests/FlowAffordanceTests.swift:42` —
  `if let description = shown.description`, which is the fix for the missing
  synopsis and cannot be produced by a stub.
- `MangaBakaTests/CoverGalleryTests.swift:184` —
  `guard isTruncated || isExpanded else { return }`.
- **`MangaBakaTests/ChromeReachabilityTests.swift:50-51`** — the only two that
  are not text at all: `Metrics.scrollTopInset <= 32` and `> 0` evaluate the
  compiled constant. **This is the shape the other 44 should be.**
- **`MangaBakaTests/DesignTokenTests.swift:51`** — sweeps every Swift file under
  `MangaBaka/` for a reference to each declared token, so a token nothing uses
  fails. It found `Metrics.gutterStatus` and `Metrics.backButton`
  (`findings-todo.md` G5). A whole-project scan is a different thing from a
  one-file grep and should not be lumped in with them.

**The general rule this suite should adopt, which it already discovered twice:**
a source grep earns its place when it asserts an *absence* or matches a *whole
call with its arguments*. Matching a bare identifier does not.

## 2.4 THE TOP FINDING: the credential guard was fixed in one file and left broken in its duplicate

**Note on provenance:** `SecurityTests.swift:68-88` is an **uncommitted
working-tree change** made during this same review session by a sibling agent
(`git diff MangaBakaTests/SecurityTests.swift` shows it as unstaged). So this is
not history — it is a fix landing right now that stops one file short. Its
comment (`:71-77`) says it plainly:

> This read `release.contains("MB_PAT =")` until 2026-09-11, which passes just
> as happily against `MB_PAT = mb-a-real-token`. The one test whose entire job
> is to stop a credential shipping would have watched it ship.

**The same assertion still exists, unfixed, in a second file.**

- **What:** `LibraryTests.swift:258` asserts `release.contains("MB_PAT =")` with
  the message *"Release forces the value empty"* — and never looks at the value.
- **Where:** `MangaBakaTests/LibraryTests.swift:258`, in
  `@Suite("Release builds cannot carry a token")` at `LibraryTests.swift:236`.
  Compare the fixed version at `MangaBakaTests/SecurityTests.swift:79-88`.
  The agent that fixed `SecurityTests` did not grep for the assertion it was
  fixing, so the second copy was never looked at.
- **Why it matters:** `MB_PAT = mb-<a real 60-character token>` in
  `Configs/Release.xcconfig` passes this test and its failure message would
  actively assert the opposite. `SecurityTests` would catch it today, so the
  credential is not currently at risk — but two suites guard the same file with
  the same name and only one of them works, which is precisely the
  "duplication fixed by copying" hazard CLAUDE.md forbids. Whichever is deleted
  first, it must not be the working one.
- **Effort:** a function — or better, delete
  `LibraryTests.swift:236-278` entirely and leave `SecurityTests` as the single
  guard. The two suites duplicate `includesSecrets` verbatim
  (`LibraryTests.swift:248-252` vs `SecurityTests.swift:91-97`).
- **Confidence:** certain. Both files read, both assertions quoted above.
  Caveat: line numbers in `SecurityTests.swift` are against the **working
  tree**, which is 20 lines longer than `HEAD`. Every other file in this report
  is clean at `HEAD`.

## 2.5 An assertion that can never fail, in the same suite

- **What:** `#expect(!example.contains("mb-") || example.contains("your-personal"))`
  is a tautology. The file it reads is asserted one line earlier to contain
  `"mb-your-personal-access-token-here"` (`:275`), which contains
  `"your-personal"` — so the right-hand side of the OR is *always* true and the
  expression can never be false, whatever the file holds.
- **Where:** `MangaBakaTests/LibraryTests.swift:277`, comment at `:276` claiming
  *"the placeholder must not look like one"*.
- **Why it matters:** replacing the placeholder in
  `Configs/Secrets.example.xcconfig` with a real token while leaving the
  placeholder line above it passes both `:275` and `:277`. The test that checks
  the example file for a real token cannot fail.
- **Effort:** a line — assert the token-shaped value's length, or assert the
  file contains exactly one `mb-` prefixed string and that it is the placeholder.
- **Confidence:** certain.

## 2.6 A privacy guard satisfied by the comment that explains it

- **What:** `#expect(source.contains(parameter))` for
  `"exclude_user_library"` and `"blend_user_id"`, checking they are "treated as
  identity".
- **Where:** `MangaBakaTests/SecurityTests.swift:108-110`. The set it means to
  check is `APIClient.identifyingParameters` at
  `MangaBaka/Core/Networking/APIClient.swift:341-345`.
- **Why it matters:** both strings also appear in the doc comment directly above
  that set, at `MangaBaka/Core/Networking/APIClient.swift:339-341`. Emptying
  `identifyingParameters` to `[]` — which would make every identity-bearing URL
  cacheable to disk — leaves both strings in the file and the test green. The
  comment is load-bearing for the test, which is the same trap
  `LibraryTests.swift:248` and `SecurityTests.swift:91` were written to avoid.
- **Effort:** a line — `#expect(APIClient.identifyingParameters.contains(...))`
  against the compiled value, the way `ChromeReachabilityTests.swift:50` does.
- **Confidence:** certain. Both files read at the cited lines.

## 2.7 The gate on source-reading tests has a hole

`SourceTestGuardTests.swift:47-48` detects a source-reading test by looking for
`SourceTree.read` or `SourceTree.root` in its body. The suite's own comment
(`:11-16`) records that an ungated source test cost build 16 and build 21.

**`AccessibilityTests.swift:84-90` defines a private `repositoryRoot` from
`#filePath` and reads files through `String(contentsOfFile:)` directly**
(`:34-37`, `:54-57`, `:66-69`, `:77-80`). None of those four tests contain
either token the guard looks for. `SafeLinkTests.swift:73` does the same thing.

- **Why it matters:** today both suites happen to be gated by hand
  (`AccessibilityTests.swift:8`, `SafeLinkTests.swift:8`), so nothing is broken.
  But the guard cannot see them, so the next test copied from this pattern into
  an ungated suite passes locally and fails in the cloud — the exact failure the
  guard exists to prevent, twice already.
- **Effort:** a line in the guard (also match `contentsOfFile:` and `#filePath`),
  plus a line in each test to route through `SourceTree.read`.
- **Confidence:** certain.

## 2.8 A loop that asserts nothing when its input is empty

- **What:** `AccessibilityTests.swift:40-47` splits `Typography.swift` on
  `"scaledFont(size:"` and asserts `relativeTo:` on each fragment. If the ramp
  is refactored so that string no longer appears, `calls` is empty, the loop
  runs zero times, and the test named *"Every ramp entry is anchored to a text
  style"* passes having checked nothing.
- **Where:** `MangaBakaTests/AccessibilityTests.swift:40`.
- **Why it matters:** H3 in `findings-todo.md` was a Dynamic Type bug found by
  measurement, not by this test. Renaming the helper to `scaled(size:)` while
  dropping every `relativeTo:` is green.
- **Effort:** a line — `#expect(!calls.isEmpty)` first. The same guard is
  missing at `AccessibilityTests.swift:409` (`silentCoversAreHidden`, where
  `hidden >= empties` is `0 >= 0` on a file with no empty-labelled covers).
- **Confidence:** certain.

---

# 3. Tests that assert a call happened rather than that a thing works

## 3.1 The whole `Request budget` suite measures requests and never looks at cards

- **What:** every test in `@Suite("Request budget")` discards the repository's
  return value with `_ =` and asserts only `URLProtocolStub.requests.count`.
- **Where:** `MangaBakaTests/RequestBudgetTests.swift:47-48`, `:70-76`, `:85-88`.
  The suite's own comment at `:51-53` claims *"five feed reads at 20 cards each
  is 100 cards, on one request"* — **nothing in the file ever counts a card.**
- **Why it matters:** a decode regression that made `feed()` cache and return an
  empty list keeps the request count at exactly 1, and
  `hundredCardSessionStaysUnderBudget` still passes while the reader sees no
  cards at all. That is the charter's Pattern 1 and Pattern 5 meeting: an empty
  screen that looks like a passing budget test. The suite would be
  *strengthened*, not weakened, by `#expect(result.series.count == 20)`, because
  that is the claim its own comment makes.
- **Effort:** a line per test.
- **Confidence:** likely. `requestsMaximumPageSize` at `:59-61` does inspect the
  URL, so the suite is not blind — but no test in it asserts a decoded result,
  and I did not trace every path by which the repository could cache an empty
  list. Flagged as an unsure rather than a verdict.

## 3.2 A cache test that never compares the two answers

- **What:** `CatalogueTests.swift:35-45` calls `genres()` twice and asserts
  `requests.count == 1`.
- **Where:** `MangaBakaTests/CatalogueTests.swift:35-45`.
- **Why it matters:** a cache that stores the response and returns `[]` on the
  second read satisfies "one request" perfectly. The user-visible property —
  the second call returns the same genres — is never asserted.
- **Effort:** a line. **Confidence:** likely.

## 3.3 An "instrument" that carries an assertion which cannot fail

- **What:** `#expect(!lines.isEmpty)` where `lines` is built by iterating a
  six-element compile-time literal, in a test whose own comment at
  `DynamicTypeRampTests.swift:75` says *"Never asserts: it is an instrument."*
- **Where:** `MangaBakaTests/DynamicTypeRampTests.swift:91`; the literal is at
  `:79-82`.
- **Why it matters:** small, but it is an assertion that reads as coverage and
  is not. If the measurement itself regressed to producing identical rows for
  every anchor — which is the thing H3 was about — this still passes. The
  comment is right and the code should match it: record, do not assert. (The
  same test writes to a fixed `/tmp` path at `:89`; see section 6.)
- **Effort:** a line. **Confidence:** certain.

## 3.4 Assertions inside loops that can run zero times

Green-when-empty. Each needs one `#expect(!collection.isEmpty)` before the loop.

| Where | The collection | What passes vacuously |
|---|---|---|
| `AccessibilityTests.swift:40` | `scaledFont(size:` fragments | the whole Dynamic Type ramp contract |
| `AccessibilityTests.swift:409` | `empties`/`hidden` counts (`0 >= 0`) | every cover left focusable and silent |
| `DesignTokenTests.swift:43` | `tokens(in: file)` | every orphaned design token |
| `RecommendationQualityTests.swift:71` | `URLProtocolStub.requests` | identity leaking into a URL — the privacy property |
| `DetailFidelityTests.swift:351` | `DetailCredits(series:).rows` | every credit row becoming expandable |

`RecommendationQualityTests.swift:71` is the one that matters most: if a
regression made the repository short-circuit before the network, `requests` is
empty, the loop never runs, and the suite reports that no identity leaked
without having looked. **Confidence:** certain on the mechanism, likely on
whether each can actually reach the empty state.

---

# 4. Tests whose subject is unreachable in the app

## 4.1 `ShelfDetailView` is still unreachable, and tests still spend assertions on it

`docs/unknowns-2026-09-11.md` leaves this open as a product decision. Confirmed
still true today, and the shape is slightly different from how it is written up:

- `MangaBaka/App/RootView+Session.swift:34` carries
  `.navigationDestination(item: $openShelf)` presenting `ShelfDetailView` at
  `:35`.
- Its trigger is `onOpenShelf` (`RootView+Session.swift:27`), passed into
  `LibraryView`, stored at `MangaBaka/Features/Library/LibraryView.swift:35`,
  and **never invoked anywhere in `LibraryView.swift`**.
- `MangaBaka/Features/Library/ShelfCard.swift:5` declares `ShelfCard` and
  **grep finds zero `ShelfCard(` call sites in the whole app.**

**Careful, because this trips people up:** there are *two different*
`onOpenShelf` closures. `StackView`'s (`MangaBaka/Features/Stack/StackView.swift:19`,
`() -> Void`) is live — wired at `RootView.swift:110` to `selection = .library`
and invoked at `StackSections.swift:152`. Only `LibraryView`'s
`(LibraryEntry.State) -> Void` is dead. A reviewer grepping `onOpenShelf` will
see eleven live-looking hits and conclude the screen is reachable. It is not.

Tests still pointed at the dead screen:

- `MangaBakaTests/AccessibilityTests.swift:409` — `silentCoversAreHidden`
  iterates `ShelfDetailView.swift` (and passes vacuously anyway, see 3.4).
- `MangaBakaTests/InlineSearchTests.swift:65` — asserts
  `ShelfDetailView.swift` contains `InlineSearchField(`.
- `MangaBakaTests/InlineSearchTests.swift:74-75` — asserts the `>= 12` threshold
  and the empty-state copy, both inside `ShelfDetailView`.
- `MangaBakaUITests/AccessibilityAuditTests.swift:249-254` — correctly and
  explicitly `XCTSkip`s with the reason. **This one is right** and should be the
  model: it keeps the question visible in every run.

**Why it matters:** four assertions guard a screen no reader can open, and
`AccessibilityTests.swift:409`'s file list makes `LibraryView`'s real coverage
look larger than it is. **Effort:** a file, once the product decision is made.
**Confidence:** certain that nothing presents it; verified by grep on both
`ShelfCard(` and the `onOpenShelf` invocation.

No *other* unreachable-subject test was found: every other grepped view
(`DetailTagSections`, `EmptyState`, `FailureState`, `SettingsRow`,
`SaveLensButton`, `RatingSegments`, `StackResetMenu`, `LinksSection`,
`MixFilterStrip`, `TagPickerSheet`) has a real presenter in `MangaBaka/`.
`FlowChips` — the charter's precedent — was genuinely fixed: the grep at
`AccessibilityTests.swift:144` now points at `DetailTagSections.swift`, which
`SeriesDetailView` does present.

---

# 5. The UI tests: real gestures, but skips that disarm them

`MangaBakaUITests/FlowAffordanceUITests.swift` and `AccessibilityAuditTests.swift`
are the best work in the slice — they drive the app instead of grepping it, and
`arrived()` (`AccessibilityAuditTests.swift:61-67`) is the direct fix for the
audit-the-wrong-screen bug. Three things still weaken them.

## 5.1 `XCTSkip` on the path that a real failure would take

Every UI test guards navigation with `guard ... else { throw XCTSkip(...) }`,
and these tests hit the **live API** — there is no `URLProtocolStub` in a UI
test target.

- `AccessibilityAuditTests.swift:154` — *"no series on Discover to open —
  offline or empty feed"*. An empty Discover feed is **the exact symptom** of
  the decode bugs this project keeps shipping. When Discover breaks,
  `testSeriesDetailPassesTheAudit` (`:166`) and
  `testCoverGalleryPassesTheAudit` (`:208`) both skip, and a skip reads green.
- `FlowAffordanceUITests.swift:76-78`, `:101`, `:127` — same shape. The comment
  at `FlowAffordanceUITests.swift:68-69` admits it outright: *"which is how this
  skipped twice rather than failing."*
- **Why it matters:** the tests written to catch a broken screen are switched
  off by the screen being broken.
- **Effort:** a function — distinguish "the app is offline" (skip) from "the app
  loaded and the thing is missing" (fail), e.g. by asserting the tab drew
  *something* before deciding.
- **Confidence:** certain.

## 5.2 `arrived()` was applied to the deep screens and not to the tab loop

- **What:** `_ = app.staticTexts.firstMatch.waitForExistence(timeout: 5)` —
  the result is discarded, and it matches *any* static text, including the tab
  bar's own labels.
- **Where:** `MangaBakaUITests/AccessibilityAuditTests.swift:133` (all four
  tabs), `:181` (Settings), `:233` (Library search results).
- **Why it matters:** this is the same defect `arrived()` was written for, left
  in the four tests that run most often. If Discover's feed fails to load, the
  audit runs against an empty screen, finds zero issues, passes, and the log
  records *"Discover: clean"*. A clean audit of a blank screen is the charter's
  Pattern 5 exactly — a number that moved for the wrong reason.
- **Effort:** a line each: `guard arrived(<a marker unique to that screen>, tab)`.
- **Confidence:** certain.

## 5.3 Two tests assert something their own setup may not have produced

- **`AccessibilityAuditTests.swift:222-235`** — `testLibrarySearchResultsPassTheAudit`.
  Line `:225` picks the field with `app.searchFields.firstMatch.exists`, a
  **no-wait** existence check made immediately after tapping the Library tab, so
  it will nearly always fall through to `app.textFields.firstMatch`. Nothing
  then asserts that any result appeared. The suite comment at `:218-221` says
  this test exists precisely because *"a list with results in it is a different
  screen"* — but it may be auditing the Library at rest and filing it as
  "Library search results". **Confidence:** likely.
- **`AccessibilityAuditTests.swift:261-275`** — `testStackMidDragPassesTheAudit`.
  `arrived()` proves the Stack opened; nothing proves the **drag** registered,
  and the badges are at `opacity(0)` until it does (`:257-259`). If the
  press-drag-hold at `:273` does not take, this audits a card at rest and files
  it as "Stack mid-drag" — the same false record the suite's own comment at
  `:55-60` says is *"worse than no record"*. **Confidence:** likely.
- **`FlowAffordanceUITests.swift:119-137`** — `testStackCardsDoNotOfferACopyMenu`
  asserts a **negative** (`XCTAssertFalse`) reached through an action
  (`card.press`) that is not itself verified. A long-press that silently failed
  to register satisfies the assertion. A negative assertion is only as good as
  the proof that the triggering action happened.
  **Effort:** a function — assert the positive control first (a long press on a
  Discover cover *does* open a menu, which `testCoverArtCanBeCopied` already
  proves) and then the negative. **Confidence:** certain about the logic gap.

---

# 6. Suites that share mutable state

## 6.1 THE FLAKE: three suites drive one global HTTP stub in parallel

- **What:** `URLProtocolStub.handler` and `.recorded` are process-wide statics
  (`MangaBakaTests/URLProtocolStub.swift:25-26`). The `NSLock` at `:24` prevents
  *corruption*; it does nothing about *ordering*. 19 test files share them.
  Swift Testing's `.serialized` serialises a suite's own tests — it does **not**
  stop two different suites running at the same time.
- **Where:** three suites use the stub with **no `.serialized` at all**, so even
  their own tests run concurrently against the single global handler:
  - `MangaBakaTests/ReleaseCalendarTests.swift:6` — `@Suite("Release calendar")`,
    **7 tests**, each calling `URLProtocolStub.setHandler` (via `calendar()` at
    `:25`) and `reset()` in a `defer`.
  - `MangaBakaTests/FormatFilterTests.swift:13` —
    `@Suite("The format filter holds everywhere")`, 4 tests, 5 `setHandler` calls.
  - `MangaBakaTests/FormatFilterTests.swift:109` —
    `@Suite("Applying stored filters at launch is not a change")`, 2 tests,
    4 `setHandler` calls.
- **Why it matters, concretely:** `setHandler` at `:28-32` **also clears
  `recorded`**. So while `ReleaseCalendarTests.sortsByDate` is awaiting its
  four-page walk, `narrowsToTheLibrary` can call `setHandler`, replace the
  handler and wipe the request log — and `sortsByDate` then receives the *other*
  test's works and asserts `["a","b","c","z"]` against them. That is a real,
  order-dependent failure in the suite that was rebuilt this week, and it will
  present as an unreproducible flake rather than as a bug. `defer { reset() }`
  makes it worse, not better: one test's teardown disarms another's stub
  mid-flight, and an unarmed stub fails the request with `.unsupportedURL`
  (`:63-65`), which `ReleaseCalendar.swift:38` swallows with `try?` into an
  empty page.
- **Effort:** a line each — add `.serialized`. The real fix is a redesign:
  make the handler an instance the session carries rather than a static, so
  suites cannot see each other's at all.
- **Confidence:** certain that the three suites lack `.serialized` and share the
  statics (verified by parsing every `@Suite` declaration and its body).
  Likely on whether the interleaving actually fires today — it depends on the
  scheduler, and I could not run the suite to find out. **This is the kind of
  thing that will be dismissed as "it passes on my machine" right up until it
  fails in CI.**

## 6.2 Fixed `/tmp` paths written by tests

- `MangaBakaUITests/AccessibilityAuditTests.swift:39` — `/tmp/mb-a11y-audit.txt`,
  **appended** to at `:101-109` and never truncated, so it grows across every
  run and mixes results from different runs in one file. Anyone reading it to
  answer "how many issues does Discover have" is reading an accumulated total.
  That is a denominator nobody stated — charter Pattern 5.
- `MangaBakaUITests/AccessibilityAuditTests.swift:51` — `/tmp/mb-a11y-<screen>.png`,
  overwritten per run (fine, and deliberately so — `:41-46` explains why).
- `MangaBakaTests/DynamicTypeRampTests.swift:89` — `/tmp/mb-type-anchors.txt`.
- **Effort:** a line — truncate the log at the start of the run, or key it by
  a run id. **Confidence:** certain.

## 6.3 What the suite does correctly here — and it is most of it

Named because the pattern is right and should be copied:

- `MangaBakaTests/BlockedTagsTests.swift:9-21` — one fixed suite name,
  `removePersistentDomain` before every use, `.serialized` on the suite. The
  comment at `:11-18` records a **measured** result: per-test UUID suites leaked
  two `.plist` files per run into the simulator's Preferences, a `deinit`-based
  cleanup was tried and *measured to not help*, and the fix was to stop creating
  them. A negative result recorded with its reason, exactly as CLAUDE.md asks.
- `MangaBakaTests/DisplayTitleTests.swift:109-125` with
  `MangaBaka/Core/Model/TitlePreference.swift:44-77` — `TitleSettings` exposes
  an injectable store *for this purpose*; the test redirects it, restores it in
  a `defer` at `:119`, and then **asserts that the real `UserDefaults.standard`
  value was left untouched** (`:117`, `:124`). A test that checks its own
  blast radius is rare and this one does it.
- Per-test unique suite names, correctly: `LensTests.swift:10`,
  `OnboardingTests.swift:98`, `ReminderTests.swift:12`,
  `FormatPreferencesTests.swift:9-11`, `ContentPreferencesTests.swift:8-10`,
  `HistoryTests.swift:122-124`.
- `MangaBakaTests/SourceTree.swift` — every filesystem call is read-only.
- **No UI test passes `-AppleLanguages` or `-AppleLocale`, and none resets or
  erases anything.** The simulator-language incident is not repeated anywhere in
  the current slice. Verified across both UI test files.

---

# 7. Coverage claims that are not what they seem

Beyond the known `APIShapeContractTests` "every endpoint" claim (section 1.6):

## 7.1 "on every surface" covers three of four, and the fourth is a duplicated rule

- **What:** `@Suite("Blocked tags reach the request")`, doc comment *"The block
  has to reach the wire, on every surface, or it is decoration."*
- **Where:** claim at `MangaBakaTests/BlockedTagsTests.swift:81-82`; the three
  tests at `:104`, `:117`, `:132` cover feed, search and blend.
- **The uncovered fourth:**
  `MangaBaka/Core/Persistence/SeriesRepository+Count.swift:31-33` builds its own
  `tag_not` query items for the lens-count endpoint, **independently of** the
  shared filter path in `SeriesRepository.swift`. No test in the repository
  calls `count()` with blocked tags set.
- **Why it matters:** this is a duplicated rule *and* an untested surface at the
  same time — the combination CLAUDE.md names explicitly ("never fix a
  duplication by copying a value into a second place"). Change the blocking rule
  in the shared path and the lens counts silently keep the old behaviour: a
  reader's saved lens reports "412 results" including series they blocked.
- **Effort:** a function (a test), and separately a refactor to expose the rule
  at its source.
- **Confidence:** certain about the duplication and the absent test; likely
  about the exact user-visible symptom.

## 7.2 "whatever its path says" only exercises one of the two branches

- **What:** `@Suite("Identity never reaches the disk cache")`, doc comment
  *"...must not be written to the shared on-disk URL cache, whatever its path
  says."*
- **Where:** claim at `MangaBakaTests/RecommendationQualityTests.swift:459-461`;
  tests at `:481` and `:496`. The guard is
  `MangaBaka/Core/Networking/APIClient.swift:377`:
  `path.hasPrefix("/v1/my") || path.hasPrefix("/v0/my") || carriesIdentity`.
  Both tests exercise only the `carriesIdentity` arm, via `/v1/series/mix`.
- **Mitigating, and it matters:** the path-prefix arm **is** covered, by
  `MangaBakaTests/SafeLinkTests.swift:96-106`
  (`AuthenticatedCacheTests.personalDataBypassesCache`, hitting
  `/v1/my/library`). So the app's behaviour is tested; the suite that makes the
  broad claim is not the one that tests it.
- **Why it matters:** low severity, real cost. Someone deleting or narrowing
  `SafeLinkTests` would read this suite's name and believe the property was
  still guarded.
- **Effort:** a line (a cross-reference comment) or a function (move the test).
- **Confidence:** certain.

## 7.3 `ReleaseSchedule.swift` coverage — already correctly withdrawn

`findings-todo.md` D2 records that the 10.6% figure was attached to the wrong
unit and the estimator is well covered elsewhere. I re-checked and agree; the
entry is already written up with the reason. **No new finding.** Worth saying
because it is the one place this project already caught a coverage claim that
was not what it seemed, and the write-up is the model for the two above.

---

# 8. What this suite does well

Held to the same evidence standard as the findings. These are not consolation
prizes; several of them are why the bugs in `findings-todo.md` were findable.

## 8.1 The best test in the suite: a security guard fixed by asking this review's own question

`MangaBakaTests/SecurityTests.swift:68-88`. It checks the *value* of the
`MB_PAT` assignment, not that the key exists; it strips comments before deciding
whether `Release.xcconfig` includes the secrets file (`:91-97`), specifically so
the prose explaining the exclusion cannot satisfy the check; and its comment at
`:71-77` records the date it was fixed, what the broken version was, and how it
was found. That comment is the reason section 2.4 above exists — the fixed
version is what let me recognise the unfixed copy in `LibraryTests.swift:258`.
**A comment that records its own failure is worth more than the test.**

## 8.2 Control-first decoding

`MangaBakaTests/SeriesDecodingTests.swift:5-7` — *"The control suite runs first
by convention: it decodes a fixture whose answers are known by construction. If
the control fails, no other result in this file means anything."* CLAUDE.md's
"every measurement ships with a control" implemented literally, in the place it
matters most.

## 8.3 A test that asked a question no other test had asked

`MangaBakaTests/SeriesDecodingTests.swift:74-100`, `SourceKeyStrategyTests`. Its
comment states the problem exactly: *"Every test that touches it builds the
dictionary by hand in snake_case, so no test has ever asked."* It then asks —
does `convertFromSnakeCase` rewrite dictionary keys? — against the **real**
`rising.json`, and the failure message at `:94-97` prints the keys it actually
found. The whole release schedule is gated on `mangaUpdatesID`, and this is the
only test that proves the lookup can find anything on a real payload. This is
the single best-conceived test in the slice.

## 8.4 Measurements recorded with their date and method

The comments in this suite are unusually good and repeatedly load-bearing:

- `MangaBakaTests/ReleaseCalendarTests.swift:127-133` — the price bug, the real
  shape, the date it was verified live, and the sentence *"The fixture said
  String too, so the tests agreed with the bug."*
- `MangaBakaTests/SeriesFactory.swift:61-65` — `Cover.realWide` is 4800x5450
  because a real twenty-item row came back with fourteen distinct ratios
  spanning 0.63 to 0.88, fetched 2026-09-09. A fixture with a *cited
  measurement* behind its numbers.
- `MangaBakaTests/BlockedTagsTests.swift:11-18` — a leak, a fix that was tried
  and **measured not to work**, and the fix that did. A negative result kept.
- `MangaBakaTests/SourceTestGuardTests.swift:11-16` — *"It has happened twice.
  The first time cost build 16; the second cost build 21."* Named cost.
- `MangaBaka/Core/Persistence/SeriesRepository.swift:631-640` (read from a test
  claim) — two endpoints measured on 2026-09-10 to ignore `type` entirely, with
  the counts.
- `MangaBakaTests/SeriesFactory.swift:105-107` — a stub returns `nil` rather
  than `0` *because* `0` would make every lens row claim its search now finds
  nothing. Someone thought about what a wrong stub value would silently assert.

## 8.5 The negatives

Seventeen of the seventy-eight catalogued source assertions assert an absence,
and absence is the one thing a stub cannot manufacture. The two best are
`MangaBakaTests/LibraryTests.swift:248-252` / `SecurityTests.swift:91-97`
(comment-stripping line scanners, not substring matches) and
`MangaBakaTests/DetailFidelityTests.swift:419`, whose comment says the negative
form was chosen *because* a presence grep could not tell the two call shapes
apart. `MangaBakaTests/StateFamilyTests.swift:79` is a project-wide scan
asserting `Palette.stale` has exactly one user; `AccessibilityTests.swift:388`
asserts a *file does not exist*.

## 8.6 Two assertions that read the compiled value instead of the source text

`MangaBakaTests/ChromeReachabilityTests.swift:50-51` —
`#expect(Metrics.scrollTopInset <= 32)` and `> 0`. No string, no grep, no
rename fragility. This is what the other 44 stub-satisfiable assertions should
become, and it is already in the repository as a worked example.

## 8.7 `DesignTokenTests` is a whole-project scan, not a grep

`MangaBakaTests/DesignTokenTests.swift:51` sweeps every Swift file under
`MangaBaka/` for a reference to each declared token. It found
`Metrics.gutterStatus` and `Metrics.backButton` (`findings-todo.md` G5). The
difference between this and a one-file `contains` is the denominator: this one
has a complete one. (It still needs the empty-loop guard from 3.4.)

## 8.8 The UI tests fail rather than measure the wrong screen

`MangaBakaUITests/AccessibilityAuditTests.swift:61-67` (`arrived`) and
`:148-162` (`openSeries`, which excludes the "Open the stack" card by predicate)
are the direct, correct fix for the audit-the-wrong-screen bug, and the comment
at `:143-147` says how it was found. `:20-31` lists the audit categories
explicitly rather than passing `.all`, *so that a new SDK category shows up as a
new failure instead of silently changing what "all" meant* — that is a
denominator being pinned on purpose, and it is the opposite of the mistake in
`findings-todo.md` H2.

## 8.9 A skip that keeps a question visible

`MangaBakaUITests/AccessibilityAuditTests.swift:249-254` — `testShelfDetailPassesTheAudit`
throws `XCTSkip` naming the unreachability and pointing at the write-up, rather
than being deleted. The comment at `:247-248` says why: *"so the question stays
visible in the test output until it is answered."* Contrast section 5.1, where
`XCTSkip` is used for a condition that should fail — the difference is that this
one skips for a reason that is *known and recorded*, not for one that is
indistinguishable from a bug.

---

# 9. Summary

**19 findings.** Ordered by what I would do first.

| # | Finding | Where | Effort | Confidence |
|---|---|---|---|---|
| 1 | The `MB_PAT` credential guard is fixed in `SecurityTests` and still broken in its duplicate | `LibraryTests.swift:258` | a function | certain |
| 2 | Three suites drive the one global HTTP stub with no `.serialized` | `ReleaseCalendarTests.swift:6`, `FormatFilterTests.swift:13`, `:109` | a line each / a redesign | certain (mechanism) |
| 3 | `mix.json` is the only fixture with no provenance | `APIShapeContractTests.swift:48` | a line | certain |
| 4 | `/v1/works/upcoming` — the price-bug endpoint — is in no sweep and no fixture; `Price.value` is non-optional against a nullable spec field | `UpcomingWork.swift:35`, `APIShapeContractTests.swift:82-90` | a line + a test | certain (spec), likely (impact) |
| 5 | `publisherLink` filters on `"publisher"`; the spec's default is `"store"`, and the fixture hand-writes the model's assumption | `UpcomingWork.swift:103`, `ReleaseCalendarTests.swift:17` | a line | likely — needs one live call |
| 6 | 44 of 78 source-grep assertions are stub-satisfiable | `AccessibilityTests.swift:58,59,70,492`, `DetailFidelityTests.swift:141,152-155`, +38 | a file | certain |
| 7 | `LibraryTests.swift:277` is a tautology — it cannot fail | `LibraryTests.swift:277` | a line | certain |
| 8 | The identity-parameter privacy check is satisfied by the doc comment above the set it guards | `SecurityTests.swift:108-110` | a line | certain |
| 9 | `SourceTestGuardTests` cannot see tests that read files without `SourceTree` | `SourceTestGuardTests.swift:47`, `AccessibilityTests.swift:84-90` | a line | certain |
| 10 | The whole `Request budget` suite counts requests and never counts cards | `RequestBudgetTests.swift:47,70-76,85-88` | a line each | likely |
| 11 | Five loops whose assertions vanish when the collection is empty | `AccessibilityTests.swift:40,409`, `DesignTokenTests.swift:43`, `RecommendationQualityTests.swift:71`, `DetailFidelityTests.swift:351` | a line each | certain |
| 12 | UI tests `XCTSkip` on exactly the condition a broken screen produces | `AccessibilityAuditTests.swift:154`, `FlowAffordanceUITests.swift:76,101,127` | a function | certain |
| 13 | `arrived()` was applied to the deep screens and not to the four tab audits | `AccessibilityAuditTests.swift:133,181,233` | a line each | certain |
| 14 | Two audits may be measuring a screen they did not reach the state of | `AccessibilityAuditTests.swift:225,271-273` | a function | likely |
| 15 | A negative assertion reached through an unverified action | `FlowAffordanceUITests.swift:129-136` | a function | certain |
| 16 | "on every surface" misses the lens-count surface, which duplicates the blocking rule | `BlockedTagsTests.swift:81`, `SeriesRepository+Count.swift:31-33` | a function + a refactor | certain |
| 17 | `ShelfDetailView` still unreachable; ~14 assertions spent on it | `LibraryModelTests.swift:205-238,258,261`, `InlineSearchTests.swift:63,73`, `AccessibilityTests.swift:177,409` | a file | certain |
| 18 | `library.json`/`mix.json` redaction collapsed `titles` to one entry and emptied `shared_tags` | `Fixtures/library.json`, `Fixtures/mix.json` | a line | certain |
| 19 | Fixed `/tmp` log appended across runs; an "instrument" carrying an assertion that cannot fail | `AccessibilityAuditTests.swift:39`, `DynamicTypeRampTests.swift:89,91` | a line | certain |

**The honest headline:** the four known cases were all found in this slice
because somebody looked. The same looking finds more — the credential guard
(#1) is the same defect as the one fixed on 2026-09-11, surviving in a second
file, and the stub-grep pattern that `FlowAffordanceTests` was closed for is
alive in a dozen others. **Fixture provenance, the question that produced the
worst bug, is in good shape: three of four fixtures are captured and dated, and
the fourth is a declared control.** The gap has moved from the fixtures to the
source greps and to the endpoints that have no fixture at all.
