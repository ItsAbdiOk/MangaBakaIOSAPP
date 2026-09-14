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

    /// `store` has no default. It used to be `= TokenStore()`, which built a
    /// third instance of a type whose memo was per-instance, so the client
    /// read a stale "no token" while Settings wrote into a different one
    /// (second-pass review S1, 2026-09-14). The memo is static now and the
    /// bug cannot come back through this door, but the parameter stays
    /// required so the single owner of the store is visible at the one call
    /// site that builds this (`AppServices.init`).
    init(store: TokenStore, infoDictionary: [String: Any]?) {
        self.store = store
        self.buildTimeToken = PATTokenProvider(infoDictionary: infoDictionary)?.token
    }

    /// Whether this provider can authenticate a request at all.
    ///
    /// The decision lives here because this is where the credential is
    /// resolved. `AppServices` used to spell it `{ keychain.read() != nil }`
    /// in two places, which ignored `buildTimeToken` — so every Debug build
    /// with `MB_PAT` in `Secrets.xcconfig` and nothing in the Keychain said
    /// "No account" in the Library tab and cleared Spotlight, the widget and
    /// the taste ledger on every launch, while Discover, the stack and
    /// Settings' token check all authenticated successfully. Two definitions
    /// of "signed in", disagreeing on exactly the builds the app is developed
    /// on — which is the reason S1 above survived every walk
    /// (second-pass review item 13 / S3, 2026-09-14).
    ///
    /// Same expression as `authorizationHeader()`'s guard, deliberately: if
    /// that one can produce a header, this must answer `true`.
    var hasCredentials: Bool { store.read() != nil || buildTimeToken != nil }

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
