import Testing
import Foundation
@testable import MangaBaka

/// The library as one list: what it shows, in what order, and what it leaves
/// out.
@Suite("Library list")
@MainActor
struct LibraryListTests {
    private func entry(
        _ id: Int,
        _ state: LibraryEntry.State,
        title: String = "Series",
        rating: Double? = nil,
        finished: Date? = nil
    ) -> LibraryEntry {
        LibraryEntry(
            id: id, seriesId: id, state: state, progressChapter: nil,
            progressVolume: nil, rating: rating, note: nil, startDate: nil,
            finishDate: finished, numberOfRereads: nil, priority: nil,
            isPrivate: nil, readLink: nil,
            series: SeriesFactory.make(id: id, title: title)
        )
    }

    private func model(_ entries: [LibraryEntry]) async -> LibraryModel {
        let model = LibraryModel(library: StubLibrary(entries: entries))
        await model.load()
        return model
    }

    @Test("Dropped is counted everywhere and listed nowhere, unless asked for")
    func droppedIsCountedNotListed() async throws {
        let model = await model([
            entry(1, .reading, title: "Reading one"),
            entry(2, .dropped, title: "Gave up")
        ])

        // It is a real part of the library and the shape bar says so.
        #expect(model.shape.contains { $0.state == .dropped && $0.count == 1 })
        // But a list of everything you read that opens with what you gave up
        // on is a worse answer than one that does not.
        #expect(model.listed.map(\.seriesId) == [1])

        model.filter = .dropped
        #expect(model.listed.map(\.seriesId) == [2], "asked for, it appears")
    }

    @Test("Dropped comes last among the states")
    func droppedIsLast() async throws {
        let model = await model([
            entry(1, .dropped),
            entry(2, .reading),
            entry(3, .completed)
        ])

        #expect(model.shape.last?.state == .dropped)
        #expect(model.shape.first?.state == .reading)
    }

    @Test("Sorting by title ignores a leading article")
    func titleSortIgnoresArticles() async throws {
        // Sorting on the raw title files a quarter of an English-language
        // library under "The".
        let model = await model([
            entry(1, .reading, title: "The Greatest Estate Developer"),
            entry(2, .reading, title: "Havoc"),
            entry(3, .reading, title: "A Returner's Magic")
        ])
        model.sort = .title

        #expect(model.listed.map { $0.series?.displayTitle } == [
            "The Greatest Estate Developer", "Havoc", "A Returner's Magic"
        ])
    }

    @Test("An entry with no date sorts last, not first")
    func undatedEntriesSinkOnRecency() async throws {
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        let model = await model([
            entry(1, .reading, finished: nil),
            entry(2, .reading, finished: old)
        ])
        model.sort = .recentlyUpdated

        #expect(model.listed.map(\.seriesId) == [2, 1], "nil is not newer than a date")
    }

    @Test("The jump index only appears where it can point at something")
    func jumpIndexIsConditional() async throws {
        // The board draws one on a screen sorted by "Recently updated"; its own
        // caption says title-sorted and 200-plus. The caption wins: an A-Z rail
        // down a list ordered by date points at nothing.
        let many = (1...250).map { entry($0, .reading, title: "Series \($0)") }
        let model = await model(many)

        model.sort = .recentlyUpdated
        #expect(!model.showsJumpIndex)

        model.sort = .title
        #expect(model.showsJumpIndex)

        model.filter = .paused
        #expect(!model.showsJumpIndex, "nothing left to index")
    }

    @Test("Search covers only what has loaded, and says nothing it cannot")
    func searchIsLocal() async throws {
        let model = await model([
            entry(1, .reading, title: "Solo Leveling"),
            entry(2, .reading, title: "Omniscient Reader")
        ])
        model.searchText = "solo"

        #expect(model.listed.map(\.seriesId) == [1])
    }

    private final class StubLibrary: LibraryProviding, @unchecked Sendable {
        let entries: [LibraryEntry]
        init(entries: [LibraryEntry]) { self.entries = entries }

        func library(page: Int, limit: Int) async -> [LibraryEntry] {
            page == 1 ? entries : []
        }
        func recommendationStatus() async -> RecommendationStatus? { nil }
        func recommendations(
            limit: Int, page: Int, excluding: [Int]
        ) async -> [PersonalRecommendation] { [] }
        func hiddenTagIDs() async -> Set<Int>? { [] }
        func topGenres() async -> [TopGenre]? { [] }
        func update(seriesId: Int, change: LibraryChange) async throws(APIError) {}
        func add(seriesId: Int, state: LibraryEntry.State) async throws(APIError) -> Bool { true }
        func remove(seriesId: Int) async throws(APIError) {}
    }
}
