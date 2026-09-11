# Wire slice review — `Core/Networking` + `Core/Model`

Read-only pass, 2026-09-11. 2,618 lines across 25 files, all read. No build, no test
run, no network call.

**A source of evidence this review used that the charter did not name:**
`docs/schemas/mangabaka_openapi.json` is in the repo and carries per-field
nullability and `required` lists. Several findings below are Swift-vs-schema
mismatches that can be checked without a network call. The spec is known to lag
reality (`Series.swift:5-9`), so a mismatch is not proof of a live failure — but a
field the spec marks nullable and the model marks non-optional is exactly the shape
of all four bugs the charter records, and none of these has a fixture or a sweep
entry beside it.

17 findings. Question 1 (field-by-field evidence) is answered in the table at the
end; question 2 (swallowed decodes) in section C.

---

## A. A model that disagrees with the payload (charter pattern 1)

### W1. `SeriesWork.Price.value` is non-optional against a schema that says nullable

- **What** — `let value: Double` cannot decode `{"value": null, "iso_code": "usd"}`,
  which the repo's own schema permits.
- **Where** — `MangaBaka/Core/Model/SeriesWork.swift:12`. Schema:
  `components.schemas.V1_Price` — `"value": {"type": ["number","null"]}`, and
  `value` is in that object's `required` list, so null is the *documented* way to
  say "no price".
- **Why it matters** — one unpriced edition anywhere in
  `/v1/series/{id}/works` throws `Price` → throws `[SeriesWork]` → the `try?` at
  `MangaBaka/Core/Persistence/SeriesRepository.swift:662` yields nil →
  `SeriesWork.volumes(from: [])` → **the whole volumes section of the series page
  is absent**, for that series, silently. This is the same field family as the
  charter's `UpcomingWork.price` bug, one layer down. A free digital first volume
  or a not-yet-priced announced volume is the trigger.
- **Effort** — a line (`Double?`), plus one line in `price` to skip valueless
  entries.
- **Confidence** — certain about the mismatch; likely about it occurring live.

### W2. `NewsItem.id` is non-optional against a nullable-and-required `id`

- **What** — `let id: Int` where the schema says `["number","null"]`.
- **Where** — `MangaBaka/Core/Model/SeriesExtras.swift:102`. Schema:
  `/v1/series/{id}/news` → `data.items.properties.id` is `["number","null"]` and is
  listed in `required`.
- **Why it matters** — one ANN item with a null id throws the whole array; the
  `try?` at `SeriesRepository.swift:646` turns it into nil, and the news rail on
  the series page shows nothing. `NewsItem` is `Identifiable` off this field, so
  the fix needs a synthesised id (source_id, or the URL) rather than just `Int?`.
- **Effort** — a function.
- **Confidence** — certain about the mismatch.

### W3. `SeriesImage.id` is non-optional against a nullable-and-required `id`

- **What** — same shape as W2.
- **Where** — `MangaBaka/Core/Model/SeriesImage.swift:10`. Schema:
  `components.schemas.V1_Series_Cover_Image` — `"id": {"type": ["number","null"]}`,
  and `id` is in `required`. `series_id` and `index_numeric` are nullable too, and
  the model has those optional already — `id` is the one that was missed.
- **Why it matters** — `SeriesRepository.swift:612` is `try?` → `[]`, and the
  guard on the next line (`guard let all, !all.isEmpty`) makes a decode failure
  and "this series has one cover" literally the same value. The cover gallery
  disappears with no error anywhere. Solo Leveling carries 24 images; one bad id
  loses all 24.
- **Effort** — a line, plus an `id` fallback for `Identifiable`.
- **Confidence** — certain about the mismatch.

### W4. `PublisherRecord.id` is non-optional against a field that is both nullable and not required

- **What** — `let id: Int`; the schema's publisher object lists only
  `["type","aliases","name"]` as required and types `id` as `["number","null"]`.
- **Where** — `MangaBaka/Core/Model/Catalogue.swift:47`. Schema:
  `/v1/publishers/search` → `data.items`.
- **Why it matters** — one imprint without an id throws the array;
  `CatalogueService.swift:104-111` swallows it with `try?` and returns `[]`, so
  the publisher browse screen says "nothing found" for a query that matched. This
  is the one field in the file where the model is stricter than the wire.
- **Effort** — a line, plus an `id` derived from `name`.
- **Confidence** — certain about the mismatch.

### W14. `Series.tagsV2` is decoded under a `try?`, so one bad tag drops all of them

- **What** — `tagsV2 = try? container.decodeIfPresent([SeriesTag].self, ...)`.
  `decodeIfPresent` already handles absence; the extra `try?` only ever swallows a
  *shape* disagreement.
- **Where** — `MangaBaka/Core/Model/Series.swift:126`. `SeriesTag.id` and
  `SeriesTag.name` are both non-optional (`SeriesTag.swift:12-13`).
- **Why it matters** — Solo Leveling has 146 tags across 17 groups. A single
  entry with a null name empties `richTags`, `TagGrouping.groups` returns nothing,
  and the tag section on the series page is blank — with the flat `tags` fallback
  masking it further, because the reader sees *a* tag list and cannot tell it is
  the degraded one. The comment justifies the `try?` on the grounds that tags_v2
  is absent on v2, which `decodeIfPresent` already covers.
- **Effort** — a line to drop the `try?`, or a function to decode tags
  element-by-element so one bad entry costs one tag.
- **Confidence** — certain about the code; likely about the impact.

### W17. `CommunityPulse` counts are `Int` against a schema that says `number`

- **What** — four `Int` fields decoded from JSON the schema types as `number`.
- **Where** — `MangaBaka/Core/Model/CommunityPulse.swift:14-17`. Schema:
  `/v0/frontpage/community-pulse` types all eighteen fields as `number`.
- **Why it matters** — the sibling field `chapters_read_count` is *measured* to
  arrive fractional (`53975689.25981874`, recorded at `CommunityPulse.swift:61-63`)
  and is correctly `Double`. The same server that sends a fractional chapter count
  is one release away from a fractional user count, and `Int` throws on
  `290.0`-style values in a way `Double` does not. A throw here hides the whole
  card (`CommunityPulseService.swift:29-30`).
- **Effort** — four lines, rounding at the `figures` boundary that already rounds.
- **Confidence** — worth checking. The fractional sibling is the reason to bother.

### W16. `PublisherRecord.subType`'s comment names values the schema does not have

- **What** — the comment says `"both", "original", "english"`; the schema's enum
  is `["physical","digital","both"]`.
- **Where** — `MangaBaka/Core/Model/Catalogue.swift:51-52`.
- **Why it matters** — nothing branches on it today, so the cost is future: this
  is precisely the charter's tell, "a comment that says what a field is without
  saying when it was last checked against a response". The first screen that
  filters on `subType == "english"` will filter to zero rows and look like an empty
  result.
- **Effort** — a line.
- **Confidence** — certain.

---

## B. Computed and discarded / code that disagrees with its own comment

### W5. `SeriesWork.volumes(from:)` drops every work without a `sequence_string`, and its comment says it does not

- **What** — the doc comment promises "Anything without a number keeps the API's
  own order at the end — a side story or a box set is still worth showing, just
  not worth pretending to place." The loop then `continue`s past exactly those.
- **Where** — `MangaBaka/Core/Model/SeriesWork.swift:124-131`. The guard is
  line 131; the comment it contradicts is lines 124-126.
- **Why it matters** — the sort below (lines 136-144) carefully handles a nil
  `sequenceNumeric`, which is dead work: nothing with a nil sequence ever reaches
  it, because the guard filters on `sequenceString` first. Box sets, omnibuses and
  side stories vanish from the volumes list, and the person reading the comment
  believes they are at the bottom of it. Note the spec marks `sequence_string`
  required-and-non-null, so this may bite rarely — which is worse, not better,
  because it will look like a data problem rather than a code one.
- **Effort** — a function (group the numberless ones under their own label, or
  keep them in API order at the end as promised).
- **Confidence** — certain.

### W15. `preferredCover` has no final fallback, and the language it falls back to is usually nil

- **What** — ranks `["en", nativeLanguage]` and returns nil when neither matches,
  rather than falling back to any cover at all.
- **Where** — `MangaBaka/Core/Model/SeriesImage.swift:49-56`.
- **Why it matters** — `nativeLanguage` reads
  `titles.first { $0.traits.contains("native") }?.language`
  (`Series.swift:236-238`), and `DisplayTitle.swift:69-72` records a measurement
  that says most series carry no `native` trait at all — "the origin-language
  title is simply tagged `ja` or `ko` with nothing else". So for the common case
  the ranked list is just `["en"]`, and a Korean manhwa with only Korean volume
  covers returns nil from a function whose doc says it returns "the series' own
  language". Two files already in the repo disagree; one of them measured it.
- **Effort** — a line (append the best remaining cover), or a function if the
  language matching should use the same normalisation `DisplayTitle.languageCode`
  already implements.
- **Confidence** — likely.

---

## C. Swallowed decodes — question 2, traced

Fifteen sites where a decode failure reaches a caller. Three of them are
distinguishable from empty; twelve are not.

| Site | Feeds | Failure looks like |
|---|---|---|
| `CatalogueService.swift:35` genres | Browse genre chips | no genres exist — **and is cached, W9** |
| `CatalogueService.swift:52` tags | Browse tag tree, both tag pickers | no tags exist — **and is cached, W9** |
| `CatalogueService.swift:90` searchTags | tag pickers | **distinguishable** — returns nil, `TagSearch.emptyMessage` says "Could not search" |
| `CatalogueService.swift:104` searchPublishers | publisher browse | no publishers match — **W10** |
| `CommunityPulseService.swift:29` | Discover pulse strip | **distinguishable** — `didFail`, card hidden by choice |
| `APIClient.swift:325` `profile()` | "am I signed in" | nil; `verifiedProfile()` exists for the case that needs the reason |
| `Series.swift:126` tagsV2 | series page tag section | no rich tags — **W14** |
| `SeriesRepository.swift:612` images | cover gallery | series has one cover |
| `SeriesRepository.swift:645` links | "Read it" / publisher links | series has no links |
| `SeriesRepository.swift:646` news | news rail | no news about this series |
| `SeriesRepository.swift:650` relationships | related series | series is unrelated to anything |
| `SeriesRepository.swift:654` full v1 series | synopsis, tags, year, chapter count | series has no synopsis |
| `SeriesRepository.swift:655` collections | editions section | no editions |
| `SeriesRepository.swift:662` works | volumes section | no volumes — **W1's blast radius** |
| `SeriesRepository+Count.swift:34` total | saved-lens counts | **distinguishable** — nil, and `APIClient.total`'s doc at `APIClient.swift:99-102` explains why nil must never become 0 |

The seven `try?`s in `fetchExtras` (`SeriesRepository.swift:645-662`) all land in
one `SeriesExtras`, and every one of them is `?? []`. A series page whose network
dropped mid-load renders identically to a series with no links, no news, no
relatives, no editions and no volumes. Nothing on that screen, and nothing in any
log, says which happened. The surrounding code shows the lesson *was* learned once
— `images` deliberately does not cache an empty result (`:613-616`) and `extras`
deliberately does not cache an empty `SeriesExtras` (`:637`) — but not caching a
failure is a different thing from being able to see one.

### W9. `CatalogueService` caches a failed fetch as an empty success for the rest of the session

- **What** — `genres()` and `tags(limit:)` write the result of a `try?` into the
  cache unconditionally.
- **Where** — `MangaBaka/Core/Model/CatalogueService.swift:34-41` (genres:
  `cachedGenres = fetched` at `:39` after `(try? ...) ?? []` at `:35`) and
  `:51-69` (tags: `cachedTags = fetched` and `cachedTagLimit = limit` at `:66-67`
  after `try?` at `:52`).
- **Why it matters** — `if let cachedGenres { return cachedGenres }` at `:30` and
  `if let cachedTags, cachedTagLimit >= limit` at `:48` then return `[]` forever,
  with no further request. One dropped packet while Browse is opening empties the
  genre chips and the tag tree until the app is relaunched. The actor is a
  singleton on `AppServices`, so "the session" is the whole app run. The file's own
  header comment is about not re-fetching too often; this is the opposite failure.
- **Effort** — a function (cache only a non-empty result, or cache a
  `Result`).
- **Confidence** — certain.

### W10. `searchPublishers` collapses failure into "no results", against the rule `searchTags` writes down two functions above it

- **What** — `return results ?? []`.
- **Where** — `MangaBaka/Core/Model/CatalogueService.swift:104-111`.
- **Why it matters** — `searchTags` at `:85-87` carries the decision explicitly:
  *"Returns nil, not an empty array, when the request fails: 'no tags match' and
  'the network is down' must not look the same on screen."* The publisher search
  right below it does the thing that comment forbids, and the publisher browse
  screen has no way to tell the reader which it was. The two functions are eight
  lines apart.
- **Effort** — a line here, plus the caller's empty state.
- **Confidence** — certain.

---

## D. The rate-limit gate

### W6. Every write bypasses the gate — it is neither consulted before a write nor armed by a write's 429

- **What** — `send()` (the one path behind `post`, `patch` and `delete`) never
  calls `limiter.secondsUntilAllowed()` and never calls
  `limiter.recordRateLimit(retryAfter:)`.
- **Where** — `MangaBaka/Core/Networking/APIClient.swift:228-273`. Compare
  `rawData`, which does both: the pre-flight refusal at `:117-119` and the arming
  at `:159-161`. `send`'s 429 branch is `:259-262` and only throws.
- **Why it matters** — two concrete failures, in both directions:
  1. **Writes hammer an active backoff.** A reader marking ten chapters read
     while the gate is closed fires ten real requests into a 429 window. The
     gate's own header comment says why that is not only our problem: the limit is
     per IP and shared, so "retrying into a 429 ... keeps other people's requests
     failing too."
  2. **A write's 429 does not protect the reads.** A rate limit discovered on a
     library update leaves the gate open, so the next feed fetch spends another
     request discovering the same refusal.
  `LibraryWriteTests.swift:150-158` proves a write's 429 is surfaced as an error,
  which is why this looked handled. Nothing asserts the gate is involved, and
  `RateLimitTests` only drives reads (`makeClient` + `get`).
- **Effort** — a function: route `send` through the same pre-flight and arming, or
  factor the gate handling out of `rawData`.
- **Confidence** — certain.

### W7. The write path's offline detection is narrower than the read path's

- **What** — `rawData` treats `.notConnectedToInternet`, `.networkConnectionLost`
  and `.dataNotAllowed` as `.offline`; `send` treats only
  `.notConnectedToInternet`.
- **Where** — `APIClient.swift:250-251` against `APIClient.swift:136-139`.
- **Why it matters** — a connection dropping mid-write (a lift, a tunnel — the
  case `APIClientTests.swift:83` has a dedicated test for on the read path)
  produces `.transport` instead of `.offline`. That is not cosmetic:
  `APIError.staleContentRemainsUseful` is true for `.offline` and false for
  `.transport` (`APIError.swift:44-48`), and the headline changes from "You're
  offline" to "Something went wrong" (`:128-131`). The reader is told the app
  broke rather than that their signal did. The two also disagree on detail text —
  `rawData` uses `error.localizedDescription` (`:142`), `send` uses
  `String(describing: error)` (`:254`), which is the internals-y one.
- **Effort** — a line, by sharing one `catch` ladder.
- **Confidence** — certain.

### W8. Writes are invisible to `NetworkLedger`, so any request-budget number excludes them

- **What** — `rawData` records path, bytes, seconds and failure to
  `NetworkLedger.shared` (`APIClient.swift:145-152`); `send` records nothing.
- **Where** — `APIClient.swift:246-273`.
- **Why it matters** — charter pattern 5. Any claim of the form "N requests per
  session" or "K bytes on a series page" built from the ledger has an unstated
  denominator that silently omits every library write — and library writes are the
  bursty ones (a batch status change, a re-read marking). A budget tuned on that
  number is tuned against the wrong traffic.
- **Effort** — a line.
- **Confidence** — certain.

---

## E. Envelopes and the shape-contract test

### W13. The test that claims to cover "every endpoint the app decodes" checks a hardcoded seven of about seventeen

- **What** — `sweepCoversEveryEndpoint` asserts the sweep script mentions seven
  endpoints, listed inside the test itself. Its doc says this exists "so an
  endpoint added later without being swept is caught here" — but an endpoint added
  to the app is not added to this list, so nothing is caught.
- **Where** — `MangaBakaTests/APIShapeContractTests.swift:78-94`.
- **Why it matters** — `grep -rE 'client\.(get|getBare|getRoot|getResults|total)\('`
  over `MangaBaka/` returns 24 call sites covering roughly 17 distinct paths. The
  ten not swept and not fixtured are exactly where W1-W4 sit:
  `/v1/series/{id}/works`, `/collections`, `/images`, `/news`, `/links`,
  `/relationships`, `/v0/frontpage/community-pulse`, `/v1/tags`, `/v1/genres`,
  `/v1/publishers/search`, plus `/v1/works/upcoming` and
  `/v1/my/series/discover/top-genres`. The four fixtures in
  `MangaBakaTests/Fixtures/` are `rising`, `mix`, `library` and `control` — every
  one a series-shaped payload. **Every decode bug this project has paid for was in
  a series-shaped payload, because that is the only shape it has ever tested.**
- **Effort** — a file: derive the endpoint list from the source (a grep, as above)
  rather than retyping it, so the assertion is about the app rather than about the
  test's own literal.
- **Confidence** — certain.

### W12. `getBare` and `getRoot` are the same function under two names, and one has a dead `catch`

- **What** — `getBare` (`APIClient.swift:79-89`) and `getRoot`
  (`:287-299`) both fetch raw data and decode `Payload` with no envelope. Their
  bodies are identical apart from `getRoot`'s extra
  `catch let error as APIError` at `:294-295`, which can never fire —
  `decoder.decode` throws `DecodingError`, and `rawData`'s typed `APIError` is
  thrown before the `do` block is entered.
- **Why it matters** — three envelope shapes, four accessors. A caller choosing
  between `getBare` and `getRoot` is choosing between two spellings of the same
  thing, and the two doc comments each describe a different single endpoint as
  though it were the reason the method exists. (`getResults`' identical-looking
  catch at `:313-314` is *not* dead — its `guard` throws an `APIError` from inside
  the `do`. Keep that one.)
- **Effort** — a line: delete one, point its callers at the other.
- **Confidence** — certain.

### W11. `total()` decodes the entire series payload to read one integer

- **What** — `decoder.decode(APIEnvelope<[Series]>.self, from: data).pagination?.count`.
- **Where** — `MangaBaka/Core/Networking/APIClient.swift:106`.
- **Why it matters** — the method's doc (`:92-102`) is careful that a missing
  count must show as missing and never as zero. But it makes the count hostage to
  the full `Series` decode of whichever one series came back in the `limit=1`
  page: any of the shape problems above in that one row throws, and the saved
  lens loses its count. The count is in `pagination`, which does not need `data`
  at all — decoding `APIEnvelope<[EmptyPayload]>`, or a pagination-only envelope,
  removes the coupling entirely.
- **Effort** — a line (a two-field private struct).
- **Confidence** — certain.

---

## F. Question 1, answered as a table

Every `Codable` type in the slice, and what evidence stands beside its field types.

| Type | Evidence | Dated? |
|---|---|---|
| `Series` | `rising.json`, `mix.json` fixtures + shape sweep + `APIShapeContractTests` + per-field comments | yes — 2026-09-08/09, and the v1/v2 split table is written into the test file |
| `Cover` | both fixtures, both shapes, comment naming the endpoints | yes — 2026-09-09 |
| `SeriesTitle` | comment recording 25/25, 14/14, 18/18 `is_primary` | yes — 2026-09-08 |
| `Series.TrackerEntry` | comment naming anime_planet (string) vs anilist (number) | undated, but names the payloads |
| `Recommendation` | `mix.json` fixture | yes — 2026-09-08 |
| `SeriesTag` | schema matches; comment cites Solo Leveling's 146 tags / 17 groups | undated |
| `Pagination` | comment records the live query and the answer | yes — 2026-09-10 |
| `SeriesWork` | api-opportunities records the *shape*; **no fixture, no sweep entry, and `Price.value` disagrees with the schema (W1)** | 2026-09-11 for the shape, never for the Swift types |
| `SeriesEdition` | comment records the endpoint returns own-series editions | 2026-09-10 — behaviour checked, field types not |
| `SeriesImage` | none for field types; **`id` disagrees with the schema (W3)** | no |
| `SeriesLink` | comment counts link types on series 3397 | 2026-09-11 — vocabulary checked, types not |
| `NewsItem` | none; **`id` disagrees with the schema (W2)** | no |
| `SeriesRelationship` | none. *Checked during this review: the endpoint really does nest a full `V1_Series_Default` under `series`, so the non-optional `series` is correct.* | no — now yes, against the spec |
| `CommunityPulse` | comment records the fractional chapter count; **`Int` vs `number` (W17)** | 2026-09-11 |
| `Genre` | schema matches exactly (both required, both non-null) | no |
| `Tag` | schema matches; `namePath` optional where spec is required — safe direction | no |
| `PublisherRecord` | **`id` disagrees with the schema (W4); `subType` comment disagrees with the enum (W16)** | no |
| `APIEnvelope` / `ResultsEnvelope` / `APIErrorEnvelope` | comments name the endpoints and the failure each shape caused | yes — 2026-09-09 and 2026-09-11 |
| `SearchQuery` | comments record live counts for `publisher` and for the leftover-tag case | yes — 2026-09-10 |

**The pattern:** every type with dated evidence is series-shaped, and every type
with no evidence is one of the satellite endpoints added on 2026-09-10/11. The
four mismatches this review found are all in the second group. That is not a
coincidence — it is the sweep's coverage boundary (W13) showing through.

---

## G. What this slice does well

Same evidence standard.

- **The error taxonomy earns its size.** `APIError.staleContentRemainsUseful`
  (`APIError.swift:44-48`) is a real distinction — a rate limit says nothing about
  the cached copy, a decode failure means the shape moved and the cache may lie —
  and it is the kind of thing most apps collapse into `showError()`. The
  rate-limit copy (`:84-87`) refusing to blame the reader for a shared per-IP
  limit is a genuine piece of product judgement, with the reason written next to
  it.
- **`APIClientTests` is behavioural, not a source grep.** Nineteen tests driven
  through a `URLProtocol` stub covering 429 with and without `Retry-After`,
  connection-lost, unreadable error bodies, empty bodies, a 200 with no `data`
  key, and header/credential handling. It opens with a test literally named
  "Control — a well-formed response decodes" (`APIClientTests.swift:23`), which is
  CLAUDE.md's control rule actually honoured rather than cited. `RateLimitTests`
  injects a movable clock so backoff is tested without waiting
  (`RateLimitGate.swift:17-21`).
- **The cache-policy rule is derived from the threat, not the path.**
  `APIClient.swift:364-379` explains that a path prefix is insufficient because
  `/v1/series/mix` becomes identifying the moment it carries
  `exclude_user_library` — the URL is the cache key, so the account id would land
  in a 256 MB on-disk cache. `identifyingParameters` (`:343-347`) pre-lists
  `blend_user_id`, a parameter the app does not yet send, so adding it cannot be
  the change that quietly starts caching an id. That is a defence written before
  the bug.
- **`SafeLink`** (`SeriesExtras.swift:89-97`) filters contributed URLs to
  http/https *and* requires a host, with the reason stated: community data must
  not be able to trigger another installed app. Applied at both `SeriesLink` and
  `NewsItem`.
- **Comments record measurements with dates and methods, and they are why this
  review found anything.** `Pagination.count` (`APIEnvelope.swift:24-31`) names
  the wrong old name, the live query, the answer and the date. `DisplayTitle.best`
  (`DisplayTitle.swift:88-93`) records the exact series (638) where taking the
  first `en` title showed a romanisation. `TitleSettings.resetForTesting`
  (`TitlePreference.swift:47-51`) records that a test once changed what the app
  did on the next launch.
- **The three-envelope problem is handled explicitly rather than guessed at.**
  `getResults` returns a named decoding error when `results` is absent
  (`APIClient.swift:309-312`) instead of an empty array, which is the precise
  mistake the charter's pattern 1 is about.
- **`Series.filling(gapsFrom:)`** (`Series.swift:192-217`) guards on matching ids
  before merging and states why: merging two different series would be silent data
  corruption. Field-by-field, with the on-screen copy winning, so nothing changes
  under the reader.
- **No force-unwraps.** Confirmed by reading all 25 files: not one `!` on a value
  derived from a response. The charter asked for this to be re-verified rather than
  assumed; for this slice it still holds.

---

## H. Not reviewed

- Nothing live was called, so every Swift-vs-schema mismatch above is a mismatch
  with the repo's spec, not a reproduced failure. The spec lags the API by the
  app's own account. W1-W4 each cost one `curl` to settle, and settling them is
  worth more than any other item here.
- `NetworkLedger`, `TokenStore`, `LibraryEntry`, `UpcomingWork`, `MixEnvelope`,
  `PersonalRecommendation` and `TopGenre` are outside the slice. `UpcomingWork` is
  worth someone's attention for the same reason as W1 — it is the type whose
  `price` was the original bug.
