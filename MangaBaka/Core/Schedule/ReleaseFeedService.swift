import Foundation

/// What the release section says, and who it is saying it about.
struct ReleaseFailure: Equatable, Sendable {
    let source: ReleaseSource
    let error: APIError
}

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
    /// Which providers were carrying a link for this series and asked, but
    /// failed (gap 19) — as opposed to a provider with nothing to say
    /// (`.notCarried`) or one that answered but had nothing (`.answered(nil)`,
    /// e.g. a series not in this issue of a magazine). `ReleaseSection`
    /// (batch 2) reads this to show `InlineFailure` instead of silently
    /// having no release row for a series that clearly has a Webtoons link.
    /// Each source that was asked and failed, with the error it failed with,
    /// so the section can say "Webtoons had a problem" in the error's own
    /// words rather than reconstructing one from the source name.
    let failures: [ReleaseFailure]
    var failedSources: [ReleaseSource] { failures.map(\.source) }

    static let empty = ReleaseReport(
        summary: .none, source: nil, sourceName: nil, gap: .none, failures: []
    )
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
        let indexed = await withTaskGroup(of: (Int, FeedAnswer).self) { group in
            for (index, provider) in providers.enumerated() {
                group.addTask { (index, await provider.feed(for: series, links: links)) }
            }
            var slots = [FeedAnswer](repeating: .notCarried, count: providers.count)
            for await (index, answer) in group {
                slots[index] = answer
            }
            return slots
        }
        let answers = zip(providers.map(\.source), indexed)
        let failures: [ReleaseFailure] = answers.compactMap { source, answer in
            if case let .failed(error) = answer { return ReleaseFailure(source: source, error: error) }
            return nil
        }
        let feeds = indexed.compactMap(\.feed)

        let naver = feeds.first { $0.source == .naverWebtoon }
        // The reader's own edition: the first non-Naver feed to answer, in
        // provider order. Naver is the original, never what the reader reads.
        let primary = feeds.first { $0.source != .naverWebtoon }

        // A Korean-only reader: nothing translated exists, but Naver answered,
        // so the summary is Naver's own feed rather than staying empty.
        guard let edition = primary ?? naver else {
            return ReleaseReport(
                summary: .none, source: nil, sourceName: nil, gap: .none, failures: failures
            )
        }

        let summary = ReleaseSummary.summarise(edition, knownChapterCount: series.totalChapters)
        guard !summary.isEmpty else {
            return ReleaseReport(
                summary: .none, source: nil, sourceName: nil, gap: .none, failures: failures
            )
        }

        let gap = Self.gap(primary: primary, naver: naver, now: now)
        return ReleaseReport(
            summary: summary, source: edition.source, sourceName: edition.sourceName, gap: gap,
            failures: failures
        )
    }

    /// Whatever the providers already have cached for a batch of library
    /// entries, with no network call — the counterpart to `report(for:)` for
    /// `ReleaseReminders.reschedule`, which needs a `[Int: ReleaseFeed]` to
    /// notice a confirmed episode, a season ending, or a Naver-finished
    /// original, but must not turn a reminder refresh into one request per
    /// series in the library.
    ///
    /// Same preference as `report(for:)`: providers are asked in `providers`
    /// order and the first to have something cached wins — Webtoons before
    /// GigaViewer before Naver in the production wiring. Unlike `report`,
    /// there is no separate Naver-as-original slot: a reminder only needs one
    /// feed per series to test the three conditions against, and Naver
    /// answering when nothing else does is exactly the "Korean-only reader"
    /// case `report` already treats as the edition.
    ///
    /// - Parameter links: a series id's stored links, e.g.
    ///   `SeriesRepositoryProtocol.cachedExtras(for:)?.links` — never a
    ///   fetch; a series with nothing cached simply supplies `[]`.
    func cachedFeeds(
        for entries: [LibraryEntry], links: @Sendable (Int) -> [SeriesLink]
    ) async -> [Int: ReleaseFeed] {
        var result: [Int: ReleaseFeed] = [:]
        for entry in entries {
            guard let series = entry.series else { continue }
            let seriesLinks = links(entry.seriesId)
            for provider in providers {
                if let feed = await provider.cachedFeed(for: series, links: seriesLinks) {
                    result[entry.seriesId] = feed
                    break
                }
            }
        }
        return result
    }

    /// `report(for:links:)` over whatever is already cached, with no network
    /// call and no spacing claim.
    ///
    /// Abdi, 2026-09-14 (Q12): Siri answers from cache only. One "what's due
    /// this week" used to fire up to eight `report(for:links:)` calls, and
    /// every Webtoons candidate serialises behind one 3.5 s actor with a
    /// placeholder lookup first — so eight placeholder-linked series is
    /// sixteen slots and up to 56 seconds. Siri gives up with a generic error
    /// long before that, and the requests still complete, having spent the
    /// publishers' budget on an answer nobody heard. A first ask on a cold
    /// cache now falls back to the MangaUpdates estimate, which is what the
    /// widget shows anyway.
    ///
    /// The `gap` is deliberately `.none`: it needs Naver's original feed
    /// beside the translation, and the whole point here is to ask nobody.
    func cachedReport(for series: Series, links: [SeriesLink]) async -> ReleaseReport {
        for provider in providers {
            guard let feed = await provider.cachedFeed(for: series, links: links) else { continue }
            let summary = ReleaseSummary.summarise(feed, knownChapterCount: series.totalChapters)
            guard !summary.isEmpty else { continue }
            return ReleaseReport(
                summary: summary, source: feed.source, sourceName: feed.sourceName,
                gap: .none, failures: []
            )
        }
        return .empty
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
