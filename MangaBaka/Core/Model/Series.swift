import Foundation

/// A series as returned by the v2 endpoints.
///
/// Only fields the app currently uses are modelled. Swift's `Decodable`
/// ignores unknown keys, which matters here: the live API returns
/// `canonical_url`, which the published OpenAPI spec does not document
/// (verified 2026-09-08). The spec lags the API, so this type must never
/// assume the spec is exhaustive.
struct Series: Codable, Identifiable, Equatable, Sendable, Hashable {
    let id: Int
    /// "active", "merged" or "deleted".
    let state: String
    /// When `state == "merged"`, the ID that replaced this one. The API asks
    /// clients to update stored references to it.
    let mergedWith: Int?
    let titles: [SeriesTitle]?
    let cover: Cover
    let description: String?
    let authors: [String]?
    let artists: [String]?
    /// Publication status, e.g. "releasing", "completed".
    let status: String?
    /// 0-100, or `nil` when unrated.
    let rating: Double?
    let type: String?
    let contentRating: String?
    /// Chapters published so far, when known.
    let totalChapters: Double?
    /// The final volume number, when the series has ended.
    let finalVolume: Double?
    /// Who publishes it, and where. Objects rather than names: each carries a
    /// type ("Original", "English") and sometimes a note about volume counts.
    let publishers: [Publisher]?
    /// Whether an anime adaptation exists, and which chapters it covers.
    /// The mockup derived this from the rating; it is a real field.
    let anime: AnimeAdaptation?
    /// The same series on other trackers, with their ratings. Also real —
    /// the mockup faked these as arithmetic offsets from the base rating.
    let source: [String: TrackerEntry]?
    /// First publication year. Present on the v1 endpoints; the v2 lean schema
    /// returns null for it even with `schema=full` (verified 2026-09-09).
    let year: Int?
    /// How many people rated it. The reverse of `year`: present on v2, absent
    /// on v1. Neither endpoint carries both, so the meta line renders whichever
    /// parts it actually has rather than waiting for a complete set.
    let ratingCount: Int?
    /// Tag names, flattened.
    ///
    /// Three shapes across the API: v1 returns an array of plain strings, v2
    /// with `schema=full` returns an array of objects, and the v2 lean schema
    /// omits them. Normalised to names here so a caller does not care which it
    /// was handed.
    let tags: [String]?

    struct Publisher: Codable, Equatable, Sendable, Hashable {
        let name: String
        /// "Original", "English", and similar.
        let type: String?
        /// Free text, often a volume count or completion note.
        let note: String?
    }

    struct AnimeAdaptation: Codable, Equatable, Sendable, Hashable {
        let exists: Bool?
        /// Where the adaptation starts in the manga, as free text.
        let start: String?
        let end: String?
    }

    struct TrackerEntry: Codable, Equatable, Sendable, Hashable {
        /// The tracker's own id, kept as a string.
        ///
        /// It arrives as a string on some trackers and a number on others
        /// (`anime_planet` sends "tsukihime", `anilist` sends 30705), so it is
        /// decoded leniently and normalised to a string. Modelling it as either
        /// concrete type fails on whichever shape was not anticipated — the
        /// same v1/v2 trap that has cost this app three silent decode failures.
        let id: String?
        let rating: Double?
        /// Every tracker uses a different scale; this one is 0-100 throughout,
        /// which is the only way to compare them honestly.
        let ratingNormalized: Double?
    }

    /// Decoded by hand for one reason: three numeric fields come back as
    /// strings on the v1 endpoints and as numbers on v2.
    ///
    /// `/v1/my/library` sends `"total_chapters": "87"`; `/v2/series/{id}` sends
    /// `"total_chapters": 87`. Verified against both on 2026-09-09. The
    /// synthesised decoder throws on whichever shape it was not written for,
    /// and because the library call swallows errors with `try?`, the whole
    /// response silently became an empty list.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        state = try container.decode(String.self, forKey: .state)
        mergedWith = try container.decodeIfPresent(Int.self, forKey: .mergedWith)
        titles = try container.decodeIfPresent([SeriesTitle].self, forKey: .titles)
        cover = try container.decode(Cover.self, forKey: .cover)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        authors = try container.decodeIfPresent([String].self, forKey: .authors)
        artists = try container.decodeIfPresent([String].self, forKey: .artists)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        contentRating = try container.decodeIfPresent(String.self, forKey: .contentRating)
        publishers = try container.decodeIfPresent([Publisher].self, forKey: .publishers)
        anime = try container.decodeIfPresent(AnimeAdaptation.self, forKey: .anime)
        source = try container.decodeIfPresent([String: TrackerEntry].self, forKey: .source)

        rating = container.lenientDouble(forKey: .rating)
        totalChapters = container.lenientDouble(forKey: .totalChapters)
        finalVolume = container.lenientDouble(forKey: .finalVolume)
        year = container.lenientDouble(forKey: .year).map { Int($0) }
        ratingCount = container.lenientDouble(forKey: .ratingCount).map { Int($0) }
        tags = container.lenientTagNames(forKey: .tags)
    }

    /// Memberwise, because the custom `init(from:)` replaces the synthesised
    /// one and the test factory builds series directly.
    init(
        id: Int, state: String, mergedWith: Int?, titles: [SeriesTitle]?, cover: Cover,
        description: String?, authors: [String]?, artists: [String]?, status: String?,
        rating: Double?, type: String?, contentRating: String?, totalChapters: Double?,
        finalVolume: Double?, publishers: [Publisher]?, anime: AnimeAdaptation?,
        source: [String: TrackerEntry]?,
        year: Int? = nil,
        ratingCount: Int? = nil,
        tags: [String]? = nil
    ) {
        self.id = id
        self.state = state
        self.mergedWith = mergedWith
        self.titles = titles
        self.cover = cover
        self.description = description
        self.authors = authors
        self.artists = artists
        self.status = status
        self.rating = rating
        self.type = type
        self.contentRating = contentRating
        self.totalChapters = totalChapters
        self.finalVolume = finalVolume
        self.publishers = publishers
        self.anime = anime
        self.source = source
        self.year = year
        self.ratingCount = ratingCount
        self.tags = tags
    }

    /// The title to show, chosen by `DisplayTitle`. `nil` when the series
    /// carries no titles at all, which the schema permits.
    var displayTitle: String? {
        DisplayTitle.choose(from: titles)
    }

    /// MangaUpdates' id for this series, if it has one. Base-36, and it must be
    /// decoded before use — see `MangaUpdatesID`.
    var mangaUpdatesID: String? {
        source?["manga_updates"]?.id
    }

    /// The language the series was originally published in, if its titles say.
    ///
    /// Taken from the title marked "native" rather than from a field, because
    /// there is no field: MangaBaka records the language per title, and the
    /// native one is the only reliable statement about the work's own language.
    var nativeLanguage: String? {
        titles?.first { $0.traits.contains("native") }?.language
    }

    /// Whether this series answers to a name the reader typed.
    ///
    /// Every title the series carries, not just the displayed one. A library
    /// search that only matched `displayTitle` could not find a series by the
    /// name the reader actually knows it by — the Korean title, the official
    /// English one, an alternative romanisation — which on a 937-entry library
    /// is the difference between a search and a guess. Authors count too: "show
    /// me everything by this artist" is a real question about your own shelf.
    func matches(_ needle: String) -> Bool {
        let trimmed = needle.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return true }
        if titles?.contains(where: { $0.title.localizedCaseInsensitiveContains(trimmed) }) == true {
            return true
        }
        return authors?.contains { $0.localizedCaseInsensitiveContains(trimmed) } == true
    }

    /// A series whose `state` is "merged" or "deleted" should not be shown in
    /// discovery surfaces; it exists only so stored references can be updated.
    var isDiscoverable: Bool {
        state == "active"
    }
}

private struct NamedTag: Decodable { let name: String? }

private extension KeyedDecodingContainer {
    /// Tag names, whichever of the API's three shapes arrived.
    func lenientTagNames(forKey key: Key) -> [String]? {
        if let names = try? decodeIfPresent([String].self, forKey: key) { return names }
        if let objects = try? decodeIfPresent([NamedTag].self, forKey: key) {
            return objects.compactMap(\.name)
        }
        // The lean v2 schema sends a placeholder string rather than a list.
        return nil
    }

    /// A number the API sends as a number on one endpoint and as a string on
    /// another. Returns nil rather than throwing: an unparsable value means the
    /// field is unknown, which the model already allows for, and throwing here
    /// would discard the entire series over one optional field.
    func lenientDouble(forKey key: Key) -> Double? {
        if let value = try? decodeIfPresent(Double.self, forKey: key) { return value }
        guard let text = try? decodeIfPresent(String.self, forKey: key) else { return nil }
        return Double(text)
    }
}

extension Series.TrackerEntry {
    private enum CodingKeys: String, CodingKey { case id, rating, ratingNormalized }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // String on some trackers, number on others. Normalised rather than
        // insisted upon.
        if let text = try? container.decodeIfPresent(String.self, forKey: .id) {
            id = text
        } else if let number = try? container.decodeIfPresent(Int.self, forKey: .id) {
            id = String(number)
        } else {
            id = nil
        }
        rating = try container.decodeIfPresent(Double.self, forKey: .rating)
        ratingNormalized = try container.decodeIfPresent(Double.self, forKey: .ratingNormalized)
    }
}
