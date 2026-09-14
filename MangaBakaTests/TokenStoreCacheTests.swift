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
///
/// **Every test here uses two `TokenStore` instances on purpose.** The
/// original three were single-instance and were green over the worst bug in
/// the tree (second-pass review S1, 2026-09-14): the memo was
/// `private let cache`, so each of the app's three `TokenStore()`s memoised
/// separately, Settings' write was invisible to the API client's read, and a
/// pasted token on a Release install was validated unauthenticated, 401'd and
/// deleted as rejected. One instance can never see that. Do not simplify these
/// back to one `store`.
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
        let writer = TokenStore()
        let reader = TokenStore()
        defer { writer.clear() }

        #expect(writer.write("mb-cache-test-token"))
        TokenStore.keychainQueryCountForTesting = 0

        let first = reader.read()
        let second = reader.read()

        #expect(first == "mb-cache-test-token")
        #expect(second == "mb-cache-test-token")
        // One query total across two *different* instances: the memo is
        // static, so the second instance's first read is already served.
        #expect(TokenStore.keychainQueryCountForTesting == 1)
    }

    /// The test S1 says was missing, and the reason the memo is static.
    ///
    /// Expected to fail on the pre-fix code with `a.read()` returning `nil`
    /// rather than `"mb-two-instances-token"`: `a.read()` caches
    /// `.some(nil)` in instance `a`'s own `Cache`, `b.write` invalidates only
    /// `b`'s, so `a` keeps answering "no token" — which is precisely the
    /// sequence the app performs on a fresh install (launch feed → paste
    /// token in Settings → validate).
    @Test("A token written through one instance is visible through another")
    func writeIsVisibleToASecondInstance() {
        let apiClientsStore = TokenStore()
        let settingsStore = TokenStore()
        defer { settingsStore.clear() }

        settingsStore.clear()
        #expect(apiClientsStore.read() == nil)

        #expect(settingsStore.write("mb-two-instances-token"))

        #expect(apiClientsStore.read() == "mb-two-instances-token")
    }

    /// The mirror, and S1's third failure: "Remove token" cleared Settings'
    /// instance while the API client and `hasCredentials` went on sending and
    /// reporting the removed token until the next relaunch.
    ///
    /// Expected to fail on the pre-fix code with `a.read()` returning
    /// `"mb-removed-token-value"` rather than `nil`.
    @Test("Clearing through one instance is visible through another")
    func clearIsVisibleToASecondInstance() {
        let apiClientsStore = TokenStore()
        let settingsStore = TokenStore()
        defer { settingsStore.clear() }

        #expect(settingsStore.write("mb-removed-token-value"))
        #expect(apiClientsStore.read() == "mb-removed-token-value")

        #expect(settingsStore.clear())

        #expect(apiClientsStore.read() == nil)
    }

    /// `write` is one of the two writers `Cache.invalidate()` exists for —
    /// a token entered in Settings must be visible to the very next read,
    /// not the previously cached value (or absence) from before it was
    /// entered.
    @Test("write invalidates a previously cached value")
    func writeInvalidatesCache() {
        let writer = TokenStore()
        let reader = TokenStore()
        defer { writer.clear() }

        #expect(writer.write("mb-first-token-value"))
        _ = reader.read()
        #expect(writer.write("mb-second-token-value"))

        #expect(reader.read() == "mb-second-token-value")
    }

    /// `clear` is the other writer — a signed-out reader must not keep
    /// seeing a cached token that Settings just deleted.
    @Test("clear invalidates a previously cached value")
    func clearInvalidatesCache() {
        let writer = TokenStore()
        let reader = TokenStore()
        defer { writer.clear() }

        #expect(writer.write("mb-third-token-value"))
        _ = reader.read()
        #expect(writer.clear())

        #expect(reader.read() == nil)
    }

    /// Item 72, 2026-09-14: `Scripts/check-credentials.sh` looked for
    /// `mb-[A-Za-z0-9]{16,}` while `TokenStore.looksValid` accepts `mb-` plus
    /// a total length over 12 — a ten-character suffix. Every token between
    /// those two lengths was one the app would store and the pre-push scanner
    /// would not see. A shell script cannot read a Swift constant, so this is
    /// the seam that stops them drifting again: it derives both numbers from
    /// the two files and asserts the scanner is not the looser of the pair.
    ///
    /// Expected to fail on the pre-fix script with `16 > 10` — the scanner's
    /// floor above the app's, which is the wrong way round.
    ///
    /// Source-read like the rest of the shell pins, so it is skipped when the
    /// source tree is not beside the bundle (see `SourceTree` and work-list
    /// item 60 — those runs are the ones Xcode Cloud makes).
    @Test("The credential scanner is not looser than the token the app accepts",
          .enabled(if: SourceTree.isAvailable))
    func scannerMatchesLooksValid() throws {
        let swift = try SourceTree.read("MangaBaka/Core/Auth/TokenStore.swift")
        let script = try SourceTree.read("Scripts/check-credentials.sh")

        // `trimmed.count > 12` counts the whole token, `mb-` included.
        let minimumTotal = try #require(
            swift.firstMatch(of: Self.looksValidLength).flatMap { Int($0.1) }
        )
        let scannerSuffix = try #require(
            script.firstMatch(of: Self.scannerSuffixLength).flatMap { Int($0.1) }
        )

        #expect(scannerSuffix <= minimumTotal + 1 - "mb-".count)
    }

    /// Computed, not stored: CLAUDE.md's rule for regexes in this project.
    private static var looksValidLength: Regex<(Substring, Substring)> {
        /trimmed\.count > (\d+)/
    }

    private static var scannerSuffixLength: Regex<(Substring, Substring)> {
        /mb-\[A-Za-z0-9\]\{(\d+),\}/
    }

    /// The other half of "who is signed in", kept inside this `.serialized`
    /// suite because it reads the same real Keychain item: run in parallel
    /// with the tests above, the negative control would see their token.
    @Suite("Two definitions of signed in")
    struct ProviderCredentialsTests {
        /// Item 13 / S3, 2026-09-14. `AppServices` spelled "signed in" as
        /// `{ keychain.read() != nil }` in two places while the client spelled it
        /// `store.read() ?? buildTimeToken`, so every Debug build with `MB_PAT`
        /// and an empty Keychain — Abdi's own — showed "No account" in the
        /// Library tab and cleared Spotlight, the widget and the taste ledger on
        /// every launch, while Discover, the stack and Settings' token check
        /// all authenticated. That disagreement is why the S1 bug this suite
        /// guards survived every walk of the app.
        ///
        /// Expected to fail before the fix with a compile error, not a wrong
        /// value: `hasCredentials` did not exist on `ResolvingTokenProvider` at
        /// all — the rule lived twice, inline, inside `AppServices.init`, where
        /// no test could reach it. The behavioural assertion that fails on a
        /// *value* is `providerWithoutPATOrTokenHasNoCredentials` below, which
        /// pins the other half: nothing configured still means nothing.
        @Test("A build-time MB_PAT counts as credentials even with an empty Keychain")
        func providerWithPATHasCredentials() {
            let store = TokenStore()
            store.clear()
            defer { store.clear() }

            let provider = ResolvingTokenProvider(
                store: store, infoDictionary: ["MB_PAT": "mb-abcdefghijklmnop"]
            )

            #expect(provider.hasCredentials)
        }

        /// The control: the same provider with nothing configured must say no,
        /// so the test above is not passing because `hasCredentials` is `true`.
        @Test("No token and no MB_PAT is no credentials")
        func providerWithoutPATOrTokenHasNoCredentials() {
            let store = TokenStore()
            store.clear()
            defer { store.clear() }

            let provider = ResolvingTokenProvider(store: store, infoDictionary: [:])

            #expect(!provider.hasCredentials)
        }

        /// The two spellings must not drift apart again: anything that can
        /// produce an `x-api-key` header has credentials, by construction.
        @Test("hasCredentials agrees with the header the provider would send")
        func hasCredentialsAgreesWithHeader() async {
            let store = TokenStore()
            store.clear()
            defer { store.clear() }

            let provider = ResolvingTokenProvider(
                store: store, infoDictionary: ["MB_PAT": "mb-abcdefghijklmnop"]
            )

            #expect(await provider.authorizationHeader() != nil)
            #expect(provider.hasCredentials)
        }
    }
}
