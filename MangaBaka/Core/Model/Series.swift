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
