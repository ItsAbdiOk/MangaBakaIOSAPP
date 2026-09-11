import Foundation
import Testing
@testable import MangaBaka

/// How the schedule groups what it has, which is where the honesty lives: on a
/// real library most estimates are already in the past.
@Suite("Schedule grouping")
@MainActor
struct ScheduleGroupingTests {
    private let calendar = Calendar(identifier: .gregorian)

    private func makeService() throws -> ReleaseScheduleService {
        ReleaseScheduleService(library: SilentLibrary(), database: try AppDatabase.inMemory())
    }

    private final class SilentLibrary: LibraryProviding, @unchecked Sendable {
        func recommendationStatus() async -> RecommendationStatus? { nil }
        func recommendations(
            limit: Int, page: Int, excluding: [Int]
        ) async -> [PersonalRecommendation] { [] }
        func library(page: Int, limit: Int) async -> [LibraryEntry] { [] }
        func hiddenTagIDs() async -> Set<Int>? { [] }
        func topGenres() async -> [TopGenre]? { [] }
        func update(seriesId: Int, change: LibraryChange) async throws(APIError) {}
        func add(seriesId: Int, state: LibraryEntry.State) async throws(APIError) -> Bool { true }
        func remove(seriesId: Int) async throws(APIError) {}

    }

    private func cadence(dueIn days: Int, regular: Bool = true) -> Cadence {
        Cadence(
            medianGapDays: 7,
            spreadDays: regular ? 0 : 9,
            lastRelease: Date(),
            due: Date().addingTimeInterval(Double(days) * 86_400),
            samples: 20,
            gaps: 19,
            isRegular: regular
        )
    }

    private func work(_ id: Int, _ cadence: Cadence?, reason: ScheduledWork.Reason? = nil) -> ScheduledWork {
        ScheduledWork(
            series: SeriesFactory.make(id: id, title: "S\(id)"),
            cadence: cadence,
            reason: reason
        )
    }

    private func model(with snapshot: ScheduleSnapshot) throws -> ScheduleModel {
        let model = ScheduleModel(service: try makeService())
        model.applyForTesting(snapshot)
        return model
    }

    @Test("Before the first measurement the screen says what it is about to do")
    func firstRunExplainsItself() throws {
        // The device showed "Not measured yet", a Measure button, and a panel
        // reading "0 ESTIMATED OF 0 IN SCOPE" over two thirds of an empty
        // screen. "0 of 0" is not a number a reader can act on, and nothing
        // said the measurement takes minutes.
        var snapshot = ScheduleSnapshot()
        snapshot.inScope = 55
        snapshot.measuredAt = nil
        let model = try model(with: snapshot)

        #expect(model.hasNeverMeasured)
        // 55 series, one MangaUpdates request every three seconds.
        #expect(model.firstRunEstimate == "about 3 minutes")
        #expect(model.firstRunExplanation.contains("55 series"))
        #expect(model.firstRunExplanation.contains("progress is kept"))
    }

    @Test("A measured schedule is past its first run")
    func measuredIsNotFirstRun() throws {
        var snapshot = ScheduleSnapshot()
        snapshot.inScope = 55
        snapshot.measuredAt = Date()
        #expect(try !model(with: snapshot).hasNeverMeasured)
    }

    @Test("A tiny library is not told to wait minutes")
    func shortEstimateReadsHonestly() throws {
        var snapshot = ScheduleSnapshot()
        snapshot.inScope = 4
        #expect(try model(with: snapshot).firstRunEstimate == "under a minute")
    }

    @Test("Due within a week, later, and past due are separated")
    func splitsByWhen() throws {
        var snapshot = ScheduleSnapshot()
        snapshot.dated = [
            work(1, cadence(dueIn: 2)),
            work(2, cadence(dueIn: 30)),
            work(3, cadence(dueIn: -400))
        ]
        snapshot.inScope = 3

        let groups = try model(with: snapshot).groups
        #expect(groups.map(\.id) == ["due-soon", "late", "later"])
        #expect(groups.first { $0.id == "late" }?.works.count == 1)
    }

    /// Past due is second, not hidden and not last. On a real library 61% of
    /// estimates were already in the past.
    @Test("Past due sits directly under what is coming")
    func lateIsProminent() throws {
        var snapshot = ScheduleSnapshot()
        snapshot.dated = [work(1, cadence(dueIn: -10)), work(2, cadence(dueIn: 3))]
        snapshot.inScope = 2

        let groups = try model(with: snapshot).groups
        #expect(groups.first?.id == "due-soon")
        #expect(groups.dropFirst().first?.id == "late")
        #expect(groups.first { $0.id == "late" }?.isOverdue == true)
    }

    /// Works with no date still appear, with the reason. Dropping them would
    /// hide them entirely, which is worse than saying nothing is known.
    @Test("Works with no estimate are shown with their reason")
    func undatedAreKept() throws {
        var snapshot = ScheduleSnapshot()
        snapshot.undated = [work(9, nil, reason: .onHiatus)]
        snapshot.inScope = 1

        let groups = try model(with: snapshot).groups
        let undated = try #require(groups.first { $0.id == "undated" })
        #expect(undated.works.first?.reason == .onHiatus)
        #expect(ScheduledWork.Reason.onHiatus.explanation == "On hiatus — estimate paused")
    }

    @Test("An empty scope reads as empty, not as an error")
    func emptyScope() throws {
        #expect(try model(with: ScheduleSnapshot()).isEmpty)
    }

    /// Offline, the library walk fails and nothing is in scope — which used to
    /// read as "0 in scope", the empty state, for a reader with 900 series.
    @Test("A library that could not be read is a failure, not an empty scope")
    func unreadableLibraryIsNotEmpty() throws {
        var snapshot = ScheduleSnapshot()
        snapshot.libraryFailure = .offline
        let model = try model(with: snapshot)
        #expect(!model.isEmpty)
        #expect(model.libraryFailure == .offline)
    }

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

    private final class OneEntryLibrary: LibraryProviding, @unchecked Sendable {
        let entry: LibraryEntry
        init(entry: LibraryEntry) { self.entry = entry }
        func recommendationStatus() async -> RecommendationStatus? { nil }
        func recommendations(
            limit: Int, page: Int, excluding: [Int]
        ) async -> [PersonalRecommendation] { [] }
        func library(page: Int, limit: Int) async -> [LibraryEntry] { page == 1 ? [entry] : [] }
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

    /// The build recorded its failure and no view read it: a measurement in
    /// which every request failed ended with "55 still to measure" and no why.
    @Test("A measurement that left series unmeasured says why")
    func measurementFailureIsSaid() throws {
        var snapshot = ScheduleSnapshot()
        snapshot.inScope = 55
        snapshot.pending = 55
        let model = try model(with: snapshot)
        model.applyForTesting(
            ScheduleProgress(isRunning: false, done: 55, total: 55, failure: "MangaUpdates returned 503.")
        )
        #expect(model.measurementFailureLine == "55 not measured. MangaUpdates returned 503.")
    }

    @Test("A finished measurement with nothing left says nothing")
    func completeMeasurementSaysNothing() throws {
        var snapshot = ScheduleSnapshot()
        snapshot.inScope = 55
        let model = try model(with: snapshot)
        model.applyForTesting(ScheduleProgress(isRunning: false, done: 55, total: 55, failure: nil))
        #expect(model.measurementFailureLine == nil)
    }

    /// Measure everything, come back six weeks later, open one series page:
    /// one row is fresh and 54 are old. The header used to report the fresh one.
    @Test("The measured line is as old as the oldest estimate")
    func measuredLineUsesOldest() throws {
        var snapshot = ScheduleSnapshot()
        snapshot.inScope = 55
        snapshot.measuredAt = Date().addingTimeInterval(-60)
        snapshot.oldestMeasuredAt = Date().addingTimeInterval(-42 * 86_400)
        let model = try model(with: snapshot)
        #expect(model.measuredLine == "Measured over the last 1 month")
    }

    @Test("Rows measured together report one time")
    func measuredLineForOneBuild() throws {
        var snapshot = ScheduleSnapshot()
        snapshot.inScope = 55
        snapshot.measuredAt = Date().addingTimeInterval(-3 * 3_600)
        snapshot.oldestMeasuredAt = Date().addingTimeInterval(-3 * 3_600 - 120)
        let model = try model(with: snapshot)
        #expect(model.measuredLine == "Measured 3 hours ago")
    }

    @Test("The scope line counts what was estimated against what is in scope")
    func scopeLine() throws {
        var snapshot = ScheduleSnapshot()
        snapshot.dated = [work(1, cadence(dueIn: 1)), work(2, cadence(dueIn: 2))]
        snapshot.inScope = 55
        #expect(try model(with: snapshot).scopeLine == "2 estimated of 55 in scope")
    }
}
