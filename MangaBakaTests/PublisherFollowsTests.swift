import Testing
import Foundation
@testable import MangaBaka

/// Following a publisher, studio, or creator: the persisted list, and the
/// daily check that notices when they have put something new out.
@Suite("Publisher follows")
@MainActor
struct PublisherFollowsTests {
    private func store(now: @escaping () -> Date = Date.init) throws -> PublisherFollows {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("publisher-follows-tests-\(UUID().uuidString)")
        return PublisherFollows(directory: directory, now: now)
    }

    @Test("Following, then unfollowing, round-trips through disk")
    func followUnfollowRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("publisher-follows-tests-\(UUID().uuidString)")

        let first = PublisherFollows(directory: directory)
        #expect(!first.isFollowing("REDICE STUDIO", kind: .publisher))
        first.follow("REDICE STUDIO", kind: .publisher)
        #expect(first.isFollowing("REDICE STUDIO", kind: .publisher))

        // A fresh instance over the same file sees the same follow — this is
        // what "persisted" has to mean, not just held in memory.
        let reloaded = PublisherFollows(directory: directory)
        #expect(reloaded.isFollowing("REDICE STUDIO", kind: .publisher))

        reloaded.unfollow("REDICE STUDIO", kind: .publisher)
        #expect(!reloaded.isFollowing("REDICE STUDIO", kind: .publisher))

        let final = PublisherFollows(directory: directory)
        #expect(!final.isFollowing("REDICE STUDIO", kind: .publisher))
    }

    @Test("A publisher and an author of the same name are followed separately")
    func kindsAreDistinct() throws {
        let follows = try store()
        follows.follow("Manta", kind: .publisher)
        #expect(follows.isFollowing("Manta", kind: .publisher))
        #expect(!follows.isFollowing("Manta", kind: .author))
    }

    @Test("The first check only records the top series, without notifying")
    func firstCheckJustRecords() async throws {
        let follows = try store()
        follows.follow("REDICE STUDIO", kind: .publisher)
        let repository = StubSearchRepository(results: [SeriesFactory.make(id: 100)])

        var notified = 0
        let updates = await follows.check(using: repository) { _, _ in notified += 1 }

        #expect(updates.isEmpty)
        #expect(notified == 0)
        #expect(follows.follows.first?.lastSeenSeriesID == 100)
        #expect(repository.callCount == 1)
    }

    @Test("A changed top series notifies once and updates what is remembered")
    func changedTopSeriesNotifies() async throws {
        let clock = TestClock()
        let follows = try store(now: { clock.now })
        follows.follow("REDICE STUDIO", kind: .publisher)
        let repository = StubSearchRepository(results: [SeriesFactory.make(id: 100, title: "Old")])
        await follows.check(using: repository)

        clock.advance(by: 2 * 86_400)
        repository.results = [SeriesFactory.make(id: 200, title: "New Arrival")]

        var notifiedTitles: [String] = []
        let updates = await follows.check(using: repository) { _, title in notifiedTitles.append(title) }

        #expect(updates.map(\.seriesTitle) == ["New Arrival"])
        #expect(notifiedTitles == ["New Arrival"])
        #expect(follows.follows.first?.lastSeenSeriesID == 200)
    }

    @Test("A second check within a day does not query the API again")
    func dailyThrottleHolds() async throws {
        let clock = TestClock()
        let follows = try store(now: { clock.now })
        follows.follow("REDICE STUDIO", kind: .publisher)
        let repository = StubSearchRepository(results: [SeriesFactory.make(id: 100)])

        await follows.check(using: repository)
        #expect(repository.callCount == 1)

        clock.advance(by: 3_600)
        await follows.check(using: repository)
        #expect(repository.callCount == 1, "still within the same day")

        clock.advance(by: PublisherFollows.checkInterval)
        await follows.check(using: repository)
        #expect(repository.callCount == 2, "a full day has now passed")
    }

    /// 2026-09-13: never retry into a 429. `check` used to mark a follow
    /// `lastCheckedAt` and move on regardless of what `search` answered, so a
    /// rate limit earned by the first due follow was asked again by every
    /// other one, one at a time, into the same refusal.
    ///
    /// Expected to fail before the fix: `repository.callCount` would reach
    /// 2 (both follows asked), and Alpha's `lastCheckedAt` would be set even
    /// though it was never actually answered.
    @Test("A rate-limited check stops the run rather than asking every other follow")
    func rateLimitStopsTheRun() async throws {
        let follows = try store()
        follows.follow("Alpha", kind: .publisher)
        follows.follow("Beta", kind: .publisher)
        let repository = RateLimitedFirstRepository()

        let updates = await follows.check(using: repository)

        #expect(updates.isEmpty)
        #expect(repository.callCount == 1, "The second follow must not be asked into the same refusal")
        // Not marked checked — it genuinely was not — so the next run, not
        // tomorrow's throttle lapsing, retries it.
        #expect(follows.follows.first { $0.name == "Alpha" }?.lastCheckedAt == nil)
    }

    @Test("A publisher and staff use their own search key")
    func searchesByTheRightKey() async throws {
        let follows = try store()
        follows.follow("Yoshihiro Togashi", kind: .author)
        let repository = StubSearchRepository(results: [SeriesFactory.make(id: 1)])

        await follows.check(using: repository)

        #expect(repository.lastQuery?.staff == "Yoshihiro Togashi")
        #expect(repository.lastQuery?.publisher == nil)
        #expect(repository.lastQuery?.sort == "latest")
        #expect(repository.lastQuery?.limit == 1)
    }
}

/// Counts calls and reports the last query, so the daily throttle and the
/// search key can both be checked against a real number rather than an
/// assumption about what ran.
private final class StubSearchRepository: StubRepositoryBase, @unchecked Sendable {
    var results: [Series]
    private(set) var callCount = 0
    private(set) var lastQuery: SearchQuery?

    init(results: [Series]) {
        self.results = results
    }

    override func search(_ query: SearchQuery) async -> FeedResult {
        callCount += 1
        lastQuery = query
        return FeedResult(series: results, origin: .network)
    }
}

/// Refuses the first search with a rate limit, answers any later one. The
/// follows check must stop at the refusal rather than walk into it again.
private final class RateLimitedFirstRepository: StubRepositoryBase, @unchecked Sendable {
    private(set) var callCount = 0

    // The priority overload is a protocol-extension forward onto this one,
    // so this is the method to override.
    override func search(_ query: SearchQuery) async -> FeedResult {
        callCount += 1
        if callCount == 1 {
            return FeedResult(
                series: [],
                origin: .staleAfter(.rateLimited(retryAfter: 30, party: .mangaBakaSearch))
            )
        }
        return FeedResult(series: [SeriesFactory.make(id: callCount)], origin: .network)
    }
}
