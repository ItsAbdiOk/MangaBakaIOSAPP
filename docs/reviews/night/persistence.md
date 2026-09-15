# Night review — `persistence` slice

Read-only. I changed nothing. Files: `AppDatabase*.swift`, `LibrarySnapshot*.swift`,
`WidgetSnapshot*.swift`, `MangaBakaWidgets/*`, the snapshot write in
`RootView+Session.swift`, and their tests. Read cold, 2026-09-15. Nothing built or run;
every claim below is by reading, and each says so where it matters.

## The five questions

**1. Can `moveLibraryCacheToCacheFile` run against a test in-memory queue and misbehave?**
Not today. Its only production caller is `finishOpening` (`AppDatabase.swift:151`), reached
from `onDisk` and `onDiskResettingIfCorrupt`, both of which open two distinct on-disk pools.
`inMemory()` goes through `init(writer:)` (`:64-68`), which never calls it. Every test that
calls it directly (`LibraryCacheMoveTests:172,226,269`) passes an on-disk pool. The one
shape that *would* misbehave: the single-file `init(writer:)` mode, where `cacheWriter ===
libraryWriter`, combined with a caller passing that file's own path as `cachePath` — SQLite
attaches the same file as `cache`, the copy REPLACEs a table into itself, verify passes, and
the drop then removes the only copy. Nothing does this; there is also nothing stopping it
(see finding 6).

**2. Is `VACUUM main` safe with a WAL pool and an attached database?** Yes, by reading:
`VACUUM schema-name` is supported since SQLite 3.15; it runs outside any transaction
(`writeWithoutTransaction`, and the drop's `inTransaction` has committed at `:313`); WAL
lets pool readers continue; every table in the reader's file has an explicit primary key,
so rowid renumbering touches nothing; `LibraryCacheMoveVacuumTests` proves the freelist
reaches zero on disk. Two things it is not: it is not retried (finding 4), and it is not
measured at device size (finding 5). Small aside: the reader's `-wal` grows to roughly the
post-vacuum live size (~2 MB at the measured 560 live pages) and SQLite does not shrink it
without `journal_size_limit`; that sidecar is in the backup. Not worth a change.

**3. Can a reader open the app mid-move and read an empty library twice?** Not within one
launch: `finishOpening` runs synchronously inside `AppServices.init` before any `AppDatabase`
exists, so no `LibrarySnapshot` can read during the move. Across two launches, yes, and
worse than empty — see finding 1: a failed first copy leads to a walk, and the retry then
overwrites that walk with the older rows.

**4. Does the widget's decoder tolerate every field the app can write?** Yes. Every key the
app's synthesized `encode(to:)` emits (`WidgetSnapshot.swift:86-88`, `:19-47`, `:55-79`) has
a same-named field in `WidgetSnapshotData` (`:16-49`); the two nil-able fields (`due`,
`sourceURL`, `coverURL`) are Optional on the widget side, so an omitted key decodes;
`nextVolumes` is `decodeIfPresent` on both sides; both coders are `.iso8601`
(`WidgetSnapshot.swift:153-163`, `WidgetSnapshotData.swift:86-87`). The contract tests
decode with the *real* widget type compiled into the test target (`project.yml:171-180`;
`WidgetSnapshotTests:25-57`, `NextVolumeSnapshotTests:210-263`). An old extension reading a
new file ignores the extra key. The only shape not tested is a `nextVolumes` row inside the
`WidgetSnapshotTests` fixture (`:141-157` carries none); the other suite covers it.

**5. Is `.background`/`Sendable` correct in `CoverLoader`?** There is no `.background` in
`CoverLoader.swift` — no task priority, no `Task.detached`; the question may be about a
version that no longer exists. Sendable: the child task captures `session` (Sendable),
`url`, `seriesID`, and `thumbnailSize` (`:70-77`); it returns `UIImage?`, which UIKit marks
Sendable; `WidgetCoverRow: Sendable` (`:97`) keeps the generic row out of the closure, as
the comment at `:67-69` says. The `Completion` box (`SeriesWidgetEntry.swift:100-102`) is
`@unchecked Sendable` around a non-Sendable closure — a documented hole resting on
WidgetKit's "any thread" promise, and I have nothing against it. Compiles under
`SWIFT_STRICT_CONCURRENCY: complete` / Swift 6 (`project.yml:31-32`), which is the real check.

## Findings

### 1. The retry copies stale rows over a fresh walk
- **What** — after a failed or interrupted first attempt, the next launch's
  `INSERT OR REPLACE` overwrites the cache file's freshly-walked library with the older
  copy from the reader's file, metadata stamp included.
- **Where** — `AppDatabase+Split.swift:267-277` (the claim that the source "is the
  authoritative copy: until this ran, every build read the library cache from the reader's
  file") and `:297-299`; `LibrarySnapshot.swift:49-56, 339-358` (the build that ran the
  failed attempt already reads and writes the cache file).
- **Why it matters** — launch 1: the copy throws (`SQLITE_FULL` mid-way through 24.7 MB is
  not exotic, nor is a kill) → app walks, 13 requests, writes 945 fresh rows + `cachedAt =
  now` into the cache file. Launch 2: `alreadyCopied` is false → REPLACE puts the pre-upgrade
  rows and the pre-upgrade `cachedAt` back over them → verify, mark, drop. The reader now
  sees a library up to days old (rows they removed on the website are back) until
  `readCache()` calls it stale and walks again — a second 24.7 MB download. Not a loss of
  user data; a wasted walk and a stale screen. The doc comment says the opposite.
- **Effort** — a function: before copying, compare `libraryMetadata.cachedAt` on both sides
  and skip straight to mark+drop when the cache file's is newer (or when it has a metadata
  row at all and the reader's does not). `interruptionLosesNothing` should then gain a step
  that writes to the cache file between the two launches, because today's walk (`:158-198`)
  never exercises a cache file that changed in between.
- **Confidence** — certain by reading; not run.

### 2. A signed-out launch clears one widget tile of three
- **What** — the `needsAccount` branch blanks `pickBackUp` and leaves `nextVolumes` and
  `dueThisWeek` from the previous account on the Home Screen, deep links included.
- **Where** — `RootView+Session.swift:268` (`WidgetSnapshot.write(pickBackUp: [])`);
  `WidgetSnapshot.swift:183-185` (write merges, so a nil list is kept as-is).
- **Why it matters** — both other lists are derived from the library
  (`WidgetSnapshot+NextVolume.swift:99`, `ScheduleModel.swift:426`), so they are exactly
  what item 12 said must not survive a sign-out. The account-change path calls `clear()`
  (`:206`); this path — token removed elsewhere, 401 — predates `nextVolumes` and was not
  widened when the third tile arrived.
- **Effort** — a line: `WidgetSnapshot.clear()`.
- **Confidence** — certain.

### 3. `nextVolumeCandidates` reintroduces the per-entry launch cost this project already measured out
- **What** — one actor hop, one *synchronous* SQLite read and one whole-`SeriesExtras` decode
  per reading/rereading/paused library entry, on every launch.
- **Where** — `WidgetSnapshot+NextVolume.swift:99-102`; `SeriesRepository.swift:797-799` →
  `SeriesRepository+Cache.swift:24-33` (sync `read`). The project's own record of why this
  is bad is at `SeriesRepository+Cache.swift:37-41`: "939 actor hops on the launch path, each
  its own SQLite read and a whole `SeriesExtras` decode" — fixed for reminders with
  `cachedExtrasLinks(for:)` and one `WHERE seriesId IN`.
- **Why it matters** — on the measured 945-row library, several hundred serialised hops on
  the repository actor at launch, and the sync read holds the actor's thread on SQLite for
  each. Not on the main thread, but it delays every other repository ask during launch.
  I did not measure it; the earlier fix's own comment is the evidence it is worth measuring.
- **Effort** — a function: a `cachedExtrasVolumes(for ids:)` sibling that decodes only the
  `volumes` key, the same shape as `cachedExtrasLinks`.
- **Confidence** — likely (pattern certain; cost not measured by me).

### 4. The VACUUM runs exactly once and is never retried
- **What** — `VACUUM main` only runs in the same call as the drop; a kill or a throw between
  the drop's commit (`:313`) and the VACUUM (`:322`) leaves the freelist full forever, because
  `present` is empty on every later open (`:294-295`) and the function returns early.
- **Where** — `AppDatabase+Split.swift:308-324`; the comment at `:319-320` ("Once, here,
  because `present` is empty on every later open") records the mechanism and not the hole.
- **Why it matters** — the measured saving (3,585 of 4,145 pages, 17 MB) is the whole point
  of the move; a device that hits this window keeps paying it into every backup. And
  `finishOpening` logs a VACUUM failure as "Library cache move failed, retrying next launch"
  (`AppDatabase.swift:153`) when nothing will retry.
- **Effort** — a line: on the `present.isEmpty` path, `VACUUM` when `PRAGMA
  freelist_count` exceeds a stated threshold (label it a guess), or record "vacuumed" beside
  the marker.
- **Confidence** — certain by reading; the window is narrow.

### 5. The device-sized move is unmeasured and on the main thread
- **What** — copy 24.7 MB across two files, an `EXCEPT` over both copies, a drop and a
  VACUUM, synchronously inside `AppServices.init`, once per device.
- **Where** — `AppServices.swift:144, 370` (`Signposts.measure("Database open")`);
  `AppDatabase+Split.swift:171-196, 321-323`. The tests use three rows (`LibraryCacheMoveTests:36-49`)
  or three 64 KB blobs (`LibraryCacheMoveVacuumTests:39-45`).
- **Why it matters** — the launch watchdog is the failure mode, and the number that says
  whether this is 300 ms or 8 s on a real file does not exist. The "Database open" signpost
  already brackets it; the measurement is one upgrade launch on the real simulator file.
- **Effort** — a measurement, not a change, unless the number is bad.
- **Confidence** — worth checking.

### 6. Nothing stops `cachePath` from being the reader's own file
- **What** — `moveLibraryCacheToCacheFile` and `splitReaderTables` attach whatever path
  they are given; the single-file `init(writer:)` mode makes "both roles, one file" a real
  shape in this codebase.
- **Where** — `AppDatabase+Split.swift:289-290, 85-89`; `AppDatabase.swift:60-68`.
- **Why it matters** — see question 1: same-file attach, self-copy, verify passes, drop
  removes the only copy. Not reachable today.
- **Effort** — a line: refuse when `cachePath` equals the writer's `path`.
- **Confidence** — worth checking (a guard against a future caller, not a live bug).

### 7. `schemasMatch` stopped covering the two tables that moved
- **What** — the declaration-drift test loops `readerTables`, and `libraryEntry` /
  `libraryMetadata` left that list on 2026-09-14.
- **Where** — `LibrarySplitTests.swift:238-241`; `AppDatabase+Schema.swift:222-225, 237`.
- **Why it matters** — the runtime `copyPlan` check (`AppDatabase+Split.swift:200-213`)
  catches a column-*set* difference; a type or constraint change on one side (say
  `payload BLOB` → `TEXT` in L1 only) passes both the runtime check and this test.
- **Effort** — a line: `readerTables + libraryCacheTables`.
- **Confidence** — certain.

### 8. The version pair is spelled twice
- **What** — `MARKETING_VERSION: "1.1.0"` and `CURRENT_PROJECT_VERSION: "1"` appear in both
  the app and the widget target, with a comment that iOS refuses an extension whose pair
  differs from its host's.
- **Where** — `project.yml:107-108, 159-160`; CI's sed (`ci_pre_xcodebuild.sh:47`) happens
  to hit both lines, the marketing version is bumped by hand.
- **Why it matters** — the charter's duplicated-constant pattern; the failure is an install
  refused on the device after a one-sided bump.
- **Effort** — a line: hoist both into the top-level `settings`.
- **Confidence** — certain.

## Charter sweep, briefly
- Force-unwraps: none in the slice (grep of the nine production files).
- `try?` around decodes: `readCache` (`LibrarySnapshot.swift:306-327`) guards the gap with a
  row-count check; `WidgetSnapshotData.read()` and `CoverLoader` fall to a placeholder by
  design and say so. Nothing indistinguishable from "empty" that matters.
- Underived constants: all labelled — `pickBackUpThreshold`, the 60/6 in `+NextVolume`,
  `staleAfter`, `thumbnailSize`, the 10 s timeout, `WidgetRefresh.interval`.
- Doc comments describing absent callers: `libraryCacheMoveHasCompleted` is read only by
  tests, and says nothing else. `NextVolumeEntry.sourceURL` and the ANN `Link` branch
  (`NextVolumeWidget.swift:157-164`) are shape-only and say so at `:153-156`.
- Copy on screen: "The next volume due for series you've opened recently." and the empty
  message at `NextVolumeWidget.swift:139` match the measured coverage. No overclaim found.

## Done well, with the same standard
- `interruptionLosesNothing` (`LibraryCacheMoveTests:158-198`) is parameterised over every
  `SplitStep` against real files, and the split's twin does the same — the kind of test
  that would have caught a drop-first ordering.
- The contract test compiles the extension's own decoder into the app's test bundle
  (`project.yml:171-180`) instead of round-tripping one type through itself; the comment
  records the day it did the weaker thing and why that passed.
- Measurements with dates and controls throughout: the freelist count
  (`LibraryCacheMoveVacuumTests:6-10`), the four-agent `curl` matrix with `api.mangabaka.org`
  as the control (`CoverLoader.swift:38-47`), the `keyNotFound` experiment behind the
  hand-written decoders (`WidgetSnapshot.swift:109-121`).
- Every test states what it fails with on the old code, and the ones whose honest answer is
  "a compile error, which proves nothing" say exactly that (`LibraryCacheMoveTests:153-157`).
- The `SELECT *` positional-copy hazard (`AppDatabase+Split.swift:119-141`) is reasoned
  through against SQLite's `EXCEPT` semantics and labelled "not run".
