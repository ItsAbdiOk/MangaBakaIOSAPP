import Foundation

/// The `URLSession` every third-party client uses.
///
/// Nine clients — AniList, Shikimori, Apple Books, Google Books, Open Library,
/// Webtoons, Naver, GigaViewer, MangaUpdates — each defaulted to
/// `URLSession.shared`, which meant none of the rules `APIClient` already has
/// for MangaBaka's own host applied to any of them:
///
/// **Cookies.** `URLSession.shared` accepts and replays them. Webtoons sets
/// five per answer (including a `locale` cookie with a one-year lifetime) and
/// Shikimori's DDoS-guard edge sets three `__ddg` cookies; all of those were
/// being stored in the shared cookie jar and sent back on every later request,
/// which is a per-device identifier this app never asked for and quietly
/// contradicts the privacy note's "the app sends nothing it did not choose to".
/// Nothing here needs a session: no third-party call signs in.
///
/// **Timeout.** `URLSession.shared` waits 60 seconds. `APIClient` settled on
/// 20 (`APIClient.defaultSessionConfiguration`, and see its comment for why —
/// one third-party outage held a request open past 60s), and the same number
/// is used here rather than a second guess: these are the same kind of request
/// to the same kind of host, and a widget or a Siri answer has far less
/// patience than a screen does.
///
/// **User-Agent.** Carried for every client at once, so the four that sent
/// none now do — see `AppUserAgent`.
///
/// **Disk cache.** Off. All nine clients keep their own on-disk caches with
/// their own freshness rules (`AppleBooksClient.readCache` and six siblings);
/// a second, invisible `URLCache` layer underneath them only makes "how old is
/// this answer" unanswerable, and the feed responses are `no-store` anyway.
enum ThirdPartySession {
    /// - Parameter configure: an escape hatch for a client that needs one
    ///   setting of its own without re-deriving the rest. Nothing uses it yet.
    static func make(
        configure: (URLSessionConfiguration) -> Void = { _ in }
    ) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        // Belt and braces: `.ephemeral` already has no persistent store, but
        // these two say the intent outright and survive someone swapping the
        // base configuration later.
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        // 20 seconds, the same number and the same reasoning as
        // `APIClient.defaultSessionConfiguration` (`APIClient.swift:34-36`) —
        // **a guess there and still one here**, not re-derived. Written as a
        // literal rather than read off that configuration object because it
        // is a mutable class instance and this is a different target's
        // concurrency domain; if that number is ever measured, change both.
        configuration.timeoutIntervalForRequest = 20
        configuration.httpAdditionalHeaders = ["User-Agent": AppUserAgent.value]
        configure(configuration)
        return URLSession(configuration: configuration)
    }

    /// One session shared by all nine clients, so they share one connection
    /// pool the way they would have on `URLSession.shared` — the thing that
    /// was actually right about the old default.
    static let shared = make()
}
