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
        /// The id is a string on some trackers and a number on others, so it
        /// is not modelled — nothing here needs it, and decoding it would fail
        /// on whichever shape was not anticipated.
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
    }

    /// Memberwise, because the custom `init(from:)` replaces the synthesised
    /// one and the test factory builds series directly.
    init(
        id: Int, state: String, mergedWith: Int?, titles: [SeriesTitle]?, cover: Cover,
        description: String?, authors: [String]?, artists: [String]?, status: String?,
        rating: Double?, type: String?, contentRating: String?, totalChapters: Double?,
        finalVolume: Double?, publishers: [Publisher]?, anime: AnimeAdaptation?,
        source: [String: TrackerEntry]?
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
    }

    /// The title to show, chosen by `DisplayTitle`. `nil` when the series
    /// carries no titles at all, which the schema permits.
    var displayTitle: String? {
        DisplayTitle.choose(from: titles)
    }

    /// A series whose `state` is "merged" or "deleted" should not be shown in
    /// discovery surfaces; it exists only so stored references can be updated.
    var isDiscoverable: Bool {
        state == "active"
    }
}

private extension KeyedDecodingContainer {
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
