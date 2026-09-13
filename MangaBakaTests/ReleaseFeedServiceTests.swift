import Foundation
import Testing
@testable import MangaBaka

/// A provider that answers a fixed feed (or nil), for testing
/// `ReleaseFeedService` without any network stand-in.
private struct StubProvider: ReleaseFeedProvider {
    let source: ReleaseSource
    let answer: FeedAnswer

    init(source: ReleaseSource, answer: ReleaseFeed?) {
        self.source = source
        self.answer = .answered(answer)
    }

    init(source: ReleaseSource, answer: FeedAnswer) {
        self.source = source
        self.answer = answer
    }

    func feed(for series: Series, links: [SeriesLink]) async -> FeedAnswer { answer }
}

/// `ReleaseFeedService` is a pure function over its providers' answers, so
/// every case here is built from stubs rather than real clients.
@Suite("Release feed service")
struct ReleaseFeedServiceTests {
    private let now = Date(timeIntervalSince1970: 1_757_000_000)
    private let series = SeriesFactory.make(id: 1, title: "Tower of God")

    private func day(_ offset: Int) -> Date { now.addingTimeInterval(Double(offset) * 86_400) }

    private func episode(_ number: Int, daysAgo: Int, season: Int? = nil) -> ReleaseEntry {
        ReleaseEntry(title: "Episode \(number)", published: day(-daysAgo), number: number, season: season)
    }

    private func service(webtoons: ReleaseFeed, naver: ReleaseFeed) -> ReleaseFeedService {
        ReleaseFeedService(providers: [
            StubProvider(source: .webtoons, answer: webtoons),
            StubProvider(source: .naverWebtoon, answer: naver)
        ])
    }

    /// Tower of God, measured 2026-09-13: Webtoons "[Season 3] Ep. 235",
    /// Naver "3부 235화" with `totalCount` 653 across every season. A gap of
    /// 653 - 235 would be fiction; the two are on the same episode.
    @Test("Within one season the gap is measured on episode numbers, not totalCount")
    func sameSeasonIgnoresTotalCount() async {
        let webtoons = ReleaseFeed(
            title: "Webtoons", entries: [episode(235, daysAgo: 0, season: 3)], source: .webtoons
        )
        let naver = ReleaseFeed(
            title: "Naver", entries: (0..<4).map { episode(235 - $0, daysAgo: $0 * 7, season: 3) },
            source: .naverWebtoon, totalCount: 653
        )
        let report = await service(webtoons: webtoons, naver: naver).report(for: series, links: [], now: now)
        #expect(report.gap == .none)
    }

    @Test("Different seasons say nothing: no number here can state the gap")
    func differentSeasonsSayNothing() async {
        let webtoons = ReleaseFeed(
            title: "Webtoons", entries: [episode(120, daysAgo: 0, season: 2)], source: .webtoons
        )
        let naver = ReleaseFeed(
            title: "Naver", entries: (0..<4).map { episode(40 - $0, daysAgo: $0 * 7, season: 3) },
            source: .naverWebtoon, totalCount: 653
        )
        let report = await service(webtoons: webtoons, naver: naver).report(for: series, links: [], now: now)
        // 40 < 120 would otherwise read as "not ahead", and 653 - 120 as
        // "533 ahead". Both are wrong; silence is the honest answer.
        #expect(report.gap == .none)
    }

    @Test("Webtoons is preferred over GigaViewer when both answer")
    func webtoonsPreferredOverGigaViewer() async {
        let webtoons = ReleaseFeed(
            title: "Webtoons", entries: (1...4).map { episode($0, daysAgo: (4 - $0) * 7) },
            source: .webtoons
        )
        let giga = ReleaseFeed(
            title: "Giga", entries: (1...4).map { episode($0 + 10, daysAgo: (4 - $0) * 7) },
            source: .gigaViewer, sourceName: "Tonari no Young Jump"
        )
        // Provider order is Webtoons, then GigaViewer, matching the
        // production default in `SeriesDetailView`.
        let service = ReleaseFeedService(providers: [
            StubProvider(source: .webtoons, answer: webtoons),
            StubProvider(source: .gigaViewer, answer: giga)
        ])
        let report = await service.report(for: series, links: [], now: now)
        #expect(report.source == .webtoons)
    }

    @Test("GigaViewer is used when Webtoons has nothing")
    func gigaViewerWhenWebtoonsSilent() async {
        let giga = ReleaseFeed(
            title: "Giga", entries: (1...4).map { episode($0, daysAgo: (4 - $0) * 7) },
            source: .gigaViewer, sourceName: "Comic Days"
        )
        let service = ReleaseFeedService(providers: [
            StubProvider(source: .webtoons, answer: nil),
            StubProvider(source: .gigaViewer, answer: giga)
        ])
        let report = await service.report(for: series, links: [], now: now)
        #expect(report.source == .gigaViewer)
        #expect(report.sourceName == "Comic Days")
    }

    @Test("Naver is never the reader's edition when another source answers")
    func naverNeverPrimaryWhenAnotherExists() async {
        let webtoons = ReleaseFeed(
            title: "Webtoons", entries: (1...4).map { episode($0, daysAgo: (4 - $0) * 7) },
            source: .webtoons
        )
        let naver = ReleaseFeed(
            title: "Naver", entries: (1...4).map { episode($0 + 50, daysAgo: (4 - $0) * 7) },
            source: .naverWebtoon, totalCount: 60
        )
        let service = ReleaseFeedService(providers: [
            StubProvider(source: .webtoons, answer: webtoons),
            StubProvider(source: .naverWebtoon, answer: naver)
        ])
        let report = await service.report(for: series, links: [], now: now)
        #expect(report.source == .webtoons)
    }

    @Test("A Korean-only reader: only Naver answers, so the summary is Naver's own")
    func naverOnlyBecomesTheSummary() async {
        let naver = ReleaseFeed(
            title: "Naver", entries: (1...4).map { episode($0, daysAgo: (4 - $0) * 7) },
            source: .naverWebtoon, totalCount: 4
        )
        let service = ReleaseFeedService(providers: [
            StubProvider(source: .webtoons, answer: nil),
            StubProvider(source: .naverWebtoon, answer: naver)
        ])
        let report = await service.report(for: series, links: [], now: now)
        #expect(report.source == .naverWebtoon)
        #expect(!report.summary.isEmpty)
    }

    /// R3/F8 (`docs/reviews/reader.md`, `tests.md`, 2026-09-13): live GET,
    /// 화산귀환 (`titleId=769209`, no seasons): `totalCount` 185, newest free
    /// episode `174화` — five paid-ahead episodes and six non-episode
    /// articles sit between them. `totalCount` used to be preferred, so the
    /// gap read as 185 - translated, overstating the original by 11.
    /// Expected failure before the fix: `episodes == 85` (185 - 100), where
    /// this now asserts 74 (174 - 100).
    @Test("The gap uses Naver's title-parsed episode number, not its article-count totalCount")
    func gapPrefersTitleParsedNumberOverTotalCount() async {
        let webtoons = ReleaseFeed(
            title: "Webtoons", entries: [episode(100, daysAgo: 0)], source: .webtoons
        )
        let naver = ReleaseFeed(
            title: "Naver", entries: (0..<4).map { episode(174 - $0, daysAgo: $0 * 7) },
            source: .naverWebtoon, totalCount: 185
        )
        let service = ReleaseFeedService(providers: [
            StubProvider(source: .webtoons, answer: webtoons),
            StubProvider(source: .naverWebtoon, answer: naver)
        ])
        let report = await service.report(for: series, links: [], now: now)
        guard case let .ahead(episodes) = report.gap else {
            Issue.record("expected .ahead, got \(report.gap)")
            return
        }
        #expect(episodes == 74, "174 (title-parsed) - 100 (translated), not 185 (totalCount) - 100")
    }

    // Note: `naver.totalCount` as a fallback for when no title parses at all
    // is, by inspection, unreachable through `Self.gap` as written —
    // `naver.lastEpisodeAt` (computed from the same `episodes` filter as
    // `latestEpisodeNumber`) is nil exactly when `latestEpisodeNumber` is,
    // and `gap` already returns `.none` on a nil `lastEpisodeAt` before the
    // fallback is ever consulted. Left in place rather than removed — a
    // future feed shape might decouple the two — but a test exercising it
    // would be exercising dead code, so none is added here. Flagged for
    // whoever owns this file next rather than silently dropped.

    /// F7 (`docs/reviews/tests.md`, 2026-09-13): only the "both seasoned,
    /// different season" branch of the switch in `Self.gap` had a test. The
    /// two branches where exactly one side names a season landed on the same
    /// `default: return .none` and had never been exercised — this is the
    /// case the finale rule is written for: a series that has just finished
    /// a season shows up seasoned on Webtoons and, in the fixture available
    /// here, unseasoned on Naver.
    @Test("A season on one side only says nothing, not a wrong number")
    func onlyPrimarySeasonedSaysNothing() async {
        let webtoons = ReleaseFeed(
            title: "Webtoons", entries: [episode(112, daysAgo: 0, season: 1)], source: .webtoons
        )
        let naver = ReleaseFeed(
            title: "Naver", entries: (0..<4).map { episode(112 - $0, daysAgo: $0 * 7) },
            source: .naverWebtoon, totalCount: 112
        )
        let report = await service(webtoons: webtoons, naver: naver).report(for: series, links: [], now: now)
        #expect(report.gap == .none)
    }

    @Test("A season on the original only says nothing, not a wrong number")
    func onlyNaverSeasonedSaysNothing() async {
        let webtoons = ReleaseFeed(
            title: "Webtoons", entries: [episode(100, daysAgo: 0)], source: .webtoons
        )
        let naver = ReleaseFeed(
            title: "Naver", entries: (0..<4).map { episode(112 - $0, daysAgo: $0 * 7, season: 1) },
            source: .naverWebtoon, totalCount: 112
        )
        let report = await service(webtoons: webtoons, naver: naver).report(for: series, links: [], now: now)
        #expect(report.gap == .none)
    }

    /// R5 (`docs/reviews/reader.md`, 2026-09-13): `finished` was decoded and
    /// never read, so a completed Korean original read as `.originalPaused` —
    /// a hiatus, not a completion, and the opposite thing to tell a reader.
    /// Expected failure before the fix: `report.gap == .originalPaused(...)`
    /// where this now asserts `.originalComplete`.
    @Test("A finished original reports complete, not paused")
    func finishedOriginalIsComplete() async {
        let webtoons = ReleaseFeed(
            title: "Webtoons", entries: [episode(100, daysAgo: 0)], source: .webtoons
        )
        // Stale by any pause threshold (last release 400 days ago) — the
        // fixture that would otherwise land on `.originalPaused`.
        let naver = ReleaseFeed(
            title: "Naver", entries: (0..<4).map { episode(140 - $0, daysAgo: 400 + $0 * 7) },
            source: .naverWebtoon, totalCount: 140, finished: true
        )
        let report = await service(webtoons: webtoons, naver: naver).report(for: series, links: [], now: now)
        #expect(report.gap == .originalComplete(episodesAhead: 40))
    }

    /// R1 (`docs/reviews/reader.md`, 2026-09-13), through the whole service:
    /// True Beauty's real feed shape (4+ entries, "Episode 0"-"Episode 7",
    /// years old) against MangaBaka's own chapter count for the series.
    /// Expected failure before the fix: `report.summary` a `.rhythm` (and
    /// therefore `report != .empty`), where this now asserts `.empty`.
    @Test("A completed series' oldest-first feed reports empty, not a false rhythm")
    func oldestFirstFeedReportsEmpty() async {
        let completed = SeriesFactory.make(id: 1, title: "True Beauty", totalChapters: 230)
        let webtoons = ReleaseFeed(
            title: "Webtoons", entries: [
                episode(7, daysAgo: 0), episode(6, daysAgo: 7),
                episode(5, daysAgo: 14), episode(4, daysAgo: 21)
            ], source: .webtoons
        )
        let service = ReleaseFeedService(providers: [
            StubProvider(source: .webtoons, answer: webtoons)
        ])
        let report = await service.report(for: completed, links: [], now: now)
        #expect(report == .empty)
    }

    @Test("Nothing from any provider is .empty")
    func allNilIsEmpty() async {
        let service = ReleaseFeedService(providers: [
            StubProvider(source: .webtoons, answer: nil),
            StubProvider(source: .gigaViewer, answer: nil),
            StubProvider(source: .naverWebtoon, answer: nil)
        ])
        let report = await service.report(for: series, links: [], now: now)
        #expect(report == .empty)
    }

    /// Gap 19: before `FeedAnswer` existed, every provider returned
    /// `ReleaseFeed?`, so "Webtoons had a link and the request failed" and
    /// "this series has no Webtoons link at all" were both `nil` — a series
    /// with a real, matched Webtoons link and a dead connection reported the
    /// same silence as one that was never on Webtoons. Expected failure
    /// before the fix: this does not compile, because `ReleaseFeedProvider`
    /// had no `.failed` case to construct a stub with.
    @Test("A provider that had a link but failed is named in failedSources")
    func failedProviderIsNamed() async {
        let service = ReleaseFeedService(providers: [
            StubProvider(source: .webtoons, answer: .failed(.rateLimited(until: nil, party: .webtoons))),
            StubProvider(source: .naverWebtoon, answer: .notCarried)
        ])
        let report = await service.report(for: series, links: [], now: now)
        #expect(report.failedSources == [.webtoons])
        #expect(report.summary == .none)
    }

    @Test("A provider with no link for this series is not in failedSources")
    func notCarriedProviderIsNotNamed() async {
        let service = ReleaseFeedService(providers: [
            StubProvider(source: .webtoons, answer: .notCarried),
            StubProvider(source: .naverWebtoon, answer: .notCarried)
        ])
        let report = await service.report(for: series, links: [], now: now)
        #expect(report.failedSources.isEmpty)
    }
}
