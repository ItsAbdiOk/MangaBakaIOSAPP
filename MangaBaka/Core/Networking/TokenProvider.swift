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

/// Resolves credentials fresh on every request.
///
/// The app used to choose one provider at launch. If no token existed then, the
/// client was pinned to unauthenticated for the whole session — so a token
/// entered in Settings was written to the Keychain and then never read, and
/// every attempt to validate it was rejected regardless of whether it was good.
struct ResolvingTokenProvider: TokenProvider {
    private let store: TokenStore
    private let buildTimeToken: String?

    init(store: TokenStore = TokenStore(), infoDictionary: [String: Any]?) {
        self.store = store
        self.buildTimeToken = PATTokenProvider(infoDictionary: infoDictionary)?.token
    }

    func authorizationHeader() async -> (field: String, value: String)? {
        // A token the reader entered on this device wins over one baked in at
        // build time; unauthenticated is a fully functional mode, not a
        // degraded one, because every discovery endpoint is public.
        guard let token = store.read() ?? buildTimeToken else { return nil }
        return ("x-api-key", token)
    }
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
