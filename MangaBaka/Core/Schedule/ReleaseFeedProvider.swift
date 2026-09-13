import Foundation

/// Something that can answer a series' release feed for one publisher.
///
/// One protocol, three adapters (`WebtoonsFeedClient`, `NaverFeedClient`,
/// `GigaViewerFeedClient`), assembled by `ReleaseFeedService`. Each adapter
/// owns its own request spacing and cache, because each publisher has its
/// own rules for both.
///
/// **Tapas was not built.** `tapas.io/series/<slug>.json` answers, but with
/// no episode list at all, and every episode-list URL shape tried (`/episodes`,
/// `/episode-list`, an RSS-style path, a paginated variant) answered 400 or
/// 302 (measured 2026-09-13). See docs/release-sources-2026-09-12.md.
protocol ReleaseFeedProvider: Sendable {
    var source: ReleaseSource { get }

    /// nil when no link belongs to this source, or the fetch failed. Failure
    /// is silent by design: the series page already has a cadence estimated
    /// from release history, and a provider only ever replaces it with
    /// something better when it can.
    func feed(for series: Series, links: [SeriesLink]) async -> ReleaseFeed?
}
