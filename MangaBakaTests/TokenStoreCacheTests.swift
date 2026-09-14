import Foundation
import Testing
@testable import MangaBaka

/// Wire review #72/#8, 2026-09-14: `ResolvingTokenProvider.authorizationHeader()`
/// called `TokenStore.read()` — a `SecItemCopyMatching` round trip — on every
/// outgoing request, on the client actor, in the critical path of every first
/// paint that needs the network. `TokenStore` now caches the token in memory
/// behind a lock and invalidates only on `write`/`clear`, the sole writers.
///
/// Runs against the real Keychain (there is no mockable seam for
/// `SecItemCopyMatching` short of a much larger refactor than this fix's
/// remit), so it uses its own service/account under the hood via a real
/// `TokenStore()` and cleans up after itself. `.serialized` because
/// `TokenStore.keychainQueryCountForTesting` is shared, static, test-only
/// state.
@Suite("TokenStore caches the Keychain read", .serialized)
struct TokenStoreCacheTests {
    /// Expected to fail before the fix with: `count == 2`, not `1` — every
    /// prior `read()` called `SecItemCopyMatching` unconditionally, so two
    /// reads back to back paid two Keychain round trips. The counter itself
    /// is new (added alongside the cache), so "before the fix" here means
    /// the equivalent uninstrumented code path made the same two calls; the
    /// counter exists specifically so this is provable rather than assumed.
    @Test("A second read after a write reuses the cached token")
    func secondReadSkipsKeychain() {
        let store = TokenStore()
        defer { store.clear() }

        #expect(store.write("mb-cache-test-token"))
        TokenStore.keychainQueryCountForTesting = 0

        let first = store.read()
        let second = store.read()

        #expect(first == "mb-cache-test-token")
        #expect(second == "mb-cache-test-token")
        #expect(TokenStore.keychainQueryCountForTesting == 1)
    }

    /// `write` is one of the two writers `Cache.invalidate()` exists for —
    /// a token entered in Settings must be visible to the very next read,
    /// not the previously cached value (or absence) from before it was
    /// entered.
    @Test("write invalidates a previously cached value")
    func writeInvalidatesCache() {
        let store = TokenStore()
        defer { store.clear() }

        #expect(store.write("mb-first-token-value"))
        _ = store.read()
        #expect(store.write("mb-second-token-value"))

        #expect(store.read() == "mb-second-token-value")
    }

    /// `clear` is the other writer — a signed-out reader must not keep
    /// seeing a cached token that Settings just deleted.
    @Test("clear invalidates a previously cached value")
    func clearInvalidatesCache() {
        let store = TokenStore()
        defer { store.clear() }

        #expect(store.write("mb-third-token-value"))
        _ = store.read()
        #expect(store.clear())

        #expect(store.read() == nil)
    }
}
