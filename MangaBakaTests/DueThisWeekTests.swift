import Foundation
import Testing
@testable import MangaBaka

/// "What's due this week", as Siri says it.
@Suite("Due this week")
struct DueThisWeekTests {
    private let now = Date(timeIntervalSince1970: 1_789_000_000) // a Wednesday, 2026-09-09

    private func work(_ id: Int, _ title: String, dueIn days: Int) -> ScheduledWork {
        let due = now.addingTimeInterval(Double(days) * 86_400)
        let cadence = Cadence(
            medianGapDays: 7, spreadDays: 0, lastRelease: due.addingTimeInterval(-7 * 86_400),
            due: due, samples: 10, gaps: 9, isRegular: true
        )
        return ScheduledWork(series: SeriesFactory.make(id: id, title: title), cadence: cadence, reason: nil)
    }

    @Test("Within seven days, soonest first; late counts; beyond the week does not")
    func estimates() {
        let sentence = DueThisWeek.sentence(
            dated: [work(1, "A", dueIn: -2), work(2, "B", dueIn: 0), work(3, "C", dueIn: 1),
                    work(4, "D", dueIn: 6), work(5, "E", dueIn: 9)],
            announced: [], measured: true, now: now
        )
        #expect(sentence.hasPrefix("4 due this week: A, 2 days overdue; B, today; C, tomorrow; D, "))
        #expect(!sentence.contains("E"))
    }

    @Test("Nothing due says so; nothing measured says that instead")
    func empty() {
        #expect(DueThisWeek.sentence(dated: [], announced: [], measured: true, now: now)
                == "Nothing due in the next 7 days.")
        #expect(DueThisWeek.sentence(dated: [], announced: [], measured: false, now: now)
                .hasPrefix("The schedule hasn't been measured yet"))
    }

    @Test("One thing is singular")
    func singular() {
        let sentence = DueThisWeek.sentence(
            dated: [work(1, "A", dueIn: 3)], announced: [], measured: true, now: now
        )
        #expect(sentence.hasPrefix("One thing due this week: A, "))
    }

    /// Gap 105: this used to have no way to hear that the library read had
    /// failed, so a reader who asked "what's due" while offline got the same
    /// "Nothing due in the next 7 days" as one whose week was genuinely
    /// quiet — the one answer that is actually wrong to give with no library
    /// to check.
    /// Expected to fail before the fix with: "Nothing due in the next 7
    /// days." — no `libraryFailure` parameter existed to say otherwise.
    @Test("A library that could not be read is said, not silently answered as quiet")
    func libraryFailureIsNamed() {
        let sentence = DueThisWeek.sentence(
            dated: [], announced: [], measured: true, now: now, libraryFailure: .offline
        )
        #expect(sentence.hasPrefix("I couldn't read your library."))
    }

    /// A failure is only worth naming when it actually left nothing to say —
    /// a library read that failed on a later page but still turned up real
    /// dated works from the pages that landed should report those, not lead
    /// with the failure ahead of a real answer.
    @Test("A library failure is not mentioned when there is a real answer anyway")
    func libraryFailureIsSilentWhenThereIsSomethingToSay() {
        let sentence = DueThisWeek.sentence(
            dated: [work(1, "A", dueIn: 1)], announced: [], measured: true, now: now,
            libraryFailure: .offline
        )
        #expect(!sentence.hasPrefix("I couldn't read your library"))
        #expect(sentence.contains("A"))
    }
}

/// A provider that always answers a fixed feed, for testing
/// `DueThisWeekIntent.feedDueWorks` without any network stand-in.
private struct StubFeedProvider: ReleaseFeedProvider {
    let source: ReleaseSource
    let answer: FeedAnswer
    /// Counts what a live client would have had to fetch. Since Abdi's Q12
    /// answer `feedDueWorks` reads only `cachedFeed`, so this staying at zero
    /// is the assertion the Siri path now rests on.
    let fetches: Counter?

    init(source: ReleaseSource, answer: FeedAnswer, fetches: Counter? = nil) {
        self.source = source
        self.answer = answer
        self.fetches = fetches
    }

    func feed(for series: Series, links: [SeriesLink]) async -> FeedAnswer {
        fetches?.bump()
        return answer
    }

    /// The same feed, served the way a warmed on-disk cache would serve it.
    func cachedFeed(for series: Series, links: [SeriesLink]) async -> ReleaseFeed? { answer.feed }
}

/// A thread-safe tally, because `StubFeedProvider` has to be `Sendable`.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func bump() { lock.lock(); value += 1; lock.unlock() }
    var calls: Int { lock.lock(); defer { lock.unlock() }; return value }
}

/// A repository whose `cachedExtras` answers from a fixed table, so
/// `feedDueWorks` can be tested without a real six-hour detail cache.
///
/// Declared fresh here rather than subclassing `StubRepositoryBase`: that
/// base class relies on `SeriesRepositoryProtocol`'s own default for
/// `cachedExtras` (a protocol-extension method, not a class member), and a
/// subclass override of a method the base never declared itself would not
/// actually be picked up through the protocol's static dispatch.
private final class StubExtrasRepository: SeriesRepositoryProtocol, @unchecked Sendable {
    var extrasByID: [Int: SeriesExtras] = [:]

    func cachedExtras(for seriesId: Int) async -> SeriesExtras? { extrasByID[seriesId] }

    func feed(_ feed: FeedKind, forceRefresh: Bool) async -> FeedResult {
        FeedResult(series: [], origin: .network)
    }
    func search(_ query: SearchQuery) async -> FeedResult { FeedResult(series: [], origin: .network) }
    func feedPage(_ feed: FeedKind, page: Int) async -> FeedResult {
        FeedResult(series: [], origin: .network)
    }
    func mix(seeds: [Int], filters: SearchQuery, excludedTags: [Int]) async -> MixResult { .empty }
    func extras(for seriesId: Int) async -> SeriesExtras { extrasByID[seriesId] ?? SeriesExtras() }
    func images(for seriesId: Int) async -> [SeriesImage]? { [] }
    func relationships(for seriesId: Int) async -> [SeriesRelationship]? { nil }
    func updateContentRatings(_ ratings: [String]) async {}
    func updateFormats(_ formats: [String]) async {}
    func updateLibraryExclusion(userID: String?) async {}
    func updateBlockedTags(_ ids: [Int]) async {}
    func cachedSeriesCount() async -> Int { 0 }
    func count(_ query: SearchQuery) async -> Int? { nil }
}

private func webtoonsLink() -> SeriesLink {
    SeriesLink(
        id: "1", url: URL(string: "https://www.webtoons.com/en/x/y/list?title_no=1"),
        name: "webtoons.com", nameDisplay: "Webtoons", type: "webplatform", language: "en"
    )
}

/// Real Webtoons dates standing in for a MangaUpdates estimate, and the
/// "at most N fetches" bound around it.
@Suite("Due this week reads real release feeds")
struct DueThisWeekFeedTests {
    private let now = Date(timeIntervalSince1970: 1_789_000_000) // a Wednesday, 2026-09-09

    /// `Cadence.estimate` needs `minimumDates` real dates to speak at all —
    /// a steady weekly run whose most recent release was `lastReleaseDaysAgo`
    /// days ago, so `due` (last release + the 7-day median gap) lands
    /// `7 - lastReleaseDaysAgo` days from now.
    private func rhythmFeed(lastReleaseDaysAgo: Int) -> ReleaseFeed {
        let entries = (0..<5).map { offset in
            ReleaseEntry(
                title: "Episode \(5 - offset)",
                published: now.addingTimeInterval(Double(-lastReleaseDaysAgo - offset * 7) * 86_400),
                number: 5 - offset, season: nil
            )
        }
        return ReleaseFeed(title: "Webtoons", entries: entries, source: .webtoons)
    }

    /// Expected to fail before the fix with no `feedDueWorks` method at
    /// all: the intent had no path from a cached Webtoons link to a real
    /// due date, only the MangaUpdates cadence in `snapshot.dated`.
    @Test("A library series with a cached Webtoons link gets a real date")
    func feedSourcedSeries() async {
        let series = SeriesFactory.make(id: 42, title: "Tower of God")
        let repo = StubExtrasRepository()
        repo.extrasByID[42] = SeriesExtras(links: [webtoonsLink()])
        let feeds = ReleaseFeedService(providers: [
            StubFeedProvider(source: .webtoons, answer: .answered(rhythmFeed(lastReleaseDaysAgo: 5)))
        ])
        let work = ScheduledWork(series: series, cadence: nil, reason: nil)

        let results = await DueThisWeekIntent.feedDueWorks(for: [work], feeds: feeds, repository: repo)

        #expect(results.count == 1)
        #expect(results.first?.seriesId == 42)
        #expect(results.first?.sourceName == "Webtoons")
    }

    @Test("A series with no cached extras is skipped, not fetched")
    func noCacheIsSkipped() async {
        let series = SeriesFactory.make(id: 7, title: "Uncached")
        let repo = StubExtrasRepository()
        let feeds = ReleaseFeedService(providers: [
            StubFeedProvider(source: .webtoons, answer: .answered(rhythmFeed(lastReleaseDaysAgo: 5)))
        ])
        let work = ScheduledWork(series: series, cadence: nil, reason: nil)

        let results = await DueThisWeekIntent.feedDueWorks(for: [work], feeds: feeds, repository: repo)
        #expect(results.isEmpty)
    }

    /// Item 110 / Abdi's Q12. One Siri question used to fire up to eight
    /// `report(for:links:)` calls, each serialising behind its client's 3.5 s
    /// spacing with a placeholder lookup in front of most Webtoons links — up
    /// to 56 seconds, by which time Siri has given up with a generic error
    /// while the requests carry on spending the publishers' budget. The answer
    /// is now built from cache alone.
    ///
    /// Expected failure before the fix: `fetches.count` is 8 (the old
    /// `maxFeedFetches`), not 0.
    @Test("Answering Siri makes no release-feed request at all")
    func neverFetches() async {
        let repo = StubExtrasRepository()
        let works = (1...20).map { id -> ScheduledWork in
            repo.extrasByID[id] = SeriesExtras(links: [webtoonsLink()])
            return ScheduledWork(
                series: SeriesFactory.make(id: id, title: "S\(id)"), cadence: nil, reason: nil
            )
        }
        let fetches = Counter()
        let feeds = ReleaseFeedService(providers: [
            StubFeedProvider(
                source: .webtoons, answer: .answered(rhythmFeed(lastReleaseDaysAgo: 5)),
                fetches: fetches
            )
        ])

        let results = await DueThisWeekIntent.feedDueWorks(for: works, feeds: feeds, repository: repo)
        #expect(fetches.calls == 0, "cache only — every one of these would have been a network call")
        #expect(results.count == 20, "control: every series still gets its real date from the cache")
    }

    @Test("Feed-sourced and estimated say which they are when both are due; feed-sourced named first")
    func mixedSentenceLabelsEachKind() {
        let feedWork = DueThisWeek.FeedDueWork(
            seriesId: 1, title: "Real Deal", due: now.addingTimeInterval(2 * 86_400), sourceName: "Webtoons"
        )
        let cadence = Cadence(
            medianGapDays: 7, spreadDays: 0, lastRelease: now,
            due: now.addingTimeInterval(3 * 86_400), samples: 10, gaps: 9, isRegular: true
        )
        let estimated = ScheduledWork(
            series: SeriesFactory.make(id: 2, title: "Guess"), cadence: cadence, reason: nil
        )

        let sentence = DueThisWeek.sentence(
            dated: [estimated], announced: [], feedWorks: [feedWork], measured: true, now: now
        )

        #expect(sentence.contains("Real Deal") && sentence.contains("real dates from Webtoons"))
        #expect(sentence.contains("Guess") && sentence.contains("(estimated)"))
        #expect((sentence.range(of: "Real Deal")?.lowerBound ?? sentence.endIndex)
                < (sentence.range(of: "Guess")?.lowerBound ?? sentence.endIndex))
    }

    /// Control: with no feed data at all, the sentence must read exactly as
    /// it did before this feature existed — no "(estimated)" noise on every
    /// ordinary MangaUpdates-only answer.
    @Test("With no feed data, the sentence is unchanged")
    func controlNoFeedData() {
        let cadence = Cadence(
            medianGapDays: 7, spreadDays: 0, lastRelease: now,
            due: now.addingTimeInterval(3 * 86_400), samples: 10, gaps: 9, isRegular: true
        )
        let estimated = ScheduledWork(
            series: SeriesFactory.make(id: 2, title: "Guess"), cadence: cadence, reason: nil
        )
        let sentence = DueThisWeek.sentence(dated: [estimated], announced: [], measured: true, now: now)
        #expect(!sentence.contains("(estimated)"))
        #expect(sentence.contains("Guess"))
    }
}

@Suite("Intents are wired", .enabled(if: SourceTree.isAvailable))
struct IntentWiringTests {
    /// The previous version of this test pinned the bug as source text:
    /// `"bridge.pendingSeriesID = nil await openSeries(id: id)"` — the nil
    /// write *before* the call, which is exactly what cancelled the task
    /// before it could navigate (S2, 2026-09-14). It was green over the
    /// defect it was written to protect. Pinned the other way round now: the
    /// clear must come after the open, and must be guarded by the token.
    @Test("The app hands the bridge its services and the root opens what an intent asks")
    func wiring() throws {
        let app = try SourceTree.read("MangaBaka/App/MangaBakaApp.swift")
        #expect(app.contains("IntentBridge.shared.services = services"))
        let root = try SourceTree.read("MangaBaka/App/RootView.swift")
        #expect(root.contains(".task(id: bridge.pending?.token)"))
        // The order is the whole fix: open, then clear.
        #expect(SourceTree.containsRun(
            root,
            "await openSeries(id: request.id)"
        ))
        #expect(!SourceTree.containsRun(root, "bridge.pending = nil await openSeries"))
        // The clear is guarded, so a second request arriving mid-flight is
        // not discarded by the first one finishing.
        #expect(root.contains("if bridge.pending?.token == request.token { bridge.pending = nil }"))
    }

    /// Every producer of an open request mints a fresh `Open`.
    ///
    /// The three entry points — Siri/Shortcuts, the widgets' custom scheme,
    /// and a mangabaka.org universal link — all go through one `.task`, so if
    /// any of them still wrote a bare id the modifier would not restart and
    /// that door would stop working silently.
    ///
    /// Expected to fail before the fix with a compile error: `Open` did not
    /// exist. The behavioural half of S2 cannot be unit tested — nothing in
    /// this project can drive a SwiftUI `.task(id:)` — and the report's own
    /// way to settle it is one `print(Task.isCancelled)` at the top of
    /// `openSeries` with a Siri "Open <a series not in the library>".
    @Test("Every deep-link entry point mints a distinct open request")
    func everyEntryPointMintsARequest() throws {
        let intents = try SourceTree.read("MangaBaka/Core/Intents/AppIntents.swift")
        #expect(intents.contains("IntentBridge.Open(id: series.id)"))
        let root = try SourceTree.read("MangaBaka/App/RootView.swift")
        #expect(root.contains("IntentBridge.Open(id: id)"))
        #expect(!root.contains("pendingSeriesID"))
        #expect(!intents.contains("pendingSeriesID"))
    }

    /// The control for the test above: two requests for the *same* series are
    /// different requests. This is what a bare `Int?` could not express, and
    /// it is why the task no longer has to clear its own key to re-arm.
    @Test("Two opens of the same series are distinct")
    @MainActor
    func sameSeriesTwiceIsTwoRequests() {
        let first = IntentBridge.Open(id: 42)
        let second = IntentBridge.Open(id: 42)

        #expect(first != second)
        #expect(first.id == second.id)
    }
}
