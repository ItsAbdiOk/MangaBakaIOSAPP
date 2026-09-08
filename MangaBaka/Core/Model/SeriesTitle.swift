import Foundation

/// One title for a series, in one language.
struct SeriesTitle: Decodable, Equatable, Sendable, Hashable {
    /// BCP-47-ish tag as the API returns it: "en", "ko", "pt-br", "ko-Latn".
    let language: String
    /// Zero or more of "official", "native", "alternative".
    let traits: [String]
    let title: String
    /// Whether this is the primary title *for its own language*.
    ///
    /// Measured against the live API on 2026-09-08: every title in a series
    /// carries `is_primary: true` (25 of 25, 14 of 14, 18 of 18 across the
    /// three series returned by `/v2/series/discover/rising`). It therefore
    /// does NOT identify a single display title — selecting on this field
    /// alone yields an arbitrary language. See `DisplayTitle`.
    let isPrimary: Bool?
}
