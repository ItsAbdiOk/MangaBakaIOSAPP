# Data sources on the series page (and elsewhere)

One row per section. "Section" follows `SeriesDetailView.Section`
(`MangaBaka/Features/Detail/SeriesDetailView.swift:211-212`): stats, synopsis,
cast, tags, credits, releases, volumes, editions, siblings, onwardRows,
categories, trackers.

| Reader sees (on-screen header) | Comes from | Licence / terms | Credit shown | Cache | Empty/failed copy |
|---|---|---|---|---|---|
| No header (stats strip) | MangaBaka `/v1/series/{id}` (`SeriesRepository.swift:873-876,891`), `APIClient.swift:445` for base URL | MangaBaka Data License, CC BY-NC-SA 4.0 for MangaBaka-original fields (`docs/licences.md`) | none — MangaBaka is the app's own data host, not a third party needing a per-section credit | 6h, one bundle with `extras` (`SeriesRepository.swift:779-786`) | Section suppressed; `pageFailure` surfaces a page-level `StaleBar` instead (`SeriesDetailView.swift:229-239`) |
| No header (synopsis) | Same `/v1/series/{id}` `extras.full` leg | Same as above | none | 6h, same bundle | Same as above |
| "Characters" (`CharacterRow.swift:73,82,174`) | MangaBaka series payload (no separate endpoint found — cast rides the `full` leg) | MangaBaka Data License | none | 6h | Not traced separately from `full`'s own failure path — no distinct empty copy found in `CharacterRow.swift` |
| "Also known as" (`AlternativeTitles.swift:35`), tag chips (`DetailTagSections.swift:147` only has spoiler-count text, no section title text found) | MangaBaka `TagTaxonomy.json` (bundled, 2,686 rows) + series payload | **CC BY-NC-SA 4.0** (`docs/licences.md`, MangaBaka Data License §3) | none in-view; taxonomy attribution covered by the app-wide MangaBaka credit, not a per-row one | Bundled at build time, not fetched | Untraced — no explicit "no tags" copy located |
| "+N more" (`DetailCredits.swift:315`) | MangaBaka series payload (`full` leg) | MangaBaka Data License | none | 6h | No distinct empty copy found |
| "Releases" (`ReleaseSection.swift:66,102`), "Estimating" / "Estimated next" (`DetailScheduleBlock.swift:110,141`) | Webtoons per-series RSS (`WebtoonsFeedClient.swift`, `https://www.webtoons.com/{lang}/{genre}/{slug}/rss?title_no=N` per `docs/sources/webtoon-episodes.md`) and MangaUpdates `GET /v1/series/{id}` cadence (`MangaUpdatesClient.swift:34`, `MangaUpdatesCategories.swift`) | Webtoons: no stated licence/attribution condition, `robots.txt` allows `/rss` (`docs/licences.md`). MangaUpdates: credit mandatory per their Acceptable Use Policy | **None discharged on screen for either.** Webtoons: the series-page link via `onOpen` is the closest thing to a credit. MangaUpdates: **no Settings/attribution row exists yet** — open item in `docs/licences.md` | Webtoons 7d (`WebtoonsFeedClient.swift:14`); MangaUpdates cadence 7d (`MangaUpdatesCategories.swift:129`) | "This series has no confirmed schedule yet" not found verbatim; `ReleaseSection.swift:9,18` document that `.none` renders nothing at all rather than an empty box, to avoid implying "no releases exist" |
| "Volumes" (`VolumesSection.swift:63`, "Checking Apple Books…" `:73`) | Apple Books/iTunes Search API (`AppleBooksClient.swift`, `https://itunes.apple.com/search`) | Apple's iTunes Search API terms (not separately filed in `docs/licences.md` beyond the client's own comments) | none in-row beyond Apple's own store branding; a not-in-your-store variant reads "Not sold in your store. Covers and volume count only." (`AppleVolumesRow.swift:61`) | 7d (`AppleBooksClient.swift:13`) | `isCheckingStore` shows "Checking Apple Books…" while pending (`VolumesSection.swift:73`); a completed empty state shows no row at all, by design (`VolumesSection.swift:115-122`) |
| "Editions" (`DetailEditions.swift:27`), "Official" (`:74`) | MangaBaka `extras.editions` (collections) leg (`SeriesRepository.swift:877-880`) | MangaBaka Data License | none | 6h | No distinct empty copy located |
| "Volumes on record" (`EditionShelvesSection.swift:89`), "Checking catalogues…" (`:94`) | Anime News Network Encyclopedia API (`ANNClient.swift`, `https://cdn.animenewsnetwork.com/encyclopedia/api.xml`), Open Library editions (`OpenLibraryEditions.swift`, `https://openlibrary.org/isbn/{isbn}.json` and `/works/{key}/editions.json`), Open Library covers (`OpenLibraryCovers.swift`, `https://covers.openlibrary.org/b/isbn/{isbn}-L.jpg`), National Diet Library Search (`NDLClient.swift`, `https://ndlsearch.ndl.go.jp/api/sru`) | ANN: **per-entry backlink mandatory**, discharged (`docs/licences.md`). Open Library: no licence named, attribution shown by choice. NDL: credit mandatory, commercial use needs prior application — decided non-commercial 2026-09-14, no application filed (`docs/licences.md`) | ANN: per-row `sourceLink`, row withheld if absent (`EditionShelvesSection.swift:18-21`). Open Library: `BookEdition.Source.credit` → "Edition data from Open Library" (`BookEdition.swift:29-34`). NDL: `BookEdition.Source.credit` → "国立国会図書館サーチ" (`BookEdition.swift:29-34`). Group credit line built in `creditLine(for:)` (`EditionShelvesSection.swift:285-289`) | ANN 7d (`ANNClient.swift:52`); Open Library editions 7d (`OpenLibraryEditions.swift:96`); Open Library covers 30d (`OpenLibraryCovers.swift:33`); NDL 24h (`NDLClient.swift:41`) | "Checking catalogues…" while pending (`EditionShelvesSection.swift:94`); resolved-empty text is reason-specific: "No catalogue lists a dated volume ahead — which is not the same as none coming." / "These catalogues have no record of this series." (`:192-193`) |
| "Also exists as" (`SeriesSiblingsSection.swift:21`), "Not on MangaBaka" (`:84`) | Bundled Wikidata extract (`WikidataIdentity.json.gz` → `WikidataIdentityTable.swift`, `siblings(for:)` at `:146`) | **CC0 1.0** — public domain, no attribution required (`docs/licences.md`) | A Settings credit exists as a courtesy, not an obligation (`docs/licences.md`); no in-row credit found | Bundled at build time, rebuilt per release; not fetched live | "Not on MangaBaka" for a sibling with no MangaBaka entry (`SeriesSiblingsSection.swift:8-9,84` — absence is documented to mean nothing, not "does not exist") |
| "Related" (`DetailOnwardRows.swift:108`), "Similar by description" (`SeriesDetailView.swift:17`) | Two sources feeding this row group: MangaBaka `similar`/`alsoLike` feeds (`SeriesDetailView.swift:565-566`, 24h TTL, `SeriesRepository.swift:353-359`) **and** the bundled offline index/embeddings (`OfflineCatalogue.swift`, `EmbeddingIndex.swift` — 19,203-series Int8-quantised vectors, `MangaBaka/Resources/OfflineEmbeddings.bin`) for the on-device "similar by description" fallback (`DetailOnwardRows.swift:14,69,222`) | Live feeds: MangaBaka Data License, CC BY-NC-SA 4.0. Offline embeddings: same licence for MangaBaka-original fields; **which model produced the vectors could not be determined** — flagged unresolved in `docs/licences.md` | none | Feeds: 24h. Offline index/embeddings: bundled, not time-cached | No distinct empty copy located for this row group |
| "What it's like · MangaUpdates" (`DetailCategories.swift:132`) | MangaUpdates `GET /v1/series/{id}` categories (`MangaUpdatesClient.swift`, `https://api.mangaupdates.com/v1`) | **Credit mandatory** per MangaUpdates Acceptable Use Policy (`docs/licences.md`) | Header names the source directly ("· MangaUpdates"), but `docs/licences.md` still records the obligation as **not yet discharged** by a Settings/attribution row — the header text may or may not be judged sufficient; left as recorded | 7d (`MangaUpdatesCategories.swift:129`) | Doc comment says same loading/loaded/empty/failed shape as `ContinuationsRow` (`DetailCategories.swift:6`); no literal empty string located |
| "Scores elsewhere" (`TrackerScores.swift:80`) | Not traced to a specific client file in this pass — likely rides the MangaBaka `extras` bundle or a tracker-specific source not covered by the eight named in this brief | Untraced | Untraced | Untraced | Untraced |

## Requests per cold series open

From `docs/reviews/detail-page-budget.md` §1-2: **9 MangaBaka requests** on a
cold open (`similar`, `alsoLike`, and the six `extras` legs — `links`,
`news`, `relationships`, `full`, `editions`, `works` — plus `/images`), **0**
on a warm open inside the 6h/24h caches. Third-party requests (ANN, Open
Library, NDL, Apple Books, MangaUpdates, Webtoons) are a **separate pool**,
7-9 more per open by that document's count, gated independently per host with
no shared budget against MangaBaka's own 180/min limit.

## Notes on what could not be traced

- **"Scores elsewhere"** (`TrackerScores.swift:80`) has no client file among
  the eight named sources that obviously supplies it — not traced to an
  endpoint, licence, credit, cache, or empty-state copy in this pass.
- Several MangaBaka-only sections (cast, tags-header, credits "+N more",
  editions header) have no distinct **empty/failed copy** in the same file —
  they may simply not render when their leg of `extras` is empty, which
  wasn't independently confirmed.
- **MangaUpdates credit**: `docs/licences.md` explicitly records this as an
  open, undischarged obligation (no Settings row), even though the
  "What it's like · MangaUpdates" header names the source on screen. Worth a
  decision on whether the header counts, or whether the Settings row still
  needs to ship.
