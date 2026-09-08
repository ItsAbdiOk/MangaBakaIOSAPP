import Foundation

/// Supplies the authentication header for an outgoing request, if any.
///
/// This seam exists so that migrating from a personal access token to OAuth
/// changes one type rather than every call site. The two implementations set
/// different headers (`x-api-key` vs `Authorization: Bearer`), and the OAuth
/// one will additionally own refresh-token rotation and Keychain storage —
/// which is why it is a protocol and not a stored string.
protocol TokenProvider: Sendable {
    /// Header field and value to attach, or `nil` for an unauthenticated request.
    func authorizationHeader() async -> (field: String, value: String)?
}

/// No credentials. Every discovery endpoint is public, so this is a fully
/// functional mode, not a degraded one.
struct UnauthenticatedTokenProvider: TokenProvider {
    func authorizationHeader() async -> (field: String, value: String)? { nil }
}

/// Development-only. Reads a personal access token supplied at build time via
/// the gitignored `Secrets.xcconfig`.
///
/// A PAT is a real credential for a real account and never expires, so a build
/// containing one grants whoever holds the binary full access to that account.
/// Local builds only — never TestFlight, never the App Store.
struct PATTokenProvider: TokenProvider {
    let token: String

    /// Returns `nil` when no token was configured, so an absent
    /// `Secrets.xcconfig` degrades to unauthenticated rather than crashing.
    init?(infoDictionary: [String: Any]?) {
        guard let raw = infoDictionary?["MB_PAT"] as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // The example file ships a placeholder; treat it as absent.
        guard !trimmed.isEmpty, trimmed.hasPrefix("mb-"),
              trimmed != "mb-your-personal-access-token-here" else { return nil }
        self.token = trimmed
    }

    func authorizationHeader() async -> (field: String, value: String)? {
        ("x-api-key", token)
    }
}
