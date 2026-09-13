import Foundation
import Testing
@testable import MangaBaka

/// A provider that answers a fixed feed (or nil), for testing
/// `ReleaseFeedService` without any network stand-in.
private struct StubProvider: ReleaseFeedProvider {
    let source: ReleaseSource
    let answer: ReleaseFeed?

    func feed(for series: Series, links: [SeriesLink]) async -> ReleaseFeed? { answer }
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

    @Test("The gap uses Naver's totalCount rather than its latest episode number")
    func gapUsesTotalCountOverLatestNumber() async {
        let webtoons = ReleaseFeed(
            title: "Webtoons", entries: [episode(100, daysAgo: 0)], source: .webtoons
        )
        // Naver's public article list is thin (paywalled), so its highest
        // *listed* number is only 105 — but totalCount says the real original
        // is at 140, and that is the number the gap must be measured against.
        let naver = ReleaseFeed(
            title: "Naver", entries: (1...4).map { episode($0 + 100, daysAgo: (4 - $0) * 7) },
            source: .naverWebtoon, totalCount: 140
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
        // 140 (totalCount) - 100 (translated) = 40, not 104 (latest listed) - 100 = 4.
        #expect(episodes == 40)
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
}
