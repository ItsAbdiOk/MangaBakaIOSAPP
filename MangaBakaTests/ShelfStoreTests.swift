import Foundation
import Testing
@testable import MangaBaka

@Suite("Shelf store")
struct ShelfStoreTests {
    private func makeShelf() throws -> ShelfStore {
        ShelfStore(database: try AppDatabase.inMemory(), clock: TestClock())
    }

    @Test("A saved series comes back")
    func savesAndReads() async throws {
        let shelf = try makeShelf()
        try await shelf.record(SeriesFactory.make(id: 1, title: "Kept"), as: .saved)

        let saved = try await shelf.entries(.saved)
        #expect(saved.map(\.id) == [1])
        #expect(saved.first?.displayTitle == "Kept")
    }

    /// A skip is recorded rather than discarded, so the same series stops
    /// reappearing in the stack and can still be recovered.
    @Test("Saves and skips are kept apart")
    func kindsAreSeparate() async throws {
        let shelf = try makeShelf()
        try await shelf.record(SeriesFactory.make(id: 1, title: "Kept"), as: .saved)
        try await shelf.record(SeriesFactory.make(id: 2, title: "Passed"), as: .skipped)

        #expect(try await shelf.entries(.saved).map(\.id) == [1])
        #expect(try await shelf.entries(.skipped).map(\.id) == [2])
    }

    /// The stack asks for this to avoid showing something already judged.
    @Test("Reacted ids cover both saves and skips")
    func reactedCoversBoth() async throws {
        let shelf = try makeShelf()
        try await shelf.record(SeriesFactory.make(id: 1), as: .saved)
        try await shelf.record(SeriesFactory.make(id: 2), as: .skipped)

        #expect(try await shelf.reactedIDs() == [1, 2])
    }

    /// Changing your mind is ordinary: a skip later saved must not leave two
    /// rows, or the series appears in both lists at once.
    @Test("Re-reacting replaces rather than duplicates")
    func reReactingReplaces() async throws {
        let shelf = try makeShelf()
        let series = SeriesFactory.make(id: 1, title: "Reconsidered")
        try await shelf.record(series, as: .skipped)
        try await shelf.record(series, as: .saved)

        #expect(try await shelf.entries(.saved).map(\.id) == [1])
        #expect(try await shelf.entries(.skipped).isEmpty, "It cannot be in both lists")
    }

    @Test("Removing takes it out of both lists")
    func removes() async throws {
        let shelf = try makeShelf()
        try await shelf.record(SeriesFactory.make(id: 1), as: .saved)

        try await shelf.remove(seriesId: 1)

        #expect(try await shelf.entries(.saved).isEmpty)
        #expect(try await shelf.reactedIDs().isEmpty)
    }

    /// The shelf renders when the cache is empty or the reader is offline, so
    /// it stores its own copy of the series rather than a reference to one.
    @Test("A saved series survives without the feed cache")
    func selfContained() async throws {
        let database = try AppDatabase.inMemory()
        let shelf = ShelfStore(database: database, clock: TestClock())
        try await shelf.record(
            SeriesFactory.make(id: 1, title: "Standalone", cover: .sized),
            as: .saved
        )

        // Wipe the derived cache out from under the shelf. GRDB offers sync
        // and async writes; the sync one is named explicitly because in an
        // async test the async overload wins and does not compile.
        try await database.writer.write { db in
            try db.execute(sql: "DELETE FROM series")
            try db.execute(sql: "DELETE FROM feedEntry")
        }

        let saved = try await shelf.entries(.saved)
        #expect(saved.first?.displayTitle == "Standalone")
        #expect(saved.first?.cover.width == 200, "The stored copy keeps its cover")
    }

    /// Most recent first, so the shelf reads as a record of what you just found.
    @Test("Newest saves come first")
    func newestFirst() async throws {
        let clock = TestClock()
        let shelf = ShelfStore(database: try AppDatabase.inMemory(), clock: clock)
        try await shelf.record(SeriesFactory.make(id: 1, title: "First"), as: .saved)
        clock.advance(by: 60)
        try await shelf.record(SeriesFactory.make(id: 2, title: "Second"), as: .saved)

        #expect(try await shelf.entries(.saved).map(\.id) == [2, 1])
    }
}
