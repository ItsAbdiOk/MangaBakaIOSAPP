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
    private let service = "org.mangabaka.pat"
    private let account = "default"

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
