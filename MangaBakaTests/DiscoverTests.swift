import Foundation
import Testing
@testable import MangaBaka

/// A repository stub that answers each `FeedKind` from a fixed table, so a
/// test can make exactly one row fail while the rest succeed — the situation
/// gap 13 got wrong: one failing, empty row painted the other three,
/// perfectly fine rows as "showing stale" too.
private final class TableRepository: StubRepositoryBase, @unchecked Sendable {
    private let table: [FeedKind: FeedResult]

    init(_ table: [FeedKind: FeedResult]) {
        self.table = table
    }

    override func feed(_ feed: FeedKind, forceRefresh: Bool) async -> FeedResult {
        table[feed] ?? FeedResult(series: [], origin: .network)
    }
}

/// A repository whose `feedPage` always answers the same way, for driving
/// `DiscoverModel.loadMore` in isolation.
private final class PagingRepository: StubRepositoryBase, @unchecked Sendable {
    private let initial: [FeedKind: FeedResult]
    private let page: FeedResult

    init(initial: [FeedKind: FeedResult], page: FeedResult) {
        self.initial = initial
        self.page = page
    }

    override func feed(_ feed: FeedKind, forceRefresh: Bool) async -> FeedResult {
        initial[feed] ?? FeedResult(series: [], origin: .network)
    }

    override func feedPage(_ feed: FeedKind, page: Int) async -> FeedResult { self.page }
}

/// Two waves of `feed` calls, the first held open on a continuation until the
/// test releases it — so a second, newer `load()` can be proven to finish
/// and win before the first, older one is ever allowed to complete
/// (gap 47's interleaving).
private actor SequencedRepository: SeriesRepositoryProtocol {
    private var callsSoFar = 0
    private var pendingContinuations: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private let firstWave: [Series]
    private let secondWave: [Series]

    init(firstWave: [Series], secondWave: [Series]) {
        self.firstWave = firstWave
        self.secondWave = secondWave
    }

    func releaseFirstWave() {
        released = true
        pendingContinuations.forEach { $0.resume() }
        pendingContinuations = []
    }

    func feed(_ feed: FeedKind, forceRefresh: Bool) async -> FeedResult {
        callsSoFar += 1
        // The model's four rows mean the first `load()` issues exactly four
        // concurrent calls before a second `load()` can issue any — held
        // here until the test calls `releaseFirstWave()`.
        if callsSoFar <= 4 {
            if !released {
                await withCheckedContinuation { pendingContinuations.append($0) }
            }
            return FeedResult(series: firstWave, origin: .network)
        }
        return FeedResult(series: secondWave, origin: .network)
    }

    func search(_ query: SearchQuery) async -> FeedResult { FeedResult(series: [], origin: .network) }

    func feedPage(_ feed: FeedKind, page: Int) async -> FeedResult {
        FeedResult(series: [], origin: .network)
    }
    func mix(seeds: [Int], filters: SearchQuery, excludedTags: [Int]) async -> MixResult { .empty }
    func extras(for seriesId: Int) async -> SeriesExtras { SeriesExtras() }
    func images(for seriesId: Int) async -> [SeriesImage]? { [] }
    func relationships(for seriesId: Int) async -> [SeriesRelationship]? { nil }
    func updateContentRatings(_ ratings: [String]) async {}
    func updateFormats(_ formats: [String]) async {}
    func updateLibraryExclusion(userID: String?) async {}
    func updateBlockedTags(_ ids: [Int]) async {}
    func cachedSeriesCount() async -> Int { 0 }
    func count(_ query: SearchQuery) async -> Int? { nil }
}

/// Gaps 13, 14, 15, 46, 47 (FAILURES-SUMMARY.md, Batch 4).
@Suite("Discover")
@MainActor
struct DiscoverTests {
    private func series(_ id: Int) -> Series { SeriesFactory.make(id: id) }

    /// Expected to fail before the fix with: `isShowingStale == true` — the
    /// old property was `failure != nil && rows.contains { !$0.series.isEmpty
    /// }`, and rows 1-3's content alone satisfied that once *any* row (row 0)
    /// had set the screen-wide `failure`. `rows[0].failure` did not exist at
    /// all: `Row` carried no per-row error, only the screen-wide one.
    @Test("One empty, failed row does not make three fine rows read as stale")
    func isolatedRowFailureDoesNotLeak() async {
        let repository = TableRepository([
            .rising: FeedResult(series: [], origin: .staleAfter(.offline)),
            .hiddenGems: FeedResult(series: [series(1)], origin: .network),
            .trending: FeedResult(series: [series(2)], origin: .network),
            .newReleases: FeedResult(series: [series(3)], origin: .network)
        ])
        let model = DiscoverModel(repository: repository)
        await model.load()

        #expect(model.isShowingStale == false)
        #expect(model.rows[0].failure == .offline)
        #expect(model.rows[0].series.isEmpty)
    }

    /// Expected to fail before the fix with: `emptyState` (the view) handing
    /// `FailureState` an error of `.offline` even though `model.failure` was
    /// `nil` — proven here at the model level, since `?? .offline` lived only
    /// in the view: a genuinely empty, all-succeeded screen must not carry an
    /// invented failure for the view to fall back on.
    @Test("All rows empty but successful leaves no failure to report")
    func allEmptySuccessHasNoFailure() async {
        let repository = TableRepository([
            .rising: FeedResult(series: [], origin: .network),
            .hiddenGems: FeedResult(series: [], origin: .network),
            .trending: FeedResult(series: [], origin: .network),
            .newReleases: FeedResult(series: [], origin: .network)
        ])
        let model = DiscoverModel(repository: repository)
        await model.load()

        #expect(model.isCompletelyEmpty == true)
        #expect(model.failure == nil)
    }

    /// `staleFailure`/`staleDetail` should only speak for a row that is
    /// actually showing stale content, and should carry the real error
    /// rather than a generic "refresh failed" (gap 46).
    @Test("The stale bar names the real cause, not a generic one")
    func staleDetailNamesTheCause() async {
        let until = Date().addingTimeInterval(30)
        let repository = TableRepository([
            .rising: FeedResult(series: [series(1)], origin: .staleAfter(.rateLimited(until: until))),
            .hiddenGems: FeedResult(series: [], origin: .network),
            .trending: FeedResult(series: [], origin: .network),
            .newReleases: FeedResult(series: [], origin: .network)
        ])
        let model = DiscoverModel(repository: repository)
        await model.load()

        #expect(model.isShowingStale == true)
        #expect(model.staleFailure == .rateLimited(until: until))
        #expect(model.staleDetail?.contains("Too many requests") == true)
    }

    /// Expected to fail before the fix with: `rows[index].hasReachedEnd ==
    /// true` — `loadMore` used to set `hasReachedEnd = !result.hasMore`
    /// unconditionally, and a page-2 failure looked exactly like the end of
    /// the feed. `pageFailure` did not exist on `Row` at all.
    @Test("A failed later page is not read as the end of the row")
    func pageFailureDoesNotEndTheRow() async {
        let repository = PagingRepository(
            initial: [.trending: FeedResult(series: [series(1)], origin: .network)],
            page: FeedResult(series: [], origin: .staleAfter(.offline), hasMore: true)
        )
        let model = DiscoverModel(repository: repository)
        await model.load()

        let trendingID = model.rows[2].id
        await model.loadMore(trendingID)

        let row = model.rows.first { $0.id == trendingID }
        #expect(row?.hasReachedEnd == false)
        #expect(row?.pageFailure == .offline)
    }

    /// Expected to fail before the fix with: the model's rows ending up a mix
    /// of the first and second wave's series, or the first wave's overwriting
    /// the second's outright — there was no generation counter at all, so
    /// whichever `loadRows` call's four concurrent tasks happened to finish
    /// last simply won, regardless of which `load()` call was newer.
    @Test("A newer load wins over an older one still in flight")
    func newerLoadWinsOverOlder() async {
        let repository = SequencedRepository(
            firstWave: [series(1)],
            secondWave: [series(2)]
        )
        let model = DiscoverModel(repository: repository)

        let firstLoad = Task { await model.load() }
        // Give the first load's four concurrent `feed` calls a chance to
        // register and suspend on the continuation before the second starts.
        try? await Task.sleep(nanoseconds: 20_000_000)

        await model.load()
        await repository.releaseFirstWave()
        await firstLoad.value

        #expect(model.rows.allSatisfy { $0.series.map(\.id) == [2] })
    }
}

/// Gap 48 (FAILURES-SUMMARY.md): a pulse fetch that failed at launch used to
/// be remembered as failed forever, because `hasLoaded` was set unconditionally
/// on the first call regardless of outcome.
@Suite("Community pulse retry", .serialized)
@MainActor
struct CommunityPulseRetryTests {
    private let baseURL = URL(string: "https://api.example.invalid").unsafeTestURL

    private func makeService() -> CommunityPulseService {
        CommunityPulseService(client: APIClient(
            baseURL: baseURL,
            session: URLProtocolStub.makeSession(),
            tokenProvider: UnauthenticatedTokenProvider()
        ))
    }

    /// Expected to fail before the fix with: a second `load()` making zero
    /// further requests, because `hasLoaded` was already `true` after the
    /// first, failed attempt — `pulse` stays `nil`, so the grace note never
    /// gets a second chance until the process restarts.
    @Test("A failed pulse retries on the next explicit load")
    func retriesAfterFailure() async {
        URLProtocolStub.setHandler { _ in .fail(URLError(.notConnectedToInternet)) }
        let service = makeService()
        await service.load()
        #expect(service.didFail == true)
        #expect(service.pulse == nil)

        URLProtocolStub.setHandler { _ in
            .respond(.init(body: Data("""
            {"active_series_count": 1, "active_series_count_prev_week": 1,
             "registered_user_count": 1, "registered_user_count_prev_week": 1,
             "chapters_read_count": 1, "chapters_read_count_prev_week": 1}
            """.utf8)))
        }
        defer { URLProtocolStub.reset() }
        await service.load()

        #expect(service.didFail == false)
        #expect(service.pulse != nil)
    }

    @Test("A successful load is never retried")
    func successIsNotRetried() async {
        URLProtocolStub.setHandler { _ in
            .respond(.init(body: Data("""
            {"active_series_count": 1, "active_series_count_prev_week": 1,
             "registered_user_count": 1, "registered_user_count_prev_week": 1,
             "chapters_read_count": 1, "chapters_read_count_prev_week": 1}
            """.utf8)))
        }
        defer { URLProtocolStub.reset() }
        let service = makeService()
        await service.load()
        await service.load()

        #expect(URLProtocolStub.requests.count == 1)
    }
}

/// Gap 49 (FAILURES-SUMMARY.md): `isDue` used to mutate `lastSeen` on a fresh
/// install as a side effect of being called from `DiscoverView.body` — a
/// write during SwiftUI view evaluation, which SwiftUI warns about and makes
/// no promise about the timing or count of.
@MainActor
@Suite("What's new, first-run stamp")
struct WhatsNewFirstRunTests {
    /// Expected to fail before the fix with: `lastSeen` no longer `nil` after
    /// this call — `isDue(hasCompletedOnboarding: false)` used to call
    /// `dismiss()` itself, which both mutated state and persisted it to
    /// `UserDefaults`, entirely as a side effect of a query the view calls
    /// from `body`.
    @Test("isDue never writes, even on a fresh install")
    func isDueDoesNotMutate() throws {
        let defaults = try #require(UserDefaults(suiteName: "WhatsNewFirstRunTests.\(UUID())"))
        let state = WhatsNewState(defaults: defaults)

        _ = state.isDue(hasCompletedOnboarding: false)

        #expect(state.lastSeen == nil)
    }

    @Test("The fresh-install stamp only happens through the dedicated call")
    func freshInstallStampIsExplicit() throws {
        let defaults = try #require(UserDefaults(suiteName: "WhatsNewFirstRunTests.\(UUID())"))
        let state = WhatsNewState(defaults: defaults)

        state.markSeenOnFreshInstall(hasCompletedOnboarding: false)

        #expect(state.lastSeen == ReleaseNotes.current.id)
        #expect(state.isDue(hasCompletedOnboarding: true) == false)
    }

    @Test("A returning reader is never silently marked seen")
    func returningReaderIsUnaffected() throws {
        let defaults = try #require(UserDefaults(suiteName: "WhatsNewFirstRunTests.\(UUID())"))
        let state = WhatsNewState(defaults: defaults)

        state.markSeenOnFreshInstall(hasCompletedOnboarding: true)

        #expect(state.lastSeen == nil)
        #expect(state.isDue(hasCompletedOnboarding: true) == true)
    }
}
