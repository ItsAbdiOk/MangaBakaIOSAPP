import Foundation
import Security

/// Stores a personal access token in the Keychain.
///
/// The Keychain rather than UserDefaults because a PAT never expires and grants
/// full access to the account it belongs to. `afterFirstUnlock` means the app
/// can read it on a background refresh, but it is unreadable while the device
/// has not been unlocked since boot.
///
/// `ThisDeviceOnly` keeps it out of iCloud Keychain and off device backups: a
/// token that syncs is a token that leaks somewhere its owner did not expect.
struct TokenStore: Sendable {
    /// Which secret this store holds. Parameterised rather than copied when a
    /// second secret arrived (the Google Books key): the Keychain query, the
    /// `ThisDeviceOnly` accessibility and the delete-on-empty behaviour are
    /// the parts worth getting right once.
    private let service: String
    private let account = "default"

    /// The personal access token, which is what this held before there was
    /// anything else.
    static let patService = "org.mangabaka.pat"
    /// The Google Books API key. A quota identifier rather than a credential —
    /// it reaches no account — but it is still the reader's to keep off
    /// backups and out of iCloud, and it costs nothing to store it the same way.
    static let googleBooksService = "org.mangabaka.googlebooks"

    init(service: String = TokenStore.patService) {
        self.service = service
    }

    /// Reads the stored token, or `nil` when there is none.
    func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let token = String(data: data, encoding: .utf8),
              !token.isEmpty
        else { return nil }
        return token
    }

    /// Replaces any stored token. Passing an empty string clears it.
    @discardableResult
    func write(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return clear() }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(trimmed.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return true }
        if status == errSecItemNotFound {
            return SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
                == errSecSuccess
        }
        return false
    }

    @discardableResult
    func clear() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// The shape MangaBaka documents for a personal access token. Checked before
    /// storing so an obvious paste error is caught at the point of entry rather
    /// than surfacing later as an unexplained 401.
    static func looksValid(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("mb-") && trimmed.count > 12
    }
}

/// What checking a token actually established.
///
/// Three outcomes, not two. Collapsing them is what let a network failure be
/// reported as "That token was not accepted by MangaBaka" — and then delete a
/// working token from the Keychain, because the save path treats a failed check
/// as proof the token is bad.
enum TokenCheck: Equatable, Sendable {
    case accepted(String?)
    /// MangaBaka answered, and said no. The only outcome that justifies
    /// clearing the stored token.
    case rejected
    /// Something else went wrong — offline, rate limited, a 500. Says nothing
    /// about the token.
    case unknown(String)

    var isRejection: Bool { self == .rejected }
}
