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

    /// A short, plain phrase for a wait, e.g. "30 seconds" or "2 minutes".
    private static func humanDuration(_ seconds: TimeInterval) -> String {
        if seconds < 60 {
            let rounded = max(Int(seconds.rounded()), 1)
            return "\(rounded) second\(rounded == 1 ? "" : "s")"
        }
        let minutes = max(Int((seconds / 60).rounded()), 1)
        return "\(minutes) minute\(minutes == 1 ? "" : "s")"
    }

    /// Whether showing stale content alongside this error is the right call.
    /// A rate limit or an outage says nothing about the cached copy, so the
    /// content stays; a decoding failure means the shape changed, and stale
    /// content may be misleading.
    var staleContentRemainsUseful: Bool {
        switch self {
        case .offline, .rateLimited, .server: true
        case .decoding, .transport: false
        }
    }

    /// A symbol suited to the cause, so the screen reads at a glance.
    var symbolName: String {
        switch self {
        case .offline: "wifi.slash"
        case .rateLimited: "hourglass"
        case .server: "exclamationmark.triangle"
        case .decoding, .transport: "questionmark.circle"
        }
    }

    /// A message safe to display. Never surfaces technical detail for cases
    /// where the user can act, and never blames the user for a shared limit.
    var userFacingMessage: String {
        switch self {
        case .offline:
            "You're offline. Showing what's already downloaded."
        case let .rateLimited(retryAfter):
            // Never phrased as the reader's fault. The limit is per IP and
            // shared, so this can be triggered entirely by a stranger on the
            // same network.
            if let retryAfter, retryAfter > 0 {
                "MangaBaka is busy. Try again in \(Self.humanDuration(retryAfter))."
            } else {
                "MangaBaka is busy right now."
            }
        case let .server(_, message):
            message
        case .decoding, .transport:
            "Something went wrong talking to MangaBaka."
        }
    }
}
