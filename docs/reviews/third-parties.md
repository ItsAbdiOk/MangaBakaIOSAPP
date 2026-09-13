# Deep review — third parties and what is kept (2026-09-13)

Read-only. No build, no lint, no test run, no edits outside this file. Focus of
this run: data-shape assumptions that fail on real inputs, cache invalidation,
cache-key versioning. Charter patterns hunted first.

## Scope

Reviewed in full (every line read):

- `MangaBaka/Core/Volumes/` — `AppleBooksVolume.swift`, `AppleBooksClient.swift`,
  `GoogleBooksVolume.swift`, `GoogleBooksClient.swift`, `ShelfVolume.swift`
- `MangaBaka/Core/Characters/` — `AniListClient.swift`, `CharacterService.swift`,
  `SeriesCharacter.swift` (Shikimori client), `ShikimoriDescriptionParser.swift`,
  `CharacterProfile.swift` (AniList parser), `CharacterDescriptionTranslator.swift`,
  `TranslationGate.swift`
- `MangaBaka/Core/Persistence/` — all seven files
- `MangaBaka/Core/Images/` — all three files
- `MangaBaka/Core/Settings/`, `Core/History/`, `Core/Notifications/`, `Core/Intents/` — all

Read for context only (callers, outside the slice): `Features/Detail/SeriesDetailView+Store.swift`,
`SeriesDetailView+Covers.swift`, `App/AppServices.swift` (grep only), `MangaBakaTests/AppleBooksTests.swift`,
`CharacterSourceTests.swift` (partial).

Not reviewed: `Core/Schedule/` (the release-gap bug lives there, another slice), `Core/Library/`,
GRDB internals, everything under `Features/`.

Live requests used (6 of 6):

1. `GET itunes.apple.com/search?term=the+apothecary+diaries&media=ebook&entity=ebook&country=gb&limit=200`
   — 53 rows. Manga "01 (Manga)"…"16 (Manga)"; novels 1–6 untagged ("The Apothecary Diaries:
   Volume 1"), 7–16 tagged "(Light Novel)"; 6 rows with no `price` (pre-orders); every
   `releaseDate` ends in `Z`.
2. `GET …?term=進撃の巨人&country=jp` — 210 rows. Kodansha writes `進撃の巨人 (1)` and
   `進撃の巨人(34)`: parenthesised, sometimes without a space. 34 volumes in that form,
   0 in the bare form.
3. `GET …?term=呪術廻戦&country=jp` — 210 rows. Shueisha writes `呪術廻戦 30`: bare. 30 match.
4. `GET …?term=Attack+on+Titan&country=jp` — the Japanese edition does come back for the
   English term (rows 8–10 are `進撃の巨人 (1)`, `(34)`, `(17)`), so the query is fine; only
   the parse fails.
5. `GET shikimori.one/api/characters/45627` — HTTP 301 to `shikimori.io`; following it,
   Levi's description uses only `[character=…]` (9) and `[spoiler]` (1).
6. `HEAD shikimori.one/api/characters/45627` — `server: ddos-guard`, 301, three `__ddg` cookies set.

No AniList request was made; findings about AniList are from code and tests only.

## Findings, by value

### 1. The Japanese-store fallback parses nothing from Kodansha

- **What** — `barePattern` requires whitespace, an optional edition word, then bare digits at
  the end; Kodansha (and the bilingual editions) write the number in brackets.
- **Where** — `MangaBaka/Core/Volumes/AppleBooksVolume.swift:191`
  (`/^(.+?)\s+(?:(モノクロ版|カラー版|新装版|完全版)\s*)?(\d+)\s*$/`). Fixture:
  `MangaBakaTests/AppleBooksTests.swift:117-121` — ONE PIECE only, Shueisha's one shape.
- **Why it matters** — live request 2: 0 of 34 Attack on Titan volumes match; live request 3: 30
  of 30 Jujutsu Kaisen do. Every Kodansha series with no English ebook (the exact case the
  fallback exists for) shows "no volumes" and then spends a Google request. Charter 2: the
  fixture was built from the one publisher the regex was written against.
- **Effort** — a line: add `|\s*[（(](\d+)[)）]` as an alternative, plus one fixture row
  (`進撃の巨人 (1)`, `進撃の巨人(34)`). Bump the `v4-…-jp-ja-bare` key.
- **Confidence** — certain.

### 2. One series with no AniList cast blacks out AniList for every series for 15 minutes

- **What** — `CharacterService` treats every `APIError.server` as "AniList is down", and the
  client throws `.server` for three things that are AniList answering normally.
- **Where** — `MangaBaka/Core/Characters/CharacterService.swift:79-81` (`if case .server`
  → `aniListDownUntil = now + 15 min`). Sources of `.server` that are not outages:
  `AniListClient.swift:160-162` (empty cast, "AniList knows no cast"); `:150-155` (GraphQL
  `errors` with `Media: null`, i.e. an id AniList does not have); `:133-137` (non-2xx — and
  `:372-373` records that an unknown media id answers HTTP 404).
- **Why it matters** — open one manga whose AniList id is stale or whose cast page is empty,
  and every series page for the next fifteen minutes gets Shikimori's cast (Russian-first
  names, fewer portraits, no relevance sort) with AniList healthy. The tests agree with the
  bug: `CharacterSourceTests.swift:126` and `:144` assert the fallback happens and never
  assert the outage memory stayed clear afterwards (charter 2).
- **Effort** — a function: carry "refused" vs "answered nothing" in the error (a 403/5xx or
  transport-level refusal is an outage; 404, empty edges, GraphQL "Not Found" are not), and add
  the negative test (`fallsBackOnEmptyCast` then a second series must still ask AniList).
- **Confidence** — certain.

### 3. The Google Books matcher has neither of this morning's Apple fixes, and its language field goes nowhere

- **What** — `GoogleBooksMatch.volumes` is still first-result-wins with no tagged-first ranking
  and no creator check; the reader's language is accepted and used only in the cache key; the
  `language` decoded onto each volume is never filtered on.
- **Where** — `MangaBaka/Core/Volumes/GoogleBooksVolume.swift:83-88` (first wins);
  `GoogleBooksClient.swift:50-54` (`language` → key only); `GoogleBooksVolume.swift:14-15` says
  the field "flow[s] through the same `Series.coverLanguages` narrowing" — the gallery merge at
  `Features/Detail/SeriesDetailView+Covers.swift:56-59` and the shelf merge at
  `ShelfVolume.swift:42` never look at it. `GoogleBooksVolume.swift:68-70` "Mirrors
  `AppleBooksMatch` deliberately" is now stale.
- **Why it matters** — the Apothecary Diaries defect fixed on Apple this morning is intact on
  the Google path (`"The Apothecary Diaries: Volume 1"` untagged beats `"… 01 (Manga)"` when
  Google ranks it first), and a Korean or French edition fills a gap on an English shelf with no
  way to reject it. Charter 3: a documented consumer that does not exist.
- **Effort** — a function: route Google's items through the same rank-then-match as Apple
  (extract the ranking from `AppleBooksMatch.volumes` so there is one rule), and apply
  `language` in `GoogleBooksMatch.volumes`. Bump the `v1-` Google key when the rule changes.
- **Confidence** — certain.

### 4. Untagged novels still fill the volume numbers the comic lacks

- **What** — the morning fix ranks tagged editions first but still accepts an untagged row as
  whatever the series is; a number only the novel has gets the novel's cover.
- **Where** — `AppleBooksVolume.swift:121` (`if let tag …` — no tag, no rejection) and `:127`
  (first by number wins).
- **Why it matters** — live request 1: J-Novel Club tags only from volume 7; volumes 1–6 are
  bare "The Apothecary Diaries: Volume N". Today the manga also reaches 16 so nothing leaks.
  Any series where the manga trails an untagged novel run — the normal case for an adaptation
  — puts the novel's spine on the comic's shelf for exactly the numbers the comic has not
  reached. The same test would have caught this morning's bug earlier: the fixture at
  `AppleBooksTests.swift:46-69` needs one untagged row with a number the tagged run lacks.
- **Effort** — a few lines: once any accepted row for a title carries a tag matching the
  series' kind, drop untagged rows of that title.
- **Confidence** — likely (mechanism certain; a live series that trips it was not found within
  the request budget).

### 5. `shikimori.one` now 301s to `shikimori.io` through a DDoS guard

- **What** — every Shikimori API call and every portrait URL is built on a host that redirects.
- **Where** — `MangaBaka/Core/Characters/SeriesCharacter.swift:125` (base URL), `:92` and `:298`
  (relative image paths resolved against it), `ShikimoriDescriptionParser.swift:47` (link base).
  Live request 6: `HTTP/2 301`, `server: ddos-guard`, `Set-Cookie: __ddg8_/__ddg9_/__ddg10_`.
- **Why it matters** — it works today because `URLSession` follows a GET redirect and keeps
  the `User-Agent`. It costs one extra round trip per request and per portrait, the app now
  accepts three tracking cookies from a third party's edge, and `docs/todo-next-week.md:79-80`
  lists `shikimori.one` as the host reader traffic reaches — the truthful list is
  `shikimori.io`. If the guard ever challenges the app's UA, the fallback dies as a `.server`
  error with nothing on screen, which is the design.
- **Effort** — a line (base URL), plus the privacy-list line.
- **Confidence** — certain on the redirect; worth checking whether the guard ever challenges.

### 6. Shikimori BBCode: nested and unlisted tags reach the screen and the translator as brackets

- **What** — the parser recognises `h1-6`, `b`, `i`, `url`, `character`, `spoiler`; anything
  else, and any tag nested inside `[b]`/`[i]`/`[h3]`, survives as literal text.
- **Where** — `ShikimoriDescriptionParser.swift:34-40` (the alternation); `:26` spoiler is
  non-greedy, so `[spoiler=a] … [spoiler=b] … [/spoiler] … [/spoiler]` ends at the inner
  close and leaves a literal `[/spoiler]` in the next plain span; `:36` captures the raw inside
  of `[b]…[/b]`, so `[b][character=1]Name[/character][/b]` renders the tag.
- **Why it matters** — Shikimori's documented BBCode also has `[anime=id]`, `[manga=id]`,
  `[person=id]`, `[br]`, `[list]`/`[*]`, `[quote]`, `[image=id]`, `[s]`, `[u]`, and character
  pages cross-reference series constantly. A literal `[anime=5114]Стальной алхимик[/anime]`
  is then handed to the translator, which is the exact failure the file's own header (`:9-12`)
  says the parse-first design exists to prevent. The 9-id sample recorded at `:14-20` and my
  one live id did not hit it, so this is a gap, not a reproduced defect.
- **Effort** — a function: a final pass that strips any remaining `[tag…]…[/tag]` to its inner
  text, and a fixture with a nested spoiler.
- **Confidence** — worth checking.

### 7. AniList's description dialect is wider than the three markers parsed

- **What** — `CharacterDescriptionParser` handles `__bold__`, `[text](url)`, `~!spoiler!~`.
- **Where** — `MangaBaka/Core/Characters/CharacterProfile.swift:120` and `:126`.
- **Why it matters** — AniList's markdown also carries `~~~centered~~~`, `*italic*`,
  `_italic_`, `img220(url)`, `<br>`, `<i>`/`<b>`, and `#` headings; each reaches the screen
  verbatim. Not checked live this run (no AniList budget); the two ids verified on 2026-09-12
  (`:112-114`) used the three handled forms.
- **Effort** — a function.
- **Confidence** — worth checking.

### 8. "(Graphic Novel)" is read as a novel

- **What** — a comic tag containing the word "novel" is treated as a novel edition.
- **Where** — `AppleBooksVolume.swift:147` (`tag.contains("novel")`), `GoogleBooksVolume.swift:87`.
- **Why it matters** — a comic labelled "(Graphic Novel)" is rejected from a comic's shelf and
  accepted onto a light novel's. No live example found within budget; the label is common on
  Western publishers and rare on manga, so this may never fire.
- **Effort** — a line: `tag.contains("novel") && !tag.contains("graphic")`.
- **Confidence** — worth checking.

### 9. One bad `releaseDate` sinks the whole 200-row store answer, for a field nothing reads

- **What** — the envelope is decoded with `.iso8601` and `try?`; `price` and `releaseDate` on
  `AppleBooksVolume` are decoded, cached, and never displayed.
- **Where** — `AppleBooksClient.swift:106-108`; `AppleBooksVolume.swift:20,23`. Grep of
  `Features/` finds no reader of `AppleBooksVolume.price` or `.releaseDate`
  (`AppleVolumesRow.swift` uses `formattedPrice` only, `:104,:113`).
- **Why it matters** — a single row with a fractional-second or missing-zone date turns the
  entire shelf into "Apple Books couldn't be reached" (charter 1: decode failure and empty
  answer are one thing to the caller). Live request 1: 53/53 rows end in `Z`, so not
  reproduced today; charter 3 for the two dead fields.
- **Effort** — a line: drop `releaseDate` (and `price`) or decode the date as `String?`.
- **Confidence** — worth checking.

### 10. The three standing filters are assembled by hand in four places

- **What** — `content_rating` + `type` + `tag_not` are built separately for feeds, mix, search
  and count, with the `types.isEmpty` rule repeated in three of them.
- **Where** — `SeriesRepository.swift:601-605` (`filterQuery`), `:441-449` (mix),
  `SeriesRepository+Paging.swift:44-56` (search), `SeriesRepository+Count.swift:25-33`.
- **Why it matters** — `CacheScope` (`+Cache.swift:62-72`) fixed exactly this shape for
  invalidation; the request side still has it. A fourth filter is four edits and a fourth
  chance to miss one, and the count/search pair drifting apart is the "count promises what the
  search hides" failure `+Count.swift:12-13` warns about.
- **Effort** — a function: `filterQuery(overridingTypes:)`.
- **Confidence** — certain (shotgun surgery, no live defect today).

### 11. Google asks for 40 with a comment that says 200, and never pages

- **What** — `maxResults=40` is Google's maximum; no `startIndex` follow-up.
- **Where** — `GoogleBooksClient.swift:76-78` ("the same margin is used" — it is not), `:75`
  (`intitle:"\(term)"` breaks on a title containing `"`).
- **Why it matters** — a 100-volume series with novels and spin-offs interleaved cannot be
  gap-filled from one page. Bounded today by the anonymous quota already being exhausted
  (`docs/todo-next-week.md:44`), so low value until a key exists.
- **Effort** — a function (page loop) or a line (fix the comment).
- **Confidence** — certain on the comment; worth checking on impact.

### 12. History filters by rating only, and drops undecodable rows silently

- **What** — `entries(allowedRatings:)` applies the content rating; formats and blocked tags
  are not applied, though the doc says "what the reader currently allows".
- **Where** — `MangaBaka/Core/History/HistoryStore.swift:58-64` (claim), `:74-78` (rating only),
  `:72` (`try? decoder.decode` → a row vanishes with no reason, the pattern
  `+Cache.swift:154-157` removed from the feed cache).
- **Why it matters** — a reader who switches novels off still sees the novel they opened
  yesterday in "Recently viewed". Minor; the row is short-lived.
- **Effort** — a few lines.
- **Confidence** — certain on the mismatch; the product intent is an open question below.

### 13. Reminder constants without a derivation, and nudge memory that outlives the account

- **Where** — `ReleaseReminders.swift:196` (`minimum: 10` chapters), `:182` (24 h), `:199`
  (30 d) — none labelled a guess (charter 4; `limit = 40` at `:28-31` is derived, correctly).
  `:82-84` `cancelAll()` clears pending requests but `:231-233` `nudgeDates` survive, so after an
  account change a `finished-<seriesId>` the previous account was already nudged about never
  fires for the new one, and the "catch-up" date stays on the old account's clock.
- **Effort** — a line each.
- **Confidence** — certain on the labels; likely on the account case (R1/R8 in
  `docs/reviews/SUMMARY-2026-09-11.md:339-341` cover the sibling bugs, not this one).

### 14. Birthday hand-formatted from `monthSymbols`

- **Where** — `AniListClient.swift:418-425`: `"\(name) \(day)"`.
- **Why it matters** — a French phone shows "mars 4". `Date.FormatStyle().month(.wide).day()`
  exists (charter 6). Cosmetic.
- **Effort** — a line. **Confidence** — certain.

## What this slice does well

- Cache keys were bumped with today's rule change, not after it: `AppleBooksClient.swift:42-44`
  says why, and `git show df43edc` shows `v3-` → `v4-` on both keys in the same commit.
- Every on-disk cache read decodes with `try?` and treats failure as a miss that refetches
  (`AppleBooksClient.swift:122-127`, `GoogleBooksClient.swift:105-110`,
  `SeriesRepository+Cache.swift:23-31`), so a shape change in `AppleBooksVolume` or
  `SeriesExtras` costs one request, not a bug. The feed cache deliberately does the opposite
  and says why (`+Cache.swift:154-157`).
- Invalidation is declared once: `CacheScope` at `SeriesRepository+Cache.swift:62-72` with the
  history of the four disagreeing setters, and `applied` at `SeriesRepository.swift:483-500`
  records why a first application is not a change. Checked the four paths: ratings clears
  feeds+images+detail (`:506`), formats feeds (`:513`, and the read path re-filters at
  `+Cache.swift:163`), blocked tags feeds+detail (`:521`), token change feeds (`:545-553`, with
  the persisted-id reasoning at `:527-544`). The in-memory `cachedRelationships` (`:371`) is
  outside the enum, but it is filtered by `state == "active"` only, not by any preference, so
  it does not need to be in it.
- Payload shapes carry their provenance: `AniListClient.swift:5-14` (the 403 outage and its
  re-verification), `SeriesCharacter.swift:208-209`, `CharacterProfile.swift:3-6`,
  `GoogleBooksVolume.swift:101-111` (measured bytes per image parameter), `AppleBooksVolume.swift:81-83`
  (60 results, 15 volumes). The unverified `[b]`/`[i]` handling is labelled unverified
  (`ShikimoriDescriptionParser.swift:18-20`).
- The two id spaces cannot be crossed: `CharacterProfileRequest` (`CharacterProfile.swift:235-245`)
  is the only way to turn a `SeriesCharacter` into a request, and both directions are tested
  (`CharacterProfileTests.swift:19-24`, `ShikimoriCharacterProfileTests.swift:141-155`).
- Guesses are labelled: `AppleBooksClient.swift:10-11`, `GoogleBooksClient.swift:18-21`,
  `CharacterService.swift:38`, `HistoryStore.swift:21-24`, `ReleaseReminders.swift:28-31`.
- Rate limits are respected per API with back-off on 429 (and Apple's 403,
  `AppleBooksClient.swift:100-104`), and none of these clients fires per keystroke.
- Privacy holds: nothing identifying leaves the phone in this slice; the only third-party
  traffic is a series title to Apple/Google and a tracker id to AniList/Shikimori. The
  AniList health check at launch (`CharacterService.swift:115-124`) sends a constant query.
- No force-unwraps, `try!` or `as!` in the slice (grep, 2026-09-13).
- `TranslationGate.swift:5-26` records the crash, the wrong gate, and the cost of the right one.

## Open questions

- Should a comic's shelf ever show an untagged edition when a tagged one exists for the
  series? (Finding 4 assumes no.)
- Is the `shikimori.io` host the permanent one, and does the app's User-Agent pass its DDoS
  guard unchallenged from a phone? One HEAD from a Mac is not evidence for either.
- History: is "filtered by what the reader currently allows" meant to include formats and
  blocked tags, or only ratings? The doc says the former; the code does the latter.
- Whether AniList's `Media(id:)` for a manga with an empty `characters` connection answers
  `edges: []` or `errors` — decides whether finding 2 needs one branch or two.
- The Google `language` parameter: filter Google's volumes by it (as the comment promises) or
  drop it from the signature and the cache key?
