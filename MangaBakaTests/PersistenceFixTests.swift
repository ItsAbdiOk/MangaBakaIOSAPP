import Foundation
import Testing
@testable import MangaBaka

/// Perf review, persistence slice, 2026-09-15 (`docs/reviews/perf/persistence.md`).
/// Covers PS2, PS4, PS8 and PS12 — the fixes in this batch with a
/// user-visible behaviour to pin. PS3, PS5, PS9, PS10, PS11, PS13 and D1 are
/// logging, dead-code deletion, a measurement hook or a doc/label fix with
/// nothing new to assert by reading the result; PS1, PS6, PS7 and PS-m2
/// belong to other files in this batch.
@Suite("Persistence perf fixes")
struct PersistenceFixTests {
    private let baseURL = URL(string: "https://api.example.invalid").unsafeTestURL

    private func makeRepository(database: AppDatabase, clock: any Clock) -> SeriesRepository {
        SeriesRepository(
            client: APIClient(
                baseURL: baseURL,
                session: URLProtocolStub.makeSession(),
                tokenProvider: UnauthenticatedTokenProvider()
            ),
            database: database,
            clock: clock
        )
    }

    // MARK: - PS2

    /// Expected to fail before PS2 with both reads non-empty: nothing aged a
    /// per-series feed out, so `series/1/similar` sat in `feedEntry` and
    /// `feedMetadata` forever, growing the tables on every series page ever
    /// opened.
    @Test("A per-series feed older than the retention window is swept; a fresh one is not")
    func perSeriesFeedsAgeOut() async throws {
        let database = try AppDatabase.inMemory()
        let clock = TestClock()
        let repository = makeRepository(database: database, clock: clock)

        try await repository.write([SeriesFactory.make(id: 101)], for: .similar(seriesId: 1))
        // Past `seriesFeedRetention` (7 days). Any later write runs the sweep.
        clock.advance(by: 8 * 24 * 60 * 60)
        try await repository.write([SeriesFactory.make(id: 202)], for: .similar(seriesId: 2))

        let aged = try await repository.readCacheWithDate(.similar(seriesId: 1))
        let fresh = try await repository.readCacheWithDate(.similar(seriesId: 2))
        #expect(aged.series.isEmpty, "an 8-day-old per-series feed should have been swept")
        #expect(fresh.series.map(\.id) == [202], "a feed written moments ago must not be swept")
    }

    // MARK: - PS4

    /// A repository double that counts how it was asked for cached extras,
    /// so the test can tell "one batched read" from "one read per work"
    /// without depending on timing.
    private final class CountingExtrasRepository: SeriesRepositoryProtocol, @unchecked Sendable {
        var extrasByID: [Int: SeriesExtras] = [:]
        private let lock = NSLock()
        private var perSeriesCalls = 0
        private var batchedCalls = 0

        var callCounts: (perSeries: Int, batched: Int) {
            lock.lock(); defer { lock.unlock() }
            return (perSeriesCalls, batchedCalls)
        }

        func cachedExtras(for seriesId: Int) async -> SeriesExtras? {
            lock.withLock { perSeriesCalls += 1 }
            return extrasByID[seriesId]
        }

        func cachedExtrasLinks(for ids: [Int]) async -> [Int: [SeriesLink]] {
            lock.withLock { batchedCalls += 1 }
            var links: [Int: [SeriesLink]] = [:]
            for id in ids {
                if let cached = extrasByID[id] { links[id] = cached.links }
            }
            return links
        }

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

    /// Expected to fail before PS4 with `callCounts.perSeries == works.count,
    /// callCounts.batched == 0` — one actor hop and one full `SeriesExtras`
    /// decode per scheduled work, exactly the 939-hop shape
    /// `cachedExtrasLinks` was already built to avoid for its other caller.
    @Test("feedDueWorks reads cached links with one batched call, not one per work")
    func feedDueWorksUsesBatchedRead() async {
        let repo = CountingExtrasRepository()
        let works = (1...5).map { id -> ScheduledWork in
            repo.extrasByID[id] = SeriesExtras(links: [webtoonsLink()])
            return ScheduledWork(series: SeriesFactory.make(id: id), cadence: nil, reason: nil)
        }
        let feeds = ReleaseFeedService(providers: [])

        _ = await DueThisWeekIntent.feedDueWorks(for: works, feeds: feeds, repository: repo)

        let counts = repo.callCounts
        #expect(counts.batched == 1, "one WHERE seriesId IN (…) read for the whole list")
        #expect(counts.perSeries == 0, "no per-work cachedExtras hop left")
    }

    // MARK: - PS8 / PS12 shared fixtures

    private func entry(id: Int, progressChapter: Double? = 3) -> LibraryEntry {
        LibraryEntry(
            id: id, seriesId: id, state: .reading, progressChapter: progressChapter,
            progressVolume: nil, rating: nil, note: nil, startDate: nil,
            finishDate: nil, numberOfRereads: nil, priority: nil,
            isPrivate: nil, readLink: nil, series: nil
        )
    }

    private final class StubLibrary: LibraryProviding, @unchecked Sendable {
        private let entries: [LibraryEntry]
        private let lock = NSLock()
        private var pageCalls = 0

        init(entries: [LibraryEntry]) { self.entries = entries }

        var calls: Int { lock.lock(); defer { lock.unlock() }; return pageCalls }

        func libraryPage(page: Int, limit: Int) async throws(APIError) -> [LibraryEntry] {
            lock.withLock { pageCalls += 1 }
            let start = (page - 1) * limit
            guard start < entries.count else { return [] }
            return Array(entries[start..<min(start + limit, entries.count)])
        }
        func library(page: Int, limit: Int) async -> [LibraryEntry] {
            (try? await libraryPage(page: page, limit: limit)) ?? []
        }
        func recommendationStatus() async throws(APIError) -> RecommendationStatus {
            throw APIError.offline
        }
        func recommendations(
            limit: Int, page: Int, excluding: [Int]
        ) async -> PersonalRecommendations { PersonalRecommendations() }
        func hiddenTagIDs() async -> Set<Int>? { [] }
        func topGenres() async -> [TopGenre]? { [] }
        func update(seriesId: Int, change: LibraryChange) async throws(APIError) {}
        func add(seriesId: Int, state: LibraryEntry.State) async throws(APIError) -> Bool { true }
        func remove(seriesId: Int) async throws(APIError) {}
    }

    // MARK: - PS8

    /// Fires `onDeinit` the moment nothing else holds it — the test's proof
    /// that a captured closure (and whatever it captured) has actually been
    /// released, not merely gone out of the test's own scope.
    private final class DeinitFlag: @unchecked Sendable {
        private let onDeinit: () -> Void
        init(onDeinit: @escaping () -> Void) { self.onDeinit = onDeinit }
        deinit { onDeinit() }
    }

    private final class FlagBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.withLock { value = true } }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// Expected to fail before PS8 with `flagBox.isSet == false`: only
    /// `finish` (the walk path) cleared `onPage`, so the disk-cache-hit
    /// branch in `load()` left the closure — and whatever it captured —
    /// retained for the life of the actor.
    @Test("A disk-cache hit releases the page observer, same as a finished walk")
    func cacheHitReleasesPageObserver() async throws {
        let database = try AppDatabase.inMemory()
        let clock = TestClock()
        let library = StubLibrary(entries: [entry(id: 1)])

        // Warm the disk cache with a real walk.
        _ = await LibrarySnapshot(library: library, database: database, clock: clock).load()

        // A fresh instance has nothing in memory, so `load()` takes the
        // disk-cache-hit branch rather than the walk.
        let reopened = LibrarySnapshot(library: library, database: database, clock: clock)
        let flagBox = FlagBox()
        await reopened.observePages { [flag = DeinitFlag(onDeinit: { flagBox.set() })] _ in _ = flag }

        _ = await reopened.load()

        #expect(flagBox.isSet, "the observer closure must not outlive the disk-cache read that used it")
    }

    // MARK: - PS12

    /// Expected to fail before PS12 with `library.calls == 1`: the bad row
    /// used to be dropped alone (`continue`), the other row still wrote and
    /// committed, and `readCache`'s row-count-vs-decoded-count guard passed
    /// because the table was short by exactly the row that never made it in
    /// — a permanently, silently shrunk library that reads as complete.
    @Test("An entry that fails to encode aborts the whole cache write, not just that row")
    func encodeFailureAbortsWholeWrite() async throws {
        let database = try AppDatabase.inMemory()
        let clock = TestClock()
        // `.nan` is not representable in JSON and makes `JSONEncoder.encode`
        // throw `EncodingError.invalidValue` — the realistic case P12 names.
        let library = StubLibrary(entries: [entry(id: 1), entry(id: 2, progressChapter: .nan)])

        _ = await LibrarySnapshot(library: library, database: database, clock: clock).load()

        // A fresh instance forces a disk read. If the write above committed
        // a short table (the pre-PS12 bug), this reads it back as a
        // complete one-row library and never asks the network again. If the
        // write aborted instead (PS12), nothing is on disk and this re-walks.
        let reopened = LibrarySnapshot(library: library, database: database, clock: clock)
        _ = await reopened.load()

        #expect(library.calls > 1, "an aborted write must leave nothing to read back, forcing a re-walk")
    }
}
