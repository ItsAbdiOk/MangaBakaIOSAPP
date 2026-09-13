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

    /// The whole point of filtering on read: nothing is deleted, so widening
    /// the preference again must bring the row straight back.
    @Test("A row hidden under a narrow rating reappears once the preference widens")
    func widenedRatingBringsRowBack() async throws {
        let (history, _) = try store()
        try await history.record(SeriesFactory.make(id: 1, contentRating: "explicit"))

        #expect(try await history.entries(allowedRatings: ["safe"]).isEmpty, "control: hidden under safe")
        #expect(try await history.entries(allowedRatings: ["safe", "explicit"]).map(\.id) == [1])
    }

    /// `entries` promised to filter by "what the reader currently allows",
    /// but only ever read `allowedRatings` — a reader who switched novels off
    /// still saw the novel they opened yesterday in "Recently viewed".
    @Test("Turning a format off removes it from history too, and widening brings it back")
    func filtersByFormat() async throws {
        let (history, clock) = try store()
        try await history.record(SeriesFactory.make(id: 1, type: "manga"))
        clock.advance(by: 60)
        try await history.record(SeriesFactory.make(id: 2, type: "novel"))

        #expect(try await history.entries(allowedFormats: ["manga"]).map(\.id) == [1])
        #expect(
            try await history.entries(allowedFormats: ["manga", "novel"]).map(\.id) == [2, 1],
            "the hidden row is still on disk and comes back once the format is allowed again"
        )
    }

    @Test("A series with no stated type is not filtered out by the format preference")
    func keepsUntypedSeries() async throws {
        let (history, _) = try store()
        try await history.record(SeriesFactory.make(id: 1, type: nil))

        #expect(try await history.entries(allowedFormats: ["manga"]).map(\.id) == [1])
    }

    /// The same standing preference `SeriesRepository` applies to a live feed.
    @Test("A blocked tag hides a row too, and widening the block brings it back")
    func filtersByBlockedTag() async throws {
        let (history, _) = try store()
        let spoiler = SeriesTag(
            id: 99, name: "Major Character Death", namePath: nil, isGenre: false,
            isSpoiler: true, isExplicit: nil, impliedByTagIds: nil,
            contentRating: nil, weight: "core", seriesCount: nil
        )
        try await history.record(SeriesFactory.make(id: 1, tagsV2: [spoiler]))

        #expect(try await history.entries(blockedTags: [99]).isEmpty, "the tag is blocked")
        #expect(try await history.entries(blockedTags: [42]).map(\.id) == [1], "an unrelated block")
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

/// The stack's one-time instruction.
@Suite("Stack instruction")
@MainActor
struct StackHintTests {
    private func defaults() throws -> UserDefaults {
        let suite = "stack.hint.\(UUID().uuidString)"
        return try #require(UserDefaults(suiteName: suite))
    }

    @Test("Shown until the reader drags a card")
    func showsUntilFirstDrag() throws {
        let hint = StackHint(defaults: try defaults())
        #expect(!hint.hasDragged)

        hint.markDragged()
        #expect(hint.hasDragged)
    }

    @Test("Stays gone across launches")
    func survivesRelaunch() throws {
        let store = try defaults()
        StackHint(defaults: store).markDragged()

        #expect(StackHint(defaults: store).hasDragged, "a tutorial that comes back is not one")
    }
}
