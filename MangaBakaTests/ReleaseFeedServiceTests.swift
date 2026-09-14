import Foundation
import os
import Testing
@testable import MangaBaka

/// A provider that answers a fixed feed (or nil), for testing
/// `ReleaseFeedService` without any network stand-in.
private struct StubProvider: ReleaseFeedProvider {
    let source: ReleaseSource
    let answer: FeedAnswer
    /// What `cachedFeed(for:links:)` answers — `answer.feed` by default, so a
    /// stub built only for `report(for:)` tests still behaves sensibly if
    /// `cachedFeeds` is ever run against it, but overridable for a
    /// `cachedFeeds` test that wants cache and live-fetch answers to differ.
    let cached: ReleaseFeed?

    init(source: ReleaseSource, answer: ReleaseFeed?, cached: ReleaseFeed? = nil) {
        self.source = source
        self.answer = .answered(answer)
        self.cached = cached ?? answer
    }

    init(source: ReleaseSource, answer: FeedAnswer, cached: ReleaseFeed? = nil) {
        self.source = source
        self.answer = answer
        self.cached = cached ?? answer.feed
    }

    func feed(for series: Series, links: [SeriesLink]) async -> FeedAnswer { answer }
    func cachedFeed(for series: Series, links: [SeriesLink]) async -> ReleaseFeed? { cached }
}

/// `ReleaseFeedService` is a pure function over its providers' answers, so
/// every case here is built from stubs rather than real clients.
@Suite("Release feed service")
struct ReleaseFeedServiceTests {
    /// Only a fixed base for `day(_:)` below. `report(for:links:)` stopped
    /// taking a `now` when `TranslationGap` went — nothing left in the service
    /// reads a clock.
    private let now = Date(timeIntervalSince1970: 1_757_000_000)
    private let series = SeriesFactory.make(id: 1, title: "Tower of God")

    private func day(_ offset: Int) -> Date { now.addingTimeInterval(Double(offset) * 86_400) }

    private func episode(_ number: Int, daysAgo: Int, season: Int? = nil) -> ReleaseEntry {
        ReleaseEntry(title: "Episode \(number)", published: day(-daysAgo), number: number, season: season)
    }

    // The translation-gap tests were here — six of them, plus the two that
    // made Naver the reader's edition. All deleted 2026-09-14 with
    // `TranslationGap` itself (`docs/reviews/full2/wire.md` W6): every one
    // built a `StubProvider(source: .naverWebtoon, ...)`, a provider wiring
    // production has not had since the Naver adapter was removed on
    // 2026-09-13, so they were green over unreachable code. See the tombstone
    // in `ReleaseFeedService.swift` for what they were asserting and what a
    // permitted source would have to supply to bring them back.

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
        let report = await service.report(for: series, links: [])
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
        let report = await service.report(for: series, links: [])
        #expect(report.source == .gigaViewer)
        #expect(report.sourceName == "Comic Days")
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
        let report = await service.report(for: completed, links: [])
        #expect(report == .empty)
    }

    @Test("Nothing from any provider is .empty")
    func allNilIsEmpty() async {
        let service = ReleaseFeedService(providers: [
            StubProvider(source: .webtoons, answer: nil),
            StubProvider(source: .gigaViewer, answer: nil)
        ])
        let report = await service.report(for: series, links: [])
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
            StubProvider(source: .gigaViewer, answer: .notCarried)
        ])
        let report = await service.report(for: series, links: [])
        #expect(report.failedSources == [.webtoons])
        #expect(report.summary == .none)
    }

    @Test("A provider with no link for this series is not in failedSources")
    func notCarriedProviderIsNotNamed() async {
        let service = ReleaseFeedService(providers: [
            StubProvider(source: .webtoons, answer: .notCarried),
            StubProvider(source: .gigaViewer, answer: .notCarried)
        ])
        let report = await service.report(for: series, links: [])
        #expect(report.failedSources.isEmpty)
    }
}

/// `cachedFeeds(for:links:)`: the read-only counterpart to `report(for:)` that
/// `RootView+Session.refreshReminders` calls, over a batch of library entries
/// rather than one series, and with no network call of its own — split out of
/// `ReleaseFeedServiceTests` for the `type_body_length` lint cap, not because
/// the two are testing different things.
@Suite("Release feed service — cachedFeeds")
struct ReleaseFeedServiceCachedFeedsTests {
    private let series = SeriesFactory.make(id: 1, title: "Tower of God")

    private func entry(id: Int, series: Series?) -> LibraryEntry {
        LibraryEntry(
            id: id, seriesId: id, state: .reading, progressChapter: nil, progressVolume: nil,
            rating: nil, note: nil, startDate: nil, finishDate: nil, numberOfRereads: nil,
            priority: nil, isPrivate: nil, readLink: nil, series: series
        )
    }

    /// Expected failure before `cachedFeeds` existed: does not compile —
    /// `ReleaseFeedService` had no such method, only `report(for:)`, which
    /// costs a network request per provider and is exactly what
    /// `RootView+Session.refreshReminders` cannot pay for every launch.
    @Test("Webtoons is preferred over GigaViewer, same as report(for:)")
    func prefersWebtoonsOverGigaViewer() async {
        let webtoonsFeed = ReleaseFeed(title: "Webtoons", entries: [], source: .webtoons)
        let gigaFeed = ReleaseFeed(title: "Giga", entries: [], source: .gigaViewer)
        let service = ReleaseFeedService(providers: [
            StubProvider(source: .webtoons, answer: nil, cached: webtoonsFeed),
            StubProvider(source: .gigaViewer, answer: nil, cached: gigaFeed)
        ])
        let feeds = await service.cachedFeeds(for: [entry(id: 1, series: series)]) { _ in [] }
        #expect(feeds[1]?.source == .webtoons)
    }

    @Test("GigaViewer is used when Webtoons has nothing cached")
    func fallsBackToGigaViewer() async {
        let gigaFeed = ReleaseFeed(title: "Giga", entries: [], source: .gigaViewer)
        let service = ReleaseFeedService(providers: [
            StubProvider(source: .webtoons, answer: nil, cached: nil),
            StubProvider(source: .gigaViewer, answer: nil, cached: gigaFeed)
        ])
        let feeds = await service.cachedFeeds(for: [entry(id: 1, series: series)]) { _ in [] }
        #expect(feeds[1]?.source == .gigaViewer)
    }

    @Test("A series no provider has cached anything for is simply absent")
    func absentWhenNothingCached() async {
        let service = ReleaseFeedService(providers: [
            StubProvider(source: .webtoons, answer: nil, cached: nil),
            StubProvider(source: .gigaViewer, answer: nil, cached: nil)
        ])
        let feeds = await service.cachedFeeds(for: [entry(id: 1, series: series)]) { _ in [] }
        #expect(feeds[1] == nil)
        #expect(feeds.isEmpty)
    }

    @Test("An entry with no series (state 'considering') is skipped, not crashed on")
    func skipsEntriesWithNoSeries() async {
        let webtoonsFeed = ReleaseFeed(title: "Webtoons", entries: [], source: .webtoons)
        let service = ReleaseFeedService(providers: [
            StubProvider(source: .webtoons, answer: nil, cached: webtoonsFeed)
        ])
        let feeds = await service.cachedFeeds(for: [entry(id: 1, series: nil)]) { _ in [] }
        #expect(feeds.isEmpty)
    }

    @Test("Each entry's own links are passed to the providers, by series id")
    func linksArePerEntry() async {
        let webtoonsFeed = ReleaseFeed(title: "Webtoons", entries: [], source: .webtoons)
        let service = ReleaseFeedService(providers: [
            StubProvider(source: .webtoons, answer: nil, cached: webtoonsFeed)
        ])
        let entries = [entry(id: 1, series: series), entry(id: 2, series: series)]
        // The closure is @Sendable now, so the record goes through a lock
        // rather than a captured var.
        let seen = OSAllocatedUnfairLock(initialState: Set<Int>())
        _ = await service.cachedFeeds(for: entries) { seriesId in
            let link = SeriesLink(
                id: "\(seriesId)", url: nil, name: "webtoons", nameDisplay: nil,
                type: "webplatform", language: "en"
            )
            _ = seen.withLock { $0.insert(seriesId) }
            return [link]
        }
        #expect(seen.withLock { $0.sorted() } == [1, 2])
    }
}
