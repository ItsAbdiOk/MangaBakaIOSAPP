import Foundation

/// Every MangaBaka response, success or failure, is wrapped in this shape.
///
/// From the spec's own description:
///   - all endpoints return a JSON document, success or not
///   - `status` is always present and follows HTTP status conventions
///   - errors always carry `message`
///   - paginated results carry `pagination`
///   - successes carry `data` (object for one resource, array for many)
struct APIEnvelope<Payload: Decodable>: Decodable {
    let status: Int
    let data: Payload?
    let message: String?
    let pagination: Pagination?
}

/// Present on any paginated response.
struct Pagination: Decodable, Equatable, Sendable {
    let page: Int?
    let limit: Int?

    /// How many results the whole query has.
    ///
    /// **The wire name is `count`, not `total`.** This was modelled as `total`
    /// and had never been read, so the mistake sat here harmlessly until the
    /// first thing that needed it — the live count on a saved lens — would have
    /// silently shown no count at all, for every lens, forever. Checked against
    /// the live endpoint on 2026-09-10: `?tag=Regression&limit=1` answers with
    /// `"pagination": {"count": 1017, ...}` and no `total` anywhere.
    let count: Int?

    /// The next page's URL, or nil on the last page. Its absence is a more
    /// reliable end-of-list signal than comparing counts.
    let next: String?
}

/// Error envelope for non-2xx responses, which carry `message` but no `data`.
struct APIErrorEnvelope: Decodable {
    let status: Int
    let message: String?
}
