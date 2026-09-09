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
        func topGenres() async -> [TopGenre] { [] }
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

    @Test("The scope line counts what was estimated against what is in scope")
    func scopeLine() throws {
        var snapshot = ScheduleSnapshot()
        snapshot.dated = [work(1, cadence(dueIn: 1)), work(2, cadence(dueIn: 2))]
        snapshot.inScope = 55
        #expect(try model(with: snapshot).scopeLine == "2 estimated of 55 in scope")
    }
}
