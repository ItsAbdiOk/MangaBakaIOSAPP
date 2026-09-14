import Foundation

/// What the release section says, and who it is saying it about.
struct ReleaseFailure: Equatable, Sendable {
    let source: ReleaseSource
    let error: APIError
}

struct ReleaseReport: Equatable, Sendable {
    /// From the edition the reader actually follows — the first provider, in
    /// `ReleaseFeedService.providers` order, to answer with something.
    let summary: ReleaseSummary
    /// Who said it, so the section can attribute itself the way the volumes
    /// shelf attributes Apple and Google. Nil when `summary` is `.none`.
    let source: ReleaseSource?
    /// The GigaViewer host's own name, e.g. "Tonari no Young Jump" — see
    /// `ReleaseFeed.sourceName`. Nil for every other source.
    let sourceName: String?
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
        summary: .none, source: nil, sourceName: nil, failures: []
    )
}

// MARK: - Where the translation gap used to be
//
// `TranslationGap` lived here (`TranslationGap.swift`, plus `ReleaseReport.gap`,
// `ReleaseFeedService.gap(primary:naver:)` and `ReleaseSection.gapLine`) until
// 2026-09-14. It compared the Korean original against the English translation a
// reader follows and said one of three things under the release rows: the
// original is N episodes ahead; the original has not released since <date>, so
// the translation will catch up and stop; or the original is complete, N ahead,
// so the translation will end there. The second and third are the ones worth
// having — nothing on the English side can reveal either.
//
// It went because its only input did. The original's episode numbers, its
// release dates, its `totalCount` and its `finished` flag all came from
// `comic.naver.com/api/article/list`, the undocumented JSON Naver's own page
// fetches. That adapter went (Q8) under the standing "no private APIs" rule,
// which the App Store answer — yes, it is going — makes non-negotiable. For a
// day afterwards the consumer side stood with no populator:
// `gap(primary:naver:)` returned `.none` for every series, and about a dozen
// tests went on passing against a provider wiring production did not have
// (`docs/reviews/full2/wire.md`, W6). Deleted rather than left as a field
// nothing can fill.
//
// To bring it back you need a *permitted* source that publishes, per series,
// the original's latest episode number, its recent release dates (for
// `Cadence`), and ideally a completion flag. Checked 2026-09-14 and none of
// what the app already has qualifies: `Series.totalChapters` and
// `Series.status` from MangaBaka's own `/v1/series/{id}` describe the
// catalogue entry as a whole, not an original distinct from a translation, so
// they cannot state a gap between the two; `WebtoonsFeedClient` and
// `GigaViewerFeedClient` both read the reader's own edition. A licensed or
// documented Korean feed, or a MangaBaka field that names the original's own
// progress, would be enough — `ReleaseSource.naverWebtoon` still recognises the
// links, so the series page can already tell that an original exists.
// Do not re-implement this against `/api/article/list`.

/// Turns whatever a series' release providers answer into one report.
///
/// A pure function over provider results, not a client of its own — so it can
/// be tested with stub providers instead of real network stand-ins. See
/// `ReleaseFeedServiceTests`.
struct ReleaseFeedService: Sendable {
    /// Preference order for which feed becomes the reader's edition. Webtoons
    /// before GigaViewer purely because that is the order they were built in;
    /// nothing about either publisher makes one more authoritative than the
    /// other.
    let providers: [any ReleaseFeedProvider]

    /// `now` went with `TranslationGap` on 2026-09-14 — it was only ever used
    /// to measure the original's silence against its own cadence. Nothing left
    /// in this function depends on the clock.
    func report(for series: Series, links: [SeriesLink]) async -> ReleaseReport {
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

        // The reader's own edition: the first feed to answer, in provider
        // order.
        guard let edition = feeds.first else {
            return ReleaseReport(
                summary: .none, source: nil, sourceName: nil, failures: failures
            )
        }

        let summary = ReleaseSummary.summarise(edition, knownChapterCount: series.totalChapters)
        guard !summary.isEmpty else {
            return ReleaseReport(
                summary: .none, source: nil, sourceName: nil, failures: failures
            )
        }

        return ReleaseReport(
            summary: summary, source: edition.source, sourceName: edition.sourceName,
            failures: failures
        )
    }

    /// Whatever the providers already have cached for a batch of library
    /// entries, with no network call — the counterpart to `report(for:)` for
    /// `ReleaseReminders.reschedule`, which needs a `[Int: ReleaseFeed]` to
    /// notice a confirmed episode or a season ending, but must not turn a
    /// reminder refresh into one request per series in the library.
    ///
    /// Same preference as `report(for:)`: providers are asked in `providers`
    /// order and the first to have something cached wins — Webtoons before
    /// GigaViewer in the production wiring.
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
    func cachedReport(for series: Series, links: [SeriesLink]) async -> ReleaseReport {
        for provider in providers {
            guard let feed = await provider.cachedFeed(for: series, links: links) else { continue }
            let summary = ReleaseSummary.summarise(feed, knownChapterCount: series.totalChapters)
            guard !summary.isEmpty else { continue }
            return ReleaseReport(
                summary: summary, source: feed.source, sourceName: feed.sourceName,
                failures: []
            )
        }
        return .empty
    }
}
