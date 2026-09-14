# Full review 2 — slice 1: the database split, the caches, and the no-account path

2026-09-14. Read-only. No builds, no tests, no edits. Nothing in this slice was run; every
claim below is from reading the source, and where I am inferring rather than reading I say so.

**Coverage.** I read in full: `Core/Persistence/*` (all 10 files), `Core/Library/LibrarySnapshot.swift`,
`Core/Offline/*` (3 files), `Core/Images/*` (3 files), `Core/Settings/*` (3 files), and
`MangaBakaTests/LibrarySplitTests.swift`. Partially read (the network half, ~120 of 952 lines):
`Core/Persistence/SeriesRepository.swift`. Read outside the slice, only far enough to trace a
consumer: `TasteLedger`, `TasteProfile`, `RootView+Session`, `AppServices`, `LibraryTransferSection`,
`LibraryImport`, `SpotlightIndex`, `ScheduleModel`, `DataUseSection`. **≈90 % of the slice by line
count, 100 % of the files the brief named as highest risk.**

---

## Top ten, value against effort

| # | Finding | Lens | Effort | Confidence |
|---|---|---|---|---|
| 1 | An import run after a failed library walk treats every row as new — no progress guard, one write per row | bugs | function | certain |
| 2 | One failed library walk deletes the whole taste ledger (`absorb([])` retracts everything) | bugs | line | certain |
| 3 | `all()`/`seriesIDs()` throw the failure away, so five consumers cannot tell "no account" from "empty" | errors | function | certain |
| 4 | `v12_shelfOrderIndex` breaks the rule stated 25 lines below it; the next migration that does the same bricks every device into a silent in-memory DB | crash risk | line + comment | certain |
| 5 | The whole-row `EXCEPT` cannot catch the drift it says it catches | bugs / charter 5 | function | certain |
| 6 | `CoverStore`'s cost comment is off by ~10×: the cache holds ~28 covers, not 300 | bad practice | line | certain |
| 7 | `TasteLedger.clear()` leaves `tasteSeen`, so Settings reports the previous account's count after sign-out | bugs | line | certain |
| 8 | `salvage` does not carry `librarySplit`, so a reset reader's file can re-run a copy it already did | bugs | line | likely |
| 9 | `EmbeddingIndex.load` multiplies two header-supplied `UInt32`s before validating either | crash risk | lines | likely |
| 10 | `CoverStore.prefetch` fans out unbounded `Task`s | load balancing | function | certain |

---

## Part 1 — the five questions the brief asked

### 1.1 The migration: copy → verify → mark → drop

**The order is what the code does.** `AppDatabase+Split.swift:88-129`:
copy at `:92-99` (`INSERT OR IGNORE INTO main.X SELECT * FROM cache.X`, inside one
`db.inTransaction`), verify at `:107-118` (whole-row `EXCEPT`, per table), mark at `:121`
(`INSERT OR REPLACE INTO main.librarySplit`), drop at `:124-129` (one `db.inTransaction` over
all tables). The `guard last > .copy` / `> .verify` / `> .mark` gates are in the right places.

**Each step is confined to one database, and the claim at `:74-78` is true.** Copy writes
`main` only; verify reads both and writes nothing; mark writes `main`; drop writes `cache` only.
The cross-database-atomicity hazard the comment names is real and is genuinely avoided.

One consequence the comment does *not* draw out, and which I think is a strength worth recording:
because the drop is a single transaction against a single database, **a partial drop is impossible**.
Either all eight tables leave the cache file or none do. That closes the "drop interrupted halfway,
marker lost" case I went looking for.

**Interrupted between mark and drop.** Safe. Next launch: `alreadyCopied` is true (`:73`),
`present` is the still-present tables, copy/verify/mark are skipped, drop runs. `LibrarySplitTests
.interruptionLosesNothing` walks exactly this.

**Interrupted between drop and next launch.** Safe. `present` is empty, and `:82-88` marks (if not
already marked) and returns.

**If the copy runs twice.** Safe in the normal case — `INSERT OR IGNORE`, and the marker at `:73`
stops the second copy — but see F8 below for the one path that loses the marker.

**Reader's file exists, marker does not.** Two sub-cases, both handled:
- Cache reader tables already dropped → `present` empty → `mark` at `:85`. Consistent from then on.
- Cache reader tables still present → a full re-copy. This is the dangerous direction (a row the
  reader deleted after the first copy comes back from the dead) and it is only reachable via F8.

**Marker exists, reader's file missing.** Not reachable: the marker lives in the reader's file.
The nearest real case is an iCloud restore to a new device — the reader's file is backed up and
comes back with its marker, the cache file is excluded from backup and does not, so a fresh cache
file is created by the full migrator (which creates all eight reader tables empty), `alreadyCopied`
is true, and the drop removes them. Correct, and I verified this by reading, not by running it.

### 1.2 The reset

**Corrupt cache, silently.** `AppDatabase.swift:239-242` opens the cache with
`keepingCorruptCopy: !split`; `openRecoveringFromCorruption:303-310` takes the `else` branch and
`removeItem`s the file outright. `:256` then computes `lostSomething = library.wasReset ||
(cache.wasReset && !split)`, so a post-split cache reset reports `.opened` and no toast fires.
Traced and correct.

**Corrupt reader's file, salvaged.** `:228-232`: opened with `keepingCorruptCopy: true` (hard-coded,
not derived — good), renamed aside with an ISO-8601 stamp at `:296-302`, then `salvageIfNeeded`
ATTACHes the renamed copy and `INSERT OR IGNORE`s each of `readerTables` across
(`:376-403`). `pruneCorruptFiles` keeps one. Traced and correct.

**"Can the cache reset run before the split marker exists?" — the guard is real.**
`AppDatabase.swift:237`:

```swift
let split = (try? splitHasCompleted(library: library.writer)) ?? false
```

passed to `:241` as `keepingCorruptCopy: !split`. The `(try?) ?? false` fails in the safe
direction (an unreadable marker means "keep the copy"). The ordering is also right: the reader's
file is opened *first* (`:228`, with the comment at `:225-227` giving the reason), so the marker
can be read before the cache is touched, and `:245` then salvages the pre-split cache's reader
tables into the reader's file. **Verified. The agent's claim holds.**

Two second-order notes, neither a defect:
- After a reader's-file reset the marker is gone, so `split` is false and a *simultaneously*
  corrupt cache is kept and reported. Over-cautious, which is the right direction.
- `AppDatabase.onDisk(named:)` (`:118-123`) has no reset path at all. That is by design — the doc
  at `:112-116` says so and `onDiskResettingIfCorrupt` is what the app uses
  (`AppServices.swift:311`).

### 1.3 Ownership

**No query, join, transaction or migration spans both files.** I grepped every literal reader-table
name across `MangaBaka/` and `MangaBakaWidget/` and read each hit. Every one of
`shelfEntry`, `viewedEntry`, `tagAffinity`, `tasteSource`, `tasteSeen`, `tasteContribution`,
`libraryEntry`, `libraryMetadata`, `librarySplit` is reached only through `libraryWriter`
(`ShelfStore`, `HistoryStore`, `TasteLedger`, `LibrarySnapshot`, `AppDatabase+Split`). Every one of
`series`, `feedEntry`, `feedMetadata`, `seriesDetail`, `cadenceEntry` is reached only through
`cacheWriter` (`SeriesRepository+Cache`, `SeriesRepository.swift:662`, `ReleaseSchedule`).
`SeriesRepository+Cache.trimOrphans:372` deletes from `series` using a subquery on `feedEntry` —
both cache-side. **Nothing writes the reader's tables to the cache file or reads them from it,
except the split itself, which is the point.**

The one exception, and it is deliberate: `AppDatabase.migrator` (the *cache* migrator) still
*creates* all eight reader tables, because its recorded history cannot be rewritten. That is
documented at `AppDatabase+Schema.swift:174-181` and is correct — but see F4, where that
interacts badly with a rule the same file states.

### 1.4 The no-account path

`LibrarySnapshot.load():136-142` refuses before the memory cache, the disk cache and the walk, and
returns `Result(entries: [], isComplete: true, failure: .noAccount)` — a real 401 shaped exactly
like the server's (`:104-106`). That part is right, and the wiring
(`AppServices.swift:151`, `hasCredentials: { keychain.read() != nil }`, backed by a memoising
`TokenStore`) is right.

**What each consumer does when a token appears or disappears mid-session:**

| Consumer | Token disappears | Token appears |
|---|---|---|
| Library header (`LibraryModel.load:424`) | reads `result.failure`, shows `ScreenState.noAccount` | next `reload()` walks |
| Discover "Pick back up" (`RootView+Session:314`) | only reached after `guard walk.failure == nil`, so it is left standing until the next `startSession` | filled on next `startSession` |
| Widget (`RootView+Session:246`) | `WidgetSnapshot.write(pickBackUp: [])` on `needsAccount` | rewritten on next `startSession` |
| Spotlight (`RootView+Session:255`) | `spotlight.clear()` on `needsAccount` | reindexed on next `startSession` |
| Taste ledger (`RootView+Session:269`) | `taste.forgetEverything()` — but see F7 | rebuilt from the first successful walk |
| Export (`LibraryTransferSection:66`) | silently offers nothing — see F1 | `loadEntriesIfNeeded`'s `guard entries.isEmpty` lets it retry |

The four surfaces in `startSession` are correct and the comments at `:237-271` are accurate. The
problem is everything that does not go through `startSession`.

**"Can the refusal be mistaken for an empty library anywhere?" — yes, in six places, and two of
them cost something.** `LibrarySnapshot.swift:252`:

```swift
func all() async -> [LibraryEntry] { await load().entries }
```

`all()` and `seriesIDs():255` discard `Result.failure` — the field whose own doc at `:31-34` says
"an empty list and a failed request are not the same thing". Callers: `TasteProfile:106` (F2),
`TasteProfile:132`, `RootView+Session:101` → `LibraryTransferSection` (F1),
`RootView+Session:296`, `:324`, `:352`, `ScheduleModel:336`, `StackModel:617`,
`AppIntents.swift:46`. The last one means Siri answers "nothing coming up" rather than "you are
not signed in".

The same hole swallows a *transient* failure identically — offline, a 500, a rate limit — which is
what makes F1 and F2 real bugs rather than sign-out cosmetics.

### 1.5 Backup exclusion

**On the cache only, and yes it survives a recreate.** `AppDatabase+Split.excludeFromBackup:145-160`
is called from `finishOpening:128`, which both `onDisk:120` and `onDiskResettingIfCorrupt:247` call
*after* the pools are open — so a freshly recreated cache file is excluded on the same launch that
created it, and re-excluded on every launch thereafter. It covers `""`, `"-wal"` and `"-shm"`, skips
files that do not exist, and never touches `libraryName(for:)`.
`LibrarySplitTests.onlyTheCacheIsExcludedFromBackup:257` asserts both halves.

---

## Part 2 — findings

### F1 — An import run after a failed library walk treats every row as new

**What.** `LibraryImport.apply` is given `existing: []` whenever the shared library walk failed,
so its "never downgrades progress" guard cannot fire and every row is sent as a fresh `add`.

**Where.** `RootView+Session.swift:101` (`loadExisting: { await librarySnapshot.all() }`) →
`LibraryTransferSection.swift:66` (`entries = await loadExisting()`) →
`:150` (`LibraryImport.apply(preview, to: library, existing: entries, …)`) →
`LibraryImport.swift:414-441`.

**Why it matters.** `LibraryImport.swift:430-434` skips a row whose imported chapter is behind
`existing`'s, and `:438` chooses `add` vs `update` on `current == nil`. With `existing` empty both
collapse. A reader who is offline, rate-limited or momentarily 500'd when they open Settings, then
imports an old export or a stale MyAnimeList list, **walks their real MangaBaka progress backwards**
— and spends one request per row at 500 ms each (`LibraryImport.swift:65-67`) instead of the handful
of genuine changes. `LibraryTransferSection:105`'s preview also reports every row as "new", so the
number on screen agrees with the bug rather than warning about it (charter pattern 2).

**Fix.** Change `loadExisting` to hand over the `Result`, not the entries — e.g.
`loadExisting: { await librarySnapshot.load() }` with `LibraryTransferModel` storing
`entries` plus `libraryFailure`/`isComplete`. Then in `loadEntriesIfNeeded`, refuse to build a
preview when `failure != nil || !isComplete` and say why ("Couldn't read your current library —
importing now could overwrite it"). Do not just retry: a page-capped walk is short, not failed.

**Effort.** A function (plus one line at the call site). **Confidence.** Certain — I read every
step. **Lens.** 1 (bugs), 2 (errors), 6 (load balancing).

### F2 — One failed library walk deletes the whole taste ledger

**What.** `TasteLedger.absorb(_ entries:)` treats "no entries" as "every series left the library"
and retracts all of them. `TasteProfile` feeds it `snapshot.all()`, which is `[]` on any failure.

**Where.** `TasteProfile.swift:106` (`try? await ledger.absorb(await snapshot.all())`) →
`TasteLedger.swift:116-121`:

```swift
let presentIDs = entries.map(\.seriesId)
let stale = try TasteSource.filter(!presentIDs.contains(Column("seriesId"))).fetchAll(db)
for source in stale { try Self.retract(seriesId: source.seriesId, in: db); try source.delete(db) }
```

With `presentIDs` empty, GRDB emits `NOT 0` for that predicate, so every `tasteSource` row matches.

**Why it matters.** `favouredTagIDs()` is called from every series page. Open one while offline (or
during a rate-limit window, or with the API 500ing) and the ledger — 945 sources and ~3,175 tags on
Abdi's real install per the `v11_recountTaste` measurement — is emptied. It rebuilds on the next
successful walk, so this is recoverable, but for the rest of that session tag highlighting and
taste-ranked ordering silently degrade to "this reader likes nothing", Settings → Data Used drops to
"Nothing counted yet", and the rebuild is the 939-select/939-upsert pass the `absorb(_ series:)` doc
at `:186-191` was specifically optimised to avoid paying.

**Fix.** `absorb` must not retract on an unreliable snapshot. Either give it the `Result` and skip
the stale sweep unless `failure == nil && isComplete`, or — smaller — `guard !entries.isEmpty else
{ return }` before the sweep at `:116`, with a comment saying that an empty library is indistinguishable
from a failed walk at this call site and that the real signal is the `Result`. The `guard` is a
patch; passing the `Result` is the fix, and it shares a seam with F1/F3.

**Effort.** A line for the patch, a function for the fix. **Confidence.** Certain that the SQL
matches everything on an empty array; likely on the exact GRDB spelling (`NOT 0`) — the *behaviour*
is what matters and either spelling matches all rows. **Lens.** 1, 2.

**Prove it fails first.** A test that seeds two `tasteSource` rows, calls `absorb([])`, and asserts
`countedSeries() == 2` fails today.

### F3 — `all()` and `seriesIDs()` erase the refusal the snapshot was rebuilt to carry

**What.** The refusal added yesterday is only visible to the three callers that use `load()`.

**Where.** `LibrarySnapshot.swift:252` and `:255`.

**Why it matters.** F1 and F2 are both instances. The rest are milder but real:
`AppIntents.swift:46` has Siri say "nothing coming up" to a signed-out reader;
`ScheduleModel.swift:336` shows an empty Announced section with no explanation (the doc at `:327-333`
argues the section should vanish "without a library", which is fair for an *empty* library and wrong
for a failed one); `StackModel.swift:617` stops excluding library series from the stack, so a
signed-in reader on a bad connection gets offered series they are already reading — the exact
failure `libraryExclusionUserID` exists to prevent.

**Fix.** Delete `all()` and `seriesIDs()`, or mark them `@available(*, deprecated)` and move each
caller to `load()`. Where a caller genuinely cannot act on a failure, make it write
`let result = await snapshot.load(); let entries = result.entries` so the discard is visible at the
call site instead of hidden behind a convenience. The doc at `:250-251` ("for callers that do not
care why it stopped") is the assumption that turned out to be wrong.

**Effort.** A function plus nine call sites. **Confidence.** Certain. **Lens.** 2 (errors).

### F4 — `v12_shelfOrderIndex` breaks the rule stated 25 lines below it

**What.** `AppDatabase+Schema.swift:160-165` states, in bold, that a new `v…` migration must never
touch a table on `readerTables`, because on a device that has split those tables are not in the
cache file and the migration will throw on open. `v12_shelfOrderIndex` at `:139-140` does exactly
that — `createShelfOrderIndex` at `:232` runs `CREATE INDEX … ON shelfEntry`.

**Where.** `AppDatabase+Schema.swift:139-140`, `:232`, against the rule at `:160-165`.

**Why it matters.** It does not fire *today*, and the reason is invisible: v12 and the split shipped
in the same build, and both `onDisk` and `onDiskResettingIfCorrupt` migrate the cache file before
`finishOpening` calls `splitReaderTables`, so on the one launch where v12 runs, `shelfEntry` is
still there. The next migration that touches a reader table will not be so lucky, and the failure
mode is the worst one in this file: `CREATE INDEX` on a missing table throws `SQLITE_ERROR`,
`isCorruption` at `AppDatabase.swift:351-354` correctly says that is not corruption, so
`openRecoveringFromCorruption` returns nil, `onDiskResettingIfCorrupt` returns nil, and
`AppServices.makeDatabase:313` falls back to an **in-memory database, silently, on every launch,
forever** — `.unopened` deliberately shows no toast (`RootView+Session.swift:203-206`). The reader
sees an app that forgets everything and is told nothing, which is the exact failure gap 3 was filed
for.

**Fix.** Two lines and a comment. (a) Guard `createShelfOrderIndex`'s cache-side use:
`if try db.tableExists("shelfEntry") { try createShelfOrderIndex(db) }` inside v12 — harmless today,
and the template the next migration copies. (b) Add a comment at `:139` saying v12 is safe *only*
because it shipped in the same build as the split, so nobody reads it as permission. (c) Better
still, add a test: migrate a cache file, run `splitReaderTables`, then run `AppDatabase.migrator`
over it again and assert it does not throw. That test fails the day someone writes `v13` against a
reader table, which is the day it needs to.

**Effort.** A line plus a test. **Confidence.** Certain that the rule is violated; certain that it
does not fire today; certain about the `.unopened` consequence (I read all three hops). **Lens.**
8 (crash risk), 9 (bad practice), charter pattern 7.

### F5 — The whole-row `EXCEPT` cannot catch the drift its comment says it catches

**What.** `AppDatabase+Split.swift:103-107` claims the `EXCEPT` verification "fails loudly if the
two schemas ever drift into different column orders rather than silently copying the wrong columns
into each other". It cannot, for any reorder that keeps the column count.

**Where.** `AppDatabase+Split.swift:103-118`; the same claim is repeated in
`LibrarySplitTests.swift:216-219`.

**Why it matters.** Suppose `cache.shelfEntry` is `(seriesId, addedAt, kind, payload)` and
`main.shelfEntry` is `(seriesId, kind, addedAt, payload)`. `INSERT INTO main.X SELECT * FROM cache.X`
copies positionally, so `kind` receives the date and `addedAt` receives `"saved"` — SQLite's type
affinity does not reject either. The verify then compares `SELECT * FROM cache.X` (which yields the
tuple in *cache's* order) against `SELECT * FROM main.X` (which yields the same values in *main's*
order, because they were written there). The tuples are identical, `EXCEPT` returns zero, the split
marks and drops, and the reader's shelf is now permanently scrambled with every step having
reported success. A *count* change is caught (`EXCEPT` errors on mismatched arity, which throws and
blocks the drop); a *reorder* is not.

The real protection is `LibrarySplitTests.schemasMatch:221`, which compares `sqlite_master.sql`
text and would catch a reorder. That is a good test — but it is a test, and the comment tells the
next reader that the device checks this too.

**Fix.** Two options, both cheap:
- Correct both comments to say what actually guards this (the `schemasMatch` test, and arity only at
  runtime). One line each. This is the minimum.
- Make the runtime check real: read `PRAGMA table_info` for both sides, compare the name lists, and
  throw a new `SplitError.schemaDrift(table:)` before copying; then copy with an explicit column
  list rather than `SELECT *`. A function, and it makes the claim true instead of deleting it.

**Effort.** A comment, or a function. **Confidence.** Certain — I worked the example through by
hand against SQLite's `EXCEPT` semantics. I did **not** run it; this is reasoning, not a
measurement, and if it is going to be fixed the fix should ship with a test that reorders one
table's columns and asserts the split refuses.

**Lens.** 1 (bugs), 9, charter pattern 5 ("a measurement that measures the wrong thing").

### F6 — `CoverStore`'s cost comment is off by about 10×

**What.** The comment says the 96 MB limit holds roughly 300 covers because each is charged 320 KB
("the encoded size, not the decoded one"). The cost function charges the decoded size.

**Where.** `CoverStore.swift:31-37` (the claim) against `CoverStore.swift:149-153`:

```swift
var approximateBytes: Int {
    guard let cgImage else { return 1 }
    return cgImage.bytesPerRow * cgImage.height
}
```

— whose own comment one line above says "`cgImage` bytes rather than the encoded size, because a
decoded image is what is actually being held". The two comments contradict each other, in the same
file, about the same number.

**Why it matters.** By the first comment's own arithmetic a 768×1152 @3x cover is ~3.4 MB decoded,
so 96 MB is **about 28 covers**, not 300. That is smaller than one screen of a Discover grid plus
the series page behind it, so the cache is evicting covers the reader is still scrolling through —
and `image(for:)` will refetch them, because `NSCache` eviction is silent. It also means the
"300-cover target is a guess" hedge at `:33-37` is warning about the wrong number: the guess is not
300, the guess is 96 MB, and it is currently buying a tenth of what the file says.

This is not the same as do-not-fix #9 (cancellation) or work item 33 (`CoverImage` retention) —
this is the cost function versus its own documentation.

**Fix.** Decide which the limit means and make the file agree. Either (a) keep the decoded cost and
raise `totalCostLimit` to what 300 covers actually costs (~1 GB — which is why (a) is probably
wrong), or (b) charge the encoded size (keep `data.count` from `fetch` alongside the image) and keep
96 MB, or (c) keep both as they are and rewrite `:31-37` to say "96 MB ≈ 28 decoded covers at
~3.4 MB each". (c) is one line and stops the comment lying; (b) is the one that matches the intent.
Whichever is chosen, the hit rate on a real Discover scroll is the measurement that settles it — the
same measurement `:36-37` already asks for.

**Effort.** A line (c), or a function (b). **Confidence.** Certain that the comment and the code
disagree; certain about `bytesPerRow * height` being decoded bytes. **Lens.** 9 (bad practice), 7
(speed), 8 (unbounded/undersized cache).

### F7 — `TasteLedger.clear()` leaves `tasteSeen` behind

**What.** Sign-out clears three of the four taste tables.

**Where.** `TasteLedger.swift:213-219` deletes `TagAffinity`, `TasteSource` and `tasteContribution`.
It does not touch `tasteSeen`, which `createTasteSeen` at `AppDatabase+Schema.swift:253` creates and
which `absorb` writes on every entry (`TasteLedger.swift:85`, `:196`).

**Why it matters.** `RootView+Session.swift:269` calls `taste.forgetEverything()` on the
no-credential branch precisely so that no account-scoped data survives — the comment at `:258-268`
describes finding "Taste profile: 945 series counted · 3175 tags known" on an install with no
account and calls this an invariant checked every launch. But `DataUseSection.swift:83-90` reads
`seenSeries` first:

```swift
guard seenSeries > 0 else { return "Nothing counted yet. …" }
let untagged = seenSeries - countedSeries
guard countedSeries > 0 else { return "\(seenSeries) series seen, and none of them carried tags" }
```

So after a sign-out the screen reads **"945 series seen, and none of them carried tags"** — the
previous account's count, dressed up as this feature's one diagnosable failure. The fix that was
supposed to close this surface left it half-open, and it now reports a bug that is not there.

Note that `v11_recountTaste` (`AppDatabase+Schema.swift:127-133`) *does* delete `tasteSeen`
alongside the other two, so the migration and the clear disagree about what "forget the ledger"
means.

**Fix.** Add `try db.execute(sql: "DELETE FROM tasteSeen")` to `clear()` at `:217`. One line.
While there, consider deriving the list from `readerTables`-style single naming, since this is the
third place (`v11`, `clear`, `salvage`) that has to agree about which tables are the ledger.

**Effort.** A line. **Confidence.** Certain. **Lens.** 1 (bugs), 2 (errors — a real diagnostic
reporting a false positive).

**Prove it fails first.** `absorb` one tagless series, `clear()`, assert `seenSeries() == 0`.

### F8 — `salvage` does not carry `librarySplit`, so a reset reader's file can re-run a copy

**What.** `AppDatabase.readerTables` is what `salvage` copies out of a corrupt reader's file
(`AppDatabase.swift:381-395`), and `librarySplit` is deliberately not on that list
(`AppDatabase+Schema.swift:167-171`). So a reader's file that is reset and salvaged comes back with
its rows and without its marker.

**Where.** `AppDatabase+Schema.swift:167-171` (the list), `AppDatabase.swift:381` (the loop),
`AppDatabase+Split.swift:73` (`alreadyCopied`).

**Why it matters.** In the common shape the marker's absence is harmless — the cache file's reader
tables have already been dropped, `present` is empty, and `splitReaderTables:85` re-marks. The
harmful shape is narrow but is exactly the one the marker exists for: a device whose reader's file
is reset *while the cache file still holds the reader tables* (i.e. the drop had not run yet, or
this is the same launch as the first split). Then `alreadyCopied` is false, the copy runs again
from the cache file, and — per the reasoning at `AppDatabase+Split.swift:58-64` — any row the
reader deleted since the first copy is resurrected. `INSERT OR IGNORE` does not help: the deleted
row is not there to be ignored.

**Fix.** Salvage the marker too. Either add `"librarySplit"` to a second, salvage-only list, or
have `salvageIfNeeded(library, into:)` follow up with a `SELECT COUNT(*) FROM salvage.librarySplit`
and re-`mark` if it was set. Two lines. The reason `librarySplit` is off `readerTables` is that
`splitReaderTables` must not try to copy or drop it from the cache file — that is a different
concern from salvage, and the two lists should be separate rather than one list doing both jobs.

**Effort.** A line or two. **Confidence.** Likely — the mechanism is certain, the reachability
(a reader's file corrupting during the one launch window where the cache still holds the tables)
is narrow enough that I would not claim it has happened. **Lens.** 1 (bugs).

### F9 — `EmbeddingIndex.load` multiplies header-supplied sizes before validating them

**What.** `count` and `dims` come straight out of the file header and are multiplied before the
size check.

**Where.** `EmbeddingIndex.swift:191-200`:

```swift
let count = Int(readUInt32LE(data, at: 4))
let dims  = Int(readUInt32LE(data, at: 8))
let vectorsStart = idsStart + count * 4
let expectedSize = vectorsStart + count * dims      // traps on overflow
guard data.count == expectedSize else { throw LoadError.sizeMismatch }
…
var ids = [Int32](repeating: 0, count: count)       // 16 GB at count = UInt32.max
```

**Why it matters.** This is the same class of defect `Gunzip.validatedDestinationSize` was hardened
against on 2026-09-14 (review F3: "a truncated `OfflineIndex.json.gz` is a build-time hazard this
general-purpose utility should not carry"). `Gunzip` learned the lesson; `EmbeddingIndex`, which
parses a second bundled binary with a length-prefixed header, did not. A truncated or
mis-transferred `OfflineEmbeddings.bin` gives `count * dims` up to 2^64, which traps on the
multiplication — a crash, not a thrown `LoadError` — and a plausible-but-wrong `count` allocates
`count * 4` bytes before any validation. Bundled, so reachable only via a broken build; but a
broken build that crashes on every launch is worse than one that logs and shows no "similar by
description" row, which is what the rest of this file is carefully built to do.

**Fix.** Bound before multiplying, in `Gunzip`'s idiom and with the same "derived, not guessed"
comment: `guard count > 0, count <= 1_000_000, dims > 0, dims <= 4096 else { throw
LoadError.sizeMismatch }` (the real file is 19,203 × 384, so both bounds carry >50× headroom —
say so in the comment), or compute with `multipliedReportingOverflow(by:)`. Four lines.

**Effort.** Lines. **Confidence.** Likely — certain that Swift's `*` traps on `Int` overflow and
that the guard is downstream of it; "likely" only because I have not confirmed the exact byte
layout against the generator script. **Lens.** 8 (crash risk).

### F10 — `CoverStore.prefetch` fans out unbounded

**What.** One unstructured `Task` per URL, with no cap and no priority.

**Where.** `CoverStore.swift:92-97`:

```swift
for url in urls.compactMap({ $0 }) where cache.object(forKey: url as NSURL) == nil {
    guard inFlight[url] == nil else { continue }
    Task { _ = await image(for: url) }
}
```

**Why it matters.** The caller decides the fan-out. A Discover row or a library grid handing this
40–60 URLs starts 40–60 concurrent `URLSession.data` calls at default priority, each of which
decodes and `byPreparingForDisplay`s on the cooperative pool — competing with the scroll that asked
for them, which is the exact problem `fetch`'s `nonisolated` was made for. The cover CDN is not the
rate-limited API, so this does not spend the 30/min or 180/min windows, but it is the app's largest
byte consumer (`NetworkLedger.recordImage`) and prefetch is speculative by definition.

`prefetch`'s doc at `:86-91` argues the duplicate request is free because `image(for:)` dedupes —
true, and not the issue. The issue is the count.

**Fix.** Bound it. Either take a `limit` (`for url in urls.prefix(12)`) or run the prefetch through
a `TaskGroup` with a fixed width and `Task(priority: .utility)` so speculative covers lose to the
ones already on screen. A function.

**Effort.** A function. **Confidence.** Certain about the code; the *impact* is an inference — the
number that would settle it is concurrent-request count during one Discover fling, which needs a
device. **Lens.** 6 (load balancing), 7 (speed).

### F11 — `builtDate()`'s doc comment is attached to `titles(for:)`

**What.** A doc comment describing one function sits above a different one.

**Where.** `OfflineCatalogue.swift:157-162`. The comment beginning "The export's own build date,
e.g. '2026-09-13'. Nil when the resource is missing or unreadable" is followed immediately by
"Titles for a set of ids…" and then `func titles(for ids: [Int])`. The real `builtDate()` at `:173`
has no comment at all.

**Why it matters.** Cosmetic in isolation, but this project treats comments as load-bearing and the
brief specifically asks for comments that now lie. Quick-help on `titles(for:)` currently describes
a date.

**Fix.** Move lines 157-159 down to `:172`. **Effort.** A line. **Confidence.** Certain.
**Lens.** 9.

### F12 — `Int(rating.rounded())` on a value from a parsed file

**Where.** `OfflineCatalogue.swift:376`, inside `passesRating(_:minimum:)`.

**Why it matters.** The project's own rule (CLAUDE.md, and `Int(wholeOrClamped:)` used at
`SpotlightIndex.swift:93-94`) is that a `Double` from outside the app does not go through `Int(_:)`.
`rating` is decoded from the bundled `OfflineIndex.json.gz`; a NaN or an out-of-`Int`-range value
there traps. The file is ours, so this is a build hazard rather than a network one — the same
severity as F9 and the same fix pattern.

**Fix.** `Int(wholeOrClamped: rating.rounded())`. **Effort.** A line. **Confidence.** Certain that
the rule is broken; the reachability depends on the export generator, which I did not read.
**Lens.** 8, 9.

### F13 — The second concurrent `load()` caller gets un-replayed entries

**Where.** `LibrarySnapshot.swift:145` (`if let inFlight { return await inFlight.value }`) against
`:169-171`, where the *first* caller replays `pendingChanges` onto the walk's rows before caching.

**Why it matters.** Three callers arrive at once on launch (the doc at `:129-132` says so). Only the
one that created the task gets `replayPending` applied; the other two get the raw walk result. If
the reader edited something mid-walk (work-list 15's scenario), those two callers see the pre-edit
row. The cached copy and the disk copy are correct, so the next read is right — this is a
one-shot, in-session discrepancy, not persistent wrongness.

**Fix.** Have the task itself do the replay (move `replayPending` inside the `Task` closure via an
actor-isolated continuation), or have the second caller re-read `cached` after the await:
`await inFlight.value; return cached ?? result`. **Effort.** A function. **Confidence.** Certain
about the code path; "worth checking" on whether any real caller is close enough in time to see it.
**Lens.** 1.

### F14 — `cachedImages` and `cachedRelationships` are unbounded

**Where.** `SeriesRepository.swift:463` and `:469`.

**Why it matters.** Both are per-series dictionaries held "for as long as the app is running" with
no cap and no eviction. `cachedImages` is cleared only by `apply(_:changed:invalidating:)` when the
scope contains `.images` (`SeriesRepository+Cache.swift:140`); `cachedRelationships` is cleared by
nothing at all. A long browsing session accumulates one entry per series page opened. These hold
metadata (URLs, ids), not bitmaps, so the per-entry cost is small — but "small × unbounded" is the
shape lens 8 asks about, and `cachedRelationships` in particular has no path that ever removes an
entry.

**Fix.** An `NSCache` with a count limit, or a simple LRU bounded at a few hundred. Give whichever
number is chosen a comment saying it is a guess, per this project's own standard.

**Effort.** A function. **Confidence.** Certain that neither is bounded; the memory cost is an
inference — I did not measure a `SeriesImage` array. **Lens.** 8.

### F15 — `protocol Clock` shadows the standard library's

**Where.** `Core/Persistence/Clock.swift:8`.

**Why it matters.** Swift's concurrency `Clock` (`ContinuousClock`, `SuspendingClock`,
`Task.sleep(until:clock:)`) is in scope everywhere in this module. `any Clock` here resolves to the
app's protocol because it is more local, so nothing breaks — but a future `func wait(clock: some
Clock)` means something surprising, and `Task.sleep(for:)` sits three files away in `CoverStore`.

**Fix.** Rename to `CacheClock` or `DateProvider`, mechanically. **Effort.** A rename across the
files that name it. **Confidence.** Certain about the shadowing; no defect observed. **Lens.** 9.
Low priority — file it, do not prioritise it.

---

## Part 3 — what the slice does well

Not a courtesy section; each of these is load-bearing and I checked it.

1. **The split's ordering argument is correct and the code honours it.** `AppDatabase+Split.swift:74-78`
   names the real SQLite constraint (no cross-database atomicity in WAL) and then structures every
   step so it writes one database. The stronger property — that the drop is one transaction against
   one file, so a partial drop cannot exist — falls out of that design rather than being asserted.
2. **`LibrarySplitTests.verificationFailureDropsNothing:180` is a real control.** Its doc says so
   explicitly: "Without it, 'copy, verify, drop' could be 'copy, drop' and every test above would
   still pass." And `schemasMatch:247-250` carries its own control ("the cache file has tables the
   reader's file does not, so the comparison above is not passing on two identical schemas"). That
   is the standard CLAUDE.md asks for, actually met.
3. **`isCorruption` is narrow, and the narrowness is argued.** `AppDatabase.swift:339-354` lists
   `SQLITE_FULL`, `SQLITE_BUSY`, `SQLITE_IOERR`, `SQLITE_CANTOPEN` by name as things that must *not*
   cost the reader their shelf, and `isCorruptionForTesting:358` exists because provoking a real
   `SQLITE_FULL` needs a full disk. That is the right trade and it is written down.
4. **The three-state `OpenResult.Outcome`** (`:150-178`) fixed a genuine conflation and says which
   old meaning it kept and why, including the specific line (`AppServices.swift:181`) that was wrong.
5. **Measurements carry dates and methods throughout**, and several carry corrections:
   `SeriesRepository+Cache.swift:376-384` re-measures the detail payload at 204 KB median, states
   that this makes the existing limit *cheaper* than believed, and explicitly declines to act —
   recording the number for the next person. `v11_recountTaste` (`AppDatabase+Schema.swift:118-133`)
   records 945 sources against 0 contributions on the real simulator file and explains why that
   means the retraction "has never worked for anybody". `Gunzip.swift:107-123` labels its 64 MB
   ceiling a guess and gives the real payload size next to it.
6. **`Gunzip` verifies its CRC32 against a known-answer test** (`:143-149`, `crc32("123456789") ==
   0xCBF43926`) — the control that proves the implementation, not just the format.
7. **`readCache`'s `entries.count == rows.count` check** (`LibrarySnapshot.swift:281-288`) refuses a
   partially-decodable cache rather than silently shrinking the library. That is the right call and
   the comment gives the failure it prevents.
8. **`writeCache` uses `insert`, not `save`,** with the reason (~1,900 statements for 945 rows) and
   the invariant that makes it safe (`:307-311`). Optimisation and its precondition documented in
   the same place.
9. **`CoverStore.fetch` being `nonisolated`** (`:99-112`) — the doc names the real bug (a `Task`
   inside a `@MainActor` type inherits isolation, so `UIImage(data:)` decoded on the main thread)
   and covers `byPreparingForDisplay` for the same reason at the other end.
10. **`EmbeddingIndex`'s `.alwaysMapped` slice** (`:42-56`, `:207-212`) trades 7.37 MB of resident
    memory for pageable mapped pages and says what it replaced. The `nonisolated` restructure at
    `:16-23` also corrects a doc comment that had previously *claimed* concurrency the code did not
    have — a self-caught instance of the pattern this review is hunting.

---

## Part 4 — what I could not determine

| # | Question | The one measurement that settles it |
|---|---|---|
| P1 | How long does the one-time split actually take on a real pre-split install? `finishOpening` runs synchronously inside `AppServices.init` on the main actor, and on Abdi's file it copies 945 shelf rows + 939 `libraryEntry` rows (~25 MB of blobs) across a file boundary. If it is >200 ms it is a visible one-time launch hang. | Wrap `splitReaderTables` in a `Signposts.measure` and launch once on the real simulator file *before* it has split (restore a copy of `mangabaka.sqlite` from before yesterday). |
| P2 | Does the reader ever actually hit the `CoverStore` eviction F6 predicts? | Log `NSCache` evictions (`NSCacheDelegate.cache(_:willEvictObject:)`) during one 60-cover Discover fling. If evictions > 0 on a single screen, F6 is costing refetches. |
| P3 | Is `prefetch` ever called with more than a dozen URLs at once? I read `CoverStore` but not its call sites (outside this slice). | `grep -n "prefetch(" MangaBaka/Features` and read the largest caller — a grep, not a run. |
| P4 | Does the `OfflineIndex` generator ever emit a null/NaN `r`? (F12's reachability.) | Read `Scripts/` for the export generator, or `zcat OfflineIndex.json.gz \| jq '[.series[].r] \| map(select(. == null)) \| length'`. |
| P5 | Does `EmbeddingIndex`'s header ever carry a `count` the bundled file does not match? (F9's reachability.) | Same: read the generator. The runtime `sizeMismatch` guard catches it *if* the multiplication survives. |
| P6 | Whether `LibrarySnapshot`'s synchronous `libraryWriter.write` in `writeCache` (939 encodes + 939 INSERTs, `:298`) blocks the snapshot actor long enough to matter. **This is persistence F16 / do-not-fix #3 / U10 and I am not re-filing it** — but note that `SeriesRepository+Cache.swift:46-49` already argues the opposite convention ten files away, so whatever U10 decides should be applied to both. | U10's number. |

---

## Part 5 — the brief's second-pass questions, answered directly

**"A fix that is inert."** I found one class of it and one near-miss.
- F5: the `EXCEPT` verification cannot detect the drift its comment says it detects. The mechanism
  is present, runs, and passes — on data it cannot distinguish.
- F4 is the inverse: a mechanism that *will* fire, catastrophically, and currently does not only
  because of a shipping coincidence nothing records.
- F7 is a fix that covers three of four tables, so the surface it was aimed at (Settings → Data Used
  after sign-out) still shows the previous account's number.

**"A test rewritten to pass rather than to assert."** I read `LibrarySplitTests` in full and did not
find one. Every case carries an "expected to fail before the split with:" line naming the specific
assertion that would have failed, two carry explicit controls, and `interruptionLosesNothing`
asserts the *safe direction only* (`inLibrary + inCache >= 1`, and `inCache == 1` before the drop)
rather than an exact state — which is the correct shape for an interruption test. The one gap is
that `schemasMatch` is the only thing standing between the split and F5, and nothing says so.

**"A comment that now lies."** Three: `CoverStore.swift:31-37` (F6), `AppDatabase+Split.swift:103-107`
and `LibrarySplitTests.swift:216-219` (F5), `OfflineCatalogue.swift:157-162` (F11).

**"Two fixes that collide."** Yes — F1 and F2 are both the collision of "`LibrarySnapshot` now
refuses without a credential" with call sites that were written against `all()`'s older promise that
an empty array meant an empty library. Neither change is wrong alone.

**"Something the split introduced."** F4, F5 and F8 are all new with the split and, as the brief
predicted, nobody but the implementing agent has read them.

**"A cause that has moved rather than gone."** The third cross-cutting cause — "the account-change
forget list is hand-maintained and has never been complete" — was fixed by making the library refuse
at source, which is the right shape. But F7 shows the *same* pattern one layer down: the ledger's
own forget list (`v11`'s DELETE, `clear()`, `salvage`'s `readerTables`) is three hand-maintained
lists of the same four tables, and they already disagree.
