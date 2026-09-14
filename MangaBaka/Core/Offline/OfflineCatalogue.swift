import Foundation
import os

/// A series as the bundled offline index stores it — the top 20,000 by
/// popularity, one line each. Single-letter keys because the wire file is
/// 19,300 of these and every repeated key name costs real bytes gzipped.
struct OfflineIndexEntry: Decodable, Sendable, Equatable {
    let id: Int
    let title: String
    /// "Manga", "Manhwa" or "Manhua" in the export as of 2026-09-13.
    let kind: String
    /// First publication year.
    let year: Int?
    /// 0-100.
    let rating: Double?
    /// Popularity rank; 1 is the most popular. Matches `SortOrder`'s
    /// `popularity_asc` — ascending is "most popular first" here, not
    /// `popularity_desc`, which the live API sorts least-rated first (see
    /// `SortOrder.all`'s comment).
    let popularity: Int?
    /// "safe", "suggestive", "erotica", or similar.
    let contentRating: String?
    /// Publication status.
    let status: String?
    /// Tag ids, `TagTaxonomy`'s own ids (MangaBaka's `tags_v2`), genres
    /// included — the export does not separate the two.
    let tagIDs: [Int]

    /// The export's own single-letter keys (`t`, `k`, `y`, `r`, `p`, `c`, `s`,
    /// `g`) — every repeated key name costs real bytes across 19,300 rows,
    /// gzipped or not. Named properly here rather than living with `entry.t`
    /// and `entry.g` through the rest of this file.
    private enum CodingKeys: String, CodingKey {
        case id, title = "t", kind = "k", year = "y", rating = "r"
        case popularity = "p", contentRating = "c", status = "s", tagIDs = "g"
    }
}

/// One offline search result: a `Series` built entirely from the bundled
/// index, with no cover — that only exists once the API is reachable again.
/// One page of offline hits and how many the whole query matched.
struct OfflinePage: Sendable, Equatable {
    let hits: [OfflineHit]
    let total: Int
}

struct OfflineHit: Sendable, Equatable, Identifiable {
    let series: Series
    var id: Int { series.id }

    fileprivate init(_ entry: OfflineIndexEntry) {
        series = Series(
            id: entry.id,
            state: "active",
            mergedWith: nil,
            titles: [SeriesTitle(language: "en", traits: ["official"], title: entry.title, isPrimary: true)],
            cover: .empty,
            description: nil,
            authors: nil,
            artists: nil,
            status: entry.status,
            rating: entry.rating,
            // Lowercased to match the API's own `type` values ("manga",
            // "manhwa", "manhua"), which is what `allowsFormat` and the
            // filter chips compare against.
            type: entry.kind.lowercased(),
            contentRating: entry.contentRating,
            totalChapters: nil,
            finalVolume: nil,
            publishers: nil,
            anime: nil,
            source: nil,
            year: entry.year,
            ratingCount: nil,
            tags: nil,
            tagsV2: nil
        )
    }
}

/// The bundled offline catalogue: the top 20,000 series by popularity, with
/// just enough of each to filter by tag, genre, type, year and rating without
/// a single request. Built from a MangaBaka nightly dump, CC BY-NC-SA 4.0 —
/// see `MangaBaka/Resources/OfflineIndex.json.gz`'s own header for the exact
/// export date.
///
/// An actor rather than a plain struct: the gzip decode and JSON decode cost
/// roughly 200ms (measured against the real 1.4MB file on 2026-09-13, on the
/// simulator's host machine rather than a device — a guess for on-device
/// timing, not a measurement of it) and should happen once, off the main
/// actor, with every later call served from memory. A struct with a `static`
/// cache would work too, but would share that cache across every instance
/// forever, including in tests that want a fresh one per case.
actor OfflineCatalogue {
    private let resourceName: String
    private let resourceExtension: String
    private let bundle: Bundle

    private var state: LoadState?

    private static let logger = Logger(
        subsystem: "dev.abdirahmanmohamed.mangabaka", category: "offlineCatalogue"
    )

    private enum LoadError: Error {
        /// The resource is missing from the bundle, or unreadable, or not
        /// valid gzip, or not valid JSON for `Wire` — collapsed to one case
        /// because every one of those is the same packaging bug from the
        /// caller's point of view, and the underlying `Error` is still
        /// logged in full at the `catch` site.
        case unreadable
        /// `Wire.version` was decoded but was not the one shape this reader
        /// understands. Before this the field was decoded and never
        /// checked, so a version-2 export would decode to nonsense (wrong
        /// field meanings) or fail `Wire` decoding and read as "missing",
        /// either way silently (review F11).
        case unsupportedVersion(Int)
    }

    private struct LoadState {
        /// Popularity order (rank 1 first) — the default sort — computed
        /// once here instead of by every `filteredAndSorted` call. See
        /// `byScore` and `filteredAndSorted`'s doc for why keeping two
        /// pre-sorted arrays turns "filter then sort" into "filter" (review
        /// F15: unsorted, this was an O(n log n) sort over ~15,000 surviving
        /// rows on every page turn and every filter-panel keystroke).
        let entries: [OfflineIndexEntry]
        /// The same rows, sorted by rating descending — `Self.sorted`'s old
        /// `"score_desc"` branch, now computed once instead of per call.
        let byScore: [OfflineIndexEntry]
        /// "2026-09-13", the export's own `built` field. Empty when decoding
        /// failed, so `builtDate()` can tell "loaded but the field was blank"
        /// from "failed to load" apart — neither is expected to happen with
        /// the resource actually bundled, but a packaging mistake should read
        /// as an empty offline index, not a crash.
        let built: String
    }

    init(
        resourceName: String = "OfflineIndex",
        resourceExtension: String = "json.gz",
        bundle: Bundle = .main
    ) {
        self.resourceName = resourceName
        self.resourceExtension = resourceExtension
        self.bundle = bundle
    }

    /// How many series the bundled index carries. Nil, not 0, when it could
    /// not be loaded — 0 would read as "this device's index is genuinely
    /// empty", which the export never is.
    func totalCount() -> Int? {
        let loaded = ensureLoaded()
        return loaded.built.isEmpty ? nil : loaded.entries.count
    }

    /// Titles for a set of ids, for rows built from ids alone — the
    /// "Similar by description" cards resolve their neighbours here rather
    /// than with one request per id.
    func titles(for ids: [Int]) -> [Int: String] {
        let wanted = Set(ids)
        guard !wanted.isEmpty else { return [:] }
        var found: [Int: String] = [:]
        for entry in ensureLoaded().entries where wanted.contains(entry.id) {
            found[entry.id] = entry.title
            if found.count == wanted.count { break }
        }
        return found
    }

    /// The export's own build date, e.g. "2026-09-13". Nil when the resource
    /// is missing or unreadable — a packaging bug, not a real "no date".
    func builtDate() -> String? {
        let loaded = ensureLoaded()
        return loaded.built.isEmpty ? nil : loaded.built
    }

    // swiftlint:disable function_parameter_count
    /// Series matching `query`, honouring the same standing preferences
    /// `SeriesRepository.filterQuery`/`allowsFormat` apply online — including
    /// their "a missing field passes" rule, so a series the export could not
    /// classify is never hidden by a filter it cannot answer.
    ///
    /// - Parameters:
    ///   - allowedRatings: the reader's content-rating preference
    ///     (`ContentPreferences.queryValues`). Empty means no filter.
    ///   - allowedTypes: the reader's standing format preference
    ///     (`FormatPreferences.queryValues`). `query.types` overrides this
    ///     when the reader picked an explicit type in the filter sheet — the
    ///     same precedence `SeriesRepository.filterQuery`'s `overridingTypes`
    ///     documents, so choosing "novel" while novels are off in Settings
    ///     still shows novels instead of silently answering nothing.
    ///   - blockedTags: tag ids to exclude outright.
    ///   - limit/offset: paging, in place of the online API's `page`.
    ///
    /// Six parameters, deliberately: `query` carries the reader's own filters
    /// and the other five are the standing preferences `SearchModel` reads
    /// fresh on every call plus paging. Bundling them into a settings struct
    /// would hide exactly the "what does this depend on" list a caller needs
    /// to read at the call site, for a rule of thumb this call site does not
    /// actually violate the spirit of.
    func matches(
        _ query: SearchQuery,
        allowedRatings: [String],
        allowedTypes: [String],
        blockedTags: [Int],
        limit: Int,
        offset: Int
    ) -> [OfflineHit] {
        page(
            query, allowedRatings: allowedRatings, allowedTypes: allowedTypes, blockedTags: blockedTags,
            limit: limit, offset: offset
        ).hits
    }

    /// `matches` plus the size of the whole filtered set, which the filter
    /// pass already computed to slice a page from — so the heading's "N
    /// results" and an exact "is there a next page" cost nothing extra
    /// offline. Before this the model inferred the end from a short page
    /// and left the total unknown, to avoid a second 19,300-row filter that
    /// `count` would have spent (search review E F13, #52/#53).
    func page(
        _ query: SearchQuery,
        allowedRatings: [String],
        allowedTypes: [String],
        blockedTags: [Int],
        limit: Int,
        offset: Int
    ) -> OfflinePage {
        let filtered = filteredAndSorted(
            query, allowedRatings: allowedRatings, allowedTypes: allowedTypes, blockedTags: blockedTags
        )
        guard offset < filtered.count, limit > 0 else { return OfflinePage(hits: [], total: filtered.count) }
        let end = min(offset + limit, filtered.count)
        return OfflinePage(hits: filtered[offset..<end].map(OfflineHit.init), total: filtered.count)
    }
    // swiftlint:enable function_parameter_count

    /// How many series `query` would match, for the same reasons
    /// `SeriesRepository.count` exists: a lens row that wants a live number
    /// without downloading every row it describes.
    func count(
        _ query: SearchQuery,
        allowedRatings: [String],
        allowedTypes: [String],
        blockedTags: [Int]
    ) -> Int {
        filteredAndSorted(
            query, allowedRatings: allowedRatings, allowedTypes: allowedTypes, blockedTags: blockedTags
        ).count
    }

    // MARK: - Loading

    private func ensureLoaded() -> LoadState {
        if let state { return state }
        let loaded = Self.load(
            resourceName: resourceName, resourceExtension: resourceExtension, bundle: bundle
        )
        state = loaded
        return loaded
    }

    private static func load(resourceName: String, resourceExtension: String, bundle: Bundle) -> LoadState {
        do {
            guard let url = bundle.url(forResource: resourceName, withExtension: resourceExtension) else {
                throw LoadError.unreadable
            }
            let gzipped = try Data(contentsOf: url)
            let raw = try Gunzip.decompress(gzipped)
            let wire = try JSONDecoder().decode(Wire.self, from: raw)
            guard wire.version == 1 else { throw LoadError.unsupportedVersion(wire.version) }
            // Popularity ascending (rank 1 first) is the default — the same
            // "ascending is what a reader means by popularity" rule
            // `SortOrder.all` documents for the online path. "score_desc"
            // (by rating) is the only alternative offered offline; the
            // export carries nothing to answer "trending" or "latest" with,
            // and "random" would be a different shuffle on every page
            // rather than a stable order to page through — so exactly these
            // two orderings are worth precomputing (review F15).
            return LoadState(
                entries: wire.series.sorted { ($0.popularity ?? .max) < ($1.popularity ?? .max) },
                byScore: wire.series.sorted { ($0.rating ?? -1) > ($1.rating ?? -1) },
                built: wire.built
            )
        } catch {
            // A missing or corrupt bundled resource used to read as "offline
            // browse has nothing" with nothing in the console — `try?` three
            // times over, no logger — where `EmbeddingIndex` at least logs
            // once (review F11). Mirrors that shape.
            logger.error(
                """
                OfflineCatalogue failed to load bundled resource \
                \(resourceName, privacy: .public).\(resourceExtension, privacy: .public): \
                \(String(describing: error), privacy: .public)
                """
            )
            return LoadState(entries: [], byScore: [], built: "")
        }
    }

    private struct Wire: Decodable {
        let version: Int
        let built: String
        let source: String
        let series: [OfflineIndexEntry]
    }

    // MARK: - Filtering

    private func filteredAndSorted(
        _ query: SearchQuery,
        allowedRatings: [String],
        allowedTypes: [String],
        blockedTags: [Int]
    ) -> [OfflineIndexEntry] {
        let loaded = ensureLoaded()
        // The pre-sorted array to filter *from* — filtering with `.filter`
        // preserves the relative order of its input, so picking the
        // already-sorted-by-`query.sort` array up front turns "filter then
        // sort" into just "filter" (review F15). Before this, `entries` was
        // unsorted and every call sorted the survivors from scratch.
        let entries = query.sort == "score_desc" ? loaded.byScore : loaded.entries
        let ratings = Set(allowedRatings.map { $0.lowercased() })
        // An explicit type chosen in the filter sheet wins over the standing
        // preference — see this method's doc comment.
        let types = Set((query.types.isEmpty ? allowedTypes : query.types).map { $0.lowercased() })
        let statuses = Set(query.statuses.map { $0.lowercased() })
        let blocked = Set(blockedTags)
        let requiredTagIDs = Self.tagIDs(named: query.tags)
        let requiredGenreIDs = Self.tagIDs(forGenres: query.genres)
        // The same floor the wire has: one character is not a question here
        // either (`SearchQuery.minimumTextLength`).
        let text = query.askedText ?? ""

        let result = entries.filter { entry in
            passesRating(entry, allowed: ratings)
                && passesType(entry, allowed: types)
                && !entry.tagIDs.contains(where: blocked.contains)
                && passesStatus(entry, allowed: statuses)
                && passesRating(entry, minimum: query.minimumRating)
                && passesYear(entry, from: query.yearFrom, to: query.yearTo)
                && passesTags(entry, required: requiredTagIDs)
                && passesGenre(entry, required: requiredGenreIDs)
                && passesText(entry, needle: text)
        }
        // No `.sorted` here — `entries` was already the right order for
        // `query.sort` before filtering, and `.filter` preserves it.
        return result
    }

    /// Content rating: a missing field passes, matching
    /// `SeriesRepository.allowsFormat`'s own rule that an answer the export
    /// could not classify is never hidden by a filter it cannot honestly
    /// apply.
    private func passesRating(_ entry: OfflineIndexEntry, allowed: Set<String>) -> Bool {
        guard !allowed.isEmpty else { return true }
        guard let rating = entry.contentRating, !rating.isEmpty else { return true }
        return allowed.contains(rating.lowercased())
    }

    private func passesType(_ entry: OfflineIndexEntry, allowed: Set<String>) -> Bool {
        guard !allowed.isEmpty else { return true }
        return allowed.contains(entry.kind.lowercased())
    }

    private func passesStatus(_ entry: OfflineIndexEntry, allowed: Set<String>) -> Bool {
        guard !allowed.isEmpty else { return true }
        guard let status = entry.status, !status.isEmpty else { return true }
        return allowed.contains(status.lowercased())
    }

    private func passesRating(_ entry: OfflineIndexEntry, minimum: Int?) -> Bool {
        guard let minimum else { return true }
        guard let rating = entry.rating else { return false }
        // `Int(wholeOrClamped:)`, not `Int(_:)`. `rating` is decoded from the
        // bundled `OfflineIndex.json.gz`, which is outside the app in the
        // sense that matters: a NaN or an out-of-`Int` value there traps, and
        // this project's rule is that a `Double` the app did not compute does
        // not go through `Int(_:)` (work-list 53; `SpotlightIndex` and
        // `APIError.humanDuration` already follow it).
        return Int(wholeOrClamped: rating.rounded()) >= minimum
    }

    /// A series with no known year fails a year filter rather than passing it
    /// silently — unlike rating/type/status, "unknown year" is not a fair
    /// answer to "between 2010 and 2020": a reader who set that range wants
    /// series known to fall inside it.
    private func passesYear(_ entry: OfflineIndexEntry, from: Int?, to: Int?) -> Bool {
        guard from != nil || to != nil else { return true }
        guard let year = entry.year else { return false }
        if let from, year < from { return false }
        if let to, year > to { return false }
        return true
    }

    /// AND only. This used to honour a literal `tagMode == "or"`, which no
    /// path ever set on purpose and the wire never sends: measured
    /// 2026-09-13, `tag=Isekai&tag=Regression` answers 164 with no mode,
    /// with `tag_mode=or` and with `tag_mode=and` (`tag=isekai` alone is
    /// 7,116). Offline honouring "or" meant a lens saved with that flag
    /// answered a different question here than online.
    private func passesTags(_ entry: OfflineIndexEntry, required: [Int]) -> Bool {
        guard !required.isEmpty else { return true }
        return required.allSatisfy { entry.tagIDs.contains($0) }
    }

    /// Genres, resolved to the tag ids the export folds them into — see
    /// `tagIDs(forGenres:)`. AND, as the API does it: `genre=action`
    /// 31,025, `genre=romance` 100,947, both together 6,692
    /// (`/v1/series/search`, 2026-09-13). Before this existed a genre rode
    /// in `query.tags` and eleven of the 46 values (`slice_of_life`,
    /// `school_life`, …) matched no tag name, so a genre-only offline
    /// search silently returned the whole index (review, catalogue #2).
    private func passesGenre(_ entry: OfflineIndexEntry, required: [Int]) -> Bool {
        guard !required.isEmpty else { return true }
        return required.allSatisfy { entry.tagIDs.contains($0) }
    }

    /// Titles only — no author field exists in the export. Case- and
    /// diacritic-insensitive contains, labelled rough per the brief: this is
    /// not the live API's fuzzy `q` search, just a substring test.
    private func passesText(_ entry: OfflineIndexEntry, needle: String) -> Bool {
        guard !needle.isEmpty else { return true }
        return entry.title.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    /// Tag *names*, as `SearchQuery.tags` stores them, resolved to the ids the
    /// export keys its `g` array by, via the same bundled `TagTaxonomy` the
    /// tag picker uses. A name with no match (renamed, merged away) drops out
    /// rather than failing the whole filter.
    /// `nonisolated static` because `SearchQuery.queryItems` resolves the
    /// same names for the wire — see `SearchQuery.wireTagIDs`.
    nonisolated static func tagIDs(named names: [String]) -> [Int] {
        guard !names.isEmpty else { return [] }
        let byName = Dictionary(
            TagTaxonomy.bundled().map { ($0.name.lowercased(), $0.id) },
            uniquingKeysWith: { first, _ in first }
        )
        return names.compactMap { byName[$0.lowercased()] }
    }

    /// Genre *values* (`slice_of_life`, `sci-fi`), as `/v1/genres` and
    /// `SearchQuery.genres` spell them, resolved to the bundled tag whose
    /// name folds to the same string — lowercased, spaces to underscores.
    /// The export has no genre field of its own; its `g` array carries
    /// genres as tags. Checked 2026-09-13: all 46 live values fold to
    /// exactly one taxonomy name each ("Slice of Life" → 7, "Sci-Fi" → 1),
    /// none to two. `OfflineCatalogueTests.everyGenreResolves` holds that.
    /// `nonisolated static` so the test can ask without an actor hop.
    nonisolated static func tagIDs(forGenres values: [String]) -> [Int] {
        guard !values.isEmpty else { return [] }
        let byValue = Dictionary(
            TagTaxonomy.bundled().map { (Self.genreValue(for: $0.name), $0.id) },
            uniquingKeysWith: { first, _ in first }
        )
        return values.compactMap { byValue[$0.lowercased()] }
    }

    nonisolated private static func genreValue(for tagName: String) -> String {
        tagName.lowercased().replacingOccurrences(of: " ", with: "_")
    }

}
