import Foundation
import Testing
@testable import MangaBaka

/// The Daily Pass RSS bug: `docs/sources/webtoon-episodes.md`, item 4.
///
/// Lore Olympus (Webtoons Originals, 280 episodes, completed) answers its
/// per-title RSS with exactly episodes 1-9 from 2018, and a `lastBuildDate`
/// of 2024 that makes the feed look current. `ReleaseFeed.latestEpisodeNumber`
/// takes `max` over what the feed hands back, so untreated this reports "9 of
/// 280" and `Cadence.estimate` reads a weekly rhythm out of eight-year-old
/// dates — a wrong number shown with a confidence pill, on a series this app
/// otherwise has no idea has finished.
///
/// Fixture: `lore-olympus.rss`, built from the shape this doc records (nine
/// items, episodes 1-9, 2018 `pubDate`s, a 2024 `lastBuildDate`) — there was
/// no live capture available to this task, only the measured numbers.
@Suite("Webtoons feed — stale Daily Pass detection")
struct ReleaseFeedDailyPassTests {
    private func loreOlympus() throws -> ReleaseFeed {
        let data = try Fixture.data("lore-olympus", extension: "rss")
        return try #require(WebtoonsFeedParser.parse(data))
    }

    /// Expected failure before this test existed: `feed.latestEpisodeNumber
    /// == 9` was never checked against anything, so nothing caught the feed
    /// reporting 9 of a 280-episode series as its current position.
    @Test("The fixture reproduces the bug: 9 of 280, not the finale")
    func fixtureReproducesTheBug() throws {
        let feed = try loreOlympus()
        #expect(feed.episodes.count == 9)
        #expect(feed.latestEpisodeNumber == 9)
    }

    /// The fix. `now` is 2026, comfortably past the fixture's 2018 dates and
    /// its year-old-relative-to-2024 `lastBuildDate` either way.
    @Test("A feed whose newest episode is old and low-numbered is read as stale")
    func lowAndOldFeedIsStale() throws {
        let feed = try loreOlympus()
        let now = Date(timeIntervalSince1970: 1_757_000_000) // 2025-09, > a year past 2018
        #expect(feed.looksLikeStaleDailyPassFeed(asOf: now))
    }

    /// The control: the same nine dates, asked about as of a date close to
    /// them, must not trip the check — this is about staleness, not merely
    /// "few episodes". Proves `staleDailyPassAge` is doing the work, not
    /// `staleDailyPassEpisodeCeiling` alone.
    @Test("Control: the same low episode count, asked about soon after, is not stale")
    func lowButRecentFeedIsNotStale() throws {
        let feed = try loreOlympus()
        // 2018-04-01: a few days after the newest fixture entry (25 Mar 2018).
        let now = Date(timeIntervalSince1970: 1_522_540_800)
        #expect(!feed.looksLikeStaleDailyPassFeed(asOf: now))
    }

    /// The other half of the control: a feed with a real, current high
    /// episode number must not be flagged just because it is being asked
    /// about long after 2018 — every other fixture in this suite (e.g. "The
    /// Knight Only Lives Today", latest 112) is implicitly this control too.
    @Test("Control: a feed with a normal high episode number is never stale")
    func highEpisodeNumberIsNeverStale() throws {
        let entry = ReleaseEntry(
            title: "Episode 235", published: Date(timeIntervalSince1970: 0), number: 235, season: nil
        )
        let feed = ReleaseFeed(title: "Ongoing Series", entries: [entry], source: .webtoons)
        #expect(!feed.looksLikeStaleDailyPassFeed(asOf: Date(timeIntervalSince1970: 1_757_000_000)))
    }

    /// Through the client: a stale-Daily-Pass response must be treated the
    /// same as `.empty` — try the next candidate, and if none is left,
    /// `.answered(nil)`, never a `.answered(feed)` carrying the bad 9-of-280
    /// read into `ReleaseSummary`/`Cadence`.
    ///
    /// Expected failure before the fix: `answer.feed?.latestEpisodeNumber ==
    /// 9` — a feed was returned and carried the stale read straight through —
    /// where this now asserts `answer == .answered(nil)`.
    @Test("The client answers .answered(nil) for a stale Daily Pass feed, not the feed")
    func clientTreatsStaleFeedAsNoAnswer() async throws {
        let data = try Fixture.data("lore-olympus", extension: "rss")
        URLProtocolStub.setHandler { _ in .respond(.init(body: data)) }
        defer { URLProtocolStub.reset() }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("webtoons-tests-\(UUID().uuidString)", isDirectory: true)
        // TestClock defaults to 2025-09-04ish — well past a year from the
        // fixture's 2018 dates and its 2024 lastBuildDate either way.
        let clock = TestClock()
        let client = WebtoonsFeedClient(
            session: URLProtocolStub.makeSession(), clock: clock, cacheDirectory: directory
        )
        let link = SeriesLink(
            id: "1", url: URL(string: "https://www.webtoons.com/en/romance/lore-olympus/list?title_no=1320"),
            name: "webtoons", nameDisplay: nil, type: "webplatform", language: "en"
        )

        let answer = await client.feed(for: [link], seriesID: 1320)
        #expect(answer == .answered(nil))
    }
}
