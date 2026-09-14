import Foundation
import Testing
@testable import MangaBaka

/// Reading a Webtoons series feed.
///
/// The fixture is the real feed for "The Knight Only Lives Today", saved
/// verbatim on 2026-09-12. Abdi picked the series precisely because it is the
/// awkward case: its first season ended at episode 112 and the feed's three
/// newest entries are `Afterword 1/2/3`, published the same Friday as the
/// finale.
@Suite("Webtoons feed")
struct WebtoonsFeedTests {
    private func feed() throws -> ReleaseFeed {
        let data = try Fixture.data("knight-only-lives-today", extension: "rss")
        return try #require(WebtoonsFeedParser.parse(data))
    }

    @Test("The channel and every entry are read")
    func parsesFeed() throws {
        let feed = try feed()
        #expect(feed.title == "The Knight Only Lives Today")
        #expect(feed.entries.count == 20)
    }

    /// The headline case. Three of the twenty entries are afterwords, and they
    /// are the three newest — so anything that trusts document order, or reads
    /// a number out of any title, gets this series badly wrong.
    @Test("Afterwords are entries but not episodes")
    func afterwordsAreNotEpisodes() throws {
        let feed = try feed()
        #expect(feed.entries.prefix(3).map(\.title) == ["Afterword 3", "Afterword 2", "Afterword 1"])
        #expect(feed.entries.prefix(3).allSatisfy { !$0.isEpisode })
        #expect(feed.episodes.count == 17)
    }

    /// What the bug would have looked like: the newest entry is "Afterword 3",
    /// so a naive read reports episode 3 for a series on its 112th.
    @Test("The latest episode is 112, not the 3 the newest entry would suggest")
    func latestEpisodeIgnoresAfterwords() throws {
        let feed = try feed()
        #expect(feed.latestEpisodeNumber == 112)
        #expect(WebtoonsTitle.read("Afterword 3") == nil)
    }

    /// MangaBaka has this series at 112 chapters. Two independent sources
    /// agreeing is the control that the number means what it claims to.
    @Test("The feed's episode count agrees with MangaBaka's chapter count")
    func agreesWithCatalogue() throws {
        #expect(try feed().latestEpisodeNumber == 112)
    }

    /// Afterwords share one timestamp, so counting them would put zero-length
    /// gaps into a median taken over real weekly ones.
    @Test("Release dates are episodes only, and weekly")
    func releaseDatesAreEpisodesOnly() throws {
        let feed = try feed()
        #expect(feed.releaseDates.count == 17)

        let cadence = try #require(Cadence.estimate(from: feed.releaseDates))
        #expect(cadence.medianGapDays == 7)
        #expect(cadence.isRegular)
    }

    /// The control for the above: with the afterwords left in, the same feed
    /// still has to be read as weekly — proving the 7 above is the series'
    /// rhythm and not an artefact of which entries were kept.
    @Test("Every entry's date, afterwords included, is still a weekly rhythm")
    func cadenceControl() throws {
        let all = try feed().entries.map(\.published)
        let cadence = try #require(Cadence.estimate(from: all))
        #expect(cadence.medianGapDays == 7)
    }

    /// "Season 1 ended on 28 August" and "overdue since August" look identical
    /// to a gap-based estimate and mean opposite things to a reader.
    @Test("A finished season is read as ended, not as late")
    func finishedSeasonIsDetected() throws {
        let feed = try feed()
        #expect(feed.endedSeason == 1)
        #expect(WebtoonsTitle.marksFinale("Episode 112 (Season 1 Finale)"))
        #expect(!WebtoonsTitle.marksFinale("Episode 111"))
    }

    @Test("The newest episode's date is the finale's, not an afterword's")
    func lastEpisodeAt() throws {
        let feed = try feed()
        let last = try #require(feed.lastEpisodeAt)
        let newest = try #require(feed.entries.first?.published)
        #expect(last < newest, "The afterwords are newer than the last episode")
    }
}

/// Reading an entry title. See `WebtoonsTitle`.
@Suite("Webtoons episode titles")
struct WebtoonsTitleTests {
    @Test("The plain forms are read")
    func plainForms() {
        #expect(WebtoonsTitle.read("Episode 393")?.number == 393)
        #expect(WebtoonsTitle.read("Ep. 235")?.number == 235)
        #expect(WebtoonsTitle.read("Chapter 12")?.number == 12)
    }

    /// Tower of God's real titles. A pattern demanding `Episode <n>` exactly
    /// discards every one of them, which is how the first attempt failed.
    @Test("A bracketed season prefix does not hide the episode")
    func seasonPrefix() {
        let read = WebtoonsTitle.read("[Season 3] Ep. 235")
        #expect(read?.number == 235)
        #expect(read?.season == 3)
    }

    @Test("A trailing note does not become part of the number")
    func trailingNote() {
        #expect(WebtoonsTitle.read("Episode 112 (Season 1 Finale)")?.number == 112)
    }

    /// Naver writes the number and its unit as one token, and the season with
    /// 부. A parser test over a literal string: no feed the app fetches has
    /// carried Korean titles since the Naver adapter was deleted on
    /// 2026-09-14 — see the tombstone in `ReleaseFeedService.swift` — so this
    /// pins the rule, not a live code path.
    @Test("Korean numbering is read")
    func koreanForms() {
        #expect(WebtoonsTitle.read("235화")?.number == 235)
        let seasoned = WebtoonsTitle.read("3부 235화")
        #expect(seasoned?.number == 235)
        #expect(seasoned?.season == 3)
    }

    /// The whole design in one test: a number is not what makes a title an
    /// episode, the word is. `Afterword 3` has the same shape as `Episode 3`.
    @Test("Anything that is not an episode word is not an episode")
    func nonEpisodesRejected() {
        #expect(WebtoonsTitle.read("Afterword 3") == nil)
        #expect(WebtoonsTitle.read("Notice") == nil)
        #expect(WebtoonsTitle.read("Author's Note 2") == nil)
        #expect(WebtoonsTitle.read("Hiatus Announcement") == nil)
        #expect(WebtoonsTitle.read("Season 2 Announcement") == nil)
    }

    /// GigaViewer magazine RSS titles: `第N話`, the marker a Japanese
    /// publisher uses for "episode". Read for `GigaViewerFeedClient`.
    @Test("Japanese 第N話 forms are read")
    func japaneseForms() {
        #expect(WebtoonsTitle.read("第33話")?.number == 33)
        // A sub-episode suffix: the leading number is kept, the "-1" dropped
        // rather than guessed at.
        #expect(WebtoonsTitle.read("第12-1話")?.number == 12)
        // A circled digit trailing the marker does not stop the match.
        #expect(WebtoonsTitle.read("第77話①")?.number == 77)
        // The marker sits inside its own brackets ahead of the series' own
        // title, unlike Webtoons' "[Season 3] Ep. 235" where the bracket is a
        // prefix to an episode word that follows it.
        #expect(WebtoonsTitle.read("[第33話] カテナチオ")?.number == 33)
    }

    /// R4/finding 4 (`docs/reviews/reader.md`, 2026-09-13): a live
    /// `shonenjumpplus.com/rss` read found roughly a third of 40 titles in
    /// these shapes, and every one used to fail — full-width digits, no `第`
    /// at all, `回` instead of `話`, and a bare `#N`. Every title quoted here
    /// is copied verbatim from that read.
    @Test("Japanese titles without the exact 第N話 ASCII shape are still read")
    func japaneseWidenedForms() {
        #expect(WebtoonsTitle.read("[第１２２話]ふつうの軽音部")?.number == 122)
        #expect(WebtoonsTitle.read("[106話]クソ女に幸あれ")?.number == 106)
        #expect(WebtoonsTitle.read("[69話]英雄機関")?.number == 69)
        #expect(WebtoonsTitle.read("[4375回]猫田びより")?.number == 4375)
        #expect(WebtoonsTitle.read("[#96]ゴーストフィクサーズ")?.number == 96)
    }

    /// F6/DECISION (`docs/reviews/tests.md`, 2026-09-13): the Afterword bug,
    /// reintroduced on the Korean side. "외전 3화" (side story 3) has exactly
    /// the shape `[0-9]+화` and used to read as episode 3. Expected failure
    /// before the fix: `WebtoonsTitle.read("외전 3화")?.number == 3`, where
    /// this now asserts nil.
    @Test("Korean side stories and specials are not episodes")
    func koreanNonEpisodesRejected() {
        #expect(WebtoonsTitle.read("외전 3화") == nil)
        #expect(WebtoonsTitle.read("특별편 2화") == nil)
        #expect(WebtoonsTitle.read("후기 1화") == nil)
        // The forms that must keep working: a season prefix legitimately
        // comes before the number, unlike the disqualifying words above.
        #expect(WebtoonsTitle.read("235화")?.number == 235)
        #expect(WebtoonsTitle.read("3부 235화")?.number == 235)
    }

    /// R11/F10 (`docs/reviews/reader.md`, `tests.md`, 2026-09-13):
    /// `marksFinale` used to match "finale"/"the end" anywhere in the title,
    /// so an ordinary episode whose subtitle happened to contain those words
    /// ended the season. Expected failure before the fix:
    /// `WebtoonsTitle.marksFinale("Episode 30: The End of Summer")` was
    /// `true`; this now asserts `false`.
    @Test("An ordinary title is not read as a finale")
    func ordinaryTitlesAreNotFinales() {
        #expect(!WebtoonsTitle.marksFinale("Episode 30: The End of Summer"))
        #expect(!WebtoonsTitle.marksFinale("Episode 30: Until the end"))
    }

    /// The marker still fires inside parentheses, which is the shape
    /// Webtoons actually writes it in.
    @Test("A finale marker in parentheses, or at the end of the title, still fires")
    func finaleStillDetectedInParenthesesOrAtEnd() {
        #expect(WebtoonsTitle.marksFinale("Episode 112 (Season 1 Finale)"))
        #expect(WebtoonsTitle.marksFinale("Episode 50 - Final Episode"))
    }
}

/// A non-English edition's localised `pubDate`. See finding 2,
/// `docs/reviews/reader.md`, 2026-09-13.
///
/// Before the fix, `WebtoonsFeedParser.parse` returned a feed with a channel
/// title and **zero** entries for this fixture — every `pubDate` failed
/// `en_US_POSIX` RFC-822 parsing and was silently dropped. Expected failure
/// before the fix: `feed.entries.count == 0` (not 7), which is exactly what
/// this test's positive assertion below now rules out.
@Suite("Webtoons feed — localised editions")
struct WebtoonsFeedLocalisationTests {
    @Test("A French edition's localised pubDate still parses")
    func frenchPubDateParses() throws {
        let data = try Fixture.data("estate-developer-fr", extension: "rss")
        let feed = try #require(WebtoonsFeedParser.parse(data))
        #expect(feed.entries.count == 7)
        #expect(feed.entries.map(\.title).sorted() == (1...7).map { "Ep. \($0)" })
    }
}

/// Turning a stored series link into a feed URL. See `WebtoonsFeedParser.feedURL`.
@Suite("Webtoons feed URLs")
struct WebtoonsFeedURLTests {
    private func url(_ text: String) -> URL? {
        guard let link = URL(string: text) else { return nil }
        return WebtoonsFeedParser.feedURL(for: link)
    }

    @Test("A real series link becomes its feed")
    func derivesFeedURL() {
        #expect(url("https://www.webtoons.com/en/fantasy/tower-of-god/list?title_no=95")?
            .absoluteString == "https://www.webtoons.com/en/fantasy/tower-of-god/rss?title_no=95")
    }

    /// MangaBaka stores most of its Webtoons links with the genre and slug
    /// replaced by "-" — 84% of a 118-series sample of the real library. Those
    /// are not feed URLs directly; they are recovered by `lookupURL` below.
    @Test("A placeholder link is not a feed URL on its own")
    func placeholderLinksRejected() {
        #expect(url("https://www.webtoons.com/-/-/-/list?title_no=5188") == nil)
    }

    /// The recovery, and the reason the feature is worth more than a sixth of
    /// the library. Webtoons keys the page on title_no alone and redirects to
    /// the canonical path, correcting the language on the way: 5188 lands on
    /// /fr/, 7620 on /id/ (measured 2026-09-12).
    @Test("A placeholder link becomes a lookup that the redirect resolves")
    func placeholderBecomesLookup() throws {
        let link = try #require(URL(string: "https://www.webtoons.com/-/-/-/list?title_no=5188"))
        let lookup = try #require(WebtoonsFeedParser.lookupURL(for: link))
        #expect(lookup.absoluteString == "https://www.webtoons.com/en/x/y/list?title_no=5188")

        // What the redirect lands on, and what it is worth once it does.
        let landed = try #require(
            URL(string: "https://www.webtoons.com/fr/fantasy/estatedeveloper/list?title_no=5188")
        )
        #expect(WebtoonsFeedParser.feedURL(fromResolved: landed)?.absoluteString
                == "https://www.webtoons.com/fr/fantasy/estatedeveloper/rss?title_no=5188")
    }

    /// A link that already works needs no redirect, so it must not ask for one.
    @Test("A real link is never sent for lookup")
    func realLinksNeedNoLookup() throws {
        let link = try #require(
            URL(string: "https://www.webtoons.com/en/fantasy/tower-of-god/list?title_no=95")
        )
        #expect(WebtoonsFeedParser.lookupURL(for: link) == nil)
    }

    @Test("A placeholder with no series number cannot be looked up")
    func lookupNeedsASeriesNumber() throws {
        let link = try #require(URL(string: "https://www.webtoons.com/-/-/-/list"))
        #expect(WebtoonsFeedParser.lookupURL(for: link) == nil)
    }

    @Test("Only Webtoons links, and only ones naming a series")
    func otherLinksRejected() {
        #expect(url("https://tapas.io/series/solo-leveling-comic/info") == nil)
        #expect(url("https://www.webtoons.com/en/fantasy/tower-of-god/list") == nil)
        #expect(url("https://notwebtoons.com/en/x/y/list?title_no=95") == nil)
    }

    /// The stored link can carry more than the series id; only the id is ours
    /// to forward.
    @Test("Only title_no survives into the feed URL")
    func stripsOtherQueryItems() {
        let derived = url("https://www.webtoons.com/en/drama/x/list?title_no=7&from=share&uid=99")
        #expect(derived?.query() == "title_no=7")
    }
}

/// The client's network behaviour: what it asks for, and the shape it
/// answers in. `.serialized` because it shares `URLProtocolStub`'s per-test
/// state.
@Suite("Webtoons feed client", .serialized)
struct WebtoonsFeedClientTests {
    private func makeClient(clock: TestClock, cacheDirectory: URL) -> WebtoonsFeedClient {
        WebtoonsFeedClient(
            session: URLProtocolStub.makeSession(), clock: clock, cacheDirectory: cacheDirectory
        )
    }

    private let link = SeriesLink(
        id: "1", url: URL(string: "https://www.webtoons.com/en/fantasy/tower-of-god/list?title_no=95"),
        name: "webtoons", nameDisplay: nil, type: "webplatform", language: "en"
    )

    private let rss = Data(#"""
    <?xml version="1.0"?>
    <rss version="2.0"><channel><title>Tower of God</title>
    <item><title>Episode 1</title><pubDate>Thu, 11 Sep 2026 15:00:00 GMT</pubDate></item>
    </channel></rss>
    """#.utf8)

    /// A series with no Webtoons-shaped link is never asked, and is not
    /// reported as a failure — it simply never carried this source.
    @Test("A series with no Webtoons link is notCarried, not failed")
    func noLinkIsNotCarried() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("webtoons-tests-\(UUID().uuidString)", isDirectory: true)
        let client = makeClient(clock: TestClock(), cacheDirectory: directory)
        let answer = await client.feed(for: [], seriesID: 1)
        #expect(answer == .notCarried)
    }

    /// A matching link that answers gets `.answered(_)`, attributed to
    /// Webtoons, and the party on a subsequent 429 is Webtoons', not
    /// MangaBaka's default.
    @Test("A matching link that is rate-limited fails with Webtoons named as the party")
    func rateLimitedCarriesTheParty() async {
        URLProtocolStub.setHandler { _ in .respond(.init(statusCode: 429)) }
        defer { URLProtocolStub.reset() }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("webtoons-tests-\(UUID().uuidString)", isDirectory: true)
        let client = makeClient(clock: TestClock(), cacheDirectory: directory)

        let answer = await client.feed(for: [link], seriesID: 95)
        guard case let .failed(error) = answer else {
            Issue.record("expected .failed, got \(answer)")
            return
        }
        #expect(error == .rateLimited(until: nil, party: .webtoons))
    }

    /// Gap 29: commit 5bb36b8 changed the parser and the never-cache-empty
    /// rule without bumping the cache key, so a `v3-` file written under the
    /// old rules could still answer for up to a week under the new ones.
    /// Expected failure before the fix: this test fails because the client
    /// still reads the `v3-` file — it asks the key it always asked, which
    /// was `v3-`, so a request that should have gone to the (stubbed, and
    /// here deliberately failing) network instead returned the stale `v3-`
    /// cache and `URLProtocolStub.requests` stayed empty.
    @Test("A v3- cache file is not read; the client asks for v4-")
    func cacheKeyIsBumpedToV4() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("webtoons-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let staleFeed = ReleaseFeed(
            title: "Stale",
            entries: [ReleaseEntry(title: "Episode 1", published: Date(), number: 1, season: nil)],
            source: .webtoons
        )
        // `WebtoonsFeedClient.Cached` is private; this mirrors its shape
        // exactly (`storedAt`/`feed`) to write a file the client would read
        // if it were still asking for the `v3-` key.
        struct LegacyCached: Codable { let storedAt: Date; let feed: ReleaseFeed }
        let data = try JSONEncoder().encode(LegacyCached(storedAt: Date(), feed: staleFeed))
        try data.write(to: directory.appendingPathComponent("v3-95.json"))

        // The network fails outright, so the only way this test can see a
        // feed at all is by (incorrectly) reading the v3- file.
        URLProtocolStub.setHandler { _ in .respond(.init(statusCode: 500)) }
        defer { URLProtocolStub.reset() }
        let client = makeClient(clock: TestClock(), cacheDirectory: directory)

        let answer = await client.feed(for: [link], seriesID: 95)
        #expect(answer.feed == nil, "the v3- file must not answer for the v4- key")
        #expect(!URLProtocolStub.requests.isEmpty, "a real request must have been attempted")
    }
}

/// `cachedFeed`, the read-only counterpart `ReleaseFeedService.cachedFeeds`
/// calls from `RootView+Session.refreshReminders` — no request, no sleep, and
/// (unlike `feed(for:links:)`) no freshness gate: a stale season-ended fact is
/// still true.
@Suite("Webtoons cachedFeed", .serialized)
struct WebtoonsCachedFeedTests {
    private func makeClient(clock: TestClock, cacheDirectory: URL) -> WebtoonsFeedClient {
        WebtoonsFeedClient(
            session: URLProtocolStub.makeSession(), clock: clock, cacheDirectory: cacheDirectory
        )
    }

    private let link = SeriesLink(
        id: "1", url: URL(string: "https://www.webtoons.com/en/fantasy/tower-of-god/list?title_no=95"),
        name: "webtoons", nameDisplay: nil, type: "webplatform", language: "en"
    )

    private let rss = Data(#"""
    <?xml version="1.0"?>
    <rss version="2.0"><channel><title>Tower of God</title>
    <item><title>Episode 235</title><pubDate>Thu, 11 Sep 2026 15:00:00 GMT</pubDate></item>
    </channel></rss>
    """#.utf8)

    /// Expected failure before `cachedFeed` existed: this would not compile —
    /// `ReleaseFeedProvider` had no such method, only `feed(for:links:)`,
    /// which costs a network call `refreshReminders` cannot afford to make
    /// once per library series.
    @Test("The same v4- key feed(for:) writes is read back, with no request")
    func readsWhatFeedWrote() async {
        URLProtocolStub.setHandler { _ in .respond(.init(body: rss)) }
        defer { URLProtocolStub.reset() }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("webtoons-tests-\(UUID().uuidString)", isDirectory: true)
        let clock = TestClock()
        let client = makeClient(clock: clock, cacheDirectory: directory)
        let series = SeriesFactory.make(id: 95, title: "Tower of God")

        _ = await client.feed(for: series, links: [link])
        #expect(URLProtocolStub.requests.count == 1)

        let cached = await client.cachedFeed(for: series, links: [link])
        #expect(cached?.episodes.map(\.number) == [235])
        #expect(URLProtocolStub.requests.count == 1, "cachedFeed must not make a request")
    }

    @Test("Nothing cached yet answers nil")
    func nilWithNothingCached() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("webtoons-tests-\(UUID().uuidString)", isDirectory: true)
        let client = makeClient(clock: TestClock(), cacheDirectory: directory)
        let series = SeriesFactory.make(id: 95, title: "Tower of God")

        let cached = await client.cachedFeed(for: series, links: [link])
        #expect(cached == nil)
    }

    @Test("A series with no Webtoons-shaped link answers nil, not a lookup")
    func nilForUnservedLinks() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("webtoons-tests-\(UUID().uuidString)", isDirectory: true)
        let client = makeClient(clock: TestClock(), cacheDirectory: directory)
        let series = SeriesFactory.make(id: 95, title: "Tower of God")

        let cached = await client.cachedFeed(for: series, links: [])
        #expect(cached == nil)
    }

    /// The one place `cachedFeed` deliberately differs from `feed(for:links:)`:
    /// a stale cache still answers, per Abdi's brief — "a stale season-ended is
    /// still season-ended". `feed(for:links:)`'s own cache read would have
    /// treated this file as expired and gone to the network.
    @Test("A cache older than cacheLife still answers — age is ignored")
    func staleCacheStillAnswers() async {
        URLProtocolStub.setHandler { _ in .respond(.init(body: rss)) }
        defer { URLProtocolStub.reset() }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("webtoons-tests-\(UUID().uuidString)", isDirectory: true)
        let clock = TestClock()
        let client = makeClient(clock: clock, cacheDirectory: directory)
        let series = SeriesFactory.make(id: 95, title: "Tower of God")

        _ = await client.feed(for: series, links: [link])
        clock.advance(by: WebtoonsFeedClient.cacheLife + 1)

        let cached = await client.cachedFeed(for: series, links: [link])
        #expect(cached?.episodes.map(\.number) == [235])
    }
}

/// Rewriting a landed feed URL's language to English. See
/// `WebtoonsFeedParser.englishVariant` and finding 2 in
/// `docs/reviews/reader.md`, 2026-09-13.
@Suite("Webtoons feed language rewriting")
struct WebtoonsFeedEnglishVariantTests {
    /// The exact redirect landing spot from the live capture: `title_no=5188`
    /// resolves to `/fr/`.
    @Test("A non-English landed feed is rewritten to /en/")
    func rewritesToEnglish() throws {
        let landed = try #require(
            URL(string: "https://www.webtoons.com/fr/fantasy/estatedeveloper/rss?title_no=5188")
        )
        let english = try #require(WebtoonsFeedParser.englishVariant(of: landed))
        #expect(english.absoluteString
                == "https://www.webtoons.com/en/fantasy/estatedeveloper/rss?title_no=5188")
    }

    @Test("An already-English feed has no variant to try")
    func englishHasNoVariant() throws {
        let landed = try #require(
            URL(string: "https://www.webtoons.com/en/fantasy/tower-of-god/rss?title_no=95")
        )
        #expect(WebtoonsFeedParser.englishVariant(of: landed) == nil)
    }
}
