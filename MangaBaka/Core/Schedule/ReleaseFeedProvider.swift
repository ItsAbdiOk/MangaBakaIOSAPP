import Foundation

/// What one release-feed provider produced for one series.
///
/// Three shapes, not the bare `ReleaseFeed?` this used to be (gap 19). A
/// provider that never had a link for this series at all (`.notCarried`) must
/// not look the same, to `ReleaseFeedService`, as one that had a link and
/// asked but the network or the parser failed (`.failed`) — the first is
/// silent by design (the series page always has a cadence estimate to fall
/// back on), the second is what `ReleaseSection`'s `InlineFailure` (batch 2)
/// needs to show instead of quietly having nothing. `.answered(nil)` is the
/// third shape still: a real ask that came back with nothing usable — no
/// candidate URL resolved to a live feed, or a feed that parsed with zero
/// entries, the shape a localised non-English Webtoons edition takes — which
/// is a legitimate empty answer, not a failure.
enum FeedAnswer: Equatable, Sendable {
    case notCarried
    case answered(ReleaseFeed?)
    case failed(APIError)

    /// The feed, when this answer carried one. Nil for `.notCarried`,
    /// `.answered(nil)`, and `.failed` — mirrors `Fetched.value` for the one
    /// case (`.answered(nil)`) that type does not have a slot for.
    var feed: ReleaseFeed? {
        if case let .answered(feed) = self { return feed }
        return nil
    }
}

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

    /// See `FeedAnswer`. A cadence estimated from release history is always
    /// on the series page as a fallback, so `.failed` is never itself a
    /// reason to block the page — only to tell `ReleaseSection` there is a
    /// reason this provider has nothing, instead of it looking unasked.
    func feed(for series: Series, links: [SeriesLink]) async -> FeedAnswer

    /// Whatever this provider already has on disk for this series, with no
    /// request and no spacing claim — the cache `feed(for:links:)` would have
    /// read had it been called, and nothing more. Cache age is ignored: a
    /// season-ended or Naver-finished feed a week stale is still season-ended
    /// or finished, and `ReleaseReminders.reschedule` only needs to notice a
    /// change since the last time it looked, not a fresh number.
    ///
    /// Built for `ReleaseFeedService.cachedFeeds(for:links:)`, which
    /// `RootView+Session.refreshReminders` calls so the confirmed-episode,
    /// season-ended and Naver-finished notification conditions can fire from
    /// whatever a prior series-page visit already cached, without adding a
    /// single network call of its own.
    func cachedFeed(for series: Series, links: [SeriesLink]) async -> ReleaseFeed?
}

extension ReleaseFeedProvider {
    /// Default for anything that keeps no cache of its own (stubs in tests):
    /// nothing to read, so nothing to answer.
    func cachedFeed(for series: Series, links: [SeriesLink]) async -> ReleaseFeed? { nil }
}
