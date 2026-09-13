import Foundation
import Testing

@testable import MangaBaka

@Suite("ReleaseSummary")
struct ReleaseSummaryTests {
    /// A fixed reference instant so tests do not depend on when they run.
    private let now = Date(timeIntervalSince1970: 1_757_000_000) // 2026-09-04, arbitrary

    private func day(_ offset: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: offset, to: now) ?? now
    }

    private func episode(_ number: Int, daysAgo: Int, season: Int? = nil) -> ReleaseEntry {
        ReleaseEntry(title: "Episode \(number)", published: day(-daysAgo), number: number, season: season)
    }

    private func afterword(_ index: Int, daysAgo: Int) -> ReleaseEntry {
        ReleaseEntry(title: "Afterword \(index)", published: day(-daysAgo), number: nil, season: nil)
    }

    // MARK: - Control

    /// Reproduces `Cadence.estimate`'s own passing case (weekly, four dates)
    /// directly, so a failure here means this test's setup is wrong before
    /// `ReleaseSummary` is even suspected.
    @Test("Control: four weekly dates a week apart produce a Cadence directly")
    func controlCadenceFromWeeklyDates() throws {
        let dates = [day(0), day(-7), day(-14), day(-21)]
        let cadence = try #require(Cadence.estimate(from: dates))
        #expect(cadence.medianGapDays == 7)
    }

    // MARK: - none

    @Test("A nil feed summarises to none")
    func nilFeedIsNone() {
        #expect(ReleaseSummary.summarise(nil) == .none)
        #expect(ReleaseSummary.summarise(nil).isEmpty)
    }

    @Test("A feed with zero entries summarises to none")
    func zeroEntriesIsNone() {
        let feed = ReleaseFeed(title: "Empty", entries: [], source: .webtoons)
        #expect(ReleaseSummary.summarise(feed) == .none)
    }

    @Test("A feed whose entries are all afterwords, zero episodes, summarises to none")
    func allAfterwordsIsNone() {
        let feed = ReleaseFeed(title: "Finished", entries: [
            afterword(1, daysAgo: 0),
            afterword(2, daysAgo: 0),
            afterword(3, daysAgo: 0)
        ], source: .webtoons)
        #expect(ReleaseSummary.summarise(feed) == .none)
    }

    // MARK: - lastSeen

    @Test("Exactly one episode summarises to lastSeen with its date and number")
    func oneEpisodeIsLastSeen() {
        let episode = episode(5, daysAgo: 3)
        let feed = ReleaseFeed(title: "Naver Paywalled", entries: [episode], source: .webtoons)
        #expect(ReleaseSummary.summarise(feed) == .lastSeen(latest: episode.published, number: 5))
    }

    // MARK: - recent

    @Test("Three episodes, below Cadence's minimum history, summarise to recent")
    func threeEpisodesIsRecent() {
        // Cadence.minimumDates is 4; 3 dates cannot produce an estimate, so this
        // must fall to .recent rather than .rhythm. Confirmed against the
        // constant rather than assumed, per the file's own comment that it is a
        // guess subject to change.
        let episodes = [
            episode(3, daysAgo: 0),
            episode(2, daysAgo: 7),
            episode(1, daysAgo: 14)
        ]
        #expect(episodes.count < Cadence.minimumDates)
        let feed = ReleaseFeed(title: "Naver Paywalled", entries: episodes, source: .webtoons)
        #expect(ReleaseSummary.summarise(feed) == .recent(episodes))
    }

    @Test("Two episodes summarise to recent, not rhythm, regardless of the gap between them")
    func twoEpisodesIsRecent() {
        // Two dates are below Cadence.minimumDates (4) no matter how the single
        // gap looks, so this must land on .recent rather than .rhythm.
        let episodes = [episode(2, daysAgo: 1), episode(1, daysAgo: 40)]
        let feed = ReleaseFeed(title: "Sparse", entries: episodes, source: .webtoons)
        #expect(ReleaseSummary.summarise(feed) == .recent(episodes))
    }

    // MARK: - rhythm

    @Test("A full twenty-episode weekly feed summarises to rhythm with the latest episode")
    func twentyWeeklyEpisodesIsRhythm() throws {
        let episodes = (1...20).map { episode($0, daysAgo: (20 - $0) * 7) }
        let feed = ReleaseFeed(title: "Tower of God", entries: episodes, source: .webtoons)
        let summary = ReleaseSummary.summarise(feed)
        guard case let .rhythm(cadence, latest) = summary else {
            Issue.record("expected .rhythm, got \(summary)")
            return
        }
        #expect(cadence.medianGapDays == 7)
        // Episode 20 has the fewest days-ago (0), so it is the newest by date —
        // the fact `latest` is defined on, not feed order.
        #expect(latest?.number == 20)
    }

    @Test("Four weekly episodes, exactly at Cadence's minimum, summarise to rhythm")
    func fourWeeklyEpisodesIsRhythm() {
        let episodes = [
            episode(4, daysAgo: 0),
            episode(3, daysAgo: 7),
            episode(2, daysAgo: 14),
            episode(1, daysAgo: 21)
        ]
        let feed = ReleaseFeed(title: "Weekly", entries: episodes, source: .webtoons)
        let summary = ReleaseSummary.summarise(feed)
        guard case let .rhythm(cadence, latest) = summary else {
            Issue.record("expected .rhythm, got \(summary)")
            return
        }
        #expect(cadence.medianGapDays == 7)
        #expect(latest?.number == 4)
    }

    // MARK: - seasonEnded

    @Test("A finale entry that is also the latest episode summarises to seasonEnded")
    func finaleEntrySummarisesToSeasonEnded() {
        let finale = ReleaseEntry(
            title: "Episode 112 (Season 1 Finale)", published: day(0), number: 112, season: 1
        )
        let episodes = [
            finale,
            episode(111, daysAgo: 7, season: 1),
            episode(110, daysAgo: 14, season: 1),
            episode(109, daysAgo: 21, season: 1)
        ]
        // Afterwords sit above the finale in the real feed and share its date;
        // they must not stop endedSeason from firing.
        let entries = [afterword(1, daysAgo: 0), afterword(2, daysAgo: 0)] + episodes
        let feed = ReleaseFeed(title: "The Knight Only Lives Today", entries: entries, source: .webtoons)
        #expect(ReleaseSummary.summarise(feed) == .seasonEnded(season: 1, on: finale.published))
    }

    @Test("A finished season outranks a rhythm that the same episodes would otherwise support")
    func seasonEndedOutranksRhythm() {
        // The four episodes below are exactly the shape `fourWeeklyEpisodesIsRhythm`
        // proves goes to .rhythm. Adding only the finale marker on the newest one
        // must flip the result to .seasonEnded, showing the check order in
        // `summarise` actually matters rather than happening to agree.
        let finale = ReleaseEntry(
            title: "Episode 4 (Season 1 Finale)", published: day(0), number: 4, season: 1
        )
        let episodes = [
            finale,
            episode(3, daysAgo: 7, season: 1),
            episode(2, daysAgo: 14, season: 1),
            episode(1, daysAgo: 21, season: 1)
        ]
        let feed = ReleaseFeed(title: "Weekly, Finished", entries: episodes, source: .webtoons)
        #expect(ReleaseSummary.summarise(feed) == .seasonEnded(season: 1, on: finale.published))
    }

    // MARK: - oldest-first feeds (R1)

    /// True Beauty, measured live 2026-09-13: a completed ~230-episode series
    /// whose Webtoons feed carries only "Episode 0"-"Episode 7" from 2018 —
    /// the feed's *oldest* entries, not its newest twenty. Without the known
    /// chapter count, four-plus weekly-looking dates read as a confident
    /// `.rhythm`; that is `fourWeeklyEpisodesIsRhythm` above, deliberately
    /// reused here shape-for-shape. Expected failure before this fix: a
    /// `.rhythm` case, where this now asserts `.none`.
    @Test("A feed whose highest number is far below the known chapter count is none, not rhythm")
    func oldestFirstFeedBelowKnownCountIsNone() {
        let episodes = [
            episode(4, daysAgo: 0),
            episode(3, daysAgo: 7),
            episode(2, daysAgo: 14),
            episode(1, daysAgo: 21)
        ]
        let feed = ReleaseFeed(title: "True Beauty", entries: episodes, source: .webtoons)
        #expect(ReleaseSummary.summarise(feed, knownChapterCount: 230) == .none)
    }

    /// The control: the same four dates, with no known count at all, still
    /// read as `.rhythm` — this is `fourWeeklyEpisodesIsRhythm` again,
    /// proving the difference above is the known count, not some other
    /// change to `summarise`.
    @Test("Control: without a known chapter count the same feed is still rhythm")
    func sameFeedWithoutKnownCountIsStillRhythm() {
        let episodes = [
            episode(4, daysAgo: 0),
            episode(3, daysAgo: 7),
            episode(2, daysAgo: 14),
            episode(1, daysAgo: 21)
        ]
        let feed = ReleaseFeed(title: "True Beauty", entries: episodes, source: .webtoons)
        guard case .rhythm = ReleaseSummary.summarise(feed) else {
            Issue.record("expected .rhythm with no known count")
            return
        }
    }

    /// An ongoing series near its known count must not be flagged — the
    /// check is about a feed far below the count, not merely below it.
    @Test("A feed close to the known chapter count is not treated as oldest-first")
    func feedNearKnownCountIsStillRhythm() {
        let episodes = (1...20).map { episode($0, daysAgo: (20 - $0) * 7) }
        let feed = ReleaseFeed(title: "Tower of God", entries: episodes, source: .webtoons)
        guard case .rhythm = ReleaseSummary.summarise(feed, knownChapterCount: 21) else {
            Issue.record("expected .rhythm for a feed at 20/21 of the known count")
            return
        }
    }

    // MARK: - isEmpty

    @Test("isEmpty is true only for none")
    func isEmptyOnlyForNone() {
        #expect(ReleaseSummary.none.isEmpty)
        #expect(!ReleaseSummary.lastSeen(latest: now, number: 1).isEmpty)
        #expect(!ReleaseSummary.recent([episode(1, daysAgo: 0)]).isEmpty)
        #expect(!ReleaseSummary.seasonEnded(season: 1, on: now).isEmpty)
    }
}
