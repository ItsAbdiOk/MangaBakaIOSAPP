import Foundation

/// Some endpoints answer with `results` rather than `data`.
///
/// Verified 2026-09-09: `/v1/my/series/recommendations` and
/// `/v1/my/series/discover/top-genres` both do, and they carry extra top-level
/// flags alongside. The spec describes a single envelope shape; the API has
/// two, and decoding one as the other fails outright.
struct ResultsEnvelope<Payload: Decodable>: Decodable {
    let status: Int
    let results: Payload?
    /// True when the reader's library is too small to personalise from, so the
    /// UI can explain that rather than showing an empty list.
    let coldStart: Bool?
    /// True when the recommendation profile is being rebuilt; results are
    /// still usable, just behind.
    let profileStale: Bool?
    let pagination: Pagination?
}
