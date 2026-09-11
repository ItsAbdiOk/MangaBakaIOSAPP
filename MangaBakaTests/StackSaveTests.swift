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

        func recommendationStatus() async -> RecommendationStatus? { nil }
        func recommendations(
            limit: Int, page: Int, excluding: [Int]
        ) async -> [PersonalRecommendation] { [] }
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
        #expect(try await shelf.entries(.saved).map(\.id) == [1], "the local save survives")
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
}
