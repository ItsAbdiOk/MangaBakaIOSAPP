import Foundation

/// Where the Google Books API key comes from, and what a plausible one looks
/// like.
///
/// Two sources, in the order a reader would expect: a key typed into Settings
/// on this device wins over one baked in at build time. Same rule as the
/// personal access token — see `ResolvingTokenProvider` — and for the same
/// reason: a key entered on the phone should take effect immediately rather
/// than after a rebuild.
///
/// The build-time key lives in the gitignored `Secrets.xcconfig`, which
/// `Debug.xcconfig` alone includes, so a Release build has none. That is what
/// makes the Settings field more than a convenience: on a device build it is
/// the only way the key can get there at all.
///
/// Without a key the feature is simply off. Google's keyless tier shares one
/// anonymous quota with every unauthenticated caller on the internet and it
/// was already exhausted when measured (HTTP 429, 2026-09-12), so "no key"
/// means "ask Google nothing", not "ask and hope".
enum GoogleBooksKey {
    static func resolved(
        store: TokenStore = TokenStore(service: TokenStore.googleBooksService),
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary
    ) -> String? {
        if let entered = store.read(), looksValid(entered) { return entered }
        let built = infoDictionary?["MB_GOOGLE_BOOKS_KEY"] as? String
        return built.flatMap { looksValid($0) ? $0 : nil }
    }

    /// Google's own format: keys begin "AIza" and are 39 characters.
    ///
    /// Checked rather than trusted because the build-time value arrives from
    /// an xcconfig, where an unsubstituted `$(MB_GOOGLE_BOOKS_KEY)` or the
    /// example file's placeholder would otherwise be sent to Google as if it
    /// were real — one request, one 400, per series page.
    static func looksValid(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("AIza") && trimmed.count == 39
    }
}
