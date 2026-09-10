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
