# Wire slice review — 2026-09-13

Read-only. No build, no test, no edit outside this file. Focus for this run: data-shape
assumptions that fail on real inputs.

## Scope

**Reviewed in full (22 of 22 files, 3,631 lines):**
`Core/Networking/` — APIClient, APIEnvelope, ResultsEnvelope, APIError, RateLimitGate,
RequestSpacing, TokenProvider. `Core/Auth/` — TokenStore, Profile. `Core/Telemetry/` —
NetworkLedger, Signposts. `Core/Model/` — Series, Cover, SeriesTitle, SeriesImage,
SeriesWork, SeriesExtras, SeriesTag, SeriesEdition, SeriesWebLink, SeriesStatus,
Recommendation, BlendDNA, Catalogue, CatalogueService, PublisherDetail, CommunityPulse,
CommunityPulseService, DisplayTitle, TitlePreference, LanguageFlag, TagSearch,
SearchQuery, TagTaxonomy, ReadingPlatforms.

**Read for context only (not reviewed):** `SeriesRepository.swift:610-720` (the caller of
every v1 extras decode), `LibraryService.swift:68-93, 260-290` (write bodies),
`LibraryEditSheet.swift:120-246`, `SeriesDetailView+Covers.swift:37-75`, the OpenAPI spec
at `docs/schemas/mangabaka_openapi.json`, and the tests that decode slice types
(APIShapeContractTests, WireNullabilityTests, CatalogueTests, PublisherPageTests,
DisplayTitleTests, SeriesWorkTests, EditionLabelTests, SeriesExtrasTests headers).

**Already on record, not re-derived:** W1–W17 from `SUMMARY-2026-09-11.md` are all
either fixed in code (W1 `SeriesWork.swift:12-15`, W3 `SeriesImage.swift:10-12`, W5
`SeriesWork.swift:216-218`, W7/W8 `APIClient.swift:131-137`, W9 `CatalogueService.swift:43-45`,
W11 `APIClient.swift:114-117`, W12 `APIClient.swift:312-314`, W14 `Series.swift:127-129`,
W16 `Catalogue.swift:53-55`) or withdrawn in code (W15 `SeriesImage.swift:66-70`). The
F6 snake_case false positive stays withdrawn; nothing here touches it.

### Live requests (5 used)

The brief named `api.mangabaka.dev`. **That host is dead**: two GETs to it
(`/v1/publishers/18/full`, twice) answered
`{"status":500,"message":"api.mangabaka.dev is deprecated and no longer serves traffic —
switch to https://api.mangabaka.org"}`. The app already uses `.org`
(`Configs/Base.xcconfig:7`, `AppServices.swift:140`, both sweep scripts), so this is not
an app defect — it is a stale host in the review brief. The remaining three went to `.org`:

| # | URL | What it showed |
|---|-----|----------------|
| 3 | `GET /v1/publishers/18/full` | Yen Press: `founded: null, closed: null` — same as the Ize Press fixture, so the non-null type was still unobserved. `imprints[]` present (not in spec, not decoded). |
| 4 | `GET /v1/publishers/search?q=Kodansha&limit=6` | 3 rows. **`"founded": "2008-07-01"`** on Kodansha USA — a date string. Search rows also carry `founded`/`closed` (spec omits them). Exact name "Kodansha" is the third row. |
| 5 | `GET /v1/series/638` | 34 titles. **Two `ko-Latn` titles**, the first untagged ("Baegjaggaui Mangnaniga Doeeossda"), the second tagged `native` ("Baekjakgaui Mangnaniga Doeeotda"). `ko` native title is first in the list. `total_chapters: "188"`, `year: 2020`, `anime_news_network` tracker has all-null fields, `tags` is a string list, `tags_v2[0]` carries every `SeriesTag` field, cover is the v1 object shape. |

---

## Findings, ordered by value

### 1. `founded`/`closed` are `Int?`/`Bool?`; the wire sends date strings — every publisher with a founding date kills its own page and the search that finds it

- **What** — `PublisherRecord.founded: Int?`, `closed: Bool?` and `PublisherDetail.founded: Int?`, `closed: Bool?` decode a field the spec types `["string","null"], format: date` and the live API sends as `"2008-07-01"`.
- **Where** — `Catalogue.swift:59-61`; `PublisherDetail.swift:31-32`. Spec: `/v1/publishers/{id}/full` → `founded: string|null (date)`, `closed: string|null (date)`. Live: request 4 above.
- **Why it matters** — `[PublisherRecord]` is one array under `try?` (`CatalogueService.swift:130`), so a search whose results include any founded publisher returns nil: typing "Kodansha" in the publisher browser shows "could not search" (`PublisherBrowser.swift:112`). `PublisherDetail` is under `try?` at `CatalogueService.swift:126`, so Kodansha USA's page opens with no record at all and no error (`PublisherView.swift:262-263`). Both were verified on Ize Press and Yen Press, both of which happen to have `founded: null` — the type was chosen without ever seeing a non-null value. `PublisherDetail.swift:56` ("Since \(founded)") and `:57` ("Closed") can therefore never have rendered for anyone.
- **Also** — two fixtures agree with the bug (charter §2): `PublisherPageTests.swift:31` `"founded": 1997, "closed": true` and `CatalogueTests.swift:121` `"founded":2005,"closed":false`. Both were built from the model, not from a response; both pass; the real shape fails both types.
- **Effort** — four lines (two types × two fields: `String?` and derive the year for `summary`), plus correcting the two fixtures to the date-string shape so they fail first.
- **Confidence** — certain.

### 2. "Romanised" picks the first `-Latn` title, and series 638 — the example the setting itself quotes — has two

- **What** — `DisplayTitle.matching(.romanised)` returns `titles.first { language.hasSuffix("-Latn") }` with no trait preference, unlike the English branch which the file itself documents needed one.
- **Where** — `DisplayTitle.swift:67` (and the fallback at `:46`). Compare `best(inLanguage:)` at `:94-98`, whose comment (`:88-93`) records exactly this class of failure for `en`.
- **Why it matters** — On the live 638 payload (request 5) the first `ko-Latn` title is the untagged "Baegjaggaui Mangnaniga Doeeossda"; the one tagged `native` is "Baekjakgaui Mangnaniga Doeeotda". `TitlePreference.swift:28` shows the reader the second as the example of what "Romanised" means; the app then displays the first. `DisplayTitleTests.swift:18-23` says "The real payload, in the order the API sends it" and lists four titles of 34, omitting the untagged romanisation — so `eachPreference` (`:35-41`) passes against a subset that cannot fail. Note the order also differs: today the `ko` native title comes first, not "Baekjakga-ui…"; the API's order is not something to fixture.
- **Effort** — a line: prefer a `-Latn` title carrying a trait (`native`/`official`) before an untagged one, same shape as `best(inLanguage:)`. Then re-capture the 638 titles into the test with today's date.
- **Confidence** — certain (reproduced against the live payload; test fixture is a subset).

### 3. `nativeLanguage` accepts a `-Latn` title as the series' language, which then narrows the cover fan to English-only and answers "Original language" with a romanisation

- **What** — `Series.nativeLanguage` takes the first title whose traits contain `native` regardless of script; a `ko-Latn` title tagged `native` exists on the wire.
- **Where** — `Series.swift:241`; consumed by `coverLanguages` at `:281-282` and by `DisplayTitle.matching(.original)` at `DisplayTitle.swift:75` (whose own comment at `:73-74` says `-Latn` must be excluded — the exclusion is applied only to the *second* branch at `:76`).
- **Why it matters** — If the `ko-Latn native` title precedes the `ko native` one, `coverLanguages` becomes `["en", "ko-latn"]`; `SeriesDetailView+Covers.swift:73` matches by `hasPrefix`, `"ko".hasPrefix("ko-latn")` is false, and every Korean cover is dropped from the fan; `preferredCover(nativeLanguage:)` (`SeriesImage.swift:63`) finds nothing for the same reason. "Original language" would show the romanisation. On 638 today the `ko` title is listed first, so it works by ordering luck; nothing in the API or the code guarantees that order (see finding 2 — the order has already changed once since 2026-09-10).
- **Effort** — a line: skip `-Latn` in `nativeLanguage`, or reduce to the primary subtag.
- **Confidence** — likely (mechanism certain; depends on title order, which is observed to vary).

### 4. `Int(Double)` on wire-fed values traps; three sites reachable from the network

- **What** — `Int(_ : Double)` is a runtime trap for NaN, ±infinity, or anything ≥ 2⁶³. Three sites feed it values the server controls.
- **Where** —
  - `Series.swift:121-122`: `year`/`ratingCount` via `lenientDouble`, which at `:344-345` accepts the *string* forms `"inf"`, `"nan"`, `"1e400"` (all parse in `Double(String)`), and a JSON number `1e19` decodes to a `Double` fine.
  - `APIError.swift:33,36`: `humanDuration` on `retryAfter`, which comes straight from the `Retry-After` header via `TimeInterval.init` (`APIClient.swift:183`) with no cap — `RateLimitGate.swift:41-42` caps only the *fallback*.
  - `CommunityPulse.swift:70,73` (counts; least plausible, listed for completeness).
- **Why it matters** — CLAUDE.md's rule is "no force-unwraps reachable from real input"; this is the same class of crash with a different spelling. A single series with `"rating_count": 1e19` (or a v1 `"year": "inf"`) crashes the feed page it appears on, for every reader, until MangaBaka fixes the row. The four-agent "no force-unwraps" verification on 2026-09-11 would not have caught it.
- **Effort** — a line each: `Int(exactly:)` / clamp, and reject non-finite in `lenientDouble`.
- **Confidence** — certain mechanism; the triggering input is implausible but server-controlled.

### 5. A non-finite chapter number crashes inside `send` — `JSONSerialization` throws an ObjC exception that `try?` cannot catch

- **What** — `JSONSerialization.data(withJSONObject:)` raises `NSInvalidArgumentException` (not a Swift error) for a body containing `.infinity` or `.nan`; the surrounding `try?` does nothing.
- **Where** — `APIClient.swift:269`. The value arrives from `LibraryChange.body` (`LibraryService.swift:88`), which is built from `Double(typed)` at `LibraryEditSheet.swift:243`; `Double("inf")`, `Double("1e400")` and `Double("nan")` all succeed.
- **Why it matters** — a reader who pastes or types "inf" (hardware keyboard, paste, or any keyboard other than the decimal pad) into the chapter field crashes the app at save. `LibraryEditSheet.swift:234` and `:141` would also trap on the same value before the request (`Int(value)`), so the sheet has the same hole in three places; the in-slice fix is the one that protects every future caller.
- **Effort** — a line: `guard JSONSerialization.isValidJSONObject(body)` before encoding, throwing `.transport`.
- **Confidence** — certain (documented Foundation behaviour); input requires a non-numeric keyboard path.

### 6. `SeriesEdition`'s comments describe enum values the spec does not have, and `status` is shown raw where `SeriesStatus.label` already exists

- **What** — `medium` is documented as `"digital", "print"`; the spec's enum is `digital | paperback | hardcover`. `status` is documented as `"complete", "ongoing", "cancelled"`; the spec's enum is the series vocabulary (`completed | releasing | hiatus | …`).
- **Where** — `SeriesEdition.swift:34-37`; the raw `status` is joined into `detail` at `:63`. Spec: `/v1/series/{id}/collections` items, `medium`, `status`. The same W16 pattern as `subType` was.
- **Why it matters** — `detail` prints "12 volumes · paperback · hiatus" where the series page three sections up prints "On hiatus" via `SeriesStatus.label` (`SeriesStatus.swift:21-28`). Small, but it is a comment that will send the next reader to write a `case "ongoing"` that never fires.
- **Effort** — two lines (comment; `SeriesStatus.label(for: status)`).
- **Confidence** — certain for the comment; the spec is the evidence for the enum.

### 7. `+` in a typed search is sent unencoded and reaches the server as a space

- **What** — `URLComponents.queryItems` percent-encodes `&`, `=` and `#` but deliberately leaves `+` as a literal, and most server stacks decode a literal `+` in a query string as a space.
- **Where** — `SearchQuery.swift:76` (`q`), `:89` (`staff`), `:92` (`publisher`); the encoding happens at `APIClient.swift:374`. The same path carries `CatalogueService.swift:102,133`.
- **Why it matters** — "+Anima" (Natsumi Mukai) and "+Tic Neesan" are real titles; the server would see " Anima" / " Tic Neesan". Search is probably fuzzy enough to hide it for `q`, but `publisher=` and `staff=` are exact-match filters (`SearchQuery.swift:22-24, 26-28` measured them so), and a creator or imprint with a `+` in the name would answer 0. Not confirmed live: it would have cost two of the 30/min search budget and I had already spent the allowance on the dead host.
- **Effort** — a line: `percentEncodedQuery = ...replacingOccurrences(of: "+", with: "%2B")` after setting `queryItems`, in `makeRequest`.
- **Confidence** — worth checking (client behaviour is documented; the server's decoding is the unknown).

### 8. `Retry-After` is honoured uncapped, and its HTTP-date form is silently ignored

- **What** — `Retry-After` may be delta-seconds *or* an HTTP-date (RFC 7231 §7.1.3). The parser accepts only the first; the gate then trusts any accepted number without the 60 s cap the doc comment promises.
- **Where** — `APIClient.swift:183` (`flatMap(TimeInterval.init)`); `RateLimitGate.swift:35-43` (the cap at `:41` applies to `fallback` only — `wait = retryAfter ?? fallback`).
- **Why it matters** — an HTTP-date falls to the exponential fallback (2 s, 4 s …) rather than the server's number — benign. A delta of `3600` locks every request in the process for an hour with the screen saying "Retrying in 60 minutes"; nothing on record says what MangaBaka actually sends on a 429 (the 2026-09-11 rate-limit tests fixture `Retry-After: 30`, hand-written). Recording one real 429 header would settle both.
- **Effort** — a line (cap the honoured value too) plus one recorded header.
- **Confidence** — worth checking.

### 9. `SeriesWork.date` parses `yyyy-MM-dd` only; any other `release_date` form silently loses the date and every edition year label

- **What** — a fixed-format parser returns nil for a partial ("2026-11") or timestamped ("2021-03-02T00:00:00Z") date, and nil is the same value as "no date".
- **Where** — `SeriesWork.swift:78-81, 92-98`; consumed at `:134` (volume date) and `:156-166` (edition year labels).
- **Why it matters** — the spec gives `release_date` no `format`; the only evidence is the 2026-09-11 Solo Leveling sample. Announced-but-unscheduled volumes are the ones most likely to carry a month-only date, and they are the ones a reader is waiting for. Not confirmed — this is the field I would have spent the last request on.
- **Effort** — a line to also accept `yyyy-MM`, or a test against a captured upcoming work.
- **Confidence** — worth checking.

### 10. `LanguageFlag.name` turns a non-country region into a country

- **What** — any two-letter second subtag is looked up as a region code.
- **Where** — `LanguageFlag.swift:22-23`. The schema's title-language enum contains `es-la` (Latin America) and `ja-ro`, `ko-ro`, `ru-ro`, `zh-ro` (romanisations).
- **Why it matters** — `localizedString(forRegionCode: "la")` is "Laos", `"ro"` is "Romania": the alternative-titles row would read "Spanish (Laos)" and "Korean (Romania)". The doc comment at `:7-9` says `es-la` "falls back to the language's flag" — true for `emoji(for:)` (`:32` gates on `knownRegions`) and false for `name(for:)`, which has no such gate. `DisplayTitle.swift:46,67,114` also recognises only `-Latn` as a romanisation, so a `ko-ro` title would be treated as native script by `isNativeScript` (`:106-109`). None of the `-ro`/`-la` tags appeared on 638; they are in the spec's enum, so they exist somewhere.
- **Effort** — a line (reuse `knownRegions` in `name(for:)`); a second line if `-ro` is treated as romanised.
- **Confidence** — certain for `name(for:)` by reading; worth checking whether `-ro` occurs in data.

### 11. `findPublisher` is a first-result-wins rule with an exact-match escape hatch that only works when the series and the directory spell the name identically

- **What** — exact name, else the first hit.
- **Where** — `CatalogueService.swift:119-123`.
- **Why it matters** — 638's publishers include "COPIN" *and* "Copin Comics", "Kakao" and "Daum" (request 5). Searching "Kodansha" returned Kodansha USA first and Kodansha third (request 4) — the exact match saves it; a series naming "Kodansha Comics" would open Kodansha USA's page under that heading. This is the same shape as today's Apple Books finding (the first store result filled the shelf). It is masked entirely by finding 1 at present.
- **Effort** — a decision more than a line: require an exact match or show the candidates.
- **Confidence** — likely.

### 12. In-slice `try?` sites whose caller cannot tell an error from an empty result

Counted (charter §1). In the slice: 6 `try? client.get` sites. Distinguishable: `searchTags`
(`CatalogueService.swift:106`, nil), `searchPublishers` (`:130`, nil), `publisher(id:)` (`:126`,
nil — a single object, so nil is the only failure value there is), `profile()`
(`APIClient.swift:342`, documented as collapsing on purpose with `verifiedProfile` beside it).
**Indistinguishable: 2** — `genres()` returns `[]` at `CatalogueService.swift:47` and `tags()` at
`:78`; both correctly decline to cache the failure, but the caller still sees an empty
vocabulary. App-wide, 19 `try? client.*` sites; the eleven outside this slice are in
`SeriesRepository.swift:628-691`, `LibraryService.swift:183-298`, `ReleaseCalendar.swift:44`
and `SeriesRepository+Count.swift:34`, already counted by the 2026-09-11 summary (§X2).
A separate class, also in-slice: `TagTaxonomy.swift:42,46` — the bundled 2,686-row file
decodes under `try?` to `[]`, so a packaging or shape error in the bundled JSON produces an
empty offline picker with no signal; no test decodes the bundled resource.

---

## Evidence table — every decoded type in the slice, and when its shape was last seen

| Type | Endpoint | Evidence and date | Gap |
|------|----------|-------------------|-----|
| `Series` (v2) | `/v2/series/*` | `rising.json` captured 2026-09-08/09; `Series.swift:96-97` | — |
| `Series` (v1) | `/v1/series/mix`, `/v1/my/library`, `/v1/series/{id}` | `mix.json`, `library.json` 2026-09-09; **live 638 today** | — |
| `Cover` (both) | as above | `Cover.swift:25-28`, 2026-09-09; today | — |
| `SeriesTitle` | as above | `SeriesTitle.swift:12-14` 2026-09-08; today (traits present on v1) | order not stable — findings 2, 3 |
| `SeriesTag` | `tags_v2` | 3397 2026-09-11 (`SeriesTag.swift:8`); today 638 | — |
| `Recommendation` | mix/similar/readers-also-like | 2026-09-08; `mix.json` | — |
| `SeriesWork` | `/v1/series/{id}/works` | live 2026-09-11 (`SeriesWork.swift:8`); fixtures hand-built | `release_date` format — finding 9 |
| `SeriesLink`, `NewsItem`, `SeriesRelationship` | `/links`, `/news`, `/relationships` | `SeriesExtrasTests.swift:29-45` "real response shapes", 3397 | `NewsItem.published_at` seen once |
| `SeriesImage` | `/images` | 3397 2026-09-12 (`Series.swift:271-274`) | — |
| `SeriesEdition` | `/collections` | 2026-09-10 (`SeriesEdition.swift:7`) | comments vs spec — finding 6 |
| `PublisherDetail` | `/v1/publishers/{id}/full` | Ize Press 2026-09-11, Yen Press today — **both `founded: null`** | finding 1 |
| `PublisherRecord` | `/v1/publishers/search` | **no dated payload**; fixture hand-built | finding 1 |
| `Tag` | `/v1/tags` | measured 2026-09-10 (`CatalogueService.swift:90-92`); fixture hand-built | — |
| `Genre` | `/v1/genres` | **no dated payload**; spec `label`/`value` agrees | low risk |
| `Profile` | `/v1/my/profile` | **no dated payload**; spec `id: string`, enums for `role`/`auth_type` agree | needs a token to capture |
| `CommunityPulse` | `/v0/frontpage/community-pulse` | live 2026-09-11 | — |
| `Pagination` | any | 2026-09-10 (`APIEnvelope.swift:29-30`) | — |
| `ResultsEnvelope` | recommendations, top-genres | 2026-09-09 | — |
| `APIErrorEnvelope` | any non-2xx | today (the `.dev` 500 decoded as `{status, message}`) | — |

---

## What this slice does well

- **Dated, method-bearing verification comments are the norm, not the exception.** `Series.swift:96-97` names both endpoints and the date; `SeriesTitle.swift:12-14` gives the counts (25/25, 14/14, 18/18); `APIEnvelope.swift:29-30` quotes the exact query and the exact response that proved `count` not `total`; `APIClient.swift:16-18` records *which* user agent was rejected. Finding 1 was findable only because `PublisherDetail.swift:4-8` said what it was verified on.
- **Leniency is per-element and the input that killed the array version is written down.** `Series.swift:124-130` names Solo Leveling's 146 tags and the null that emptied them; `WireNullabilityTests.swift:80-98` reproduces it. `lenientDouble` (`:338-346`) and `TrackerEntry` (`:352-365`) each carry the two shapes they reconcile.
- **Failure is distinguished from emptiness where it matters, with the reason.** `CatalogueService.swift:43-45, 94-95, 112-115`; `TokenCheck` (`TokenStore.swift:80-93`) has three outcomes and says what collapsing them cost; `APIClient.swift:345-351` keeps `profile()` and `verifiedProfile()` side by side with the train story.
- **Guesses are labelled.** `SeriesWork.swift:170-175` marks the 2.2×-median omnibus threshold GUESS and names the volume it was fitted to. `TagSearch.debounce` (`TagSearch.swift:33-35`) says why 250 ms.
- **Negative results are recorded in code.** `SeriesImage.swift:66-70` withdraws W15 with the reason; `ReadingPlatforms.swift:13-23` records that 132 of 132 sampled hosts were legitimate — "the risk is latent, not present" — and still ships the allowlist.
- **Defences before the bug.** `APIClient.swift:356-364, 382-397` refuses to disk-cache any URL that carries the reader's id, including a parameter the app does not send yet. `RequestSpacing.swift:6-11` explains claim-before-wait with the 96 µs measurement.
- **The pagination-only decode** (`APIClient.swift:114-125`) is a real design: a saved lens's count can no longer be lost to a row-shape failure.
- **No force-unwraps, `try!`, `as!` or `fatalError` in the slice** — re-verified today by grep across all 22 files. (Finding 4 is the same hazard in a different spelling.)
- **`APIShapeContractTests.swift:106-121`** reads the endpoint list out of the source rather than a typed list — the W13 fix done at the source, as CLAUDE.md asks.

---

## Open questions

1. **What does a MangaBaka 429 actually carry?** One captured `Retry-After` header settles finding 8 either way. Not something to provoke deliberately on a shared limit.
2. **Does `release_date` ever arrive as anything but `yyyy-MM-dd`?** One `GET /v1/works/upcoming?limit=50` inspected for non-10-character dates answers finding 9.
3. **Do `ja-ro`/`ko-ro`/`es-la` occur in live titles?** They are in the spec's enum. A grep over the 450-series sample taken on 2026-09-12 for `ReadingPlatforms` would answer it without a request.
4. **Is `+` decoded as a space by `api.mangabaka.org`?** Two search requests: `q=%2BAnima` vs `q=+Anima`, `limit=1`, compare the first id.
5. **`Profile` has never been captured.** It needs a token; the spec agrees with the model, so this is low, but it is the one type in the slice with neither a payload nor a test.
6. **The review brief's host.** `api.mangabaka.dev` now answers 500 for everything. Anything else that still names it (notes, scripts outside this repo, the other five agents' briefs) will burn its request budget the way this one did.
