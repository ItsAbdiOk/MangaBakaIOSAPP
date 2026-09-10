import Testing
import Foundation
@testable import MangaBaka

/// Recently viewed: the local reading-history log.
///
/// Every test here proves a promise made to the reader in Settings' own words —
/// that the list is capped, that turning a rating off empties it, and that
/// clearing it leaves saves alone. If one of these fails, the app is lying in
/// its own copy.
@Suite("Recently viewed")
struct HistoryTests {
    private func store() throws -> (HistoryStore, TestClock) {
        let clock = TestClock()
        return (HistoryStore(database: try AppDatabase.inMemory(), clock: clock), clock)
    }

    @Test("Most recently opened comes first")
    func ordersNewestFirst() async throws {
        let (history, clock) = try store()
        for id in [1, 2, 3] {
            try await history.record(SeriesFactory.make(id: id))
            clock.advance(by: 60)
        }

        let entries = try await history.entries()
        #expect(entries.map(\.id) == [3, 2, 1])
    }

    @Test("Re-opening moves a series up rather than listing it twice")
    func reopeningDeduplicates() async throws {
        let (history, clock) = try store()
        try await history.record(SeriesFactory.make(id: 1))
        clock.advance(by: 60)
        try await history.record(SeriesFactory.make(id: 2))
        clock.advance(by: 60)
        try await history.record(SeriesFactory.make(id: 1))

        let entries = try await history.entries()
        #expect(entries.map(\.id) == [1, 2])
        #expect(try await history.count() == 2)
    }

    @Test("The list stops at the limit, dropping the oldest")
    func trimsToLimit() async throws {
        let (history, clock) = try store()
        let total = HistoryStore.limit + 5
        for id in 1...total {
            try await history.record(SeriesFactory.make(id: id))
            clock.advance(by: 60)
        }

        let entries = try await history.entries()
        #expect(entries.count == HistoryStore.limit)
        #expect(entries.first?.id == total)
        // The five oldest are gone, not merely hidden.
        #expect(!entries.contains { $0.id <= 5 })
    }

    @Test("Turning a rating off removes it from the history immediately")
    func filtersByContentRating() async throws {
        let (history, clock) = try store()
        try await history.record(SeriesFactory.make(id: 1, contentRating: "safe"))
        clock.advance(by: 60)
        try await history.record(SeriesFactory.make(id: 2, contentRating: "explicit"))

        let filtered = try await history.entries(allowedRatings: ["safe"])
        #expect(filtered.map(\.id) == [1])
        // Still held — the reader may turn it back on, and re-fetching what
        // they already opened would be a worse answer than remembering it.
        #expect(try await history.count() == 2)
    }

    @Test("A series with no stated rating is not filtered out")
    func keepsUnratedSeries() async throws {
        let (history, _) = try store()
        try await history.record(SeriesFactory.make(id: 1, contentRating: nil))

        #expect(try await history.entries(allowedRatings: ["safe"]).map(\.id) == [1])
    }

    @Test("Clearing empties the history and leaves the shelf alone")
    func clearingSparesTheShelf() async throws {
        let database = try AppDatabase.inMemory()
        let history = HistoryStore(database: database, clock: TestClock())
        let shelf = ShelfStore(database: database, clock: TestClock())

        let series = SeriesFactory.make(id: 1)
        try await history.record(series)
        try await shelf.record(series, as: .saved)

        try await history.clear()

        #expect(try await history.entries().isEmpty)
        #expect(try await shelf.entries(.saved).map(\.id) == [1])
    }

    @Test("The row stays hidden until there are two entries to come back to")
    @MainActor
    func hidesUntilWorthShowing() async throws {
        let (history, clock) = try store()
        let model = RecentlyViewedModel(history: history, allowedRatings: { ["safe"] })

        await model.load()
        #expect(!model.isWorthShowing)

        try await history.record(SeriesFactory.make(id: 1, contentRating: "safe"))
        clock.advance(by: 60)
        await model.load()
        #expect(!model.isWorthShowing, "one entry is the series they just closed")

        try await history.record(SeriesFactory.make(id: 2, contentRating: "safe"))
        await model.load()
        #expect(model.isWorthShowing)
    }
}
