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

    /// Caches the last known token in memory, behind a lock, so repeated
    /// `read()` calls don't each pay a `SecItemCopyMatching` round trip.
    /// `ResolvingTokenProvider.authorizationHeader()` calls `read()` on
    /// every outgoing request — ~7 per series page, ~19 per library walk —
    /// on the client actor, in the critical path of every first paint that
    /// needs the network (wire review #72/#8, 2026-09-14).
    ///
    /// A class, not a struct field: `TokenStore` is a cheap, freely-copied
    /// value type (`ResolvingTokenProvider` holds one `let store` and reads
    /// from it repeatedly, but nothing guarantees only one copy of
    /// `TokenStore` ever exists), and every copy must see the same cached
    /// value and the same lock, which only a reference type gives for free.
    ///
    /// Invalidated by `write`/`clear`, the only two places the Keychain
    /// value can change — nothing else writes it, so nothing else needs to
    /// invalidate the cache.
    ///
    /// The review's "measure first" — a 100 µs-per-read threshold below
    /// which this isn't worth doing — was not measured: there is no device
    /// or simulator available to this change, so the cache is implemented
    /// unconditionally rather than gated behind a number nobody has taken.
    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        /// Outer `nil` = "never read since the last invalidation"; inner
        /// `nil` = "read, and confirmed there is no token". Both are cached
        /// states, and they must be distinguished: caching "no token" is
        /// what makes a signed-out reader's app not re-query the Keychain
        /// on every request either.
        private var value: String??

        func cached() -> String?? {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func store(_ token: String?) {
            lock.lock()
            defer { lock.unlock() }
            value = token
        }

        func invalidate() {
            lock.lock()
            defer { lock.unlock() }
            value = nil
        }
    }

    private let cache = Cache()

    /// Test-only observability: incremented once per actual Keychain query
    /// inside `read()`, immediately before `SecItemCopyMatching` is called.
    /// Lets a test prove the cache above stops a second `read()` from
    /// paying a second Keychain round trip, without needing to intercept
    /// the Security framework itself. Never read by production code.
    nonisolated(unsafe) static var keychainQueryCountForTesting = 0

    /// Reads the stored token, or `nil` when there is none.
    func read() -> String? {
        if let cached = cache.cached() { return cached }

        Self.keychainQueryCountForTesting += 1
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
        else {
            cache.store(nil)
            return nil
        }
        cache.store(token)
        return token
    }

    /// Replaces any stored token. Passing an empty string clears it.
    @discardableResult
    func write(_ token: String) -> Bool {
        defer { cache.invalidate() }
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
        defer { cache.invalidate() }
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
