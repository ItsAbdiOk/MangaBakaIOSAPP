import Foundation

/// What the release section says, and who it is saying it about.
struct ReleaseReport: Equatable, Sendable {
    /// From the edition the reader actually follows — never from Naver alone
    /// unless Naver is all that answered.
    let summary: ReleaseSummary
    /// Who said it, so the section can attribute itself the way the volumes
    /// shelf attributes Apple and Google. Nil when `summary` is `.none`.
    let source: ReleaseSource?
    /// The GigaViewer host's own name, e.g. "Tonari no Young Jump" — see
    /// `ReleaseFeed.sourceName`. Nil for every other source.
    let sourceName: String?
    /// The original vs. the translation the reader is following.
    let gap: TranslationGap

    static let empty = ReleaseReport(summary: .none, source: nil, sourceName: nil, gap: .none)
}

/// Turns whatever a series' release providers answer into one report.
///
/// A pure function over provider results, not a client of its own — so it can
/// be tested with stub providers instead of real network stand-ins. See
/// `ReleaseFeedServiceTests`.
struct ReleaseFeedService: Sendable {
    /// Preference order for which feed becomes the reader's edition. Webtoons
    /// before GigaViewer purely because that is the order they were built in;
    /// nothing about either publisher makes one more authoritative than the
    /// other. Naver never becomes the reader's edition on its own merit — see
    /// `report(for:links:)` — so its position in this list does not matter.
    let providers: [any ReleaseFeedProvider]

    func report(for series: Series, links: [SeriesLink], now: Date = Date()) async -> ReleaseReport {
        // Every provider is asked concurrently — each spaces its own requests,
        // so asking one does not make the others wait, and a slow or dead
        // publisher does not hold up a fast one. Indexed rather than appended
        // as results arrive: a `TaskGroup` yields results in completion
        // order, not submission order, and `providers`' order is the
        // preference `primary` below depends on.
        let indexed = await withTaskGroup(of: (Int, ReleaseFeed?).self) { group in
            for (index, provider) in providers.enumerated() {
                group.addTask { (index, await provider.feed(for: series, links: links)) }
            }
            var slots = [ReleaseFeed?](repeating: nil, count: providers.count)
            for await (index, feed) in group {
                slots[index] = feed
            }
            return slots
        }
        let feeds = indexed.compactMap { $0 }

        let naver = feeds.first { $0.source == .naverWebtoon }
        // The reader's own edition: the first non-Naver feed to answer, in
        // provider order. Naver is the original, never what the reader reads.
        let primary = feeds.first { $0.source != .naverWebtoon }

        // A Korean-only reader: nothing translated exists, but Naver answered,
        // so the summary is Naver's own feed rather than staying empty.
        guard let edition = primary ?? naver else { return .empty }

        let summary = ReleaseSummary.summarise(edition, knownChapterCount: series.totalChapters)
        guard !summary.isEmpty else { return .empty }

        let gap = Self.gap(primary: primary, naver: naver, now: now)
        return ReleaseReport(
            summary: summary, source: edition.source, sourceName: edition.sourceName, gap: gap
        )
    }

    /// Only computed when there is a translated edition distinct from the
    /// original to compare against — a Korean-only reader already sees the
    /// original as `summary` and has nothing to compare it to.
    private static func gap(primary: ReleaseFeed?, naver: ReleaseFeed?, now: Date) -> TranslationGap {
        guard let primary, let naver else { return .none }
        guard let lastRelease = naver.lastEpisodeAt else { return .none }
        // Numbers restart each season on both sides — Tower of God is
        // "[Season 3] Ep. 235" on Webtoons and "3부 235화" on Naver, while
        // Naver's `totalCount` is 653, the count across all seasons. Measured
        // 2026-09-13; comparing 653 to 235 would have claimed the original was
        // 418 episodes ahead of a translation sitting on the same finale. So:
        // title-parsed numbers only when either side names a season, and only
        // when both are in the same season — a different season means the
        // original is ahead by an amount no number here can state, and
        // saying nothing beats stating a wrong one.
        let originalNumber: Int?
        switch (primary.latestSeason, naver.latestSeason) {
        case (nil, nil):
            // No seasons anywhere: the title-parsed number is the free
            // episode a Korean reader would give. `totalCount` counts every
            // article — paid-ahead episodes and non-episode posts alike —
            // and runs 6-11 past that: measured 2026-09-13, 화산귀환
            // (`totalCount` 185, newest free `174화`) and Lookism
            // (`totalCount` 624, newest free `617화`). It is used only when
            // no title parsed at all, so a thin paywalled list with no
            // parseable subtitle still has a number to fall back to.
            originalNumber = naver.latestEpisodeNumber ?? naver.totalCount
        case let (translated?, original?) where translated == original:
            originalNumber = naver.latestEpisodeNumber
        default:
            return .none
        }
        guard let originalNumber else { return .none }
        let cadence = Cadence.estimate(from: naver.releaseDates)
        return TranslationGap.between(
            translated: primary.latestEpisodeNumber,
            original: (number: originalNumber, lastRelease: lastRelease),
            originalCadence: cadence,
            originalFinished: naver.finished == true,
            now: now
        )
    }
}
