import Foundation

/// How this app identifies itself to every host it talks to.
///
/// One string, in one place. It was declared three times before this file
/// existed — `APIClient`, `ShikimoriClient` and `MangaUpdatesClient` each
/// carried an identical literal — and was absent entirely from
/// `OpenLibraryCovers`, `WebtoonsFeedClient` and
/// `GigaViewerFeedClient`, which is the part that matters: Open Library's
/// covers policy asks clients to identify themselves so they can contact a
/// misbehaving one instead of blocking it, and a publisher reading its own
/// logs has nothing else to go on.
///
/// Two of the hosts refuse an unidentified client outright: MangaBaka answers
/// 403 (verified 2026-09-08 — urllib's default agent is rejected where curl's
/// is accepted) and Shikimori's terms require it. So this is not politeness
/// that can be dropped; it is a request header two APIs will not work
/// without, and the cheapest courtesy the app can pay the other seven.
///
/// Carried by `ThirdPartySession.make()` through `httpAdditionalHeaders`, so
/// no client needs per-request code to send it.
enum AppUserAgent {
    /// Names the project and links the repository, so a host that wants this
    /// app to stop can say so rather than silently blocking it.
    static let value = "MangaBakaIOS/1.0 (+https://github.com/ItsAbdiOk/MangaBakaIOSAPP)"
}
