import Foundation

/// Every failure the API layer can produce, named individually.
///
/// Deliberately not a catch-all: each case carries what the UI needs to
/// respond correctly. `rateLimited` in particular must not read as the user's
/// fault, because MangaBaka rate limits per IP — another person on the same
/// carrier NAT can exhaust the budget.
enum APIError: Error, Equatable {
    /// No network path. The caller should fall back to cached content.
    case offline

    /// HTTP 429. Back off and serve cache.
    /// - Parameter retryAfter: seconds from the `Retry-After` header, when present.
    case rateLimited(retryAfter: TimeInterval?)

    /// A non-2xx response carrying the API's own message.
    ///
    /// The API documents `message` as safe to show end users verbatim:
    /// "The `message` field can be safely shown to end-users, as it generally
    /// does not contain technical terminology."
    case server(status: Int, message: String)

    /// The response was not valid JSON, or did not match the expected shape.
    case decoding(underlying: String)

    /// Anything URLSession reported that is not covered above.
    case transport(underlying: String)

    /// A message safe to display. Never surfaces technical detail for cases
    /// where the user can act, and never blames the user for a shared limit.
    var userFacingMessage: String {
        switch self {
        case .offline:
            "You're offline. Showing what's already downloaded."
        case .rateLimited:
            "MangaBaka is busy right now. Showing saved results."
        case let .server(_, message):
            message
        case .decoding, .transport:
            "Something went wrong talking to MangaBaka."
        }
    }
}
