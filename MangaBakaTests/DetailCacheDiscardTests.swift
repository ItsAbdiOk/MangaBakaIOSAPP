import Foundation
import GRDB
import Testing
@testable import MangaBaka

/// The detail cache holds the *unfiltered* series record — the page applies
/// the reader's rating to `richTags` at display time — so a rating or
/// blocked-tag change leaves it standing (review perf PS1, 2026-09-15; the
/// premise this suite carried until then, "the cache holds rating-filtered
/// tags, editions and images", was wrong on all three counts). The discard
/// path itself — `apply` reporting a failed discard rather than swallowing it
/// (item 32, gap 74) — is still pinned below through `apply` directly.
@Suite("Detail cache discard", .serialized)
struct DetailCacheDiscardTests {
    private let baseURL = URL(string: "https://api.example.invalid").unsafeTestURL

    private func makeRepository(database: AppDatabase) -> SeriesRepository {
        SeriesRepository(
            client: APIClient(
                baseURL: baseURL,
                session: URLProtocolStub.makeSession(),
                tokenProvider: UnauthenticatedTokenProvider()
            ),
            database: database,
            clock: TestClock()
        )
    }

    /// Fails on the pre-2026-09-15 code with `readDetailCache(42) == nil`:
    /// the toggle used to delete every cached page (up to 200, ~40 MB) and
    /// make each re-open pay eight requests again.
    @Test("A rating change and a blocked-tag change leave the cached series page standing")
    func ratingAndBlockedTagChangesKeepDetail() async throws {
        let database = try AppDatabase.inMemory()
        let repository = makeRepository(database: database)

        var extras = SeriesExtras()
        extras.tags = ["Dungeon", "Level System"]
        try await repository.writeDetailCache(extras, for: 42)
        #expect(try await repository.readDetailCache(42) != nil, "control: it was cached")

        await repository.updateContentRatings(["safe"])
        #expect(try await repository.readDetailCache(42) != nil, "the page filters tags at display time")
        await repository.updateBlockedTags([7])
        #expect(try await repository.readDetailCache(42) != nil, "nothing on the page reads blocked tags")
    }

    /// The control for the one above: a change that invalidates only feeds
    /// must leave the series page alone. Without it, "the detail cache is
    /// empty" would also pass for a repository that discards everything on
    /// every setter, which is what the `applied` guard was covering for.
    @Test("A format change leaves the cached series page standing")
    func formatChangeLeavesDetailIntact() async throws {
        let database = try AppDatabase.inMemory()
        let repository = makeRepository(database: database)

        var extras = SeriesExtras()
        extras.tags = ["Dungeon"]
        try await repository.writeDetailCache(extras, for: 42)

        await repository.updateFormats(["manga"])

        #expect(try await repository.readDetailCache(42) != nil)
    }

    /// The failure half. `seriesDetail` is dropped out from under the
    /// repository, so `DELETE FROM seriesDetail` throws the way a full disk or
    /// a locked file makes it throw — the only difference being that this one
    /// is reproducible. `apply` must report that, not swallow it.
    ///
    /// **Expected to fail against the pre-item-32 code with:** `apply` was
    /// `func apply(_:changed:invalidating:)` returning `Void` and calling
    /// `try? discardDetailCache()`, so `#expect(discarded == false)` would not
    /// have compiled at all — and the `try?` is precisely why. Against a
    /// version that returns `Bool` but keeps `try?` on the detail half, it
    /// fails with "Expectation failed: discarded == false" (it returns true).
    @Test("A discard that cannot run is reported, not swallowed")
    func failedDiscardIsReported() async throws {
        let database = try AppDatabase.inMemory()
        let repository = makeRepository(database: database)

        var extras = SeriesExtras()
        extras.tags = ["Dungeon"]
        try await repository.writeDetailCache(extras, for: 42)
        #expect(try await repository.readDetailCache(42) != nil, "control: it was cached")

        try await database.cacheWriter.write { db in
            try db.execute(sql: "DROP TABLE seriesDetail")
        }

        let discarded = await repository.apply(
            "ratings", changed: true, invalidating: .detail
        )
        #expect(discarded == false, "a discard that threw must not report success")
    }

    /// And the same function must still say true when nothing was wrong, or
    /// the test above passes for a repository that always reports failure.
    @Test("A discard that ran reports success")
    func successfulDiscardIsReported() async throws {
        let database = try AppDatabase.inMemory()
        let repository = makeRepository(database: database)

        let discarded = await repository.apply(
            "ratings", changed: true, invalidating: .detail
        )
        #expect(discarded == true)
    }
}
