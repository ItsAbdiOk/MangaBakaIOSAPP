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

    /// Whether the reader can fix this by connecting an account.
    var needsAccount: Bool {
        if case let .server(status, _) = self { return status == 401 || status == 403 }
        return false
    }

    /// A symbol suited to the cause, so the screen reads at a glance.
    var symbolName: String {
        switch self {
        case .offline: "wifi.slash"
        case .rateLimited: "hourglass"
        case .server: needsAccount ? "person.crop.circle.badge.plus" : "exclamationmark.triangle"
        case .decoding, .transport: "questionmark.circle"
        }
    }

    /// A message safe to display. Never surfaces technical detail for cases
    /// where the user can act, and never blames the user for a shared limit.
    ///
    /// Wording from the design board, 2026-09-10. Each one names what happened,
    /// then what is still true — because on every one of these screens
    /// something *is* still true, and a reader who is told only about the
    /// failure assumes the whole app is broken.
    var userFacingMessage: String {
        switch self {
        case .offline:
            "Showing what was downloaded. Nothing new can load until you're back."
        case .rateLimited:
            // Never phrased as the reader's fault. The limit is per IP and
            // shared, so this can be triggered entirely by a stranger on the
            // same network — and that sentence is in the body rather than a
            // footnote because it is the only line in the family that defends
            // the reader.
            """
            MangaBaka is throttling this connection. The limit is shared by \
            everyone on your network, so this may not be you at all.
            """
        // 401 and 403 have a fix the reader can actually carry out, and the
        // API's own message for them ("Unauthenticated.") names a state, not
        // an action.
        case let .server(_, message):
            if needsAccount {
                """
                Your library, recommendations and schedule are tied to a \
                MangaBaka token. Discovery, search and the stack keep working \
                without one.
                """
            } else if !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // The API's own words when it has any. It documents these as
                // safe to show, and "That series doesn't exist." tells a reader
                // something the design board's generic line cannot. The board
                // wrote for the case where the server says nothing useful; it
                // did not know the server often says something better.
                message
            } else {
                """
                Their server answered with an error. Nothing is wrong on this \
                phone, and what you already have is still here.
                """
            }
        case .decoding:
            """
            The answer wasn't in a shape this version understands. Cached \
            copies were cleared, because they may no longer be accurate.
            """
        case .transport:
            "The request didn't complete."
        }
    }

    /// The headline above `userFacingMessage`.
    ///
    /// Decode and transport share one, deliberately: a reader cannot act on the
    /// difference between them, and two near-identical screens only invite them
    /// to hunt for one.
    var headline: String {
        switch self {
        case .offline: "You're offline"
        case .rateLimited: "Too many requests, briefly"
        case .server: needsAccount ? "This part needs an account" : "MangaBaka had a problem"
        case .decoding, .transport: "Something went wrong"
        }
    }

    /// "Retrying in 38s.", when the server said how long to wait.
    ///
    /// Its own property rather than part of the message because it is the one
    /// piece of this family that is a live number: it belongs at the end of the
    /// body in bold, and it is absent when the server did not say.
    var countdown: String? {
        guard case let .rateLimited(retryAfter) = self,
              let retryAfter, retryAfter > 0
        else { return nil }
        return "Retrying in \(Self.humanDuration(retryAfter))."
    }
}
