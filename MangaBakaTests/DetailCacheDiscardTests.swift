import Foundation
import GRDB
import Testing
@testable import MangaBaka

/// The detail cache holds rating- and tag-filtered content — a series page's
/// tag rows, its editions, its images — so a filter change has to throw it
/// away. Until 2026-09-14 `apply` spent `try?` on that discard: a rating
/// change whose detail discard failed kept showing, for six hours, the tags
/// the rating was set to hide, with nothing logged. That is the exact failure
/// `SeriesRepository+Cache.swift:45-50`'s doc comment was written for, and the
/// feeds half of the same function had already grown the `-> Bool` shape for
/// it (gap 74). Review item 32.
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

    /// The behaviour the whole thing is for. Expected to fail before item 32's
    /// fix only in the second test; this one pins the working path so the
    /// second cannot pass by the discard never running at all.
    @Test("A rating change throws away the cached series page")
    func ratingChangeDiscardsDetail() async throws {
        let database = try AppDatabase.inMemory()
        let repository = makeRepository(database: database)

        var extras = SeriesExtras()
        extras.tags = ["Dungeon", "Level System"]
        try await repository.writeDetailCache(extras, for: 42)
        #expect(try await repository.readDetailCache(42) != nil, "control: it was cached")

        await repository.updateContentRatings(["safe"])

        #expect(try await repository.readDetailCache(42) == nil)
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

        try await database.writer.write { db in
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
