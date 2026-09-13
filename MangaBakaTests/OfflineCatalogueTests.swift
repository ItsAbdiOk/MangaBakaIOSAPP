import Foundation
import Testing
@testable import MangaBaka

/// `OfflineCatalogue` against the real bundled `OfflineIndex.json.gz` — the
/// 19,300-series export offline search and filtering run against with zero
/// network. Every filtering test carries its own control: the expected answer
/// is computed here, independently, from a second decode of the same file,
/// rather than trusting `OfflineCatalogue`'s own arithmetic to check itself.
@Suite("Offline catalogue")
struct OfflineCatalogueTests {
    /// Mirrors the actor's private `Wire` type so the test can decode the
    /// resource on its own, without reaching into `OfflineCatalogue`'s
    /// internals — the whole point of a control is that it does not share
    /// code with the thing it is checking.
    private struct RawWire: Decodable {
        let version: Int
        let built: String
        let series: [OfflineIndexEntry]
    }

    /// Somewhere to hang `Bundle(for:)`, matching `TagTaxonomyTests`'s own
    /// pattern for finding the resource regardless of whether the test bundle
    /// is hosted by the app or standalone.
    private final class BundleMarker {}

    fileprivate static let rawEntries: [OfflineIndexEntry] = {
        let inTestBundle = Bundle(for: BundleMarker.self)
            .url(forResource: "OfflineIndex", withExtension: "json.gz")
        guard
            let url = inTestBundle ?? Bundle.main.url(forResource: "OfflineIndex", withExtension: "json.gz"),
            let gzipped = try? Data(contentsOf: url),
            let raw = try? Gunzip.decompress(gzipped),
            let wire = try? JSONDecoder().decode(RawWire.self, from: raw)
        else { return [] }
        return wire.series
    }()

    private func makeCatalogue() -> OfflineCatalogue { OfflineCatalogue() }

    private func query(
        text: String? = nil,
        types: [String] = [],
        statuses: [String] = [],
        tags: [String] = [],
        genres: [String] = [],
        tagMode: String? = nil,
        minimumRating: Int? = nil
    ) -> SearchQuery {
        var result = SearchQuery()
        result.text = text
        result.types = types
        result.statuses = statuses
        result.tags = tags
        result.genres = genres
        result.tagMode = tagMode
        result.minimumRating = minimumRating
        return result
    }

    // MARK: - Decoding

    @Test("The control's own independent decode finds all 19,300 series")
    func controlDecodesFullFile() {
        #expect(Self.rawEntries.count == 19_300, "The export's own row count should not drift silently")
    }

    @Test("Solo Leveling (3397), the export's own #1 by popularity, is present")
    func controlFindsKnownID() {
        #expect(Self.rawEntries.contains { $0.id == 3397 })
    }

    @Test("OfflineCatalogue reports the same total the control decode found")
    func catalogueCountMatchesControl() async throws {
        let catalogue = makeCatalogue()
        let total = try #require(await catalogue.totalCount())
        #expect(total == Self.rawEntries.count)
    }

    @Test("A known id is reachable through matches(), not just present in the raw file")
    func knownIDIsReturnedByMatches() async {
        let catalogue = makeCatalogue()
        let hits = await catalogue.matches(
            query(), allowedRatings: [], allowedTypes: [], blockedTags: [],
            limit: Self.rawEntries.count, offset: 0
        )
        #expect(hits.contains { $0.id == 3397 })
    }

    @Test("The bundled resource decodes with a real build date")
    func builtDateIsPresent() async {
        let catalogue = makeCatalogue()
        let built = await catalogue.builtDate()
        #expect(built == "2026-09-13")
    }

    // MARK: - Tag filtering

    /// Tag 36 is "Fantasy" in `TagTaxonomy` — common enough to be a real
    /// subset test (thousands of hits) rather than an edge case of one or two.
    @Test("Filtering by one tag id gives a subset that all carry that tag")
    func tagFilterGivesExactSubset() async {
        let expected = Set(Self.rawEntries.filter { $0.tagIDs.contains(36) }.map(\.id))
        #expect(!expected.isEmpty, "Sanity: the fixture must actually carry this tag somewhere")
        #expect(expected.count < Self.rawEntries.count, "Sanity: this must be a real subset, not everything")

        let catalogue = makeCatalogue()
        let hits = await catalogue.matches(
            query(tags: ["Fantasy"]), allowedRatings: [], allowedTypes: [], blockedTags: [],
            limit: Self.rawEntries.count, offset: 0
        )
        #expect(Set(hits.map(\.id)) == expected)
    }

    @Test("A blocked tag excludes every series that carries it, even alongside a matching tag")
    func blockedTagExcludes() async {
        // 44 is "Horror". Expected: Fantasy present AND Horror absent.
        let expected = Set(
            Self.rawEntries.filter { $0.tagIDs.contains(36) && !$0.tagIDs.contains(44) }.map(\.id)
        )
        #expect(!expected.isEmpty)

        let catalogue = makeCatalogue()
        let hits = await catalogue.matches(
            query(tags: ["Fantasy"]), allowedRatings: [], allowedTypes: [], blockedTags: [44],
            limit: Self.rawEntries.count, offset: 0
        )
        #expect(Set(hits.map(\.id)) == expected)
    }

    // MARK: - Content rating

    /// The offline index is the one path that shows results *without* the
    /// server's `content_rating` filter, so this local one is all that
    /// stands between a reader with explicit content off and the whole
    /// export. Every other test here passes `allowedRatings: []`, which
    /// `passesRating` reads as "allow everything" — deleting the filter
    /// outright left this file green (search review, tests finding 4).
    ///
    /// Measured against the bundled export (built 2026-09-13): safe 12,268,
    /// suggestive 2,784, erotica 2,717, pornographic 1,531, none missing —
    /// so `SearchModel`'s default `["safe", "suggestive"]` must return
    /// exactly 15,052, and the "missing rating passes" rule cannot be
    /// exercised by this fixture at all (recorded, not tested).
    @Test("The default content ratings keep 15,052 of the 19,300 and none of the rest")
    func contentRatingFilterKeepsOnlyAllowed() async {
        let allowed: Set<String> = ["safe", "suggestive"]
        let expected = Set(
            Self.rawEntries.filter { entry in
                guard let rating = entry.contentRating, !rating.isEmpty else { return true }
                return allowed.contains(rating.lowercased())
            }.map(\.id)
        )
        #expect(expected.count == 15_052, "the export's own split; a drift here is a new export, not a bug")
        #expect(expected.count < Self.rawEntries.count, "Sanity: the filter must actually remove something")

        let catalogue = makeCatalogue()
        let hits = await catalogue.matches(
            query(), allowedRatings: Array(allowed), allowedTypes: [], blockedTags: [],
            limit: Self.rawEntries.count, offset: 0
        )
        #expect(Set(hits.map(\.id)) == expected)
        // The hit's `Series` carries the rating through (`OfflineCatalogue.swift:60`),
        // so a nil here would be a hit built wrong, not an unrated row — the
        // export has none.
        #expect(
            hits.allSatisfy { hit in hit.series.contentRating.map(allowed.contains) ?? false },
            "no returned hit may carry a rating outside the allowed set"
        )
    }

    /// Control for the test above: `count()` shares the filter with
    /// `matches()`, and the comparison is case-insensitive on the wire value
    /// — the export stores lowercase, the settings store whatever the picker
    /// wrote.
    @Test("count() applies the content-rating filter the same way matches() does")
    func contentRatingCountAgreesWithMatches() async {
        let catalogue = makeCatalogue()
        let count = await catalogue.count(
            query(), allowedRatings: ["Safe"], allowedTypes: [], blockedTags: []
        )
        let expected = Self.rawEntries.filter { $0.contentRating?.lowercased() == "safe" }.count
        #expect(count == expected)
        #expect(count == 12_268)
    }

    // MARK: - Rating and type

    @Test("A rating floor keeps only series at or above it")
    func ratingFloorFilters() async {
        let expected = Set(
            Self.rawEntries.filter { entry in
                guard let rating = entry.rating else { return false }
                return Int(rating.rounded()) >= 90
            }.map(\.id)
        )
        #expect(!expected.isEmpty)

        let catalogue = makeCatalogue()
        let hits = await catalogue.matches(
            query(minimumRating: 90), allowedRatings: [], allowedTypes: [], blockedTags: [],
            limit: Self.rawEntries.count, offset: 0
        )
        #expect(Set(hits.map(\.id)) == expected)
    }

    @Test("A type filter keeps only that kind")
    func typeFilterFilters() async {
        let expected = Set(Self.rawEntries.filter { $0.kind == "Manga" }.map(\.id))
        #expect(!expected.isEmpty)
        #expect(expected.count < Self.rawEntries.count)

        let catalogue = makeCatalogue()
        let hits = await catalogue.matches(
            query(), allowedRatings: [], allowedTypes: ["manga"], blockedTags: [],
            limit: Self.rawEntries.count, offset: 0
        )
        #expect(Set(hits.map(\.id)) == expected)
    }

    /// An explicit type on the query overrides the standing preference,
    /// mirroring `SeriesRepository.filterQuery`'s `overridingTypes` rule —
    /// picking "novel" in the sheet while novels are off in Settings must
    /// still show novels rather than intersecting to nothing.
    @Test("An explicit query type overrides the standing format preference")
    func explicitTypeOverridesStandingPreference() async {
        let expected = Set(Self.rawEntries.filter { $0.kind == "Manhwa" }.map(\.id))
        #expect(!expected.isEmpty)

        let catalogue = makeCatalogue()
        let hits = await catalogue.matches(
            query(types: ["manhwa"]), allowedRatings: [], allowedTypes: ["manga"], blockedTags: [],
            limit: Self.rawEntries.count, offset: 0
        )
        #expect(Set(hits.map(\.id)) == expected)
    }

    // MARK: - Paging

    @Test("Paging offset/limit produces disjoint, contiguous pages")
    func pagingIsDisjointAndContiguous() async {
        let catalogue = makeCatalogue()
        let pageOne = await catalogue.matches(
            query(), allowedRatings: [], allowedTypes: [], blockedTags: [], limit: 50, offset: 0
        )
        let pageTwo = await catalogue.matches(
            query(), allowedRatings: [], allowedTypes: [], blockedTags: [], limit: 50, offset: 50
        )

        #expect(pageOne.count == 50)
        #expect(pageTwo.count == 50)
        #expect(Set(pageOne.map(\.id)).isDisjoint(with: Set(pageTwo.map(\.id))))

        let combined = await catalogue.matches(
            query(), allowedRatings: [], allowedTypes: [], blockedTags: [], limit: 100, offset: 0
        )
        #expect(combined.map(\.id) == pageOne.map(\.id) + pageTwo.map(\.id))
    }

    @Test("An offset past the end returns nothing rather than wrapping or crashing")
    func offsetPastEndIsEmpty() async {
        let catalogue = makeCatalogue()
        let hits = await catalogue.matches(
            query(), allowedRatings: [], allowedTypes: [], blockedTags: [],
            limit: 10, offset: Self.rawEntries.count + 1000
        )
        #expect(hits.isEmpty)
    }

    // MARK: - count() agrees with matches()

    @Test("count() equals matches().count for the same filter, at a limit covering everything")
    func countMatchesMatchesCount() async {
        let catalogue = makeCatalogue()
        let filter = query(tags: ["Fantasy"], minimumRating: 50)
        let count = await catalogue.count(
            filter, allowedRatings: [], allowedTypes: [], blockedTags: []
        )
        let hits = await catalogue.matches(
            filter, allowedRatings: [], allowedTypes: [], blockedTags: [],
            limit: Self.rawEntries.count, offset: 0
        )
        #expect(count == hits.count)
        #expect(count > 0, "Sanity: this filter must actually match something")
    }

    // MARK: - Text search (labelled rough in the brief)

    @Test("A title text query matches case- and diacritic-insensitively")
    func textQueryIsCaseAndDiacriticInsensitive() async {
        let catalogue = makeCatalogue()
        let hits = await catalogue.matches(
            query(text: "SOLO LEVELING"), allowedRatings: [], allowedTypes: [], blockedTags: [],
            limit: 10, offset: 0
        )
        #expect(hits.contains { $0.id == 3397 })
    }

    // MARK: - OfflineHit shape

    @Test("A hit's Series carries no cover and the offline id/title/type/year/rating")
    func hitBuildsARenderableSeriesWithNoCover() async throws {
        let catalogue = makeCatalogue()
        let hits = await catalogue.matches(
            query(text: "Solo Leveling"), allowedRatings: [], allowedTypes: [], blockedTags: [],
            limit: 10, offset: 0
        )
        let hit = try #require(hits.first { $0.id == 3397 })
        #expect(hit.series.cover == .empty)
        #expect(hit.series.type == "manhwa")
        #expect(hit.series.year == 2018)
        // Reads the raw title rather than `displayTitle`, which additionally
        // consults a global `TitleSettings.preference` this test does not
        // want to depend on.
        #expect(hit.series.titles?.first?.title == "Solo Leveling")
    }
}

/// Genres and tag mode against the same real export. A second suite only
/// because `OfflineCatalogueTests` is at the lint's body ceiling; the
/// control is the same independent decode.
@Suite("Offline catalogue: genres and tag mode")
struct OfflineGenreTests {
    private var raw: [OfflineIndexEntry] { OfflineCatalogueTests.rawEntries }

    private func query(tags: [String] = [], genres: [String] = [], tagMode: String? = nil) -> SearchQuery {
        var result = SearchQuery()
        result.tags = tags
        result.genres = genres
        result.tagMode = tagMode
        return result
    }

    /// The export folds genres into the same `g` array as tags, so a genre
    /// value has to resolve to a tag id or the filter does nothing. Before
    /// 2026-09-13 a genre rode in `query.tags` and `"slice_of_life"` matched
    /// no tag name, so a genre-only offline search returned all 19,300 rows
    /// (review, catalogue #2). Tag 7 is "Slice of Life" in `TagTaxonomy`.
    @Test("A genre-only query narrows to the genre's rows, not the whole index")
    func genreFilterGivesExactSubset() async {
        let expected = Set(raw.filter { $0.tagIDs.contains(7) }.map(\.id))
        #expect(!expected.isEmpty, "Sanity: the fixture must carry Slice of Life somewhere")
        #expect(expected.count < raw.count, "Sanity: a real subset, not everything")

        let catalogue = OfflineCatalogue()
        let hits = await catalogue.matches(
            query(genres: ["slice_of_life"]), allowedRatings: [], allowedTypes: [], blockedTags: [],
            limit: raw.count, offset: 0
        )
        #expect(Set(hits.map(\.id)) == expected)
    }

    /// Two genres are ANDed, as the live API does it: `genre=action`
    /// 31,025, `genre=romance` 100,947, both 6,692 (`/v1/series/search`,
    /// 2026-09-13). Tags 39 "Action" and 9 "Romance".
    @Test("Two genres both have to hold")
    func genresAreAnded() async {
        let expected = Set(
            raw.filter { $0.tagIDs.contains(39) && $0.tagIDs.contains(9) }.map(\.id)
        )
        let either = Set(
            raw.filter { $0.tagIDs.contains(39) || $0.tagIDs.contains(9) }.map(\.id)
        )
        #expect(!expected.isEmpty)
        #expect(expected.count < either.count, "Sanity: AND and OR must differ for this pair")

        let catalogue = OfflineCatalogue()
        let hits = await catalogue.matches(
            query(genres: ["action", "romance"]), allowedRatings: [], allowedTypes: [], blockedTags: [],
            limit: raw.count, offset: 0
        )
        #expect(Set(hits.map(\.id)) == expected)
    }

    /// Every value `/v1/genres` answered on 2026-09-13 (46 of them) has
    /// exactly one bundled tag whose name folds to it — so the offline
    /// path can honour any genre the sheet offers, not just the ones that
    /// happened to match by case. If the taxonomy export ever renames one,
    /// this is where it shows.
    @Test("Every live genre value resolves to one bundled tag id")
    func everyGenreResolves() {
        let live = [
            "action", "adult", "adventure", "avant_garde", "award_winning", "boys_love", "comedy",
            "doujinshi", "drama", "ecchi", "erotica", "fantasy", "gender_bender", "girls_love",
            "gourmet", "harem", "hentai", "historical", "horror", "josei", "lolicon", "mahou_shoujo",
            "martial_arts", "mature", "mecha", "music", "mystery", "psychological", "romance",
            "school_life", "sci-fi", "seinen", "shotacon", "shoujo", "shoujo_ai", "shounen",
            "shounen_ai", "slice_of_life", "smut", "sports", "supernatural", "suspense", "thriller",
            "tragedy", "yaoi", "yuri"
        ]
        #expect(live.count == 46)
        let ids = OfflineCatalogue.tagIDs(forGenres: live)
        #expect(ids.count == live.count, "a genre with no bundled tag would be silently dropped")
        #expect(Set(ids).count == ids.count, "two genres must not fold to one tag")
        #expect(OfflineCatalogue.tagIDs(forGenres: ["slice_of_life"]) == [7])
    }

    /// `tagMode` is stored but never sent: the wire is always AND (see
    /// `SearchQuery.tagMode`, 164 either way). Offline used to honour a
    /// literal "or", so a saved lens carrying one answered a different
    /// question offline than online. 36 "Fantasy", 44 "Horror".
    @Test("A stored tagMode of \"or\" still filters as AND, matching the wire")
    func orModeIsAndOffline() async {
        let both = Set(
            raw.filter { $0.tagIDs.contains(36) && $0.tagIDs.contains(44) }.map(\.id)
        )
        let either = Set(
            raw.filter { $0.tagIDs.contains(36) || $0.tagIDs.contains(44) }.map(\.id)
        )
        #expect(both.count < either.count, "Sanity: the two readings must differ")

        let catalogue = OfflineCatalogue()
        let hits = await catalogue.matches(
            query(tags: ["Fantasy", "Horror"], tagMode: "or"),
            allowedRatings: [], allowedTypes: [], blockedTags: [],
            limit: raw.count, offset: 0
        )
        #expect(Set(hits.map(\.id)) == both)
    }
}
