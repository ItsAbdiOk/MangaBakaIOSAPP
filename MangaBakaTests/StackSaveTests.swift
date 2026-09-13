import Foundation
import Testing
@testable import MangaBaka

/// A save on the stack used to go only to a local shelf that MangaBaka never
/// saw, leaving the app with two lists of saved things and no relationship
/// between them.
@Suite("A stack save reaches the real library")
@MainActor
struct StackSaveWritesThroughTests {
    private final class RecordingLibrary: LibraryProviding, @unchecked Sendable {
        private(set) var added: [(id: Int, state: LibraryEntry.State)] = []
        var failsToAdd = false

        func recommendationStatus() async throws(APIError) -> RecommendationStatus {
            throw APIError.offline
        }
        func recommendations(
            limit: Int, page: Int, excluding: [Int]
        ) async -> PersonalRecommendations { PersonalRecommendations() }
        func library(page: Int, limit: Int) async -> [LibraryEntry] { [] }
        func hiddenTagIDs() async -> Set<Int>? { [] }
        func topGenres() async -> [TopGenre]? { [] }
        func update(seriesId: Int, change: LibraryChange) async throws(APIError) {}
        func remove(seriesId: Int) async throws(APIError) {}

        func add(seriesId: Int, state: LibraryEntry.State) async throws(APIError) -> Bool {
            if failsToAdd { throw APIError.offline }
            added.append((seriesId, state))
            return true
        }
    }

    private final class SilentRepository: StubRepositoryBase, @unchecked Sendable {
        override func feed(_ feed: FeedKind, forceRefresh: Bool) async -> FeedResult {
            FeedResult(series: [SeriesFactory.make(id: 1, title: "One")], origin: .network)
        }
    }

    private func makeShelf() throws -> ShelfStore {
        ShelfStore(database: try AppDatabase.inMemory())
    }

    /// A save on a discovery surface means "I intend to read this", not "I am
    /// reading it".
    @Test("Saving adds the series to the library as plan to read")
    func saveAddsToLibrary() async throws {
        let library = RecordingLibrary()
        let model = StackModel(
            repository: SilentRepository(), shelf: try makeShelf(), library: library
        )
        await model.loadIfNeeded()
        await model.react(.saved)

        #expect(library.added.map(\.id) == [1])
        #expect(library.added.first?.state == .planToRead)
        #expect(model.saveConfirmation == "Saved to your library", "The toast says where it went")
    }

    /// MangaBaka has no "not for me". Writing "dropped" for something never
    /// opened would be a lie about the reader's history.
    @Test("Skipping writes nothing to the library")
    func skipStaysLocal() async throws {
        let library = RecordingLibrary()
        let model = StackModel(
            repository: SilentRepository(), shelf: try makeShelf(), library: library
        )
        await model.loadIfNeeded()
        await model.react(.skipped)

        #expect(library.added.isEmpty)
    }

    /// Losing the save would be worse than a stale library, so a failed write
    /// is reported rather than undone.
    @Test("A failed write keeps the local save and says so")
    func failedWriteKeepsTheSave() async throws {
        let library = RecordingLibrary()
        library.failsToAdd = true
        let shelf = try makeShelf()
        let model = StackModel(repository: SilentRepository(), shelf: shelf, library: library)
        await model.loadIfNeeded()
        await model.react(.saved)

        #expect(model.saveWarning != nil)
        #expect(try await shelf.entries(.saved).series.map(\.id) == [1], "the local save survives")
        #expect(model.saveConfirmation == "Saved here", "and the toast does not claim more")
    }

    /// Signed out there is no library to write to, and that is the ordinary
    /// case rather than a failure.
    @Test("With no account, saving is local and silent")
    func noAccountIsSilent() async throws {
        let model = StackModel(repository: SilentRepository(), shelf: try makeShelf())
        await model.loadIfNeeded()
        await model.react(.saved)

        #expect(model.saveWarning == nil)
    }

    /// A shelf write is the one place a save is guaranteed to land — unlike
    /// the library push above (K9, done well already), which already has its
    /// own warning. `try?` used to let this pass silently: `saved.insert` and
    /// the "Saved here" toast fired even when the write never reached disk
    /// (gap 36, FAILURES-SUMMARY.md K8). Expected to fail today with:
    /// `model.saved.map(\.id) == [1]` (inserted anyway) and
    /// `model.shouldConfirmSave == true` (that property does not exist yet).
    @Test("A local shelf write failure keeps the id out of `saved` and blocks the toast")
    func shelfWriteFailureIsSurfaced() async throws {
        let database = try AppDatabase.inMemory()
        // Dropping the table is the write failing, not a mock: `record`
        // throws a real GRDB error the moment the table it targets is gone.
        try await database.writer.write { db in try db.drop(table: "shelfEntry") }
        let shelf = ShelfStore(database: database)
        let model = StackModel(repository: SilentRepository(), shelf: shelf)
        await model.loadIfNeeded()

        await model.react(.saved)

        #expect(model.saved.isEmpty, "the write never landed, so nothing should show as saved")
        #expect(model.saveWarning != nil)
        #expect(!model.shouldConfirmSave, "a local failure must not be confirmed as \"Saved here\"")
    }
}

/// Gap 37 (K11): `resetStack` used to be `Void` and `try?` swallowed
/// `shelf.clear()` throwing, so the caller confirmed "The stack has been
/// reset" while the database still held every save.
@Suite("Stack reset reports whether the shelf actually cleared")
@MainActor
struct StackResetReportsFailureTests {
    private final class SilentRepository: StubRepositoryBase, @unchecked Sendable {}

    /// Expected to fail to compile today: `resetStack()` returns `Void`, so
    /// `let succeeded = await model.resetStack()` does not type-check.
    @Test("A reset whose shelf clear fails is not reported as a success")
    func failedClearIsReported() async throws {
        let database = try AppDatabase.inMemory()
        try await database.writer.write { db in try db.drop(table: "shelfEntry") }
        let shelf = ShelfStore(database: database)
        let model = StackModel(repository: SilentRepository(), shelf: shelf)

        let succeeded = await model.resetStack()

        #expect(!succeeded)
    }

    @Test("An ordinary reset reports success")
    func ordinaryResetIsReported() async throws {
        let model = StackModel(
            repository: SilentRepository(),
            shelf: ShelfStore(database: try AppDatabase.inMemory())
        )

        let succeeded = await model.resetStack()

        #expect(succeeded)
    }
}

/// 2026-09-13: a catalogue deal (`fetchBatch`, via `.mix`/`.surprise`) shares
/// MangaBaka's 30/min search window with a reader's own typed search. A deal
/// made while the reader is watching the Stack tab is exactly what they asked
/// for and keeps the whole window; one made while they are elsewhere
/// (Discover, say) is this app's own idea and must leave room for a search.
///
/// A fresh conformer rather than a `StubRepositoryBase` subclass: overriding
/// `feed(_:forceRefresh:priority:)` on a subclass would not actually be
/// picked up through the protocol's dispatch, because the base class itself
/// never declares that method — see the same caveat documented on
/// `DueThisWeekTests.StubExtrasRepository`.
@Suite("A stack deal's priority follows tab visibility")
@MainActor
struct StackModelPriorityTests {
    private final class PriorityCapturingRepository: SeriesRepositoryProtocol, @unchecked Sendable {
        private(set) var lastPriority: RequestPriority?

        func feed(_ feed: FeedKind, forceRefresh: Bool) async -> FeedResult {
            await self.feed(feed, forceRefresh: forceRefresh, priority: .userInitiated)
        }
        func feed(_ feed: FeedKind, forceRefresh: Bool, priority: RequestPriority) async -> FeedResult {
            lastPriority = priority
            return FeedResult(series: [SeriesFactory.make(id: 1, title: "One")], origin: .network)
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

    @Test("Visible on the Stack tab deals at userInitiated")
    func visibleDealsAtUserInitiated() async throws {
        let repository = PriorityCapturingRepository()
        let model = StackModel(
            repository: repository, shelf: ShelfStore(database: try AppDatabase.inMemory())
        )
        model.isVisible = true

        await model.loadIfNeeded()

        #expect(repository.lastPriority == .userInitiated)
    }

    /// Expected to fail before the fix: `StackModel` had no `isVisible`
    /// property, `fetchBatch` had no way to be told the reader was elsewhere,
    /// and always dealt at `.userInitiated`.
    @Test("Dealing while off the Stack tab deals at background priority")
    func invisibleDealsAtBackgroundPriority() async throws {
        let repository = PriorityCapturingRepository()
        let model = StackModel(
            repository: repository, shelf: ShelfStore(database: try AppDatabase.inMemory())
        )
        model.isVisible = false

        await model.loadIfNeeded()

        #expect(repository.lastPriority == .background)
    }
}
