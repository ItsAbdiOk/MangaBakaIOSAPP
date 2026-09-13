import Foundation
import Testing
@testable import MangaBaka

/// The header line and the "All" pill count the library two different ways
/// — the whole of it, and everything but dropped — and on the simulator
/// (2026-09-13, real account) that put "942 series" a few points above
/// "All 513" with nothing between them saying where the other 429 went.
/// One rule now feeds the line, and these pin it down.
@Suite("Library subtitle agrees with the All pill")
@MainActor
struct LibrarySubtitleTests {
    /// Expected to fail before the fix with: `"942 series · 512 rated" ==
    /// "942 series so far · 429 dropped · 512 rated"` — the old line neither
    /// named the dropped shelf nor said the walk was still going.
    @Test("Mid-walk, the line says 'so far' and names the dropped shelf")
    func midWalkLineIsQualifiedAndReconciles() {
        let line = LibraryModel.subtitle(count: 942, dropped: 429, rated: 512, isComplete: false)
        #expect(line == "942 series so far · 429 dropped · 512 rated")
        // The pill shows `count - dropped`; the line carries both numbers, so
        // the pill's 513 is derivable from it rather than contradicting it.
        #expect(942 - 429 == 513)
    }

    @Test("Once the walk completes, 'so far' goes and the numbers stay")
    func completeLineDropsTheQualifier() {
        let line = LibraryModel.subtitle(count: 942, dropped: 429, rated: 512, isComplete: true)
        #expect(line == "942 series · 429 dropped · 512 rated")
    }

    /// A library with nothing dropped has nothing to reconcile, and a
    /// "0 dropped" segment would be noise on most small libraries.
    @Test("No dropped shelf, no dropped segment")
    func noDroppedSegmentWhenNothingIsDropped() {
        let line = LibraryModel.subtitle(count: 3, dropped: 0, rated: 2, isComplete: true)
        #expect(line == "3 series · 2 rated")
    }

    /// The model-level check: a walk that stops at the page cap is
    /// incomplete, and the stored `subtitle` must carry the qualifier while
    /// `allCount` carries the same rows minus dropped (none here — the
    /// paging stub files everything under reading).
    /// Expected to fail before the fix with: `"1,000 series · 0 rated"` has
    /// no "so far".
    @Test("The stored subtitle reflects an incomplete walk")
    func storedSubtitleSaysSoFarWhileIncomplete() async {
        let model = LibraryModel(library: PagedLibrary(total: 9_000))
        await model.load()
        #expect(!model.isComplete)
        #expect(model.subtitle.contains("so far"), Comment(rawValue: model.subtitle))
        #expect(model.allCount == model.total)
    }

    /// Same stub as `LibraryModelTests.PagedLibrary`; duplicated rather than
    /// shared so this file does not reach into another suite's private types.
    private final class PagedLibrary: LibraryProviding, @unchecked Sendable {
        let total: Int
        init(total: Int) { self.total = total }

        func library(page: Int, limit: Int) async -> [LibraryEntry] {
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
        func recommendationStatus() async throws(APIError) -> RecommendationStatus {
            throw APIError.offline
        }
        func recommendations(
            limit: Int, page: Int, excluding: [Int]
        ) async -> PersonalRecommendations { PersonalRecommendations() }
        func hiddenTagIDs() async -> Set<Int>? { [] }
        func topGenres() async -> [TopGenre]? { [] }
        func update(seriesId: Int, change: LibraryChange) async throws(APIError) {}
        func add(seriesId: Int, state: LibraryEntry.State) async throws(APIError) -> Bool { true }
        func remove(seriesId: Int) async throws(APIError) {}
    }
}
