import Foundation
import Testing
@testable import MangaBaka

/// Reading Naver Webtoon's article-list JSON — the Korean original. See
/// `NaverFeedClient`.
///
/// The fixture below is a trimmed version of the live response for Tower of
/// God, measured 2026-09-13: `totalCount` 653, `finished` false, two of the
/// twenty `articleList` entries kept.
@Suite("Naver feed decoding")
struct NaverFeedDecodingTests {
    private let fixture = Data(#"""
    {
      "totalCount": 653,
      "finished": false,
      "dailyPass": false,
      "articleList": [
        {"no": 654, "subtitle": "3부 236화", "serviceDateDescription": "25.02.09", "volumeNo": 3},
        {"no": 653, "subtitle": "3부 235화", "serviceDateDescription": "25.02.02", "volumeNo": 3}
      ]
    }
    """#.utf8)

    @Test("totalCount and finished are read from the top level")
    func topLevelFields() throws {
        let payload = try JSONDecoder().decode(NaverFeedClient.Payload.self, from: fixture)
        let feed = payload.releaseFeed
        #expect(feed.totalCount == 653)
        #expect(feed.finished == false)
        #expect(feed.source == .naverWebtoon)
    }

    /// The headline rule: `no` is the article's position in Naver's own list,
    /// not the episode number, and must never be read as one. Tower of God's
    /// real numbers: the newest `no` is 654 while the title says episode 236.
    @Test("The episode number comes from the title, never from `no`")
    func numberComesFromTitleNotPosition() throws {
        let payload = try JSONDecoder().decode(NaverFeedClient.Payload.self, from: fixture)
        let feed = payload.releaseFeed
        #expect(feed.latestEpisodeNumber == 236)
        #expect(feed.episodes.map(\.number) == [236, 235])
        #expect(feed.episodes.map(\.season) == [3, 3])
    }

    /// "25.02.02" is `YY.MM.DD`; parsed as 20YY-MM-DD at noon Asia/Seoul
    /// because the API gives no time of day. Checked as a calendar day in
    /// Seoul rather than as an absolute instant, since noon is a placeholder,
    /// not a measured fact.
    @Test("serviceDateDescription is read as 20YY-MM-DD")
    func dateParsing() throws {
        let payload = try JSONDecoder().decode(NaverFeedClient.Payload.self, from: fixture)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Seoul"))
        let published = try #require(payload.releaseFeed.episodes.first?.published)
        let components = calendar.dateComponents([.year, .month, .day], from: published)
        #expect(components.year == 2025)
        #expect(components.month == 2)
        #expect(components.day == 9)
    }
}

/// Turning a stored Naver link into the article-list endpoint.
@Suite("Naver feed URLs")
struct NaverFeedURLTests {
    @Test("titleId is read off a comic.naver.com link")
    func readsTitleID() {
        let url = URL(string: "https://comic.naver.com/webtoon/list?titleId=183559")!
        #expect(NaverFeedClient.titleID(in: [url]) == "183559")
    }

    @Test("A link with no titleId, or the wrong host, yields nothing")
    func rejectsOtherLinks() {
        let noQuery = URL(string: "https://comic.naver.com/webtoon/list")!
        let wrongHost = URL(string: "https://webtoons.com/en/x/list?titleId=1")!
        #expect(NaverFeedClient.titleID(in: [noQuery]) == nil)
        #expect(NaverFeedClient.titleID(in: [wrongHost]) == nil)
    }

    @Test("The endpoint is the article list, page 1")
    func endpoint() {
        #expect(NaverFeedClient.endpoint(titleID: "183559")?.absoluteString
                == "https://comic.naver.com/api/article/list?titleId=183559&page=1")
    }
}

/// The client's network behaviour: the request it sends and the cache it
/// keeps. `.serialized` because it shares `URLProtocolStub`'s per-test state.
@Suite("Naver feed client", .serialized)
struct NaverFeedClientTests {
    private func makeClient(clock: TestClock) -> NaverFeedClient {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("naver-tests-\(UUID().uuidString)", isDirectory: true)
        return NaverFeedClient(
            session: URLProtocolStub.makeSession(), clock: clock, cacheDirectory: directory
        )
    }

    private let answer = Data(#"""
    {"totalCount": 653, "finished": false, "articleList": [
      {"no": 653, "subtitle": "3부 235화", "serviceDateDescription": "25.02.02", "volumeNo": 3}
    ]}
    """#.utf8)

    private let link = SeriesLink(
        id: "1", url: URL(string: "https://comic.naver.com/webtoon/list?titleId=183559"),
        name: "naver", nameDisplay: nil, type: "webplatform", language: "ko"
    )

    @Test("A series with a Naver link is asked, and the feed is attributed to Naver")
    func asksNaver() async {
        URLProtocolStub.setHandler { _ in .respond(.init(body: answer)) }
        defer { URLProtocolStub.reset() }
        let client = makeClient(clock: TestClock())
        let series = SeriesFactory.make(id: 1, title: "Tower of God")

        let answerResult = await client.feed(for: series, links: [link])
        #expect(answerResult.feed?.source == .naverWebtoon)
        #expect(answerResult.feed?.totalCount == 653)
        let url = URLProtocolStub.requests.first?.url?.absoluteString ?? ""
        #expect(url.contains("titleId=183559"))
    }

    @Test("A series with no Naver link is never asked")
    func noLinkNoRequest() async {
        URLProtocolStub.setHandler { _ in .respond(.init(body: answer)) }
        defer { URLProtocolStub.reset() }
        let client = makeClient(clock: TestClock())
        let series = SeriesFactory.make(id: 1, title: "Solo Leveling")

        let answerResult = await client.feed(for: series, links: [])
        #expect(answerResult == .notCarried)
        #expect(URLProtocolStub.requests.isEmpty)
    }

    /// F18 (`docs/reviews/tests.md`, 2026-09-13): the 429 back-off path had no
    /// test. This proves the observable half — the client answers nil rather
    /// than throwing or crashing on a rate-limited response — and stops
    /// there: `RequestSpacing.backOff` really suppressing a *later* request
    /// cannot be proved without either a real 60-second wait (the back-off
    /// window is hardcoded, and `Task.sleep` runs on wall-clock time,
    /// unaffected by `TestClock` — see `Clock.swift`) or giving `Clock` a
    /// `sleep` of its own, which is a bigger change than this file's fixes.
    /// Flagged rather than half-tested.
    @Test("A 429 response answers nil rather than crashing")
    func rateLimitedResponseAnswersNil() async {
        URLProtocolStub.setHandler { _ in .respond(.init(statusCode: 429)) }
        defer { URLProtocolStub.reset() }
        let client = makeClient(clock: TestClock())
        let series = SeriesFactory.make(id: 1, title: "Tower of God")

        let answerResult = await client.feed(for: series, links: [link])
        guard case let .failed(error) = answerResult else {
            Issue.record("expected .failed, got \(answerResult)")
            return
        }
        #expect(error == .rateLimited(until: nil, party: .naver))
        #expect(URLProtocolStub.requests.count == 1)
    }

    /// The one shape the docs call out as thin: a paywalled `dailyPass`
    /// series' public list is three articles. Below `Cadence.minimumDates`
    /// (4), so it must still summarise to something listable, not `.none`.
    @Test("A dailyPass feed's three public entries still summarise, not .none")
    func dailyPassThinListSummarises() throws {
        let payload = try JSONDecoder().decode(NaverFeedClient.Payload.self, from: Data(#"""
        {
          "totalCount": 653,
          "finished": false,
          "dailyPass": true,
          "articleList": [
            {"no": 654, "subtitle": "3부 236화", "serviceDateDescription": "25.02.09", "volumeNo": 3},
            {"no": 653, "subtitle": "3부 235화", "serviceDateDescription": "25.02.02", "volumeNo": 3},
            {"no": 652, "subtitle": "3부 234화", "serviceDateDescription": "25.01.26", "volumeNo": 3}
          ]
        }
        """#.utf8))
        let summary = ReleaseSummary.summarise(payload.releaseFeed)
        #expect(!summary.isEmpty)
        guard case .recent = summary else {
            Issue.record("expected .recent for three thin entries, got \(summary)")
            return
        }
    }

    @Test("A second look inside a week costs no request")
    func cache() async {
        URLProtocolStub.setHandler { _ in .respond(.init(body: answer)) }
        defer { URLProtocolStub.reset() }
        let clock = TestClock()
        let client = makeClient(clock: clock)
        let series = SeriesFactory.make(id: 1, title: "Tower of God")

        _ = await client.feed(for: series, links: [link])
        _ = await client.feed(for: series, links: [link])
        #expect(URLProtocolStub.requests.count == 1)

        clock.advance(by: NaverFeedClient.cacheLife + 1)
        _ = await client.feed(for: series, links: [link])
        #expect(URLProtocolStub.requests.count == 2)
    }
}

/// `cachedFeed`: the read-only path `ReleaseFeedService.cachedFeeds` uses so
/// `RootView+Session.refreshReminders` can test the Naver-finished condition
/// without a request per library series.
@Suite("Naver cachedFeed", .serialized)
struct NaverCachedFeedTests {
    private func makeClient(clock: TestClock, cacheDirectory: URL) -> NaverFeedClient {
        NaverFeedClient(session: URLProtocolStub.makeSession(), clock: clock, cacheDirectory: cacheDirectory)
    }

    private let link = SeriesLink(
        id: "1", url: URL(string: "https://comic.naver.com/webtoon/list?titleId=183559"),
        name: "naver", nameDisplay: nil, type: "webplatform", language: "ko"
    )

    private let answer = Data(#"""
    {"totalCount": 653, "finished": true, "articleList": [
      {"no": 653, "subtitle": "3부 235화", "serviceDateDescription": "25.02.02", "volumeNo": 3}
    ]}
    """#.utf8)

    /// Expected failure before `cachedFeed` existed: does not compile —
    /// `NaverFeedClient` had no such method.
    @Test("The same v2-naver- key feed(for:) writes is read back, with no request")
    func readsWhatFeedWrote() async {
        URLProtocolStub.setHandler { _ in .respond(.init(body: answer)) }
        defer { URLProtocolStub.reset() }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("naver-tests-\(UUID().uuidString)", isDirectory: true)
        let clock = TestClock()
        let client = makeClient(clock: clock, cacheDirectory: directory)
        let series = SeriesFactory.make(id: 1, title: "Tower of God")

        _ = await client.feed(for: series, links: [link])
        #expect(URLProtocolStub.requests.count == 1)

        let cached = await client.cachedFeed(for: series, links: [link])
        #expect(cached?.finished == true)
        #expect(URLProtocolStub.requests.count == 1, "cachedFeed must not make a request")
    }

    @Test("Nothing cached yet answers nil")
    func nilWithNothingCached() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("naver-tests-\(UUID().uuidString)", isDirectory: true)
        let client = makeClient(clock: TestClock(), cacheDirectory: directory)
        let series = SeriesFactory.make(id: 1, title: "Tower of God")

        let cached = await client.cachedFeed(for: series, links: [link])
        #expect(cached == nil)
    }

    @Test("A series with no Naver link answers nil")
    func nilForUnservedLinks() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("naver-tests-\(UUID().uuidString)", isDirectory: true)
        let client = makeClient(clock: TestClock(), cacheDirectory: directory)
        let series = SeriesFactory.make(id: 1, title: "Tower of God")

        let cached = await client.cachedFeed(for: series, links: [])
        #expect(cached == nil)
    }

    /// "A stale season-ended is still season-ended" — Abdi's brief. A finished
    /// original a week past `cacheLife` must still read as finished, unlike
    /// `feed(for:links:)`'s own read, which would treat the file as expired.
    @Test("A cache older than cacheLife still answers — age is ignored")
    func staleCacheStillAnswers() async {
        URLProtocolStub.setHandler { _ in .respond(.init(body: answer)) }
        defer { URLProtocolStub.reset() }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("naver-tests-\(UUID().uuidString)", isDirectory: true)
        let clock = TestClock()
        let client = makeClient(clock: clock, cacheDirectory: directory)
        let series = SeriesFactory.make(id: 1, title: "Tower of God")

        _ = await client.feed(for: series, links: [link])
        clock.advance(by: NaverFeedClient.cacheLife + 1)

        let cached = await client.cachedFeed(for: series, links: [link])
        #expect(cached?.finished == true)
    }
}
