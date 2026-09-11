import Foundation
import Testing
@testable import MangaBaka

/// The schedule service against a library and a cache: what it reports when
/// either cannot be read, and whether a build survives the reader leaving.
@Suite("Schedule service", .serialized)
@MainActor
struct ScheduleServiceTests {
    @Test("The service reports a failed library walk instead of an empty scope")
    func serviceReportsFailure() async throws {
        let service = ReleaseScheduleService(library: OfflineLibrary(), database: try AppDatabase.inMemory())
        let snapshot = await service.snapshot()
        #expect(snapshot.libraryFailure == .offline)
        #expect(snapshot.inScope == 0)
    }

    /// A cached estimate that no longer decodes — the Cadence shape changed,
    /// the row was written by an older build — used to read as a settled
    /// "too few dated releases" and was never asked about again.
    @Test("An unreadable cached estimate is retried, not shown as settled")
    func unreadableCacheIsPending() async throws {
        let database = try AppDatabase.inMemory()
        let entry = LibraryEntry(
            id: 1, seriesId: 1, state: .reading, progressChapter: 3,
            progressVolume: nil, rating: nil, note: nil, startDate: nil,
            finishDate: nil, numberOfRereads: nil, priority: nil, isPrivate: nil,
            readLink: nil,
            series: SeriesFactory.make(
                id: 1, title: "S1", status: "releasing",
                source: [
                    "manga_updates": Series.TrackerEntry(id: "abc123", rating: nil, ratingNormalized: nil)
                ]
            )
        )
        try await database.writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO cadenceEntry (seriesId, payload, fetchedAt, failure) VALUES (?, ?, ?, NULL)
                """,
                arguments: [1, Data("not json".utf8), Date()]
            )
        }
        let service = ReleaseScheduleService(library: OneEntryLibrary(entry: entry), database: database)
        let snapshot = await service.snapshot()

        #expect(snapshot.pending == 1, "Unreadable is 'still to do', not an answer")
        #expect(snapshot.undated.isEmpty)
    }

    /// Leaving the screen cancelled the poll and nothing restarted it: come
    /// back to a build still running and the "Reading 12 of 55" card sat
    /// frozen under copy promising it resumes.
    @Test("Coming back to a running build follows it again")
    func returningResumesFollowing() async throws {
        URLProtocolStub.setHandler { _ in .respond(.init(body: Data(#"{"results":[]}"#.utf8))) }
        defer { URLProtocolStub.reset() }
        let entries = (1...2).map { id in
            LibraryEntry(
                id: id, seriesId: id, state: .reading, progressChapter: 3,
                progressVolume: nil, rating: nil, note: nil, startDate: nil,
                finishDate: nil, numberOfRereads: nil, priority: nil, isPrivate: nil,
                readLink: nil,
                series: SeriesFactory.make(
                    id: id, title: "S\(id)", status: "releasing",
                    source: [
                        "manga_updates": Series.TrackerEntry(
                            id: "abc\(id)", rating: nil, ratingNormalized: nil
                        )
                    ]
                )
            )
        }
        // Two series, three seconds apart by the MangaUpdates spacing rule: a
        // build that is still running when the reader comes back.
        let service = ReleaseScheduleService(
            library: OneEntryLibrary(entries: entries),
            mangaUpdates: MangaUpdatesClient(
                baseURL: URL(string: "https://mu.example.invalid/v1").unsafeTestURL,
                session: URLProtocolStub.makeSession()
            ),
            database: try AppDatabase.inMemory()
        )
        let model = ScheduleModel(service: service)
        await model.measure()
        try await Task.sleep(for: .milliseconds(200))
        #expect(model.isFollowingBuild)

        model.stop()
        #expect(!model.isFollowingBuild)

        await model.load()
        #expect(model.isMeasuring, "The build is still running while the reader was away")
        #expect(model.isFollowingBuild, "and the screen must follow it again")
        model.stop()
    }

    private final class OneEntryLibrary: LibraryProviding, @unchecked Sendable {
        let entries: [LibraryEntry]
        init(entry: LibraryEntry) { entries = [entry] }
        init(entries: [LibraryEntry]) { self.entries = entries }
        func recommendationStatus() async -> RecommendationStatus? { nil }
        func recommendations(
            limit: Int, page: Int, excluding: [Int]
        ) async -> [PersonalRecommendation] { [] }
        func library(page: Int, limit: Int) async -> [LibraryEntry] { page == 1 ? entries : [] }
        func hiddenTagIDs() async -> Set<Int>? { nil }
        func topGenres() async -> [TopGenre]? { nil }
        func update(seriesId: Int, change: LibraryChange) async throws(APIError) {}
        func add(seriesId: Int, state: LibraryEntry.State) async throws(APIError) -> Bool { true }
        func remove(seriesId: Int) async throws(APIError) {}
    }

    private final class OfflineLibrary: LibraryProviding, @unchecked Sendable {
        func recommendationStatus() async -> RecommendationStatus? { nil }
        func recommendations(
            limit: Int, page: Int, excluding: [Int]
        ) async -> [PersonalRecommendation] { [] }
        func library(page: Int, limit: Int) async -> [LibraryEntry] { [] }
        func libraryPage(page: Int, limit: Int) async throws(APIError) -> [LibraryEntry] { throw .offline }
        func hiddenTagIDs() async -> Set<Int>? { nil }
        func topGenres() async -> [TopGenre]? { nil }
        func update(seriesId: Int, change: LibraryChange) async throws(APIError) {}
        func add(seriesId: Int, state: LibraryEntry.State) async throws(APIError) -> Bool { true }
        func remove(seriesId: Int) async throws(APIError) {}
    }
}
