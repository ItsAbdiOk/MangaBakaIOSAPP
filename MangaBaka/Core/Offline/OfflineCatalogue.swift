import Foundation

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

    private struct LoadState {
        let entries: [OfflineIndexEntry]
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

    /// The export's own build date, e.g. "2026-09-13". Nil when the resource
    /// is missing or unreadable — a packaging bug, not a real "no date".
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
        let filtered = filteredAndSorted(
            query, allowedRatings: allowedRatings, allowedTypes: allowedTypes, blockedTags: blockedTags
        )
        guard offset < filtered.count, limit > 0 else { return [] }
        let end = min(offset + limit, filtered.count)
        return filtered[offset..<end].map(OfflineHit.init)
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
        guard let url = bundle.url(forResource: resourceName, withExtension: resourceExtension),
              let gzipped = try? Data(contentsOf: url),
              let raw = try? Gunzip.decompress(gzipped)
        else {
            return LoadState(entries: [], built: "")
        }
        guard let wire = try? JSONDecoder().decode(Wire.self, from: raw) else {
            return LoadState(entries: [], built: "")
        }
        return LoadState(entries: wire.series, built: wire.built)
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
        let entries = ensureLoaded().entries
        let ratings = Set(allowedRatings.map { $0.lowercased() })
        // An explicit type chosen in the filter sheet wins over the standing
        // preference — see this method's doc comment.
        let types = Set((query.types.isEmpty ? allowedTypes : query.types).map { $0.lowercased() })
        let statuses = Set(query.statuses.map { $0.lowercased() })
        let blocked = Set(blockedTags)
        let requiredTagIDs = Self.tagIDs(named: query.tags)
        let text = (query.text ?? "").trimmingCharacters(in: .whitespaces)

        let result = entries.filter { entry in
            passesRating(entry, allowed: ratings)
                && passesType(entry, allowed: types)
                && !entry.tagIDs.contains(where: blocked.contains)
                && passesStatus(entry, allowed: statuses)
                && passesRating(entry, minimum: query.minimumRating)
                && passesYear(entry, from: query.yearFrom, to: query.yearTo)
                && passesTags(entry, required: requiredTagIDs, mode: query.tagMode)
                && passesText(entry, needle: text)
        }
        return Self.sorted(result, by: query.sort)
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
        return Int(rating.rounded()) >= minimum
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

    private func passesTags(_ entry: OfflineIndexEntry, required: [Int], mode: String?) -> Bool {
        guard !required.isEmpty else { return true }
        if mode == "or" {
            return required.contains { entry.tagIDs.contains($0) }
        }
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
    private static func tagIDs(named names: [String]) -> [Int] {
        guard !names.isEmpty else { return [] }
        let byName = Dictionary(
            TagTaxonomy.bundled().map { ($0.name.lowercased(), $0.id) },
            uniquingKeysWith: { first, _ in first }
        )
        return names.compactMap { byName[$0.lowercased()] }
    }

    /// Popularity ascending (rank 1 first) by default — the same "ascending is
    /// what a reader means by popularity" rule `SortOrder.all` documents for
    /// the online path. Only "score_desc" (by rating) is offered as an
    /// alternative offline; the export carries nothing to answer "trending"
    /// or "latest" with, and "random" would be a different shuffle on every
    /// page rather than a stable order to page through.
    private static func sorted(_ entries: [OfflineIndexEntry], by sort: String?) -> [OfflineIndexEntry] {
        switch sort {
        case "score_desc":
            return entries.sorted { ($0.rating ?? -1) > ($1.rating ?? -1) }
        default:
            return entries.sorted { ($0.popularity ?? .max) < ($1.popularity ?? .max) }
        }
    }
}
