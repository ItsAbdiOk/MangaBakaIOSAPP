# Perf review — editions and volumes (`Core/Editions/**`, `Core/Volumes/**`)

Read-only, 2026-09-15, HEAD 1f5e632. Nothing built, nothing run.

- Files: **20 of 20 reviewed** (4,326 lines), plus the three callers that decide when the legs
  fire (`SeriesDetailView+Editions.swift`, `SeriesDetailView+Store.swift`, `EditionShelvesSection.swift`).
- Findings: **19** — 9 certain, 5 likely, 5 worth checking. Prior findings that are still true
  are listed under "Still open", not re-counted.
- Highest-value change: **show the shelf progressively and from the 30-day store** — `loadEditions`
  hides ANN's rows (ready in under a second) until Open Library's two gated requests land (4–12 s),
  and the merged answer it wrote to disk last week is never read back for the page. Two functions.
- Nothing in this slice logs. Zero `Logger`, zero signposts across 20 files. Every failure the
  reader sees as "had a problem" is untraceable on a device.
- One correctness bug ANN-side mirrors one fixed NDL-side today: spin-off releases share the
  main run's shelf as a second "vol. 1" (P4).

---

## Requests in flight

All third-party. None share MangaBaka's `RateLimitGate`; each has its own spacer. Numbers are
read from the code, not measured on a device this run.

| Leg | Host / spacing | Requests per cold page open | Trigger and order | Awaited before anything draws? | Cache (kind, life, key) |
|---|---|---|---|---|---|
| ANN | `cdn.animenewsnetwork.com`, 1.2 s (`ANNClient.swift:45`, own `RequestSpacing`) | 1, only when MangaBaka carries an `anime_news_network` id (`:109`) | `loadOnward` → `loadEditions` → `async let` (`+Editions.swift:51`) | No — but its rows are hidden until all three legs finish (P1) | File, 7 d (`:52`), `v2-ann-<id>` |
| Open Library editions | `openlibrary.org`, **4 s shared** `HostRateGate.openLibrary` (`HostRateGate.swift:35`) | **2, sequential** (`/isbn/…` then `/works/…/editions`, `OpenLibraryEditions.swift:159-163`), only with a MangaBaka ISBN anchor | same `async let` (`:52`) | No | File, 7 d (`:96`), `v2-<isbn>-<lang>-<format>` |
| Open Library covers | same host, **same 4 s gate** | up to **12 HEADs, serial** (`+Store.swift:169,217`) — only for coverless volumes | after Apple and Google, inside `loadAppleVolumes` (`:130`) | No | File, 30 d incl. 404s (`OpenLibraryCovers.swift:33`), `v1-<isbn>` |
| NDL | `ndlsearch.ndl.go.jp`, 2.0 s (`NDLClient.swift:36`, a labelled guess) | 1, only when `coverLanguages` has `ja` and a kana/kanji title exists (`+Editions.swift:176-178`) | same `async let` (`:53`) | No | File, 24 h (`:41`), `v2-<fnv(title)>-<format>` |
| Apple Books | `itunes.apple.com`, 3.5 s (`AppleBooksClient.swift:12`) | 1, +1 to the `jp` store when the home store answers `[]` (`+Store.swift:88-91`) | `loadOnward` → `loadAppleVolumes` (`SeriesDetailView.swift:659`) | No; its own skeleton | File, 7 d, `v6-<id>-<country>-<lang>` |
| Google Books | `googleapis.com`, 3.5 s (`GoogleBooksClient.swift:21`) | 0 or 1: only when Apple left a gap below `final_volume` (`ShelfVolume.swift:102-106`) | after Apple, before covers (`+Store.swift:116-121`) | No | File, 7 d, `v2-<id>-<lang>` |
| Wikidata | on-device table, no network | 0 | read twice (`+Editions.swift:49`, `+Store.swift:80`); memoised | — | not reviewed (Core/Offline) |

**Worst case per cold open: 4 catalogue requests + 2 store + 12 cover HEADs = 18 third-party
requests**, 14 of them on one Open Library gate at 4 s → **up to 56 s of Open Library traffic
for one page**. Warm open (all caches hit): 0. Concurrency: the three catalogue legs run in
parallel (`+Editions.swift:51-55`); Open Library's own two are serial by necessity; the cover
HEADs are serial by design and interleave with the editions leg on the same gate.

What could move:
- **Later / merged:** nothing to merge — different hosts. The cover HEADs already run last.
- **Earlier:** the shelf could draw from `EditionAnswerStore` (30 d) at time zero — see P2.
- **Dropped:** none is fetched for a section not on screen. `isPartial` on Open Library is
  hard-coded `false` (P6), so a 51st edition is silently dropped rather than requested.

Two stale numbers in the callers say 3 s / 36 s for the cover pass
(`SeriesDetailView+Store.swift:212-216`, `SeriesDetailView.swift:181-182`); the gate is 4 s
(`HostRateGate.swift:35`), so the pass is 48 s, and 12 × 4 s is the number that should be
labelled a guess.

---

## Findings

### P1 — ANN's rows wait for Open Library's slowest request before drawing
- **What** — `loadEditions` awaits all three legs, then merges once; the skeleton stays up until
  the last leg lands.
- **Where** — `SeriesDetailView+Editions.swift:55-62`; the merge already accepts `.loading` legs
  (`VolumeEditionMerge.swift:326`, `state()` maps `.loading` → `.notAsked`).
- **Why it matters** — ANN answers in one un-gated request (~0.5 s); Open Library's second request
  waits a 4 s slot, and behind interleaved cover HEADs up to 8–12 s. A reader sees "Checking
  catalogues…" for the whole span over rows that were on the phone after a second. On a 429 from
  Open Library the same wait ends in an `InlineFailure` beside rows that could have been showing
  all along.
- **Fix** — three `Task`s writing into three `@State` `Fetched`s and re-running `merge` after each
  (it is pure, ~330 rows worst case, sub-millisecond); `isLoadingEditions` becomes "any leg still
  `.loading`". The `Task.isCancelled` guard at `:59` stays per leg.
- **Effort** — a function. **Confidence** — certain on the mechanism; the seconds are from the
  spacing constants, not a device.

### P2 — The 30-day merged answer is written every open and read back by nothing on the page
- **What** — `EditionAnswerStore.write` persists the merge (`+Editions.swift:66`) and the only
  reader is the widget's `forthcoming(for:)`. `StoredEditionAnswer.answer` — "Back to the type the
  shelf view reads" — has one caller, a test.
- **Where** — `EditionAnswerStore.swift:213-228`; callers: `MangaBakaTests/EditionAnswerStoreTests.swift:81-83`
  only. No `read(for:)` exists on the actor.
- **Why it matters** — charter §3/§7. This is the "here is what we had" placeholder the
  rate-limit question asks for, already on disk, already the right type, never shown. A reader
  reopening a series after the 24 h NDL cache expires waits on NDL's 764 KB page (measured
  2026-09-15, `ndl-apothecary-diaries-50.xml`) to see a shelf that has not changed.
- **Fix** — `func answer(for seriesId:) -> (VolumeEditionAnswer, fetchedAt: Date)?`; set
  `editions` from it before the legs run, with `isLoadingEditions` true so the header still says
  "Checking…" and a `StaleBar`-style "from N days ago" is possible. Delete `StoredEditionAnswer.answer`
  if this is not wanted — a doc comment describing a caller that does not exist is the charter's tell.
- **Effort** — a function each side. **Confidence** — certain.

### P3 — A partial NDL shelf is shown as complete until the reader ticks a row
- **What** — `isPartial` reaches the screen through `OwnedSummary.line` only, and that returns
  nil when nothing is ticked.
- **Where** — `OwnedSummary.swift:20` (`guard !ticked.isEmpty else { return nil }`) before the
  `isPartial` branch at `:27`; `EditionShelvesSection.swift:241-244` is the only consumer;
  `EditionShelf.swift:22-26` promises "a view must not call a partial shelf complete".
- **Why it matters** — the measured page (`NDLClient.swift:111-114`): Square Enix shows vols 1,
  10–14 and nothing says 2–9 exist. `NDLClient.Answer` carries only the Bool; `totalRecords`
  (parsed at `NDLRecordParser.swift:170-172`) is dropped at `NDLClient.swift:129`, so the honest
  line "50 of 84 on record" cannot be built downstream.
- **Fix** — carry `totalRecords` on `Answer` and `EditionShelf`; `creditLine(for:)` appends
  "first N of M on record" when partial, ticks or not.
- **Effort** — a function across three files. **Confidence** — certain.

### P4 — ANN spin-offs land on the main run's shelf as a second "vol. 1"
- **What** — every `<release>` under the ANN entry becomes a row of one `VolumeEdition`
  regardless of the title before the marker.
- **Where** — `ANNRelease.swift:92-109` (`edition` built once at `:93`, every release at `:97`);
  the title prefix is computed by `trailingMarker` and discarded.
- **Why it matters** — recorded shape (`docs/sources/publishers.md:152-154`): the One Piece entry
  carries `One Piece: Ace's Story-The Manga (GN 1)` and `One Piece - Romance Dawn (eBook 1)`
  beside `One Piece (GN 1)`. Same shelf, same number, two rows → "You own 1 of 233" and a `missing`
  list that is wrong. NDL had exactly this bug (`docs/reviews/night/shelf.md` §A′) and was fixed
  today with `workTitle`; ANN was not.
- **Fix** — the same rule: prefix before the marker, normalised, compared to `entry.name`; a
  different work goes to `editionTitle: "\(name) · \(prefix)"`. `AppleBooksMatch.normalise` already
  exists for the comparison.
- **Effort** — a function. **Confidence** — certain on the shape (recorded), likely on the count —
  the saved fixture (`ann-delicious-in-dungeon-17164.xml`) is the happy example with no spin-off,
  so no test would fail today (charter §2).

### P5 — `withInheritedPublishers` runs on Open Library rows and ignores language
- **What** — a row with no publisher inherits the page's single stated publisher; the dictionary
  is keyed by `workTitle` only, and every Open Library row has `workTitle == nil`.
- **Where** — `BookEditionShelf.swift:44-60`; called for both catalogues at `:28`. The doc comment
  (`:34-37`) describes the NDL 近刊 case only.
- **Why it matters** — Open Library returns English plus the original language
  (`OpenLibraryEditions.swift:189-192`). A Japanese row with `publishers: ["unknown"]` (→ nil,
  `:309`) on a page whose English rows all say "Yen Press" becomes `VolumeEdition(language: "ja",
  editionTitle: "Yen Press")`: a Japanese shelf titled with the English publisher. The measured
  Solo Leveling row `Solo leveling | 2012 | unknown` escapes only because it also has no language.
  NDL: a 特装版 row is safe (edition note is its own key part); two publishers → no inheritance, safe.
- **Fix** — key on `(workTitle, language)`, or apply inheritance to `.nationalDietLibrary` rows only,
  which is what was asked for.
- **Effort** — a line. **Confidence** — likely (mechanism certain; needs an OL page with a
  publisher-less original-language row to show on screen).

### P6 — Open Library's `isPartial` is hard-coded `false` — the NDL bug, one catalogue over
- **What** — `pageSize = 50` with "a view must not present the list as exhaustive"
  (`OpenLibraryEditions.swift:97-101`); the caller passes `isPartial: false` unconditionally.
- **Where** — `SeriesDetailView+Editions.swift:163`; `EditionList` (`OpenLibraryEditions.swift:275-277`)
  decodes `entries` and not `size`, which the measured response carries ("size 3", `:13`).
- **Why it matters** — same false "You own N of M · missing" as NDL's serious #2 last night, for a
  work with >50 printings. Rare today (One Piece's work: 18).
- **Fix** — decode `size`; `isPartial: size > entries.count`; return it the way `NDLClient.Answer` does.
- **Effort** — a function. **Confidence** — certain on the mechanism, low frequency.

### P7 — The Apple Books matcher compiles its regex ~3,000 times per store answer
- **What** — `pattern` and `barePattern` are computed properties (a `Regex` is not `Sendable`, so
  not `static let`), and `isTagged` → `split` is evaluated inside the sort comparator.
- **Where** — `AppleBooksVolume.swift:166-170` (comparator calls `isTagged` twice per comparison),
  `:200-202`, `:253-277`; the comment at `:250-251` says "Cheap enough — the store answers at most
  200 names".
- **Why it matters** — 200 names sort in ~1,500 comparisons → ~3,000 regex builds + `wholeMatch`,
  then 200 more in the loop at `:183-185`. Off the main actor (`AppleBooksClient` is an actor), so
  no tap is late, but it is the wrong count in the comment (charter §5) and it runs on every cold
  store answer for every series.
- **Fix** — decorate once: `items.map { (item, split(name)) }`, sort on the decorated flag, reuse
  `parts` in the loop. Same shape as open item "TasteRanker.rank scores per comparison".
- **Effort** — a function. **Confidence** — certain on the count; the ms is unmeasured.

### P8 — Apple Books title shapes: what the regex accepts and what real listings it rejects
- **Where** — `AppleBooksVolume.swift:275` (marker) and `:261` (bare).
- **Accepts** (verified by reading the pattern): `Title, Vol. 8 (comic)`, `Title Vol 8`,
  `Title Volume 8`, `Title #8`, `Title 01 (Manga)`, `Title (Manga) Vol. 1`, `Title (novel), Vol. 1`,
  `Title, Vol. 1: Subtitle`, `Title - Volume 1` (hyphen survives `normalise`). Bare: `Title 30`,
  `Title モノクロ版 115`, `Title (1)`, `Title（1）`.
- **Rejects** — real shapes, none in any test: `Title, Vol. 8.5` (decimal), `Title Vol. II`,
  `Title: Part 1 Volume 1` (J-Novel Club multi-part — title becomes "…: Part 1"), `Title, Tome 1` /
  `T01` (French store), `Title, Band 1` (German), `Title 1巻` / `第1巻` / `〈1〉` (Japanese store
  variants other than Shueisha's and Kodansha's), `Title (LN) 1` (tag not recognised as novel →
  comic shelf). `country` is the reader's locale (`+Store.swift:73`) while every marker word is
  English/Spanish/Italian, so a French or German reader's home store answers `[]` and the page
  falls through to the Japanese store for covers.
- **Why it matters** — charter "one happy example": the doc cites one live GB answer (60 results,
  2026-09-11) and no recorded payload is in `Fixtures/` — the Apple and Google tests are hand-typed
  (`AppleBooksTests.swift:281-286, 323`, `GoogleBooksTests.swift:154-160`), so they prove the
  regex agrees with itself.
- **Fix** — save one real `itunes.apple.com` answer per storefront family (GB, FR, JP) as fixtures;
  add `tome|band|t` to the marker alternation only after seeing them.
- **Effort** — an hour for fixtures; a line per marker. **Confidence** — certain on the accept
  list; the rejected shapes are from memory of the stores, **worth checking** against a live answer.

### P9 — ANN `(Novel n)` is filed as `.print` and cannot be told from a comic
- **Where** — `ANNRelease.swift:141` (`"novel"` in the print list); `keeps()` at
  `VolumeEditionMerge.swift:125-128` drops only `.other`.
- **Why it matters** — if an ANN manga entry ever lists a novel release, a prose row sits on the
  comic shelf with a number — the Apple Books failure mode this family was built to avoid
  (`BookEdition.swift:41-44`). No observed instance in the three surveyed entries.
- **Fix** — `"novel"` → `.other` (or a `VolumeFormat.prose`). **Effort** — a line.
  **Confidence** — worth checking: needs one ANN entry that mixes them.

### P10 — `VolumeEditions.merge` runs on the main actor
- **Where** — `SeriesDetailView+Editions.swift:60` (a `View` method, so `@MainActor`);
  `VolumeEditions` is a plain enum, nonisolated.
- **Why it matters** — worst case ~330 rows (ANN 232 + OL 50 + NDL 50): filter, dictionary dedupe,
  group, two sorts, plus `withInheritedPublishers` copying every `BookEdition`. Estimated well under
  1 ms; **not a tap-latency finding**, recorded so nobody moves it to a `Task.detached` for no gain.
  The expensive parts already run off-main: NDL's 764 KB `XMLParser` on the `NDLClient` actor,
  Apple's regex on its actor, the store write on `EditionAnswerStore`.
- **Confidence** — likely (read, not profiled).

### P11 — Zero log lines in 4,326 lines of third-party networking
- **Where** — `grep -rn 'Logger\|signpost' Core/Editions Core/Volumes` → nothing. Failures that
  are swallowed with no trace: `OpenLibraryCovers.swift:78-80` (`try? session.data` — a transport
  error and a cancellation both become nil, uncached, re-asked next open), `GoogleBooksClient.swift:109-111,
  129-130` (429, 5xx, decode all → nil; the client documented as "429 is the common case" cannot say
  how common), `EditionAnswerStore.swift:59-60` (encode/DB write failures), every `readCache` /
  `writeCache` in six clients (a full disk or a bad JSON file is a silent cache miss forever).
- **Why it matters** — `NetworkLedger` counts MangaBaka paths and images only
  (`NetworkLedger.swift:44,65`), so Settings' Data Use never sees NDL's 764 KB or ANN's 237 KB, and
  "did the shelf come from cache or the network" is unanswerable on a device.
- **Fix** — one `Logger(category: "editions")` line per leg at the merge site: `leg=<ndl|ol|ann>
  outcome=<hit|miss|failed:<case>> rows=<n> partial=<bool> ms=<n>`; and `NetworkLedger.record`
  with the third-party host as the path in `ThirdPartySession`'s users. Six lines settle every
  "unsure" below.
- **Effort** — a line per leg. **Confidence** — certain.

### P12 — `NDLClient.Query.rows` deduplicates a list already deduplicated by its caller
- **Where** — `NDLClient.swift:124` then `NDLQuery.swift:64`. **Why** — two passes over 100
  records; trivial cost, but a reader of `rows` cannot tell which is load-bearing.
  **Fix** — drop one. **Effort** — a line. **Confidence** — certain.

### P13 — Cache hit is indistinguishable from a fresh fetch at the `Fetched` level for two legs
- **Where** — `+Editions.swift:163,186` pass `fetchedAt: Date()` for Open Library and NDL even
  when `readCache` answered; only ANN threads `storedAt` through (`ANNClient.swift:123`).
- **Why** — a "volumes from 6 days ago" line (`ANNClient.swift:216-219` says this is the point of
  `storedAt`) cannot be shown for the other two, and the "Detail complete" signpost cannot tell a
  cache hit from a fetch.
- **Fix** — have `editions()` / `volumes()` return `storedAt` alongside the answer, as ANN does.
  **Effort** — a function each. **Confidence** — certain.

### P14 — A cancelled wait spends the shared Open Library slot for everyone
- **Where** — `OpenLibraryEditions.swift:235-242`, `OpenLibraryCovers.swift:64-71`: `gate.claim`
  before `Task.sleep`; on cancellation the slot stays claimed (comment says so).
- **Why** — the gate is process-wide. Popping three series pages quickly leaves up to 3 × 2 + 3 × 12
  claimed slots unspent, so the next page's first Open Library request waits behind ghosts — worst
  case minutes. Documented as accepted per client; not documented as compounding across the shared gate.
- **Fix** — `gate.release(slot)` on cancellation, or claim-then-sleep-then-reclaim-if-cancelled.
  **Effort** — a function. **Confidence** — likely (reasoned; needs a device run with fast pops).

### P15 — `PartialDate.utc` builds a `Calendar` per call
- **Where** — `PartialDate.swift:161-169` (computed `static var`), called from `iso`, `longForm`
  and `periodEnd` — i.e. once per parsed date and once per `isForthcoming`. **Why** — ~µs each,
  hundreds per merge; not visible, but a `static let` is the same code and free. **Effort** — a
  line. **Confidence** — certain, low value.

### P16 — Apple's `isNovel` and Google's disagree
- **Where** — `AppleBooksClient.swift:108-115` (MangaBaka `type`, Wikidata fallback);
  `GoogleBooksClient.swift:68` (`type` only). **Why** — a series with nil `type` that Wikidata
  calls prose builds a comic shelf on Apple and a novel shelf on Google; the merge at
  `ShelfVolume.swift:40-62` then mixes them by number. Charter "duplicated constants" in rule form.
  **Fix** — Google calls `AppleBooksClient.isNovel(series:format:)`. **Effort** — a line.
  **Confidence** — certain.

### P17 — `VolumeShelf.merge` is re-run on every body pass of the detail page
- **Where** — `SeriesDetailView+Store.swift:10-12` (`var shelf` computed), read at `:31`, `:53`,
  `:197`. **Why** — dictionary build + sort over ≤ 200 rows on the main thread per pass; item 54
  fixed the same shape for synopsis/tags. Small, but the page's body runs on every scroll-driven
  state change. **Fix** — `@State shelf` set when `appleVolumes`/`googleVolumes` land.
  **Effort** — a function (outside this slice's files; the function is this slice's).
  **Confidence** — certain on the recomputation, cost unmeasured.

### P18 — MangaBaka ISBN-10s would never match a catalogue's ISBN-13
- **Where** — `VolumeEditionMerge.swift:137-146` (`datedISBNs` normalises but does not convert);
  `SeriesWork.swift:130-131` (`isbn` is any identifier named "isbn", no length rule);
  `+Editions.swift:201-214` (`anchorISBN` sends whatever it finds).
- **Why** — a MangaBaka work carrying an ISBN-10 shows once on its own shelf and again on ANN's
  (both dated). **Confidence** — worth checking: needs one `/works` payload with an ISBN-10.
  **Effort** — a function (ISBN-10 → 13 is arithmetic).

### P19 — `ANNEncyclopedia.parse` keeps releases from every `<manga>` while keeping only the first id
- **Where** — `ANNRelease.swift:185-192` (first `<manga>` only) vs `:193-202` (every `<release>`).
  **Why** — harmless for `title=<id>` (one record) and the client never uses name lookup; the
  asymmetry is a trap for the next caller. **Effort** — a line. **Confidence** — certain, low value.

---

## Main thread & rendering

- `VolumeEditions.merge` (P10) and `BookEditionShelf.editionVolumes` run on the main actor;
  estimated < 1 ms at worst-case row counts. Not worth moving.
- `VolumeShelf.merge` per body pass (P17) — the one recomputation worth fixing.
- Heavy work is correctly off-main: `XMLParser` for NDL (764 KB) and ANN (237 KB) inside their
  actors; regex matching inside `AppleBooksClient`; `NLLanguageRecognizer` per matched item
  (`AppleBooksVolume.swift:292-300`, ≤ 200 × 400 chars) inside the actor; JSON encode + GRDB write
  inside `EditionAnswerStore`.
- `EditionShelvesSection` receives a 300-row `Equatable` struct; SwiftUI diffs it per pass. Fine.
- `.arrives(index:)` staggers every row of every shelf (`EditionShelvesSection.swift:256-258`) — a
  232-row ANN shelf animates 232 entrances. Not reviewed for cost; flag for the UI slice.

## Rate-limit invisibility

What exists today: `CoverSkeletonRow` + "Checking catalogues…" while loading
(`EditionShelvesSection.swift:69-70, 93-96`); per-leg `InlineFailure` named by catalogue
(`:213-226`); third-party 429 copy "X is asking us to slow down. Nothing is wrong on this phone,
and what you already have is still here" (`APIError.swift:263-270`) — already the right sentence;
`LoadingLine` at the page level includes `isLoadingEditions` (`+Covers.swift:130-133`).

What is missing, in order of value:
1. **Progressive shelf** (P1): rows appear per leg; a slow or refused leg becomes one quiet line
   under rows that are already there, instead of a skeleton over everything.
2. **Stored answer first** (P2): on open, draw last time's shelf at once; a leg's 429 then changes
   nothing the reader can see except a small "from N days ago" note — the `StaleBar` pattern the
   page already uses for `extras` (`SeriesDetailView.swift:287-296`).
3. **Cache-age honesty** (P13): "volumes from 6 days ago" needs `storedAt` from all three legs.
4. **Partial as partial** (P3/P6): "first 50 of 84 on record" is a truthful sentence that also
   reads as "still more to come", not as a failure.
5. The 429 `InlineFailure` has no retry by design (`EditionShelvesSection.swift:205-211`). With 1
   and 2 in place that stays right: the row is there, the note is small, and the next open re-asks.

## Debuggability

- Every unsure in `docs/reviews/night/shelf.md` that a single log line settles:
  - "Whether `isAvailable` is false under `.notDetermined`" — not this slice.
  - "Whether NDL's SRU accepts `sortBy`" — a request, not a log.
  - The follow-up's four "Needs Abdi" data questions (near-title mismatch, publisher-less 近刊,
    `外伝　01`) — all become countable with P11's line: `leg=ndl rows=N inherited=N workTitles=[…]`.
  - Item 12 (duplicate `EditionVolume.id` for ISBN-less OL rows) — `leg=ol rows=N noIsbn=N`
    answers "is it real" on the first One Piece open.
- Swallowed with no trace: `OpenLibraryCovers.swift:78-80`, `GoogleBooksClient.swift:109-130`,
  `EditionAnswerStore.swift:59-60`, six `readCache`/`writeCache` pairs. All P11.
- Test hooks are uneven: `nextAllowedForTesting` exists on ANN, Google and the host gate; NDL and
  Apple have none, so their `Retry-After` handling (`NDLClient.swift:202-210`,
  `AppleBooksClient.swift:187-198`) is asserted only by inference.
- The `Task.sleep` trap (`NDLClient.swift:52-54`) is handled by injecting `minimumInterval: 0`;
  the consequence is that no test proves two NDL calls are 2 s apart. A `Clock`-driven sleeper
  would close it; recorded, not urgent.

## Size

- **Six copies of one file cache** (~30 lines each): `NDLClient.swift:222-252`,
  `OpenLibraryEditions.swift:338-368`, `OpenLibraryCovers.swift:106-134`, `ANNClient.swift:206-236`,
  `AppleBooksClient.swift:223-254`, `GoogleBooksClient.swift:135-158`. Still open as full2 #115;
  still true at these lines. ~150 lines and one place to add a size cap (none of them prunes —
  every title ever opened leaves a file until iOS purges Caches).
- **Five copies of the 429 branch** (`NDLClient:202-210`, `OpenLibraryEditions:255-263`,
  `OpenLibraryCovers:87-92`, `ANNClient:178-192`, `AppleBooksClient:187-198`, `GoogleBooksClient:112-128`).
- **Three private `unsafe…Fallback` extensions** for the same three-line idea
  (`ANNClient.swift:239-244`, `AppleBooksClient.swift:257-262`, `GoogleBooksClient.swift:161-166`).
- **Two `titles` builders** (`AppleBooksClient.swift:69,132`, `GoogleBooksClient.swift:67`).
- Test-only or caller-less: `StoredEditionAnswer.answer` (P2), `NDLRecordParser.parse(_:)`
  (`:102-104`, tests only), `PartialDate.periodEnd` is public for one internal caller.
- Nothing here is deletable outright; the file split (`VolumeEdition.swift` / `EditionShelf.swift`
  / `VolumeEditionMerge.swift`) is for the lint ceiling and reads well.

## Still open from earlier reviews (verified at new lines, not re-derived)
- `EditionVolume.id` duplicate for ISBN-less same-title rows — `VolumeEdition.swift:216`, unchanged.
- Seven file caches (full2 #115) — see Size.
- `appleUnreachable` blame ordering (full2 #59) — the fix is in at `+Store.swift:92-96`; the open-items
  row can be closed.

## Good news
- **Spacing is claim-before-sleep everywhere** and the reason is written down with its measurement
  (`RequestSpacing.swift:5-11`, "96 µs apart"); the shared host gate exists because two clients on
  one host were measured colliding (`HostRateGate.swift:5-9`, `OpenLibraryEditions.swift:76-83`
  with the TCP-refusal numbers).
- **Every constant that shapes output is labelled** — `NDLClient.swift:31-35` "A GUESS",
  `OpenLibraryEditions.swift:91-95`, `ANNClient.swift:41-44`, `EditionAnswerStore.swift:32-37,42-47`,
  `AppleBooksClient.swift:10-11`, `GoogleBooksClient.swift:18-20`. Charter §4 is met in this slice.
- **Fixtures with provenance for the three catalogues**: `NDLClientTests.swift`, the 764 KB page
  saved verbatim, `ann-delicious-in-dungeon-17164.xml` with request and date, the two Open Library
  JSONs. The Apple/Google gap (P8) is the exception, not the rule.
- **No force-unwraps** in any production file of the slice (grepped `!` outside string/comments;
  the three `preconditionFailure` fallbacks are on hard-coded literals).
- **Negative results are recorded where they were found**: GCD ruled out with numbers
  (`VolumeEdition.swift:10-40`), Open Library title search ruled out with counts
  (`OpenLibraryEditions.swift:19-28`), the wrong-anchor "coherent answer for a different book"
  (`:43-46`), `title="ONE PIECE"` → 935 Solo Leveling records (`+Editions.swift:229-237`).
- **`ForthcomingVolume` has no "nothing is coming" case** and `EditionAnswerStore.write` refuses to
  persist an empty answer for the same reason (`EditionAnswerStore.swift:52-58`).
- **The type system carries the honesty**: `.notCatalogued` vs `.editions([])`
  (`BookEdition.swift:168-188`), `Fetched.loaded(isPartial:)`, `alsoFrom`/`dateFrom` on the merged
  row so the losing catalogue keeps its credit (`VolumeEdition.swift:192-210`).

## Could not determine
- The wall-clock of a cold editions leg on a device — the seconds in P1 are the spacing constants
  plus guesses at RTT; a signpost around each leg (P11) is the measurement.
- Whether Open Library ever returns a publisher-less row in the original language with a stated
  language (P5) — one One Piece `/works/…/editions.json` capture settles it.
- The real Apple Books title shapes per storefront (P8) — one saved answer each for GB, FR, JP.
- Whether any ANN entry MangaBaka links to mixes `(Novel n)` with `(GN n)` (P9).
- Whether MangaBaka's `/works` ever carries an ISBN-10 (P18).
- The cost of `.arrives(index:)` over a 232-row shelf — a device run with the One Piece ANN answer.
