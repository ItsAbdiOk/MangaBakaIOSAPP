import Foundation
import Testing
@testable import MangaBaka

/// Perf review, reader/library-ui slices, 2026-09-15
/// (`docs/reviews/perf/reader.md`, `docs/reviews/perf/library-ui.md`,
/// `docs/reviews/perf/SUMMARY.md`). Covers the fixes in this batch that have
/// a user-visible behaviour to pin: R6, R7, R8, R11, R12, R21.
///
/// Not covered here, and why:
/// - R9, R14, R15 belong to `Core/Notifications`, owned by another agent
///   this round.
/// - R10 (`hasAnythingToSay` computed once in `ReadingInsightsView.body`),
///   L1 (`CountUpNumber`'s `TimelineView` pausing) and L2/L3 (the
///   `ContinuationsRow` countdown plumbing and its log line) are SwiftUI
///   view/body changes with no snapshot or view-inspection harness in this
///   project — untestable by reading alone; see the fix report.
/// - R13 (GigaViewer per-host memoisation), R16 (skipped, reported), R17
///   (deletion), R19 (comment labels), R20 (logging) and L4 (dead-alias
///   deletion, covered instead by the two existing tests it touches) have no
///   new externally observable behaviour to assert beyond what already
///   exists.
/// - S8 (`LibraryList`'s arrival stagger no longer repeating on ordinary
///   scroll) is also a SwiftUI view change with nothing here to drive a
///   `LazyVStack`'s real on-appear timing from a unit test.
@Suite("Reader/library-ui perf fixes", .serialized)
struct ReaderFixTests {
    // MARK: - R6: one `top-genres` request shared by both entry points

    private actor Counter {
        private(set) var value = 0
        func increment() { value += 1 }
    }

    private final class CountingLibrary: LibraryProviding, @unchecked Sendable {
        let counter = Counter()

        func recommendationStatus() async throws(APIError) -> RecommendationStatus {
            throw APIError.offline
        }
        func recommendations(
            limit: Int, page: Int, excluding: [Int]
        ) async -> PersonalRecommendations { PersonalRecommendations() }
        func library(page: Int, limit: Int) async -> [LibraryEntry] { [] }
        func hiddenTagIDs() async -> Set<Int>? { [] }
        func add(seriesId: Int, state: LibraryEntry.State) async throws(APIError) -> Bool { true }
        func remove(seriesId: Int) async throws(APIError) {}
        func update(seriesId: Int, change: LibraryChange) async throws(APIError) {}

        func topGenres() async -> [TopGenre]? {
            await counter.increment()
            return [TopGenre(tagId: 1, tagName: "Fantasy", affinityScore: 90)]
        }
    }

    /// Expected to fail before the fix with `library.counter.value == 2`:
    /// `favouredTagNames()` (launch, `RootView+Tabs.swift`) and
    /// `favouredTagIDs()` (the first series page opened) each fetched
    /// `top-genres` on their own, so a session that did both spent the
    /// endpoint twice for the one answer either could have reused.
    @Test("favouredTagNames and favouredTagIDs share one top-genres request")
    func topGenresFetchedOnceAcrossBothEntryPoints() async {
        let library = CountingLibrary()
        let profile = TasteProfile(library: library)

        _ = await profile.favouredTagNames()
        _ = await profile.favouredTagIDs()

        #expect(await library.counter.value == 1)
    }

    // MARK: - R7: a settled cadence older than `staleAfter` is re-measured

    private final class EmptyScheduleLibrary: LibraryProviding, @unchecked Sendable {
        func recommendationStatus() async throws(APIError) -> RecommendationStatus {
            throw APIError.offline
        }
        func recommendations(
            limit: Int, page: Int, excluding: [Int]
        ) async -> PersonalRecommendations { PersonalRecommendations() }
        func library(page: Int, limit: Int) async -> [LibraryEntry] { [] }
        func hiddenTagIDs() async -> Set<Int>? { nil }
        func topGenres() async -> [TopGenre]? { nil }
        func add(seriesId: Int, state: LibraryEntry.State) async throws(APIError) -> Bool { true }
        func remove(seriesId: Int) async throws(APIError) {}
        func update(seriesId: Int, change: LibraryChange) async throws(APIError) {}
    }

    /// Expected to fail before the fix: the second call would return the
    /// first call's row from `readCache(seriesId:)` — `row.failure == nil`
    /// with no age check — instead of asking MangaUpdates again, so
    /// `URLProtocolStub.requests.count` would stay at 1 and the second
    /// `.measured` cadence would be identical to the first, not the fresher
    /// one the (differently-shaped) second stub answer produces.
    @Test("A settled cadence older than staleAfter is re-measured, not kept forever")
    func staleCadenceIsReMeasured() async throws {
        let baseURL = URL(string: "https://mu.example.invalid/v1").unsafeTestURL
        let clock = TestClock()
        let series = SeriesFactory.make(
            id: 1, title: "S1", status: "releasing",
            source: ["manga_updates": Series.TrackerEntry(id: "abc1", rating: nil, ratingNormalized: nil)]
        )
        let service = ReleaseScheduleService(
            library: LibrarySnapshot(library: EmptyScheduleLibrary()),
            mangaUpdates: MangaUpdatesClient(baseURL: baseURL, session: URLProtocolStub.makeSession()),
            database: try AppDatabase.inMemory(),
            clock: clock
        )

        // One handler for the whole test, switching its answer by call
        // count — `setHandler` resets `URLProtocolStub.requests` each time
        // it is called, so a *second* `setHandler` would make the "two real
        // requests were sent" assertion below count only the second one.
        let callCount = RequestCallCounter()
        // `Cadence.minimumDates` is 4 distinct days; anything fewer reads as
        // `.none`, which is not a measured cadence at all.
        let firstBody = Self.releases(from: "2026-01-01", count: 5)
        let secondBody = Self.releases(from: "2026-06-01", count: 6)
        URLProtocolStub.setHandler { _ in
            .respond(.init(body: callCount.next() == 1 ? firstBody : secondBody))
        }
        defer { URLProtocolStub.reset() }

        guard case .measured = await service.cadence(for: series) else {
            Issue.record("expected a first measured cadence")
            return
        }
        #expect(URLProtocolStub.requests.count == 1)

        // Past `ReleaseScheduleService.staleAfter` (14 days).
        clock.advance(by: ReleaseScheduleService.staleAfter + 1)
        guard case .measured = await service.cadence(for: series) else {
            Issue.record("expected a re-measured cadence")
            return
        }
        #expect(URLProtocolStub.requests.count == 2, "a stale row must be asked about again")
    }

    /// `count` weekly releases from `start` (ISO day), as MangaUpdates'
    /// search body. Weekly so the estimate is settled, not `.none`.
    private static func releases(from start: String, count: Int) -> Data {
        let day = ISO8601DateFormatter()
        day.formatOptions = [.withFullDate]
        let first = day.date(from: start) ?? Date()
        let rows = (0..<count).map { index in
            let date = day.string(from: first.addingTimeInterval(Double(index) * 7 * 86_400))
            return #"{"record": {"chapter": "\#(index + 1)", "release_date": "\#(date)"}}"#
        }
        return Data(#"{"results": [\#(rows.joined(separator: ","))]}"#.utf8)
    }

    private final class RequestCallCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int {
            lock.lock(); defer { lock.unlock() }
            value += 1
            return value
        }
    }

    // MARK: - R8: a finale with no season number is still "ended", not overdue

    /// Expected to fail before the fix: `endedSeason` (nil, since the title
    /// carries no "Season N") was the only signal, so `summarise` fell
    /// through to `Cadence.estimate` and read this as a gap-based rhythm —
    /// "overdue" — instead of the finale it actually is.
    @Test("A season-less finale reads as ended, not as an overdue rhythm")
    func finaleWithNoSeasonNumberIsStillAnEnding() {
        let finaleDate = Date(timeIntervalSince1970: 1_757_000_000)
        let feed = ReleaseFeed(
            title: "Some Series",
            entries: [
                ReleaseEntry(
                    title: "Ep. 119", published: finaleDate.addingTimeInterval(-7 * 86_400),
                    number: 119, season: nil
                ),
                ReleaseEntry(
                    title: "Ep. 120 (Final Episode)", published: finaleDate, number: 120, season: nil
                )
            ],
            source: .webtoons
        )

        let summary = ReleaseSummary.summarise(feed)
        guard case let .seasonEnded(season, on: endedOn) = summary else {
            Issue.record("expected .seasonEnded, got \(summary)")
            return
        }
        #expect(season == nil)
        #expect(endedOn == finaleDate)
    }

    // MARK: - R11: Continuations reads the detail cache before firing a request

    private final class SpyContinuationsRepository: SeriesRepositoryProtocol, @unchecked Sendable {
        var extrasByID: [Int: SeriesExtras] = [:]
        private let lock = NSLock()
        private var relationshipsCalls = 0

        var relationshipsCallCount: Int {
            lock.lock(); defer { lock.unlock() }
            return relationshipsCalls
        }

        func cachedExtras(for seriesId: Int) async -> SeriesExtras? { extrasByID[seriesId] }
        func cachedExtrasLinks(for ids: [Int]) async -> [Int: [SeriesLink]] { [:] }
        func cachedExtrasVolumes(for ids: [Int]) async -> [Int: [SeriesWork.Volume]] { [:] }
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
        func relationships(for seriesId: Int) async -> [SeriesRelationship]? {
            lock.withLock { relationshipsCalls += 1 }
            return []
        }
        func updateContentRatings(_ ratings: [String]) async {}
        func updateFormats(_ formats: [String]) async {}
        func updateLibraryExclusion(userID: String?) async {}
        func updateBlockedTags(_ ids: [Int]) async {}
        func cachedSeriesCount() async -> Int { 0 }
        func count(_ query: SearchQuery) async -> Int? { nil }
    }

    private func finishedEntry(seriesId: Int, sequelID: Int, finishDate: Date) -> LibraryEntry {
        LibraryEntry(
            id: seriesId, seriesId: seriesId, state: .completed, progressChapter: nil,
            progressVolume: nil, rating: nil, note: nil, startDate: nil, finishDate: finishDate,
            numberOfRereads: nil, priority: nil, isPrivate: nil, readLink: nil,
            series: SeriesFactory.make(id: seriesId, title: "Finished \(seriesId)")
        )
    }

    /// Expected to fail before the fix with `relationshipsCallCount == 1`:
    /// `ContinuationsModel.load` called `repository.relationships(for:)`
    /// directly for every finished series, ignoring the same six-hour detail
    /// cache the series page already fills via `cachedExtras(for:)`.
    @MainActor
    @Test("A cached relationships answer is read before any request is sent")
    func continuationsReadsDetailCacheFirst() async {
        let repository = SpyContinuationsRepository()
        let sequel = SeriesFactory.make(id: 200, title: "Sequel")
        repository.extrasByID[100] = SeriesExtras(
            relationships: [SeriesRelationship(id: "r1", relationType: "sequel", note: nil, series: sequel)]
        )
        let entries = [finishedEntry(seriesId: 100, sequelID: 200, finishDate: Date())]

        let model = ContinuationsModel(repository: repository)
        await model.load(entries: entries)

        #expect(model.items.map(\.series.id) == [200])
        #expect(repository.relationshipsCallCount == 0, "a cache hit must not fall through to the network")
    }

    // MARK: - R12: cachedFeed only answers for a Webtoons-shaped link

    /// Expected to fail before the fix: `cachedFeed`'s guard was
    /// `links.contains { $0.safeURL != nil }` — any link with a URL, not
    /// only a Webtoons one — so a series whose Webtoons cache file still
    /// existed (written on an earlier open when it did carry a Webtoons
    /// link) would answer from a link list that no longer names Webtoons at
    /// all, e.g. after the series' own links changed.
    @Test("cachedFeed answers nil for a link list with no Webtoons-shaped link")
    func cachedFeedIgnoresNonWebtoonsLinks() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("webtoons-r12-\(UUID().uuidString)", isDirectory: true)
        let webtoonsLink = SeriesLink(
            id: "1", url: URL(string: "https://www.webtoons.com/en/fantasy/tower-of-god/list?title_no=95"),
            name: "webtoons", nameDisplay: nil, type: "webplatform", language: "en"
        )
        let otherLink = SeriesLink(
            id: "2", url: URL(string: "https://en.wikipedia.org/wiki/Tower_of_God"),
            name: "wikipedia", nameDisplay: nil, type: nil, language: nil
        )
        let rss = Data(#"""
        <?xml version="1.0"?>
        <rss version="2.0"><channel><title>Tower of God</title>
        <item><title>Episode 235</title><pubDate>Thu, 11 Sep 2026 15:00:00 GMT</pubDate></item>
        </channel></rss>
        """#.utf8)
        URLProtocolStub.setHandler { _ in .respond(.init(body: rss)) }
        defer { URLProtocolStub.reset() }
        let client = WebtoonsFeedClient(
            session: URLProtocolStub.makeSession(), clock: TestClock(), cacheDirectory: directory
        )
        let series = SeriesFactory.make(id: 95, title: "Tower of God")

        // Populates the on-disk v4-95 cache via the legitimate Webtoons link.
        _ = await client.feed(for: series, links: [webtoonsLink])

        let cached = await client.cachedFeed(for: series, links: [otherLink])
        #expect(cached == nil, "a link list with no Webtoons-shaped link must not answer from a stale cache")
    }

    // MARK: - R21: import throttling stays under the general limit and says where it stopped

    private final class ImportStubLibrary: LibraryProviding, @unchecked Sendable {
        private let lock = NSLock()
        private var addCount = 0
        var rateLimitAfter: Int

        init(rateLimitAfter: Int) { self.rateLimitAfter = rateLimitAfter }

        var addCalls: Int {
            lock.lock(); defer { lock.unlock() }
            return addCount
        }

        func recommendationStatus() async throws(APIError) -> RecommendationStatus {
            throw APIError.offline
        }
        func recommendations(
            limit: Int, page: Int, excluding: [Int]
        ) async -> PersonalRecommendations { PersonalRecommendations() }
        func library(page: Int, limit: Int) async -> [LibraryEntry] { [] }
        func hiddenTagIDs() async -> Set<Int>? { nil }
        func topGenres() async -> [TopGenre]? { nil }
        func remove(seriesId: Int) async throws(APIError) {}
        func update(seriesId: Int, change: LibraryChange) async throws(APIError) {}

        func add(seriesId: Int, state: LibraryEntry.State) async throws(APIError) -> Bool {
            let count = lock.withLock { addCount += 1; return addCount }
            if count > rateLimitAfter { throw .rateLimited(until: nil, party: .mangaBaka) }
            return true
        }
    }

    private func importedRow(seriesId: Int) -> ImportedEntry {
        ImportedEntry(
            seriesId: seriesId, malId: nil, title: nil, state: .planToRead,
            progressChapter: nil, progressVolume: nil, rating: nil, note: nil, isPrivate: nil
        )
    }

    /// Expected to fail before the fix on both counts: every row past the
    /// rate limit was recorded as `report.failures` one at a time (939 rows
    /// would have meant 939 seconds of hammering a window that was already
    /// full), and `ImportReport` had no field naming where a retry should
    /// resume from at all.
    @MainActor
    @Test("Hitting a real rate limit stops the import and records where to resume")
    func rateLimitStopsAndRecordsResumePoint() async {
        let library = ImportStubLibrary(rateLimitAfter: 2)
        let entries = (1...5).map { importedRow(seriesId: $0) }

        let report = await LibraryImport.apply(entries, to: library, existing: [])

        #expect(report.added == 2)
        #expect(report.failures == 0, "a rate limit is not counted the same as an ordinary failure")
        #expect(report.stoppedAt == 2, "should stop at the third row (index 2), the first refused")
        #expect(library.addCalls == 3, "the loop must not keep sending into a full window")
    }
}
