import Testing
import Foundation
@testable import MangaBaka

/// One library walk, shared.
///
/// **This is the most expensive thing the app does.** Measured against a real
/// account on 2026-09-10 with the app's own counter: 939 entries across 13
/// requests, **24.7 MB**, because every entry embeds its whole series with all
/// its tags. Everything else the app fetched in that session came to under 1 MB
/// combined.
///
/// It was being walked three times a launch — the Library screen, the taste
/// ledger, and the release reminders — which is 74 MB of someone's data
/// allowance to draw one screen.
@Suite("Library snapshot")
struct LibrarySnapshotTests {
    @Test("Three readers cost one walk")
    func sharedAcrossCallers() async throws {
        let library = CountingLibrary(total: 250)
        let snapshot = LibrarySnapshot(library: library)

        _ = await snapshot.all()
        _ = await snapshot.seriesIDs()
        _ = await snapshot.load()

        #expect(library.calls == 3, "250 entries is three pages, walked once")
    }

    @Test("Callers arriving at once share the request rather than racing")
    func concurrentCallersShareOne() async throws {
        // All three arrive on launch, within milliseconds of each other. Without
        // the in-flight check they each start their own walk before any of them
        // has finished, and the saving disappears exactly when it matters.
        let library = CountingLibrary(total: 250)
        let snapshot = LibrarySnapshot(library: library)

        async let first = snapshot.all()
        async let second = snapshot.all()
        async let third = snapshot.seriesIDs()
        _ = await (first, second, third)

        #expect(library.calls == 3)
    }

    @Test("A failed walk is not cached")
    func failuresAreRetried() async throws {
        // Otherwise a bad connection at launch means an empty library for the
        // rest of the session, with no way to make it try again.
        let library = CountingLibrary(total: 100, failAfter: 0)
        let snapshot = LibrarySnapshot(library: library)

        let first = await snapshot.load()
        #expect(first.failure != nil)
        #expect(!first.isComplete)

        library.failAfter = nil
        let second = await snapshot.load()
        #expect(second.failure == nil)
        #expect(second.entries.count == 100)
    }

    @Test("Invalidating makes the next read fetch again")
    func invalidateRefetches() async throws {
        // A write makes the copy in memory wrong, and a stale library is how
        // the app once offered "Add to library" for something already in it.
        let library = CountingLibrary(total: 100)
        let snapshot = LibrarySnapshot(library: library)

        _ = await snapshot.all()
        await snapshot.invalidate()
        _ = await snapshot.all()

        // Four, not two: a hundred entries fills page one exactly, so the
        // walk asks for page two, gets nothing and stops. Two requests per
        // walk, walked twice.
        #expect(library.calls == 4)
    }

    private final class CountingLibrary: LibraryProviding, @unchecked Sendable {
        let total: Int
        var failAfter: Int?
        private let lock = NSLock()
        private var counted = 0

        init(total: Int, failAfter: Int? = nil) {
            self.total = total
            self.failAfter = failAfter
        }

        var calls: Int {
            lock.lock(); defer { lock.unlock() }
            return counted
        }

        func libraryPage(page: Int, limit: Int) async throws(APIError) -> [LibraryEntry] {
            bump()
            if let failAfter, page > failAfter { throw APIError.offline }
            let start = (page - 1) * limit
            guard start < total else { return [] }
            return (start..<min(start + limit, total)).map { index in
                LibraryEntry(
                    id: index, seriesId: index, state: .reading, progressChapter: nil,
                    progressVolume: nil, rating: nil, note: nil, startDate: nil,
                    finishDate: nil, numberOfRereads: nil, priority: nil,
                    isPrivate: nil, readLink: nil, series: nil
                )
            }
        }

        private func bump() {
            lock.lock(); defer { lock.unlock() }
            counted += 1
        }

        func library(page: Int, limit: Int) async -> [LibraryEntry] {
            (try? await libraryPage(page: page, limit: limit)) ?? []
        }
        func recommendationStatus() async -> RecommendationStatus? { nil }
        func recommendations(
            limit: Int, page: Int, excluding: [Int]
        ) async -> [PersonalRecommendation] { [] }
        func hiddenTagIDs() async -> Set<Int>? { [] }
        func topGenres() async -> [TopGenre] { [] }
        func update(seriesId: Int, change: LibraryChange) async throws(APIError) {}
        func add(seriesId: Int, state: LibraryEntry.State) async throws(APIError) -> Bool { true }
        func remove(seriesId: Int) async throws(APIError) {}
    }
}

/// The library, cached on disk.
///
/// 939 entries is 24.7 MB and the same answer every launch. Paying that on a
/// cellular connection every time the app opens is indefensible.
@Suite("Library disk cache")
struct LibraryDiskCacheTests {
    private func entries(_ count: Int) -> [LibraryEntry] {
        (0..<count).map { index in
            LibraryEntry(
                id: index, seriesId: index, state: .reading, progressChapter: 12,
                progressVolume: nil, rating: 80, note: nil, startDate: nil,
                finishDate: nil, numberOfRereads: nil, priority: nil,
                isPrivate: nil, readLink: nil, series: nil
            )
        }
    }

    @Test("A second launch reads from disk rather than the network")
    func survivesRelaunch() async throws {
        let database = try AppDatabase.inMemory()
        let clock = TestClock()
        let library = Recording(entries: entries(150))

        let first = LibrarySnapshot(library: library, database: database, clock: clock)
        #expect(await first.all().count == 150)
        let afterFirst = library.calls

        // A different instance is a different launch.
        let second = LibrarySnapshot(library: library, database: database, clock: clock)
        #expect(await second.all().count == 150)
        #expect(library.calls == afterFirst, "nothing over the wire the second time")
    }

    @Test("A stale cache is refetched")
    func expires() async throws {
        let database = try AppDatabase.inMemory()
        let clock = TestClock()
        let library = Recording(entries: entries(50))

        _ = await LibrarySnapshot(library: library, database: database, clock: clock).all()
        let afterFirst = library.calls

        clock.advance(by: 7 * 60 * 60)
        _ = await LibrarySnapshot(library: library, database: database, clock: clock).all()
        #expect(library.calls > afterFirst)
    }

    @Test("A write clears the copy on disk, not just the one in memory")
    func invalidateClearsDisk() async throws {
        // A write is exactly when a stale library is most visible: the reader
        // just changed the thing they are looking at.
        let database = try AppDatabase.inMemory()
        let clock = TestClock()
        let library = Recording(entries: entries(50))

        let snapshot = LibrarySnapshot(library: library, database: database, clock: clock)
        _ = await snapshot.all()
        await snapshot.invalidate()
        let afterFirst = library.calls

        _ = await LibrarySnapshot(library: library, database: database, clock: clock).all()
        #expect(library.calls > afterFirst, "the next launch must not read the old copy")
    }

    @Test("A failed walk is never written")
    func failuresAreNotCached() async throws {
        // Otherwise one bad connection freezes an empty library onto the device
        // for six hours.
        let database = try AppDatabase.inMemory()
        let library = Recording(entries: entries(50), failOnPage: 1)

        let snapshot = LibrarySnapshot(library: library, database: database, clock: TestClock())
        let result = await snapshot.load()
        #expect(result.failure != nil)

        let library2 = Recording(entries: entries(50))
        let next = LibrarySnapshot(library: library2, database: database, clock: TestClock())
        #expect(await next.all().count == 50)
        #expect(library2.calls > 0, "nothing was cached, so it had to ask")
    }

    private final class Recording: LibraryProviding, @unchecked Sendable {
        let entries: [LibraryEntry]
        let failOnPage: Int?
        private let lock = NSLock()
        private var counted = 0

        init(entries: [LibraryEntry], failOnPage: Int? = nil) {
            self.entries = entries
            self.failOnPage = failOnPage
        }

        var calls: Int {
            lock.lock(); defer { lock.unlock() }
            return counted
        }

        func libraryPage(page: Int, limit: Int) async throws(APIError) -> [LibraryEntry] {
            bump()
            if page == failOnPage { throw APIError.offline }
            let start = (page - 1) * limit
            guard start < entries.count else { return [] }
            return Array(entries[start..<min(start + limit, entries.count)])
        }

        private func bump() {
            lock.lock(); defer { lock.unlock() }
            counted += 1
        }

        func library(page: Int, limit: Int) async -> [LibraryEntry] {
            (try? await libraryPage(page: page, limit: limit)) ?? []
        }
        func recommendationStatus() async -> RecommendationStatus? { nil }
        func recommendations(
            limit: Int, page: Int, excluding: [Int]
        ) async -> [PersonalRecommendation] { [] }
        func hiddenTagIDs() async -> Set<Int>? { [] }
        func topGenres() async -> [TopGenre] { [] }
        func update(seriesId: Int, change: LibraryChange) async throws(APIError) {}
        func add(seriesId: Int, state: LibraryEntry.State) async throws(APIError) -> Bool { true }
        func remove(seriesId: Int) async throws(APIError) {}
    }
}

/// Derived state is computed when its inputs change, not on every redraw.
@Suite("Library derived state")
@MainActor
struct LibraryDerivedStateTests {
    private func model(_ count: Int) async -> LibraryModel {
        let model = LibraryModel(library: Stub(size: count))
        await model.load()
        return model
    }

    @Test("Changing the filter changes the list")
    func filterRefreshes() async {
        let model = await model(60)
        let all = model.listed.count

        model.filter = .completed
        #expect(model.listed.count < all)
        #expect(model.listed.allSatisfy { $0.state == .completed })

        model.filter = nil
        #expect(model.listed.count == all)
    }

    @Test("Changing the sort reorders the list")
    func sortRefreshes() async {
        let model = await model(60)
        model.sort = .title
        let byTitle = model.listed.map(\.seriesId)

        model.sort = .rating
        #expect(model.listed.map(\.seriesId) != byTitle)
    }

    @Test("Searching narrows the list")
    func searchRefreshes() async {
        let model = await model(60)
        model.searchText = "Series 7"
        #expect(model.listed.count < 60)
        #expect(!model.listed.isEmpty)
    }

    @Test("The jump rail follows the list it indexes")
    func jumpTargetsFollowTheSort() async {
        let model = await model(60)
        model.sort = .title
        let titled = model.jumpTargets.map(\.letter)

        model.filter = .dropped
        #expect(model.jumpTargets.count <= titled.count, "fewer rows, no more letters")
    }

    private final class Stub: LibraryProviding, @unchecked Sendable {
        let size: Int
        init(size: Int) { self.size = size }

        func libraryPage(page: Int, limit: Int) async throws(APIError) -> [LibraryEntry] {
            guard page == 1 else { return [] }
            let states = LibraryEntry.State.allCases
            return (0..<size).map { index in
                LibraryEntry(
                    id: index, seriesId: index, state: states[index % states.count],
                    progressChapter: nil, progressVolume: nil,
                    rating: Double(index % 101), note: nil, startDate: nil,
                    finishDate: nil, numberOfRereads: nil, priority: nil,
                    isPrivate: nil, readLink: nil,
                    series: SeriesFactory.make(id: index, title: "Series \(index)")
                )
            }
        }

        func library(page: Int, limit: Int) async -> [LibraryEntry] {
            (try? await libraryPage(page: page, limit: limit)) ?? []
        }
        func recommendationStatus() async -> RecommendationStatus? { nil }
        func recommendations(
            limit: Int, page: Int, excluding: [Int]
        ) async -> [PersonalRecommendation] { [] }
        func hiddenTagIDs() async -> Set<Int>? { [] }
        func topGenres() async -> [TopGenre] { [] }
        func update(seriesId: Int, change: LibraryChange) async throws(APIError) {}
        func add(seriesId: Int, state: LibraryEntry.State) async throws(APIError) -> Bool { true }
        func remove(seriesId: Int) async throws(APIError) {}
    }
}
