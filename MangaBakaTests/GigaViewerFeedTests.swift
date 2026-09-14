import Foundation
import Testing
@testable import MangaBaka

/// Reading a GigaViewer magazine RSS feed and filtering it to one series.
/// See `GigaViewerFeedClient`.
///
/// The fixture mixes three series' episodes the way a real magazine feed
/// does — that mixing is the whole reason the filter step exists.
@Suite("GigaViewer magazine feed")
struct GigaViewerFeedParsingTests {
    private let fixture = Data(#"""
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0" xmlns:giga="https://gigaviewer.com/xmlns/1.0">
    <channel>
    <title>Tonari no Young Jump</title>
    <item>
      <title>[第33話] カテナチオ</title>
      <link>https://tonarinoyj.jp/episode/1</link>
      <pubDate>Thu, 11 Sep 2026 15:00:00 GMT</pubDate>
      <description>&lt;img src="https://example.com/page1.jpg"&gt;</description>
      <giga:freeTermStartDate>2026-09-11T15:00:00Z</giga:freeTermStartDate>
    </item>
    <item>
      <title>[第102話] 進撃の巨人スピンオフ</title>
      <link>https://tonarinoyj.jp/episode/2</link>
      <pubDate>Wed, 10 Sep 2026 15:00:00 GMT</pubDate>
      <description>thumbnail</description>
    </item>
    <item>
      <title>[第4話] カテナチオ</title>
      <link>https://tonarinoyj.jp/episode/3</link>
      <pubDate>Thu, 04 Sep 2026 15:00:00 GMT</pubDate>
    </item>
    </channel>
    </rss>
    """#.utf8)

    @Test("Every item parses, split into series title and episode title")
    func parsesItems() throws {
        let items = try #require(MagazineFeedParser.parse(fixture))
        #expect(items.count == 3)
        #expect(items[0].seriesTitle == "カテナチオ")
        #expect(items[0].episodeTitle == "[第33話] カテナチオ")
        #expect(items[1].seriesTitle == "進撃の巨人スピンオフ")
    }

    /// The whole point of using RSS over per-episode JSON: the thumbnail in
    /// `<description>` must never reach anything that could render it.
    ///
    /// F11 (`docs/reviews/tests.md`, 2026-09-13): this used to assert only
    /// `!items.isEmpty`, which cannot fail — the fixture's first item's
    /// `<description>` (with its `<img src=".../page1.jpg">`) was never
    /// actually checked against the parsed fields. Expected failure before
    /// this fix existed: none — that is the bug, a test that cannot fail.
    @Test("The description, and therefore the thumbnail, is dropped")
    func descriptionDropped() throws {
        let items = try #require(MagazineFeedParser.parse(fixture))
        let first = try #require(items.first)
        // `Item` has no field a thumbnail URL could occupy at all — a
        // structural guarantee — but that is only as strong as this check
        // that the description's own content never lands in a field by
        // string accident.
        #expect(!first.episodeTitle.contains("page1.jpg"))
        #expect(!first.seriesTitle.contains("page1.jpg"))
    }

    @Test("第N話 numbers, including the sub-episode and circled-digit shapes")
    func episodeNumbers() throws {
        let items = try #require(MagazineFeedParser.parse(fixture))
        #expect(WebtoonsTitle.read(items[0].episodeTitle)?.number == 33)
        #expect(WebtoonsTitle.read(items[1].episodeTitle)?.number == 102)
        #expect(WebtoonsTitle.read(items[2].episodeTitle)?.number == 4)
    }

    @Test("Filtering by title matches only the requested series, halfwidth/fullwidth included")
    func filtersByTitle() {
        let items = MagazineFeedParser.parse(fixture)
        let titles: Set<String> = [GigaViewerFeedClient.normalise("カテナチオ")]
        let matched = items?.filter { titles.contains(GigaViewerFeedClient.normalise($0.seriesTitle)) }
        #expect(matched?.count == 2)
        #expect(matched?.map(\.episodeTitle).sorted() == ["[第33話] カテナチオ", "[第4話] カテナチオ"])
    }

    @Test("Normalisation folds full-width forms and trims/lowercases")
    func normalisation() {
        // "ｶﾃﾅﾁｵ" (half-width katakana) is a different script entirely from
        // "カテナチオ" and is not expected to match it; the guarantee here is
        // narrower: trimming and case are not what decide a miss.
        #expect(GigaViewerFeedClient.normalise("  Catenaccio  ") == "catenaccio")
        #expect(GigaViewerFeedClient.normalise("CATENACCIO") == GigaViewerFeedClient.normalise("catenaccio"))
    }
}

/// The client's network behaviour: one request per host, cached a day.
@Suite("GigaViewer feed client", .serialized)
struct GigaViewerFeedClientTests {
    private func makeClient(clock: TestClock) -> GigaViewerFeedClient {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("giga-tests-\(UUID().uuidString)", isDirectory: true)
        return GigaViewerFeedClient(
            session: URLProtocolStub.makeSession(), clock: clock, cacheDirectory: directory
        )
    }

    private let rss = Data(#"""
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0"><channel><title>Tonari no Young Jump</title>
    <item>
      <title>[第33話] カテナチオ</title>
      <pubDate>Thu, 11 Sep 2026 15:00:00 GMT</pubDate>
      <link>https://tonarinoyj.jp/episode/1</link>
    </item>
    </channel></rss>
    """#.utf8)

    private let link = SeriesLink(
        id: "1", url: URL(string: "https://tonarinoyj.jp/series/1"),
        name: "tonarinoyj", nameDisplay: nil, type: "webplatform", language: "ja"
    )

    @Test("A matching series gets a feed attributed to the host's own name")
    func matchesAndAttributes() async {
        URLProtocolStub.setHandler { _ in .respond(.init(body: rss)) }
        defer { URLProtocolStub.reset() }
        let client = makeClient(clock: TestClock())
        let series = SeriesFactory.make(id: 1, title: "カテナチオ")

        let answerResult = await client.feed(for: series, links: [link])
        #expect(answerResult.feed?.source == .gigaViewer)
        #expect(answerResult.feed?.sourceName == "Tonari no Young Jump")
        #expect(answerResult.feed?.episodes.map(\.number) == [33])
    }

    @Test("A series absent from the magazine's feed answers nil")
    func noMatchIsNil() async {
        URLProtocolStub.setHandler { _ in .respond(.init(body: rss)) }
        defer { URLProtocolStub.reset() }
        let client = makeClient(clock: TestClock())
        let series = SeriesFactory.make(id: 2, title: "Some Other Series")

        let answerResult = await client.feed(for: series, links: [link])
        #expect(answerResult == .answered(nil))
    }

    /// F18 (`docs/reviews/tests.md`, 2026-09-13): stops at "answers nil"
    /// rather than also proving the back-off window suppresses a later
    /// request. The reason was written up on the sibling `NaverFeedClient`
    /// test, which went with that client on 2026-09-13; read F18 in
    /// `docs/reviews/tests.md` for it rather than this comment.
    @Test("A 429 response answers nil rather than crashing")
    func rateLimitedResponseAnswersNil() async {
        URLProtocolStub.setHandler { _ in .respond(.init(statusCode: 429)) }
        defer { URLProtocolStub.reset() }
        let client = makeClient(clock: TestClock())
        let series = SeriesFactory.make(id: 1, title: "カテナチオ")

        let answerResult = await client.feed(for: series, links: [link])
        guard case let .failed(error) = answerResult else {
            Issue.record("expected .failed, got \(answerResult)")
            return
        }
        #expect(error == .rateLimited(until: nil, party: .gigaViewer))
        #expect(URLProtocolStub.requests.count == 1)
    }

    @Test("The magazine feed is cached a day, shared across series on the same host")
    func cachedPerHost() async {
        URLProtocolStub.setHandler { _ in .respond(.init(body: rss)) }
        defer { URLProtocolStub.reset() }
        let clock = TestClock()
        let client = makeClient(clock: clock)
        let catenaccio = SeriesFactory.make(id: 1, title: "カテナチオ")
        let other = SeriesFactory.make(id: 2, title: "Some Other Series")

        _ = await client.feed(for: catenaccio, links: [link])
        // A different series, same host: still one request, because the
        // magazine feed itself is what is cached, not a per-series answer.
        _ = await client.feed(for: other, links: [link])
        #expect(URLProtocolStub.requests.count == 1)

        clock.advance(by: GigaViewerFeedClient.cacheLife + 1)
        _ = await client.feed(for: catenaccio, links: [link])
        #expect(URLProtocolStub.requests.count == 2)
    }
}

/// `cachedFeed`: the read-only path `ReleaseFeedService.cachedFeeds` uses.
/// Unlike Webtoons, the cache here holds the whole magazine's raw
/// items, keyed by host — `cachedFeed` must filter to the series itself the
/// same way `feed(for:links:)` does, without a request for the magazine feed.
@Suite("GigaViewer cachedFeed", .serialized)
struct GigaViewerCachedFeedTests {
    private func makeClient(clock: TestClock, cacheDirectory: URL) -> GigaViewerFeedClient {
        GigaViewerFeedClient(
            session: URLProtocolStub.makeSession(), clock: clock, cacheDirectory: cacheDirectory
        )
    }

    private let rss = Data(#"""
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0"><channel><title>Tonari no Young Jump</title>
    <item>
      <title>[第33話] カテナチオ</title>
      <pubDate>Thu, 11 Sep 2026 15:00:00 GMT</pubDate>
      <link>https://tonarinoyj.jp/episode/1</link>
    </item>
    </channel></rss>
    """#.utf8)

    private let link = SeriesLink(
        id: "1", url: URL(string: "https://tonarinoyj.jp/series/1"),
        name: "tonarinoyj", nameDisplay: nil, type: "webplatform", language: "ja"
    )

    /// Expected failure before `cachedFeed` existed: does not compile —
    /// `GigaViewerFeedClient` had no such method.
    @Test("The same v1-giga- key feed(for:) writes is read back, filtered, with no request")
    func readsWhatFeedWrote() async {
        URLProtocolStub.setHandler { _ in .respond(.init(body: rss)) }
        defer { URLProtocolStub.reset() }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("giga-tests-\(UUID().uuidString)", isDirectory: true)
        let clock = TestClock()
        let client = makeClient(clock: clock, cacheDirectory: directory)
        let series = SeriesFactory.make(id: 1, title: "カテナチオ")

        _ = await client.feed(for: series, links: [link])
        #expect(URLProtocolStub.requests.count == 1)

        let cached = await client.cachedFeed(for: series, links: [link])
        #expect(cached?.sourceName == "Tonari no Young Jump")
        #expect(cached?.episodes.map(\.number) == [33])
        #expect(URLProtocolStub.requests.count == 1, "cachedFeed must not make a request")
    }

    @Test("Nothing cached yet answers nil")
    func nilWithNothingCached() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("giga-tests-\(UUID().uuidString)", isDirectory: true)
        let client = makeClient(clock: TestClock(), cacheDirectory: directory)
        let series = SeriesFactory.make(id: 1, title: "カテナチオ")

        let cached = await client.cachedFeed(for: series, links: [link])
        #expect(cached == nil)
    }

    @Test("A series with no matching GigaViewer host answers nil")
    func nilForUnservedLinks() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("giga-tests-\(UUID().uuidString)", isDirectory: true)
        let client = makeClient(clock: TestClock(), cacheDirectory: directory)
        let series = SeriesFactory.make(id: 1, title: "カテナチオ")

        let cached = await client.cachedFeed(for: series, links: [])
        #expect(cached == nil)
    }

    /// The magazine feed is cached, but this series is not in it —
    /// `answered(nil)` for `feed(for:links:)`, and nil here for the same reason.
    @Test("A cached magazine that does not carry this series answers nil")
    func nilWhenNotInCachedMagazine() async {
        URLProtocolStub.setHandler { _ in .respond(.init(body: rss)) }
        defer { URLProtocolStub.reset() }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("giga-tests-\(UUID().uuidString)", isDirectory: true)
        let clock = TestClock()
        let client = makeClient(clock: clock, cacheDirectory: directory)
        let catenaccio = SeriesFactory.make(id: 1, title: "カテナチオ")
        let other = SeriesFactory.make(id: 2, title: "Some Other Series")

        _ = await client.feed(for: catenaccio, links: [link])
        let cached = await client.cachedFeed(for: other, links: [link])
        #expect(cached == nil)
    }

    /// "A stale season-ended is still season-ended" — the magazine cache here
    /// is a day, not a week, but the rule is the same: `cachedFeed` must not
    /// apply `feed(for:links:)`'s own freshness gate.
    @Test("A cache older than cacheLife still answers — age is ignored")
    func staleCacheStillAnswers() async {
        URLProtocolStub.setHandler { _ in .respond(.init(body: rss)) }
        defer { URLProtocolStub.reset() }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("giga-tests-\(UUID().uuidString)", isDirectory: true)
        let clock = TestClock()
        let client = makeClient(clock: clock, cacheDirectory: directory)
        let series = SeriesFactory.make(id: 1, title: "カテナチオ")

        _ = await client.feed(for: series, links: [link])
        clock.advance(by: GigaViewerFeedClient.cacheLife + 1)

        let cached = await client.cachedFeed(for: series, links: [link])
        #expect(cached?.episodes.map(\.number) == [33])
    }
}

/// The real magazine feed, not a hand-shaped one. Captured 2026-09-13 from
/// `tonarinoyj.jp/rss`: 72 items across many series, each with a thumbnail
/// `<description>` and an `<enclosure>`. A fixture the parser was written
/// against cannot fail the parser; this one was written by the publisher.
@Suite("GigaViewer magazine feed — live capture")
struct GigaViewerLiveCaptureTests {
    @Test("Every item parses, and no thumbnail or description survives into an item")
    func liveCaptureParses() throws {
        let data = try Fixture.data("tonarinoyj", extension: "rss")
        let items = try #require(MagazineFeedParser.parse(data))
        #expect(items.count == 72)
        for item in items {
            #expect(!item.episodeTitle.contains("<"))
            #expect(!item.seriesTitle.contains("<"))
            #expect(!item.seriesTitle.contains("cdn-img"))
        }
        // カテナチオ was serialised in a run of 32 episodes on the day of capture.
        let wanted = GigaViewerFeedClient.normalise("カテナチオ")
        let matched = items.filter { GigaViewerFeedClient.normalise($0.seriesTitle) == wanted }
        #expect(matched.count == 32)
        #expect(matched.allSatisfy { WebtoonsTitle.read($0.episodeTitle)?.number != nil })
    }
}
