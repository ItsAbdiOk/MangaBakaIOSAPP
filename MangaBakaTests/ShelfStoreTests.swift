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

        let saved = try await shelf.entries(.saved).series
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

        #expect(try await shelf.entries(.saved).series.map(\.id) == [1])
        #expect(try await shelf.entries(.skipped).series.map(\.id) == [2])
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

        #expect(try await shelf.entries(.saved).series.map(\.id) == [1])
        #expect(try await shelf.entries(.skipped).series.isEmpty, "It cannot be in both lists")
    }

    @Test("Removing takes it out of both lists")
    func removes() async throws {
        let shelf = try makeShelf()
        try await shelf.record(SeriesFactory.make(id: 1), as: .saved)

        try await shelf.remove(seriesId: 1)

        #expect(try await shelf.entries(.saved).series.isEmpty)
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

        let saved = try await shelf.entries(.saved).series
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

        #expect(try await shelf.entries(.saved).series.map(\.id) == [2, 1])
    }

    /// L4: `StackModel` used to build its exclusion list as
    /// `reactedIDs().sorted().suffix(60)` — the numerically largest series
    /// ids, i.e. the most recently *catalogued*, not the most recently
    /// *swiped*. A reader whose last session was all low-id (older-catalogue)
    /// series sent none of them as exclusions.
    /// Expected to fail without a recency-ordered query: reacting to the
    /// low-id series *last* would still put the high-id series first under
    /// `sorted().suffix(...)`.
    @Test("Recently reacted ids are ordered by when they were reacted to, not by id")
    func recentlyReactedIsOrderedByTime() async throws {
        let clock = TestClock()
        let shelf = ShelfStore(database: try AppDatabase.inMemory(), clock: clock)
        // Reacted to in ascending id order but descending time — the id sort
        // and the time sort disagree completely.
        try await shelf.record(SeriesFactory.make(id: 100), as: .saved)
        clock.advance(by: 60)
        try await shelf.record(SeriesFactory.make(id: 50), as: .skipped)
        clock.advance(by: 60)
        try await shelf.record(SeriesFactory.make(id: 1), as: .saved)

        let recent = try await shelf.recentlyReactedIDs(limit: 60)
        #expect(recent == [1, 50, 100], "most recently reacted to first, not highest id first")
    }

    /// The cap that keeps the exclusion list inside the URL's practical
    /// length limit.
    @Test("Recently reacted ids respect the limit")
    func recentlyReactedRespectsLimit() async throws {
        let clock = TestClock()
        let shelf = ShelfStore(database: try AppDatabase.inMemory(), clock: clock)
        for id in 1...5 {
            try await shelf.record(SeriesFactory.make(id: id), as: .saved)
            clock.advance(by: 1)
        }

        let recent = try await shelf.recentlyReactedIDs(limit: 2)
        #expect(recent == [5, 4])
    }

    /// `entries` used to `compactMap` a row that no longer decodes straight
    /// out of the result, so a shelf with one corrupt row silently reported
    /// itself one entry shorter — a shrinking disk cache with nothing to say
    /// why (gap 116, FAILURES-SUMMARY.md). Expected to fail without the fix:
    /// `entries` returned a bare `[Series]` with no way to report the drop, so
    /// `undecodable` does not exist to read yet.
    @Test("A row that no longer decodes is counted, not silently dropped")
    func undecodableRowIsCounted() async throws {
        let database = try AppDatabase.inMemory()
        let shelf = ShelfStore(database: database, clock: TestClock())
        try await shelf.record(SeriesFactory.make(id: 1, title: "Fine"), as: .saved)
        // A row GRDB will hand back but the current `Series` shape cannot
        // decode — standing in for a schema this build no longer understands.
        try await database.writer.write { db in
            try db.execute(
                sql: "INSERT INTO shelfEntry (seriesId, kind, addedAt, payload) VALUES (?, ?, ?, ?)",
                arguments: [2, ShelfEntry.Kind.saved.rawValue, Date(), Data("{}".utf8)]
            )
        }

        let result = try await shelf.entries(.saved)
        #expect(result.series.map(\.id) == [1], "the decodable row still comes back")
        #expect(result.undecodable == 1, "the corrupt row is counted rather than silently vanishing")
    }
}
