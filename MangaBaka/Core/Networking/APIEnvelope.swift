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
    let total: Int?
}

/// Error envelope for non-2xx responses, which carry `message` but no `data`.
struct APIErrorEnvelope: Decodable {
    let status: Int
    let message: String?
}
