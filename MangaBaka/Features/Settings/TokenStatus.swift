import Foundation

/// What the app currently knows about the reader's stored token.
///
/// Four states, not three, and the fourth is the point: `unverified` is a token
/// that could not be checked — offline, rate limited, a 500 — as distinct from
/// one MangaBaka rejected. Collapsing them reported a dropped connection as
/// "That token was not accepted by MangaBaka" and then deleted the token from
/// the Keychain, because the save path treats a failed check as proof.
enum TokenStatus: Equatable {
    case idle
    case checking
    /// The name may be absent: a working token belonging to an account
    /// with no display name is still signed in.
    case signedIn(String?)
    /// MangaBaka answered and said no. The only state that clears the token.
    case failed(String)
    /// Could not be checked — offline, rate limited, a server error. The
    /// token is kept, because none of that is evidence against it.
    case unverified(String)

    var isRejection: Bool { if case .failed = self { true } else { false } }

    /// What to show under the field. An unverified token is not a failure
    /// to report as one.
    var message: String? {
        switch self {
        case let .failed(reason): reason
        case let .unverified(reason): "Saved, but not checked: \(reason)"
        case .idle, .checking, .signedIn: nil
        }
    }
}
