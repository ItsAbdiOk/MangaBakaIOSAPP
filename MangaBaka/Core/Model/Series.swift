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
