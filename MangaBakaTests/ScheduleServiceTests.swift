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
        let service = ReleaseScheduleService(
            library: LibrarySnapshot(library: OfflineLibrary()), database: try AppDatabase.inMemory()
        )
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
        let service = ReleaseScheduleService(
            library: LibrarySnapshot(library: OneEntryLibrary(entry: entry)), database: database
        )
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
            library: LibrarySnapshot(library: OneEntryLibrary(entries: entries)),
            mangaUpdates: MangaUpdatesClient(
                baseURL: URL(string: "https://mu.example.invalid/v1").unsafeTestURL,
                session: URLProtocolStub.makeSession()
            ),
            database: try AppDatabase.inMemory()
        )
        let model = ScheduleModel(service: service)
        // No wait needed: measure() awaits service.build() to completion and
        // then calls followBuild() synchronously, so isFollowingBuild is
        // already set the moment measure() returns.
        await model.measure()
        #expect(model.isFollowingBuild)

        model.stop()
        #expect(!model.isFollowingBuild)

        await model.load()
        #expect(model.isMeasuring, "The build is still running while the reader was away")
        #expect(model.isFollowingBuild, "and the screen must follow it again")
        model.stop()

        // And it can be stopped: three minutes of throttled requests used to
        // be unstoppable, with a cancellation check in the loop that nothing
        // could reach.
        await service.cancelBuild()
        #expect(await !service.progress.isRunning)
    }

    /// R10 (`docs/reviews/reader.md`, 2026-09-13): `cadence(for:)` — the
    /// single-series path used when a series is opened from Search rather
    /// than measured by a full `build()` — measured a cadence without ever
    /// setting `season`, unlike `run`. A series settled that way then printed
    /// "chapter 235" instead of "Season 3 · about every 7 days" and, being
    /// settled, was never picked up by a later build either. Expected
    /// failure before the fix: `cadence.season == nil`, where this now
    /// asserts 3 — the same Tower of God shape (`v.3 c.235` restarting from
    /// `v.2`) `SeasonReadingTests` measures against the live endpoint.
    /// Chapter numbering restarts at the new volume, which is what
    /// `SeasonReading` reads as a season — MangaUpdates lists Tower of God as
    /// "v.3 c.1" after "v.2 c.337". A fixture that kept counting up would
    /// correctly report no season at all.
    @Test("cadence(for:) sets the season the same way a full build does")
    func cadenceForSeriesSetsSeason() async throws {
        let releases = Data(#"""
        {"results": [
          {"record": {"volume": "3", "chapter": "4", "release_date": "2026-09-06"}},
          {"record": {"volume": "3", "chapter": "3", "release_date": "2026-08-30"}},
          {"record": {"volume": "3", "chapter": "2", "release_date": "2026-08-23"}},
          {"record": {"volume": "3", "chapter": "1", "release_date": "2026-08-16"}},
          {"record": {"volume": "2", "chapter": "337", "release_date": "2026-01-01"}}
        ]}
        """#.utf8)
        URLProtocolStub.setHandler { _ in .respond(.init(body: releases)) }
        defer { URLProtocolStub.reset() }

        let series = SeriesFactory.make(
            id: 1, title: "Tower of God", status: "releasing",
            source: ["manga_updates": Series.TrackerEntry(id: "abc1", rating: nil, ratingNormalized: nil)]
        )
        let service = ReleaseScheduleService(
            library: LibrarySnapshot(library: OneEntryLibrary(entries: [])),
            mangaUpdates: MangaUpdatesClient(
                baseURL: URL(string: "https://mu.example.invalid/v1").unsafeTestURL,
                session: URLProtocolStub.makeSession()
            ),
            database: try AppDatabase.inMemory()
        )
        guard case let .measured(cadence) = await service.cadence(for: series) else {
            Issue.record("expected a measured cadence")
            return
        }
        #expect(cadence.season == 3)
    }

    /// Gap 18: before the fix, a MangaUpdates refusal on the single-series
    /// path collapsed to `.none` — indistinguishable from "asked and there
    /// was not enough history". Expected failure before the fix:
    /// `case .none = result` succeeds instead of `Issue.record` firing, and
    /// the failure carried no `party`, so the screen would have blamed
    /// MangaBaka for MangaUpdates' 503.
    @Test("cadence(for:) reports a failure distinctly from 'too few releases'")
    func cadenceForReportsFailure() async throws {
        URLProtocolStub.setHandler { _ in .respond(.init(statusCode: 503)) }
        defer { URLProtocolStub.reset() }

        let series = SeriesFactory.make(
            id: 1, title: "S1", status: "releasing",
            source: ["manga_updates": Series.TrackerEntry(id: "abc1", rating: nil, ratingNormalized: nil)]
        )
        let database = try AppDatabase.inMemory()
        let service = ReleaseScheduleService(
            library: LibrarySnapshot(library: OneEntryLibrary(entries: [])),
            mangaUpdates: MangaUpdatesClient(
                baseURL: URL(string: "https://mu.example.invalid/v1").unsafeTestURL,
                session: URLProtocolStub.makeSession()
            ),
            database: database
        )
        let result = await service.cadence(for: series)
        guard case let .failed(error) = result else {
            Issue.record("expected .failed, got \(result)")
            return
        }
        #expect(error == .server(status: 503, message: "MangaUpdates returned 503.", party: .mangaUpdates))
        // Gap 100: MangaUpdates' own party, not MangaBaka's — no status
        // code leaking into the copy either.
        let message = error.userFacingMessage
        #expect(!message.contains { $0.isNumber })
    }

    /// Gap 99: before the fix, an offline build kept trying every remaining
    /// series at three seconds each — 55 series is nearly three minutes spent
    /// re-discovering the same "no network" answer 54 more times. Expected
    /// failure before the fix: `progress.done` reaches `total` (55) rather
    /// than stopping at 1, and the loop takes multiple seconds per series
    /// instead of returning as soon as the first request reports offline.
    @Test("A build stops at the first offline/rate-limited answer, not the last series")
    func buildStopsOnGlobalOutage() async throws {
        URLProtocolStub.setHandler { _ in
            .fail(URLError(.notConnectedToInternet))
        }
        defer { URLProtocolStub.reset() }

        let entries = (1...55).map { id in
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
        let service = ReleaseScheduleService(
            library: LibrarySnapshot(library: OneEntryLibrary(entries: entries)),
            mangaUpdates: MangaUpdatesClient(
                baseURL: URL(string: "https://mu.example.invalid/v1").unsafeTestURL,
                session: URLProtocolStub.makeSession()
            ),
            database: try AppDatabase.inMemory()
        )
        await service.build()
        // The whole point: this returns almost immediately rather than after
        // 55 x 3s of throttled retries, because the first offline answer
        // stops the loop (gap 99).
        while await service.progress.isRunning {
            try await Task.sleep(for: .milliseconds(10))
        }
        let progress = await service.progress
        #expect(progress.done == 1)
        #expect(progress.total == 55)
        #expect(progress.failure == .offline)
    }

    private final class OneEntryLibrary: LibraryProviding, @unchecked Sendable {
        let entries: [LibraryEntry]
        init(entry: LibraryEntry) { entries = [entry] }
        init(entries: [LibraryEntry]) { self.entries = entries }
        func recommendationStatus() async throws(APIError) -> RecommendationStatus {
            throw APIError.offline
        }
        func recommendations(
            limit: Int, page: Int, excluding: [Int]
        ) async -> PersonalRecommendations { PersonalRecommendations() }
        func library(page: Int, limit: Int) async -> [LibraryEntry] { page == 1 ? entries : [] }
        func hiddenTagIDs() async -> Set<Int>? { nil }
        func topGenres() async -> [TopGenre]? { nil }
        func update(seriesId: Int, change: LibraryChange) async throws(APIError) {}
        func add(seriesId: Int, state: LibraryEntry.State) async throws(APIError) -> Bool { true }
        func remove(seriesId: Int) async throws(APIError) {}
    }

    private final class OfflineLibrary: LibraryProviding, @unchecked Sendable {
        func recommendationStatus() async throws(APIError) -> RecommendationStatus {
            throw APIError.offline
        }
        func recommendations(
            limit: Int, page: Int, excluding: [Int]
        ) async -> PersonalRecommendations { PersonalRecommendations() }
        func library(page: Int, limit: Int) async -> [LibraryEntry] { [] }
        func libraryPage(page: Int, limit: Int) async throws(APIError) -> [LibraryEntry] { throw .offline }
        func hiddenTagIDs() async -> Set<Int>? { nil }
        func topGenres() async -> [TopGenre]? { nil }
        func update(seriesId: Int, change: LibraryChange) async throws(APIError) {}
        func add(seriesId: Int, state: LibraryEntry.State) async throws(APIError) -> Bool { true }
        func remove(seriesId: Int) async throws(APIError) {}
    }
}
