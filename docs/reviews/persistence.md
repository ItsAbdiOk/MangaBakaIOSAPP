# Persistence, LibrarySnapshot and Settings — deep review

Slice: `MangaBaka/Core/Persistence/**` (9 files, 1,496 lines),
`MangaBaka/Core/Library/LibrarySnapshot.swift` (200), `MangaBaka/Core/Settings/**`
(3 files, 319). All 2,015 lines read in full. No build, no test run — static
reading only, as instructed.

To answer the cache-invalidation question I also read, outside the slice and
read-only: `App/AppServices.swift`, `App/RootView+Session.swift`,
`Core/Library/LibraryService.swift`, `Core/Model/Series.swift`,
`Core/Model/Cover.swift`, `Core/Model/SeriesWork.swift`,
`Core/Networking/APIClient.swift` (coder config only), and
`Core/Schedule/ReleaseSchedule.swift` (grep only). Findings that land in those
files are marked **[adjacent]** and belong to another slice's owner.

---

## Part 1 — The cache inventory

Eleven SQLite tables and five in-memory caches exist. Only the ones a filter or
a token can invalidate are listed here.

| Cache | Where | Filter-sensitive? | Account-scoped? |
|---|---|---|---|
| `feedEntry` + `feedMetadata` | `AppDatabase.swift:66-79` | yes — written post-filter | the `series/mix/*` keys are |
| `series` (`CachedSeries`) | `AppDatabase.swift:57-61` | yes — rows are the filtered payloads | no |
| `seriesDetail` (`CachedDetail`) | `AppDatabase.swift:176-180` | **yes** — see F5 | no |
| `libraryEntry` + `libraryMetadata` | `AppDatabase.swift:190-200` | no | **yes** |
| `tagAffinity` + `tasteSource` | `AppDatabase.swift:144-165` | no | **yes** |
| `SeriesRepository.cachedImages` | `SeriesRepository.swift:335` | **yes** — see F4 | no |
| `LibraryService.cachedProfileID` | `LibraryService.swift:145` | no | **yes** |
| `SeriesRepository.libraryExclusionUserID` | `SeriesRepository.swift:326` | no | **yes** |
| `LibrarySnapshot.cached` | `LibrarySnapshot.swift:49` | no | **yes** |
| `URLCache.shared` (256 MB of cover art) | `AppServices.swift:152-155` | yes in effect | no |

## Part 2 — The four paths, enumerated

### 1. Content-rating change
`ContentPreferencesStore.set` (`ContentPreferences.swift:103`) → `onChange`
(`AppServices.swift:90-93`) → `repository.updateContentRatings`
(`SeriesRepository.swift:511`) + `libraryService.updateContentRatings`.

- **Cleared:** `feedEntry`, `feedMetadata` — and only if this is not the first
  application since launch (`shouldDiscard`, `SeriesRepository.swift:506`).
- **Not cleared:** `cachedImages` (**F4**), `seriesDetail` (**F5**), `series`
  rows, `URLCache` cover art already on disk.
- Recently-viewed is handled correctly by re-filtering at read through a closure
  rather than by invalidation (`AppServices.swift:113-119`).

### 2. Format change
`FormatPreferencesStore.set` (`FormatPreferences.swift:108`) →
`AppServices.swift:96-99` → `repository.updateFormats`
(`SeriesRepository.swift:519`).

- **Cleared:** `feedEntry`, `feedMetadata`, same first-application rule.
- **Also enforced on read:** `readCacheWithDate` re-applies `allowsFormat` to
  every cached row on the way out (`SeriesRepository+Cache.swift:93`), so a
  format the reader turns off disappears from cached content immediately even if
  the discard were skipped.
- **No hole found.** `seriesDetail` and `cachedImages` carry nothing format-
  dependent. **This is the only one of the four that is complete, and it is
  complete because of the read-side filter, not the discard.**

### 3. Blocked-tag change
`BlockedTagsStore.toggle` (`BlockedTags.swift:71`) → `AppServices.swift:83` →
`repository.updateBlockedTags` (`SeriesRepository.swift:527`).

- **Cleared:** `feedEntry`, `feedMetadata`, same first-application rule.
- **Not cleared:** `seriesDetail`, which carries `tags` and `richTags`
  (`SeriesRepository.swift:94-98`) for six hours.
- **No read-side backstop at all** — there is no `allowsBlockedTags` analogue to
  `allowsFormat`. See **F10**.

### 4. Token change (a different person signs in)
`forgetPreviousAccount()` (`RootView+Session.swift:100-104`), called from
`SettingsView(onAccountChanged:)` (`RootView+Session.swift:85`).

- **Cleared:** `LibraryService.cachedProfileID`, `TasteLedger` (`tagAffinity` +
  `tasteSource`), `libraryEntry`, `libraryMetadata`, `LibrarySnapshot.cached`
  and its in-flight task.
- **Not cleared:** `SeriesRepository.libraryExclusionUserID` (**F2 — the same
  shape of hole as the one fixed on 2026-09-11**), the feed cache including
  cached `series/mix/*` blends (**F3**), `seriesDetail`, `cachedImages`,
  `viewedEntry`, `shelfEntry`.

### Do the four lists agree?

**No.** Three distinct shapes:

- Rating and blocked-tag clear strictly less than the data their filter governs.
- Format clears the same set but is saved by a read-side filter the other two
  do not have.
- Token change clears a fourth, disjoint set, and leaves behind a piece of the
  previous account's identity (**F2**) — which is the 2026-09-11 bug's exact
  signature, in a different variable.

Nothing in the code states which caches each path is responsible for, which is
why the lists have drifted apart. There is no single "what does a filter own"
declaration to check a new cache against — and two caches have been added since
(`seriesDetail` in v6, `cachedImages`) with neither wired into any path.

---

## Part 3 — Findings

### F1 — Every launch by a signed-in reader discards the whole feed cache. This is the exact bug `applied` was built to prevent, still live.

**What.** `updateLibraryExclusion` has no first-application guard and discards
the feed cache unconditionally whenever the id differs from what it holds — and
at launch it always does, because the repository starts at `nil`.

**Where.** `SeriesRepository.swift:545-551`; called at
`AppServices.swift:186` inside `applyStoredFilters`.

```swift
func updateLibraryExclusion(userID: String?) async {
    guard userID != libraryExclusionUserID else { return }
    libraryExclusionUserID = userID
    try? discardCachedFeeds()          // <- no shouldDiscard("exclusion")
}
```

Compare the three siblings immediately above it
(`SeriesRepository.swift:511-533`), each of which calls `shouldDiscard` first,
and the comment explaining exactly why (`SeriesRepository.swift:492-504`):

> *"every one of them differed from the empty starting state, so every launch
> discarded the entire feed cache before the first screen drew. Offline support
> was documented, tested, and silently dead."*

**Why it matters.** For any reader with a token, `library.profileID()` returns a
non-nil id, `nil != id`, and `DELETE FROM feedEntry; DELETE FROM feedMetadata`
runs on every cold launch. Offline support is dead again for exactly the readers
who have the most data. It is also a race: `applyStoredFilters` awaits a
**network** call (`profileID()` hits `/v1/my/profile`,
`LibraryService.swift:137`) before the discard, so on a slow connection the
discard lands *after* `startSession` has already fetched and cached `.rising`
(`RootView+Session.swift:113`), deleting the row it just paid for and forcing a
second fetch on the next visit. Unauthenticated readers are unaffected, which is
why the regression would survive testing on a signed-out build.

**Effort.** One line — `let discards = shouldDiscard("exclusion")` and a
`guard`. The `applied` mechanism already exists and needs no change.

**Confidence.** Certain about the code path. Certain the discard runs for a
signed-in reader. The launch-ordering race is likely rather than certain — I did
not trace task scheduling.

---

### F2 — A token change leaves the previous account's user id in the recommender.

**What.** `forgetPreviousAccount()` clears four account-scoped things and misses
the fifth. `SeriesRepository.libraryExclusionUserID` is written exactly once, at
launch, and nothing updates it afterwards.

**Where.** `RootView+Session.swift:100-104` (the three calls it does make);
`SeriesRepository.swift:326` (the field); `AppServices.swift:186` (its only
writer); `SeriesRepository.swift:555-558` (`blendExclusionQuery`, the reader).

**Why it matters.** Two failures, one variable:

- **Switch accounts.** Every blend for the rest of the session sends
  `exclude_user_library=<the previous person's id>`. The new reader's blends are
  filtered to exclude *somebody else's* library, and their own tracked series
  are recommended back to them. The comment at `SeriesRepository.swift:318-322`
  calls this exclusion "the single largest source of 'these recommendations are
  bad' for someone with a large library" — so this inverts the fix.
- **Sign in for the first time in a session.** At launch `profileID()` was nil
  (no token). Nothing calls `updateLibraryExclusion` again, so entering a token
  in Settings never switches the exclusion on at all. It works only after a
  relaunch.

This is the same defect class the 2026-09-11 fix closed — a documented
account-scoped value with a clear path and no caller — in a variable that fix
did not reach. `forgetProfile()` clears `LibraryService`'s copy of the id;
nobody clears the repository's copy of the same id.

**Effort.** Two lines in `forgetPreviousAccount()`:
`await repository.updateLibraryExclusion(userID: await library.profileID())`
after `forgetProfile()`. `RootView` already holds `repository`
(`RootView+Session.swift:113`).

**Confidence.** Certain. `grep -rn 'updateLibraryExclusion' MangaBaka/` returns
three lines: the protocol, the implementation, and one call site at
`AppServices.swift:186`.

---

### F3 — A token change does not discard cached blends.

**What.** `forgetPreviousAccount()` never calls `discardCachedFeeds()`. Feed
rows keyed `series/mix/<seed ids>` (`SeriesRepository.swift:167`) survive the
account switch, with a freshness of 3,600 s (`SeriesRepository.swift:263`).

**Where.** `RootView+Session.swift:100-104`; `SeriesRepository.swift:594-601`.

**Why it matters.** For up to an hour after signing in as someone else, the
swipe stack can serve a blend computed from the previous account's seeds and
excluded against the previous account's library. The reader sees the previous
person's recommendations, from disk, with no network request to make it obvious.
This is a milder version of the taste-ledger bug — same cause, different table.

Two lesser cases ride along and are judgement calls rather than defects:
`viewedEntry` and `shelfEntry` are device-local rather than account-local, and
there is a defensible argument for keeping them. There is no written decision
either way, which is what makes them worth naming.

**Effort.** One line, plus a decision on history and shelf.

**Confidence.** Certain about the mechanism. The one-hour window is arithmetic
from `freshness`, not observed.

---

### F4 — A content-rating change does not clear the image cache, which is rating-filtered.

**What.** `images(for:)` filters the gallery by `contentRatings` at *write*
time and memoises the filtered result. `updateContentRatings` clears feeds and
not this.

**Where.** `SeriesRepository.swift:610-620` (write), `:335` (the store),
`:511-517` (the change path that does not clear it).

```swift
let presentable = all.presentable(allowedRatings: contentRatings)
cachedImages[seriesId] = presentable        // memoised post-filter
```

**Why it matters.** Concrete input: open a series, open its cover gallery with
Erotica switched on, go to Settings, switch Erotica off, go back. The gallery
serves `cachedImages[id]` and shows the same covers. It is wrong in both
directions — switching a rating *on* also shows the old narrow set — but the
direction that matters is the one where the reader has just asked the app to
stop showing them something and it keeps showing it, on the screen they asked
from.

The code five lines above states exactly why this is the bad one:

> *"the filter failing on exactly the thing it exists to hide is a bug this app
> has already shipped once, on personalised recommendations."*
> — `SeriesRepository.swift:607-609`

Memory-only, so it heals on relaunch. That is not a defence for a content filter.

**Effort.** One line: `cachedImages.removeAll()` in `updateContentRatings`.

**Confidence.** Certain.

---

### F5 — The `seriesDetail` cache is invalidated by nothing, ever, and is rating-sensitive.

**What.** `discardCachedFeeds()` deletes `feedEntry` and `feedMetadata` only.
There is no `DELETE FROM seriesDetail` anywhere in the app.

**Where.** `SeriesRepository.swift:594-601`; table at `AppDatabase.swift:176`;
written at `SeriesRepository+Cache.swift:34-41`.
Verified: `grep -rn 'DELETE FROM\|deleteAll' MangaBaka/` returns twelve lines and
none of them touch `seriesDetail`.

**Why it matters.** The cached blob is filtered content, not raw content
(`SeriesRepository.swift:665-675`):

- `relationships` is filtered by `isDiscoverable`,
- `editions` by `.presentable`,
- `tags` / `richTags` are what a blocked-tag change is about.

So for six hours (`SeriesRepository+Cache.swift:21`) after changing a rating or
blocking a tag, every series page the reader had already opened keeps rendering
the pre-change answer. Blocking a tag *from the series page that shows it* and
watching it stay is the worst instance.

The comment at `SeriesRepository.swift:596-597` — *"Only the feed cache is
cleared. The shelf holds the reader's own saves and is not derived from the
filter"* — justifies excluding the shelf and is silent on `seriesDetail`, which
**is** derived from the filter. The v6 migration that added the table
(`AppDatabase.swift:168-181`) does not mention invalidation either.

**Effort.** A line in `discardCachedFeeds` for the rating and tag paths. Worth
splitting the function so the format path does not pay for it unnecessarily —
call it a function.

**Confidence.** Certain that nothing clears it. Certain the blob is
rating-filtered. Whether the tag row on the series page re-filters blocked tags
at render is **not reviewed** — that is in `Features/Detail`, another slice.

---

### F6 — **[adjacent]** `convertFromSnakeCase` mangles the `source` dictionary's keys, so `mangaUpdatesID` is nil for every series the API returns.

Found by auditing encoder/decoder pairs as instructed. It is not in my files;
it is the largest thing the audit turned up.

**What.** `APIClient` decodes with `.convertFromSnakeCase`
(`APIClient.swift:29-31`). `Series.source` is `[String: TrackerEntry]`
(`Series.swift:40`). Foundation applies `keyDecodingStrategy` to **dictionary
keys as well as struct keys**, so the wire's `"manga_updates"` becomes
`"mangaUpdates"` in memory. Three call sites look it up in snake_case.

**Where.**
- `Series.swift:227-229` — `source?["manga_updates"]?.id`
- `TrackerScores.swift:59-60` — `case "anime_planet"`, `case "manga_updates"`
- `CharacterService.swift:84-90` — `trackerID("anilist")` / `("shikimori")`,
  which are single words and therefore **unaffected**. That asymmetry is why
  characters work and the schedule may not.

The wire shape is not in doubt — it is in a captured fixture,
`MangaBakaTests/Fixtures/rising.json`:

```json
"source":{"anilist":{...},"anime_planet":{...},"manga_updates":{"id":"6z1uqw7",...},"my_anime_list":{...}}
```

**Why it matters.** `mangaUpdatesID` gates the entire release-schedule feature —
every path through it:

- `ReleaseSchedule.swift:173` — `guard series.mangaUpdatesID != nil else`
- `ReleaseSchedule.swift:242`, `:255`, `:303`
- `SeriesDetailView.swift:329` — the next-chapter estimate on the series page

If the id is always nil, the schedule estimates nothing, for anyone, ever, and
it fails the way this project's characteristic bug always fails: an empty
section that looks like a series with nothing to estimate. `TrackerScores` would
show MangaUpdates and Anime-Planet under their raw keys or drop them.

**And the test agrees with the bug** — charter pattern 2, verbatim:

```swift
// MangaBakaTests/SeriesMergeTests.swift:29
source: ["manga_updates": Series.TrackerEntry(...)]
// :41
#expect(merged.mangaUpdatesID == "abc123", "no id, no release estimate")
```

The fixture is built from the lookup rather than from a response, so it passes
while production returns nil. Changing that one key to what `rising.json`
actually produces after decoding would fail it.

**Effort.** A line if the diagnosis holds (decode `source` into a normalised
dictionary, or give `Series` an explicit key). Confirming it is one test.

**Confidence.** **Likely, not certain.** I have not run code — no builds, per
instructions. The claim rests on Foundation applying `keyDecodingStrategy` to
`[String: T]` keys, which is documented behaviour and a well-known gotcha, but
it is exactly the kind of thing this project's charter says to measure rather
than assert. **The control that settles it, in one test:**

```swift
let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase
let s = try d.decode(Series.self, from: Data(contentsOf: risingFixtureFirstItem))
#expect(s.mangaUpdatesID == "6z1uqw7")   // expected to FAIL today
#expect(s.source?.keys.contains("mangaUpdates") == true)  // expected to PASS
```

Two lines, uses a real captured payload, and the second assertion tells you
*which* of the two it is rather than only that something is wrong. Run it before
changing anything.

One weak corroboration, stated as weak: finding B5 recorded the schedule's first
run showing "0 ESTIMATED OF 0 IN SCOPE". That is consistent with this, but
`inScope` is counted at `ReleaseSchedule.swift:161`, *before* the
`mangaUpdatesID` gate at `:173`, so "0 in scope" has a different cause and does
**not** confirm F6. I mention it only so nobody else mistakes it for evidence.

---

### F7 — Two tables grow without bound, and the reader is shown a count of the garbage.

**What.** Nothing ever deletes from `series` or `seriesDetail`. A feed discard
removes `feedEntry` rows and orphans the `CachedSeries` rows they pointed at.

**Where.** `SeriesRepository.swift:594-601` (deletes the index, not the rows);
`SeriesRepository+Cache.swift:104-108` (`save(db)` per series, unbounded);
`SeriesRepository.swift:539-543` (`SELECT COUNT(*) FROM series`);
`DiscoverModel.swift:132` (the reader-facing use).

**Why it matters.** Two things:

1. **Disk.** Every feed fetch, every launch, forever — with F1 making it every
   launch for signed-in readers. `seriesDetail` is worse per row: the comment at
   `SeriesRepository.swift:625-627` measures a series page at about 300 KB.
   Nothing bounds either. `HistoryStore.swift:100` does exactly the right thing
   for `viewedEntry` (trims to the newest N) and is the model to copy.
2. **The number is wrong.** `cachedSeriesCount()` is not "series on device" —
   it counts orphans no feed references and no screen can reach. The mockup's
   Discover subtitle prints it (`DiscoverModel.swift:132`). A number that only
   ever goes up, never down, and counts unreachable rows is charter pattern 5:
   a measurement measuring the wrong thing, shown to the reader as a fact.

**Effort.** A function: a trim on write, plus deciding what
`cachedSeriesCount` is meant to mean.

**Confidence.** Certain about the unbounded growth (grep is exhaustive).
Certain the count includes orphans. I have not measured how fast it grows.

---

### F8 — `CachedSeries.cachedAt` is written on every row and never read, and `AppDatabase`'s doc comment states a lifetime that does not exist.

**What.** Charter pattern 3. The column is populated
(`SeriesRepository+Cache.swift:106`) and no code reads it — freshness comes
from `FeedMetadata.cachedAt` instead (`SeriesRepository+Cache.swift:65`). At
`:77-80` the rows are fetched and only `id` and `payload` are used.

**Where.** `CachedSeries.swift:10`; `AppDatabase.swift:60`;
`SeriesRepository+Cache.swift:106`.

**Why it matters.** More than tidiness, because of what the doc comment says it
buys you (`AppDatabase.swift:11-13`):

> *"Series are stored as an encoded JSON blob rather than as columns, so that
> adding a field to `Series` needs no schema migration — the cache is derived
> data with a **one-day lifetime**, and anything missing is simply refetched."*

There is no one-day lifetime on this table. `series` rows never expire and never
get deleted (F7). The argument the comment makes — "a model change is safe
because the rows turn over" — is therefore unsupported for the very table it
describes. It is also not true of the freshnesses that do exist: 30 minutes for
`newReleases`, 0 for `surprise`, 6 hours for `seriesDetail` and the library
(`SeriesRepository.swift:257-271`, `SeriesRepository+Cache.swift:21`,
`LibrarySnapshot.swift:44`). Somebody will read that comment and reason from it.

**Effort.** A line, either way — read `cachedAt` to drive a trim (which fixes F7
too), or delete it and correct the comment. Do not just delete it: per the
charter, half of what looks dead here is a behavioural gap, and this one is the
missing half of an eviction policy.

**Confidence.** Certain.

---

### F9 — One bad row silently shortens a cached feed, and the caller cannot tell.

**What.** Per-row decode uses `try?` inside a `compactMap`. A row that fails to
decode is dropped; the feed is returned short, and `feed()` accepts it as a
valid cache hit because it checks only `!fresh.isEmpty`.

**Where.** `SeriesRepository+Cache.swift:88-93`:

```swift
let series = entries
    .compactMap { entry -> Series? in
        guard let row = byID[entry.seriesId] else { return nil }
        return try? decoder.decode(Series.self, from: row.payload)   // <- silent
    }
    .filter(allowsFormat)
```

and `SeriesRepository.swift:356` — `let fresh = try? readCache(...), !fresh.isEmpty`.

**Why it matters.** This is the slice's instance of charter pattern 1: a decode
failure and a smaller result are indistinguishable to the caller. It is reachable
by a real input rather than only by corruption — **this is the "model gains or
loses a field" question**. `Series.init(from:)` uses `decodeIfPresent` for
everything except three fields (`Series.swift:103-105`): `id`, `state` and
`cover` are `decode`, so if any of those three ever became optional, moved, or
were renamed, old cached payloads would throw at that line and vanish one row at
a time. `Cover` itself is safe — its custom init is all `try?` and
`decodeIfPresent` (`Cover.swift:41-64`) and cannot throw — so the risk is
concentrated in `id`/`state`/`cover` being present at all. The 20-row Discover
row would come back as 14 with nothing logged, and a filter would be blamed.

The `filter(allowsFormat)` on the next line makes it worse by design: short
output is *expected* there, so a short feed never looks wrong.

**Effort.** A line — count the failures and treat a non-zero count as a cache
miss (refetch) rather than as a cache hit.

**Confidence.** Certain about the mechanism. The trigger is hypothetical: no
field is currently mis-shaped, and I am reporting the hazard, not a live bug.

---

### F10 — Blocked tags are sent under a parameter name whose verification is recorded for a different endpoint, with no client-side backstop.

**What.** The blocked list goes out as `tag_not` on feeds, search and count, and
as `blocked_tag` on mix. The only recorded live verification is for
`blocked_tag`.

**Where.**
- `SeriesRepository.swift:589` — `filterQuery` sends `tag_not` (feeds)
- `SeriesRepository.swift:424-426` — search sends `tag_not`
- `SeriesRepository+Count.swift:31-33` — count sends `tag_not`
- `SeriesRepository.swift:450-452` — mix sends `blocked_tag`
- `BlockedTags.swift:10-12` — *"Sent to the API as `blocked_tag`, verified
  against the live endpoint on 2026-09-09: blocking the strongest strand of a
  blend changed 12 of 20 results"* — a mix-endpoint measurement, described as
  though it covered everything.

**Why it matters.** The doc comment reads as coverage for the whole feature and
covers one of four call sites. Whether `/v2/series/discover/rising` honours
`tag_not` has no recorded check — and those are the exact two endpoints measured
on 2026-09-10 to silently ignore `type` (`SeriesRepository.swift:566-575`:
*"answered with fourteen manhwa out of twenty"*). An endpoint that ignores one
filter parameter is the first place to suspect for another.

Unlike format, there is **no client-side backstop**. `allowsFormat`
(`SeriesRepository.swift:580-584`) catches what the server ignores; there is no
`allowsBlockedTags`, and `readCacheWithDate` re-filters by format only
(`SeriesRepository+Cache.swift:93`). So if `tag_not` is ignored on those two
rows, a blocked tag is not blocked there and nothing catches it — and the reader
has no way to know, because the whole point of the control is that they stop
seeing something.

**Effort.** One live request to settle it (it is a GET with a query parameter,
not a build). A function if a backstop is needed — `Series.tags` is on the
payload, so the filter is available client-side.

**Confidence.** Certain that the parameter names differ and that only one is
verified. Certain there is no backstop. **Worth checking** whether the discover
endpoints honour `tag_not` — I did not make a network request.

---

### F11 — Two doc comments in `LibrarySnapshot` have come unstuck from what they document.

**What.** `invalidate()`'s doc comment sits on `readCache()`, and the second
half of `load()`'s sits on `onPage`. Both were merged into the following
declaration's comment block.

**Where.** `LibrarySnapshot.swift:137-143`:

```swift
/// Forgets it, so the next ask refetches.
///
/// Called after a write: adding a series or changing its state makes the
/// copy in memory wrong, and a stale library is how the app once offered
/// "Add to library" for something already in it.
/// The library as it was last written, if that was recently enough.
private func readCache() -> Result? {
```

The first three lines describe `invalidate()` (line 188), which now has only an
inline comment. Same at `:62-73`, where *"Called as each page lands, so a screen
can draw what has arrived"* — about `load()` — landed on `private var onPage`.

**Why it matters.** Low severity on its own, but the charter's tell for pattern
3 is *"a function whose doc comment describes a caller that does not exist"*, and
this file now has two comments describing something other than the thing beneath
them. The one on `readCache` describes a clearing behaviour on a function that
clears nothing; anyone grepping `invalidate` for its rationale finds nothing.
In a codebase whose comments are load-bearing — they record measurements with
dates, and that is why several real bugs were findable — a comment attached to
the wrong declaration is more costly than in an ordinary project.

**Effort.** A line each. Move them; do not delete them — the `invalidate()` one
records a real shipped bug ("Add to library" for something already in it).

**Confidence.** Certain.

---

### F12 — The three filter-update functions are three copies of one idea.

**What.** `updateContentRatings`, `updateFormats` and `updateBlockedTags` are
the same six lines with the field and the key changed.

**Where.** `SeriesRepository.swift:511-533`.

**Why it matters.** Shotgun surgery, and it is what let F1 and F4 happen. A
fourth filter means a fourth copy, and the invariant — *a change after the first
application discards what the filter governs* — lives in three places instead of
one, which is how `updateLibraryExclusion` came to be written twenty lines below
them without it. Per CLAUDE.md, the fix is to expose the rule at its source, not
to copy it a fourth time.

**Effort.** A function — one generic `apply(key:changed:)` taking the discard
set. Doing it would make F1, F4 and F5 into arguments at one call site rather
than three omissions.

**Confidence.** Certain about the duplication; the refactor is a judgement call,
not a defect.

---

## Part 4 — Encoder/decoder pairs, audited

Every pair in the app, checked for the `convertToSnakeCase` /
`convertFromSnakeCase` mismatch that cost 939 rows.

| Cache | Write | Read | Verdict |
|---|---|---|---|
| Feed (`series` blobs) | `convertToSnakeCase` (`+Cache.swift:101`) | `convertFromSnakeCase` (`SeriesRepository.swift:351`, used at `+Cache.swift:91`) | **Symmetric.** `Series` has no explicit `CodingKeys` (`Series.swift:58-60` states this is deliberate), so `tagsV2`↔`tags_v2`, `totalChapters`↔`total_chapters` round-trip exactly. |
| Detail (`seriesDetail`) | plain `JSONEncoder()` (`+Cache.swift:35`) | plain `JSONDecoder()` (`+Cache.swift:30`) | **Symmetric.** Checked the nested types too: `SeriesWork.CodingKeys` has one literal, `prices = "price"` (`SeriesWork.swift:46-50`), and `"price"` is unchanged by either strategy, so it is safe under plain coding and would still be safe if a strategy were added. |
| Library (`libraryEntry`) | plain (`LibrarySnapshot.swift:173`) | plain (`:152`) | **Symmetric, and documented with the bug it caused** (`:162-170`). This is the one that lost 939 rows; the fix is right and the reason is written down. |
| `HistoryStore` | `convertToSnakeCase` (`:35`) | `convertFromSnakeCase` (`:36`) | Symmetric, same object. Outside slice, checked for completeness. |
| `ShelfStore` | `convertToSnakeCase` (`:18`) | `convertFromSnakeCase` (`:19`) | Symmetric, same object. Outside slice. |
| `BlockedTagsStore` | plain (`BlockedTags.swift:77`) | plain (`:64`) | Symmetric. `Blocked` is `{id, name}` — single-word keys, immune either way. |
| `SearchLens` | plain (`:105`) | plain (`:68`) | Symmetric. Outside slice. |
| `ReleaseSchedule` cadence | plain (`:354`) | plain (`:338`) | Symmetric. Outside slice. |
| **API `source` dictionary** | — | `convertFromSnakeCase` (`APIClient.swift:31`) | **F6.** Not a cache mismatch — a strategy applied to keys that were never meant to be converted. |

**Result: no read/write key-strategy mismatch remains in any cache.** Every pair
uses the same strategy on both sides, and the one that did not is fixed with its
history recorded. The only key-strategy defect found is F6, and it is on the
wire, not across a cache.

## Part 5 — Migrations and schema versioning

Read `AppDatabase.swift:52-204` in full.

- Seven migrations, `v1_cache` through `v7_libraryCache`, all additive: every
  one is a `create(table:)`, none alters or drops. Downgrade is not handled and
  does not need to be — GRDB refuses unknown migrations and the file is
  disposable.
- **No `eraseDatabaseOnSchemaChange`.** Correct for this app: `shelfEntry`,
  `viewedEntry` and `tagAffinity` are the reader's own data and must not be
  erased by a schema change.
- **Model field changes:** a gained field decodes as nil from an old blob
  (`Series.init(from:)` is `decodeIfPresent` throughout,
  `Series.swift:103-126`), a lost field is ignored on decode. This works and is
  the right design. The two caveats are F9 (the three non-optional fields are
  the crack) and F8 (the comment's "one-day lifetime" justification is not true
  of the `series` table).
- `AppDatabase.swift:14-19` states plainly that unmodelled fields are **dropped**
  on re-encode, not preserved. That is the single most useful sentence in the
  file — it is the thing someone would otherwise assume the other way round.

---

## Part 6 — What this slice does well

Held to the same evidence standard.

**The comments record measurements with dates and methods, and that is why most
of the above was findable.** `SeriesRepository.swift:566-575` does not say "we
also filter client-side"; it says *"Measured against the live API on 2026-09-10:
`/v2/series/discover/rising?type=manga` answered with fourteen manhwa out of
twenty, and `hidden-gems?type=manga` returned a novel."* That one comment is what
made F10 a question worth asking. `:214-223`, `:253-256`, `:318-325` are the same
shape. This is unusual and it should not be traded away.

**Negative results are written down where the code is, not in a doc nobody
opens.** `SeriesRepository.swift:219-223` — *"The comment that used to sit here
asserted the opposite, and it held up for months because a single seed has no
comma in it."* That is a dead idea recorded with the reason it died, which
CLAUDE.md asks for and most codebases do not do.

**The `applied` mechanism (`SeriesRepository.swift:492-509`) is the right fix to
the right problem, stated honestly:** *"Offline support was documented, tested,
and silently dead."* F1 is a gap in its coverage, not a flaw in the idea, and
the idea is what makes F1 a one-line fix.

**`LibrarySnapshot`'s key-strategy comment (`:162-170`) is the model.** It names
the wrong behaviour, the exact key, the symptom (939 rows of "Untitled series"),
the date, and the rule — *"Symmetry is the fix; a strategy on one side only is
the bug."* That comment is why the Part 4 audit could be done by reading rather
than by experiment. Do not let it be deleted.

**Failure is distinguished from emptiness in three places, deliberately.**
`LibrarySnapshot.Result.failure` (`:31-36`) with its reason; `FeedResult.origin`
and `blockingError` (`SeriesRepository.swift:275-297`), which shows stale
content rather than an error page when stale content exists;
`SeriesRepository+Count.swift:14-16` — *"A lens whose count could not be fetched
shows no count; it does not show zero."* This is exactly the distinction whose
absence caused four of the seven charter bugs, and here it is drawn correctly
three times.

**Two caches deliberately refuse to store an empty result**, each with the
reason: `SeriesRepository.swift:614-616` (images — *"a failed fetch and a series
with one cover look identical from here"*) and `:635-638` (extras — *"caching it
would make a dropped connection stick for six hours"*). A cache that remembers a
failure is a class of bug this slice thought about in advance.

**Clock skew is handled, consistently, in all three freshness checks.**
`+Cache.swift:28-29`, `:66-68`, `LibrarySnapshot.swift:148-150` all guard
`age >= 0` and treat a backwards clock as stale. Three independent places, same
rule, each with the same one-line explanation. It would have been easy for one
of the three to miss it.

**Every freshness value is derived, not guessed** — `SeriesRepository.swift:251-271`
ties `rising` and `hiddenGems` to the endpoints' own measured
`x-cache-ttl-cdn-seconds: 86400`, with the argument for why matching the server
is the right number: *"Caching longer than the server does would show staler data
than the server would have given us."* Under CLAUDE.md's constants rule these
are the good kind.

**No force-unwraps.** Grepped all 2,015 lines of the slice: every `!` is a
boolean negation (`!formats.isEmpty`, `!seeds.isEmpty`, and ten similar). The
charter asked for this claim to be re-verified rather than assumed — it holds
for this slice. `AppServices.swift:184-189` even routes the one unavoidable
literal unwrap through a named `unsafelyUnwrappedFallback` with
`preconditionFailure`, specifically so the call site reads honestly.

**Both preference stores refuse to let the reader make the app empty**, and both
say why: `ContentPreferences.swift:61-67` pins `safe` on, `FormatPreferences.swift:68-74`
keeps the last format on — *"Turning everything off would produce an empty app
with no visible cause."* Both also handle a corrupt or hand-edited stored value
by falling back to the wider set rather than the empty one
(`ContentPreferences.swift:97`, `FormatPreferences.swift:100-102`).

**`FormatPreferences` persists the allowed set rather than `queryValues`, with
the reason** (`:114-116`): `queryValues` is deliberately empty when everything
is on, and storing that would be indistinguishable from nothing being on. That
is a trap someone actually walked up to and stepped around.

**`HistoryStore.swift:100` is the eviction policy F7 wants**, already written,
in this codebase, for a neighbouring table. Copying it is the fix.

---

## Denominator

Twelve findings from 2,015 lines read in full, plus seven adjacent files read to
answer the invalidation question. Two things I did **not** establish and am not
claiming: whether the discover endpoints honour `tag_not` (F10 — needs one live
request), and whether F6 reproduces (needs the two-line test above; I did not
build or run anything, as instructed). Not reviewed: whether the series detail
view re-filters blocked tags at render time, which would soften F5.
