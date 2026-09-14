import Foundation
import os

/// The bundled Wikidata identity table: what format a series is, what its
/// titles are in English and its own language, and what the same story looks
/// like in the other formats.
///
/// **Why this exists.** The app shipped a bug where untagged light novels
/// filled a comic shelf. Every other candidate measured on 2026-09-14
/// (`docs/sources/bibliographic.md`) answers "is this a manga or a light
/// novel" by guessing from a title or a fan-curated tag. Wikidata answers it
/// *structurally*: The Apothecary Diaries is three separate, separately typed
/// items — `Q106090656` manga series, `Q48751907` light novel series,
/// `Q106090452` novel series — and `P31` says which is which.
///
/// **What it is not: a volume-date source.** Measured 2026-09-14: per-volume
/// dates exist for 171 of 18,202 Wikidata manga series and per-volume ISBNs
/// for none of the five test series. Volume dates come from MangaBaka's own
/// `/v1/series/{id}/works` (100 % dated + ISBN on 5 of 5). Nothing in this
/// file should ever grow a release date.
///
/// **How far it reaches, measured 2026-09-14** against live
/// `/v1/series/search` and `/v1/series/{id}`, matching on exact ids only
/// (MangaBaka `P14262`, AniList `P8731`, MangaUpdates `P11149` — never on a
/// title):
///
/// | Sample | n | Matched |
/// |---|---|---|
/// | The 100 most popular series | 100 | **90 %** |
/// | Around popularity rank 2,000 | 50 | 48 % |
/// | Around popularity rank 6,000 | 50 | 20 % |
/// | Around popularity rank 12,000 | 50 | 14 % |
/// | **Uniform random draw from the bundled offline index's 19,300** | 60 | **25 %** |
///
/// So: a quarter of the catalogue by row, but nine in ten of what a reader
/// actually opens. The 60-row random sample is small — ±11 points at 95 % — and
/// the popularity strata above are what give it shape. `coverage()` ships the
/// build-time counts so a caller can see this rather than assume it.
///
/// **`nil` means "not in the table", never "not a comic".** A caller that
/// treats an absent answer as a negative will hide three quarters of the
/// catalogue. `WikidataFormat.other` is the *positive* "Wikidata knows this
/// and does not call it a book".
///
/// An actor, like `OfflineCatalogue`, and lazier than it on purpose: review
/// flagged `OfflineIndex` for decompressing 1.5 MB on the launch path and
/// holding it forever. This file is 451 KB gzipped and is not touched until
/// something actually asks a question — no `warm()`, nothing on the launch
/// path. A reader who never opens a series page never pays for it.
actor WikidataIdentityTable {
    private let resourceName: String
    private let resourceExtension: String
    private let bundle: Bundle

    private var state: LoadState?

    private static let logger = Logger(
        subsystem: "dev.abdirahmanmohamed.mangabaka", category: "wikidataIdentity"
    )

    /// The one wire shape this reader understands. Bumped by the generator's
    /// `WIRE_VERSION`. Checked rather than decoded-and-ignored, the mistake
    /// `OfflineCatalogue` had to be fixed for (review F11): a version-2 export
    /// would otherwise decode to field names that mean something else.
    static let supportedVersion = 1

    private struct Wire: Decodable {
        let version: Int
        let built: String
        let counts: WikidataCoverage
        let rows: [WikidataIdentity]
    }

    private struct LoadState {
        let rows: [WikidataIdentity]
        /// Key → index into `rows`, so the row bodies are stored once rather
        /// than three times over.
        let byMangaBakaID: [Int: Int]
        let byAniListID: [Int: Int]
        let byMangaUpdatesID: [String: Int]
        let byQID: [Int: Int]
        let built: String
        let counts: WikidataCoverage?

        static let empty = LoadState(
            rows: [], byMangaBakaID: [:], byAniListID: [:], byMangaUpdatesID: [:],
            byQID: [:], built: "", counts: nil
        )
    }

    init(
        resourceName: String = "WikidataIdentity",
        resourceExtension: String = "json.gz",
        bundle: Bundle = .main
    ) {
        self.resourceName = resourceName
        self.resourceExtension = resourceExtension
        self.bundle = bundle
    }

    // MARK: - Lookup

    /// The identity row for a MangaBaka series, or nil if the table does not
    /// carry it — which, per the coverage table above, is the common case for
    /// an unpopular series and means nothing about what the series is.
    ///
    /// Tried in order of how exact the join is: MangaBaka's own id first (only
    /// 212 Wikidata items carry `P14262` as of 2026-09-14, but where it exists
    /// it is unambiguous), then AniList (8,178 items, the workhorse), then
    /// MangaUpdates (4,001). No title matching at any step.
    func identity(for series: Series) -> WikidataIdentity? {
        let loaded = ensureLoaded()
        if let index = loaded.byMangaBakaID[series.id] { return loaded.rows[index] }
        if let raw = series.source?["anilist"]?.id, let aniList = Int(raw),
           let index = loaded.byAniListID[aniList] {
            return loaded.rows[index]
        }
        if let mangaUpdates = series.mangaUpdatesID, let index = loaded.byMangaUpdatesID[mangaUpdates] {
            return loaded.rows[index]
        }
        return nil
    }

    /// What kind of work this is, per Wikidata. Nil when the table has never
    /// heard of the series — the volumes shelf and the Apple Books matcher
    /// must fall back to whatever they did before rather than assume.
    func format(for series: Series) -> WikidataFormat? {
        identity(for: series)?.format
    }

    /// The same story in its other formats: the light novel a manga adapts,
    /// the manga a novel became. Transitive within an adaptation component,
    /// so the Apothecary manga sees both the light novel and the novel.
    ///
    /// This is the half that stops the Apple Books matcher buying a light
    /// novel when the reader asked for the comic — the sibling is the thing
    /// it must *not* offer, and it can only know that if it can name it.
    func siblings(of identity: WikidataIdentity) -> [WikidataIdentity] {
        let loaded = ensureLoaded()
        return identity.siblingQIDs.compactMap { qid in
            loaded.byQID[qid].map { loaded.rows[$0] }
        }
    }

    func siblings(for series: Series) -> [WikidataIdentity] {
        guard let identity = identity(for: series) else { return [] }
        return siblings(of: identity)
    }

    /// Direct lookups, for callers holding a raw id and for tests.
    func identity(mangaBakaID: Int) -> WikidataIdentity? {
        let loaded = ensureLoaded()
        return loaded.byMangaBakaID[mangaBakaID].map { loaded.rows[$0] }
    }

    func identity(aniListID: Int) -> WikidataIdentity? {
        let loaded = ensureLoaded()
        return loaded.byAniListID[aniListID].map { loaded.rows[$0] }
    }

    func identity(qid: Int) -> WikidataIdentity? {
        let loaded = ensureLoaded()
        return loaded.byQID[qid].map { loaded.rows[$0] }
    }

    // MARK: - Provenance

    /// The export's own build date, e.g. "2026-09-14". Nil when the resource
    /// is missing or unreadable — a packaging bug, not a real "no date". Same
    /// shape as `OfflineCatalogue.builtDate()`, and for the same reason.
    func builtDate() -> String? {
        let loaded = ensureLoaded()
        return loaded.built.isEmpty ? nil : loaded.built
    }

    /// What the generator measured when it built the file. Shipped rather than
    /// recomputed because the whole point is that the reading code knows how
    /// far the table reaches.
    func coverage() -> WikidataCoverage? {
        ensureLoaded().counts
    }

    /// How many rows the table carries. Nil, not 0, when it could not be
    /// loaded — 0 would read as "this build's table is genuinely empty".
    func rowCount() -> Int? {
        let loaded = ensureLoaded()
        return loaded.built.isEmpty ? nil : loaded.rows.count
    }

    // MARK: - Loading

    private func ensureLoaded() -> LoadState {
        if let state { return state }
        let loaded: LoadState
        do {
            loaded = try load()
        } catch let error {
            // Collapsed to one log line for the same reason `OfflineCatalogue`
            // collapses its load errors: missing, unreadable, bad gzip and bad
            // JSON are one packaging bug from the caller's side, and the
            // underlying error is still printed here in full.
            Self.logger.error("Wikidata identity table unavailable: \(String(describing: error))")
            loaded = .empty
        }
        state = loaded
        return loaded
    }

    private enum LoadError: Error {
        case unreadable
        case unsupportedVersion(Int)
    }

    private func load() throws -> LoadState {
        guard let url = bundle.url(forResource: resourceName, withExtension: resourceExtension),
              let compressed = try? Data(contentsOf: url) else {
            throw LoadError.unreadable
        }
        let raw = try Gunzip.decompress(compressed)
        let wire = try JSONDecoder().decode(Wire.self, from: raw)
        guard wire.version == Self.supportedVersion else {
            throw LoadError.unsupportedVersion(wire.version)
        }

        var byMangaBakaID: [Int: Int] = [:]
        var byAniListID: [Int: Int] = [:]
        var byMangaUpdatesID: [String: Int] = [:]
        var byQID: [Int: Int] = [:]
        byMangaBakaID.reserveCapacity(wire.counts.withMangaBakaID)
        byAniListID.reserveCapacity(wire.counts.withAniListID)
        byMangaUpdatesID.reserveCapacity(wire.counts.withMangaUpdatesID)
        byQID.reserveCapacity(wire.rows.count)

        for (index, row) in wire.rows.enumerated() {
            // First wins throughout. Two Wikidata items occasionally claim the
            // same external id — usually a series and its own one-shot — and
            // rows are written in ascending QID order, so "first" is stable
            // across rebuilds rather than dictionary-order luck.
            byQID[row.qid] = byQID[row.qid] ?? index
            if let id = row.mangaBakaID { byMangaBakaID[id] = byMangaBakaID[id] ?? index }
            if let id = row.aniListID { byAniListID[id] = byAniListID[id] ?? index }
            if let id = row.mangaUpdatesID { byMangaUpdatesID[id] = byMangaUpdatesID[id] ?? index }
        }

        return LoadState(
            rows: wire.rows,
            byMangaBakaID: byMangaBakaID,
            byAniListID: byAniListID,
            byMangaUpdatesID: byMangaUpdatesID,
            byQID: byQID,
            built: wire.built,
            counts: wire.counts
        )
    }
}
