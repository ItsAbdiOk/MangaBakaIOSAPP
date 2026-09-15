# Night review — `shelf` slice

Read-only. I changed nothing in the project. Scope: `Core/Library/Owned*`, `Features/Scan/`,
`Core/Volumes/`, `Core/Editions/`, the four Detail files, and their tests. One measurement was
taken: a single NDL SRU request for `薬屋のひとりごと` at `maximumRecords=50` (the app's own page
size), saved to the scratchpad as `ndl-apothecary-50.xml`. Everything below marked *measured*
comes from that page or from reading the code. Not reviewed in depth: `AppleBooks*`,
`GoogleBooks*`, `ShelfVolume`, `OpenLibraryCovers` — they predate 2026-09-14 and `full2`
covers them.

Counts: 14 findings (3 certain-and-serious, 6 certain-minor, 5 worth checking), 6 things done
well.

---

## The two open issues

### A. NDL / Apothecary: "vol 13 and 14 twice" is not the 外伝 — it is `dcndl:edition`

- **What** — The duplicate 13/14 rows are the regular printing and the 特装版 (special
  edition) of the same volume; the parser never reads `dcndl:edition`, so both arrive as
  `volume=13`, same imprint, same publisher, different ISBN.
- **Where** — `NDLRecordParser.swift:206-220` (`flat`/`nested` tables — no `dcndl:edition`);
  `NDLQuery.swift:142-159` (`row()` has nowhere to put it).
- **Why it matters** — *Measured* on the live page: `薬屋のひとりごと. 13` ×2 (ISBN
  978-4-7575-9028-1 `ed=特装版小冊子付き`, and 978-4-7575-9027-4 `ed=—`), `. 14` ×2 likewise,
  and on the Shogakukan shelf vols 18–22 are *only* the 特装版 (their regular printings arrive
  as `R100000136` records with no imprint and no genre, and the imprint rule rejects them).
  ISBN dedupe cannot collapse two different books. `OwnedSummary` then says "of 9" for a
  shelf with 7 distinct volumes.
- **Fix** — Read `dcndl:edition` into `Record.edition`, carry it on `BookEdition` (one new
  optional), and in `BookEditionShelf.editionVolume` put a row with a non-nil edition note
  on its own `VolumeEdition` (`editionTitle: "\(publisher) · 特装版"`) rather than the plain
  shelf. The reader who owns the special edition still has a row to tick with the right
  ISBN, the plain shelf counts one row per volume, and the split is a fact the catalogue
  stated. Dropping the 特装版 instead would leave Shogakukan 18–22 with no row at all.
- **Effort** — a function across three files. **Confidence** — certain on the cause
  (measured); the fix is the recommended shape, not the only one.

### A′. The 外伝 grouping — same shelf because the group key is the *publisher*

- **What** — `薬屋のひとりごと外伝小蘭回想録. 1` shares imprint and publisher with the main
  manga, so it lands in the Square Enix shelf as a second "vol 1".
- **Where** — `BookEditionShelf.swift:54` (`editionTitle: row.publisher` is the whole group
  key via `VolumeEdition.id`, `VolumeEdition.swift:169`).
- **Why it matters** — "You own 12 of 13 · missing vol. 1" for a reader who owns the whole
  main run. The prefix admission in `NDLQuery.titleMatches` is right and must stay
  (Solo Leveling's forthcoming row is `…外伝　01`); the grouping is what is wrong.
- **Fix** — Derive the NDL *work title* by stripping the catalogued volume from the title
  (`dcterms:title` is `<work>. <dcndl:volume>` on every measured record; `normalise` both,
  drop the suffix). When the work title ≠ the queried title, append it to `editionTitle`
  (`"スクウェア・エニックス · 薬屋のひとりごと外伝小蘭回想録"`). Solo Leveling's 外伝 then gets its
  own shelf, and `VolumeEditionAnswer.forthcoming` still reads across every shelf
  (`VolumeEdition.swift:365`), so the forthcoming line is unchanged. The existing
  `NDLClientTests` prefix test keeps passing; add one asserting the 外伝 row's `editionTitle`.
- **Effort** — a function (`NDLQuery.row` + `BookEdition` gains `workTitle: String?`).
  **Confidence** — certain on the grouping; the strip rule is checked against 50 records,
  not against ONE PIECE.

### B. Owned key when a row's ISBN appears later

- **What** — A tick on an ISBN-less row is keyed `row:<edition.id>-<title>`; when the same
  book later carries an ISBN (the 近刊 record replaced by the catalogued one, Open Library
  filling in `isbn_13`, or a different catalogue winning the merge), the key becomes
  `isbn:…`, the tick vanishes, and the orphan row stays in the reader's file forever —
  counted by `OwnedVolumes.count()` in Settings' "erase N".
- **Where** — `OwnedVolumeKey.swift:26-37`; `OwnedVolumes.swift:32-37` (no reconciliation);
  `SeriesDetailView+Editions.swift:86-93` (`loadOwned` reads and never compares).
- **Why it matters** — *Measured*: the live page has an ISBN-less `R100000137` 近刊 row
  (`薬屋のひとりごと～猫猫の後宮謎解き手帳～ 22`, no ISBN, no date) that is admitted by imprint
  corroboration. That is exactly the row a reader ticks the week it arrives.
- **Fix** — Do not change the key. Add `OwnedVolumes.reconcile(shelves:for:)`, called from
  `loadEditions` after merge: for every current row *with* an ISBN, compute the key it would
  have had without one (`"row:\(edition.id)-\(title)"`); if that identity is owned, rewrite
  the DB row to the `isbn:` identity (keep `ownedAt`) and drop the orphan. Title and
  catalogue are the same on both sides of the swap in every case observed; a row whose
  title also changed is genuinely a different string and stays an orphan — say so in the
  doc comment. Also expose orphans in `count()`'s caller wording, or purge rows older than a
  year with no match; either is a product call.
- **Effort** — a function. **Confidence** — certain on the loss; likely on the fix covering
  the NDL case (title may differ between the 近刊 and catalogued record — the measured pair
  above *do* differ: `～…～ 22` vs `: … . 22`, so for NDL the reconcile would miss, and the
  honest answer is the sheet should not let a 近刊 row without an ISBN be ticked, or should
  key it on `dcndl:volume` + work title. Bring this to Abdi.)

---

## Certain, serious

1. **`.digital` and `.boxSet` sit on the same shelf as `.print` and are counted as volumes.**
   *Where* `VolumeEditionMerge.swift:237-239` groups by `VolumeEdition` only;
   `VolumeEdition.swift:144-152` says the enum exists so that "showing all three on one shelf"
   does not happen, and nothing acts on it. `OwnedSummary.swift:30` uses `shelf.volumes.count`.
   *Impact* One Piece via ANN has `(eBook n)` rows (`docs/sources/publishers.md:157`), so the
   shelf is GN 1, eBook 1, GN 2 … and "You own 14 of 232". Delicious in Dungeon reads
   "You own 14 of 15" with the 15th being the box set. *Fix* group on `(edition, format)`
   or filter to `.print` in `shown()` and count only `.print` in `OwnedSummary`. Effort: a
   function. Charter §3.

2. **NDL's page is 50 of 84 and the owned line calls it complete.** *Where*
   `NDLClient.swift:45` (documented "a view must not call the list complete");
   `OwnedSummary.swift:30-35` ("You own N of M · missing vol. …");
   `SeriesDetailView+Editions.swift:164` (`isPartial: false` unconditionally);
   `NDLRecordParser.swift:85-91` (`totalRecords` — computed, no production caller).
   *Measured*: page 1 holds Square Enix vols 1, 10–14 only; 2–9 are on page 2. The line
   would read "missing vol. 2–9" to a reader holding them. *Fix* have `volumes()` return
   `isPartial: totalRecords > records.count`, thread it into `EditionShelf`, and have
   `OwnedSummary.line` drop the "of M" and "missing" clauses on a partial shelf. Effort:
   a function across three files. Charter §3 and §5.

3. **ANN's `href` bypasses `SafeLink.web`.** *Where* `ANNRelease.swift:196`
   (`URL(string:)` straight from the attribute); rendered via `openURL` at
   `EditionShelvesSection.swift:320`. `BookEditionShelf.swift:106-116` routes both library
   sources through `SafeLink.web` and calls it "the app's one rule". A `javascript:` or
   custom-scheme href in a volunteer-edited XML feed would be opened. *Fix*
   `SafeLink.web(URL(string: $0))`. Effort: a line. Confidence: certain.

## Certain, minor

4. `NDLClient.swift:96` files "asked, every record filtered out" as `.notCatalogued`; merge
   then shows "These catalogues have no record of this series" (`EditionShelvesSection:193`)
   for a series NDL holds five records of. `BookEdition.swift:118-131` defines the two
   answers as distinct. Fix: `records.isEmpty ? .notCatalogued : .editions(rows)`. A line.
5. `NDLClient.swift:120` interpolates the title into CQL unescaped; a `"` in a MangaBaka
   `ja` title breaks the query, NDL returns a diagnostic, the parser finds zero records, and
   `.notCatalogued` is cached for 24 h. Strip or escape `"`. A line.
6. `NDLClient.swift:19,75` doc comments cite `matches(_:)` / `Query.matches`, which do not
   exist (`titleMatches`/`evidence`). Charter "a doc comment describing a caller that does not
   exist". A line each.
7. `SeriesSiblingsSection.swift:104-116` copies `loadSimilarByDescription`'s private stub
   "because that one is private". CLAUDE.md rejects fixing duplication by copying. Make the
   original an internal `static` and call it. A line.
8. `SeriesDetailView+Siblings.swift:14` cites "line 48"; it is line 49 today and will drift.
   Drop the number. A line.
9. `EditionShelvesSection.swift:372` `.accessibilityAddTraits(.isButton)` on a `Button` is
   redundant. A line.

## Worth checking

10. **Camera permission never prompted on first use.** `ISBNScanSheet.swift:149` checks
    `DataScannerViewController.isAvailable` *before* the `.notDetermined` branch at :156.
    Apple documents `isAvailable` as false until the user has granted camera access; if so,
    a first-time reader gets "The camera can't be used right now" and the system prompt
    never fires. Verify on a device with camera permission reset; if confirmed, move the
    `isAvailable` check after the authorisation switch. A line. Likely.
11. `ISBNScanner.swift:86-90` sets `@State` (via `onCouldNotStart`) inside
    `makeUIViewController`, i.e. during a view update — "modifying state during view
    update" at runtime. Wrap in `Task { @MainActor in … }`. A line. Likely.
12. `EditionVolume.id` (`VolumeEdition.swift:216`) is `edition.id-(isbn13 ?? title)`; two
    Open Library rows with no ISBN, same title, same publisher (plausible on One Piece's 18
    editions; the measured Solo Leveling row `Solo leveling | 2012 | — | unknown` is one) give
    `ForEach` duplicate ids and a single `row:` owned key that ticks both. Worth checking
    against the One Piece OL response. A function if real.
13. `BookEditionShelf.swift:90-94` and `NDLQuery.swift:166`: `Int("１３")` (full-width) is
    nil, so a record like the measured `R100000038 … v=１３` would be unnumbered if it ever
    passed the filter. Run `NDLClient.Query.normalise` on `dcndl:volume` first. A line.
14. `PartialDate.swift:47` `isForthcoming` compares the *start* of the stated period: a
    month-precision `2026-10` stops being "announced" on 1 October while the book is due
    the 25th, and a year-precision `2026` is never forthcoming after 1 January. Compare
    against the period's end. A function. Low impact today — NDL and ANN dates measured
    were day-precision.

---

## Done well (same evidence standard)

- **The imprint-corroboration rule holds on 50 live records.** Every ヒーロー文庫 light-novel
  row (`. 10`–`. 14`, incl. the ドラマCD 限定特装版 ones) is rejected; every ビッグガンガン /
  サンデーGX row is admitted; the soundtrack, art book, mook and 調合書 are rejected. The doc
  at `NDLQuery.swift:25-53` predicted exactly this and stated its failure mode.
- **`OwnedVolumeKey` reasoning is right and tested against the real hazard**
  (`OwnedVolumesTests.swift:98-114` proves the key survives the catalogue flipping).
- **`ForthcomingVolume` has no "nothing is coming" case** (`VolumeEdition.swift:270-302`)
  and every piece of copy in `EditionShelvesSection.swift:190-197` respects it.
- **Fixtures have provenance**: both NDL files and the ANN file are saved verbatim with the
  request, date and `maximumRecords` recorded (`NDLClientTests.swift:7-16`,
  `ANNRelease.swift:6-11`). Charter §2 satisfied.
- **No force-unwraps** in any slice production file (grepped; `unsafeANNFallback` is a
  hard-coded literal behind `preconditionFailure`, matching the sibling clients).
- **`RequestSpacing.backOff` used everywhere**, `try?` around `Task.sleep` followed by an
  explicit cancellation check in all three new clients (`NDLClient:144-148`,
  `OpenLibraryEditions:237-241`, `ANNClient:157-161`).

## Unsure

- Whether `isAvailable` is false under `.notDetermined` (item 10) — could not fetch Apple's
  doc text; from memory of the WWDC22 session it is. Needs a device.
- Whether NDL's SRU accepts a `sortBy` that would put volumes in order and make page 1
  useful; not tried, to stay inside one request.

---

## Follow-up, 2026-09-15 (fix pass — not part of the review)

Fixed with tests: §A, §A′, Serious 1–3, Minor 4–9, Worth-checking 13 and 14, and the
reconcile half of §B (`OwnedVolumes+Reconcile.swift`, run after every merge). Not touched:
items 10 and 11 (`Features/Scan` was another agent's) and item 12 (needs the One Piece Open
Library response to know whether it is real).

### Needs Abdi

- **§B, the NDL 近刊 case.** Reconcile matches on the ISBN-less row's exact title. The
  measured 近刊 record is titled `薬屋のひとりごと～猫猫の後宮謎解き手帳～` and the catalogued one
  `薬屋のひとりごと : 猫猫の後宮謎解き手帳. 22`, so for that pair the tick is still lost.
  Options, each a product call: (a) do not let an ISBN-less 近刊 row be ticked; (b) key
  ISBN-less NDL rows on `dcndl:volume` + work title instead of the title string; (c) accept
  the loss. (b) is the one that keeps the tick and it changes `OwnedVolumeKey` for one
  source only.
- **Orphaned ticks in Settings' "erase N".** Ticks whose row never reappears still count.
  Either word the count as "N ticks (some may be for volumes no longer listed)" or purge
  rows older than a year with no match. Not done — both are wording or retention choices.
- **The 近刊 row has no publisher**, so it sits on a shelf of its own (`editionTitle` is the
  work title alone) beside Shogakukan's 1–17. Pre-existing; the fix would be to inherit the
  publisher from another row of the same work in the same page, which is a guess NDL did not
  make.
- **Solo Leveling's 外伝 shelf is named `KADOKAWA · 俺だけレベルアップな件外伝　01`** — the 近刊
  record has no `dcndl:volume`, so nothing says the `01` is a volume number and it stays in
  the work title. Stripping a trailing digit run when the volume field is absent would fix
  it and would also mangle any title that genuinely ends in a number. Left as is.
- **`xcodegen generate`** is needed: five new source files and one new fixture
  (`ndl-apothecary-diaries-50.xml`, 764 KB, the measured page verbatim).
