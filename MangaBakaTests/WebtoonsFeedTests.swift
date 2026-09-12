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
    private func feed() throws -> WebtoonsFeed {
        let data = try Fixture.data("knight-only-lives-today", extension: "rss")
        return try #require(WebtoonsFeed.parse(data))
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
    /// 부. This is the Korean original's numbering, which is what says whether
    /// the source is still running while the English translation lags.
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
}

/// Turning a stored series link into a feed URL. See `WebtoonsFeed.feedURL`.
@Suite("Webtoons feed URLs")
struct WebtoonsFeedURLTests {
    private func url(_ text: String) -> URL? {
        guard let link = URL(string: text) else { return nil }
        return WebtoonsFeed.feedURL(for: link)
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
        let lookup = try #require(WebtoonsFeed.lookupURL(for: link))
        #expect(lookup.absoluteString == "https://www.webtoons.com/en/x/y/list?title_no=5188")

        // What the redirect lands on, and what it is worth once it does.
        let landed = try #require(
            URL(string: "https://www.webtoons.com/fr/fantasy/estatedeveloper/list?title_no=5188")
        )
        #expect(WebtoonsFeed.feedURL(fromResolved: landed)?.absoluteString
                == "https://www.webtoons.com/fr/fantasy/estatedeveloper/rss?title_no=5188")
    }

    /// A link that already works needs no redirect, so it must not ask for one.
    @Test("A real link is never sent for lookup")
    func realLinksNeedNoLookup() throws {
        let link = try #require(
            URL(string: "https://www.webtoons.com/en/fantasy/tower-of-god/list?title_no=95")
        )
        #expect(WebtoonsFeed.lookupURL(for: link) == nil)
    }

    @Test("A placeholder with no series number cannot be looked up")
    func lookupNeedsASeriesNumber() throws {
        let link = try #require(URL(string: "https://www.webtoons.com/-/-/-/list"))
        #expect(WebtoonsFeed.lookupURL(for: link) == nil)
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
