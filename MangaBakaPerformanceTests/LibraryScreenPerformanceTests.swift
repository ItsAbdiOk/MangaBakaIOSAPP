import XCTest
@testable import MangaBaka

/// The work the Library and Reading screens do on every redraw.
///
/// SwiftUI evaluates a view's body far more often than a person changes
/// anything, so anything expensive written as a computed property is paid over
/// and over. These measure the four that a real library actually runs through:
/// the filtered list, the shape bar's counts, the jump index, and the tag
/// verdicts.
///
/// A thousand entries, because Abdi's library is 939 and that is the size at
/// which none of this is free any more.
final class LibraryScreenPerformanceTests: XCTestCase {
    private static let size = 1_000

    private func tags(_ count: Int) -> [SeriesTag] {
        (0..<count).map { index in
            SeriesTag(
                id: index, name: "Tag \(index)", namePath: nil, isGenre: false,
                isSpoiler: false, isExplicit: false, impliedByTagIds: nil,
                contentRating: nil, weight: "core", seriesCount: nil
            )
        }
    }

    /// A library shaped like a real one: every state represented, most entries
    /// carrying a realistic number of tags.
    private func library(tagsEach: Int = 40) -> [LibraryEntry] {
        let states = LibraryEntry.State.allCases
        let pool = tags(120)
        return (0..<Self.size).map { index in
            let slice = Array(pool[(index % 60)..<min((index % 60) + tagsEach, pool.count)])
            return LibraryEntry(
                id: index, seriesId: index, state: states[index % states.count],
                progressChapter: Double(index % 200), progressVolume: nil,
                rating: Double(index % 101), note: nil, startDate: nil,
                finishDate: nil, numberOfRereads: nil, priority: nil,
                isPrivate: nil, readLink: nil,
                series: Series(
                    id: index, state: "active", mergedWith: nil, titles: nil,
                    cover: Cover(raw: nil, x150: nil, x250: nil, x350: nil,
                                 blurhash: nil, width: nil, height: nil),
                    description: nil, authors: nil, artists: nil,
                    status: index % 3 == 0 ? "completed" : "releasing",
                    rating: nil, type: "manhwa", contentRating: nil,
                    totalChapters: Double(200 + index % 50), finalVolume: nil,
                    publishers: nil, anime: nil, source: nil, year: nil,
                    ratingCount: nil, tags: nil, tagsV2: slice
                )
            )
        }
    }

    /// What is waiting, and what ended quietly. Both walk the whole library.
    func testWaitingAndNearlyFinished() {
        let rows = library()
        measure {
            _ = ReadingInsights.waiting(in: rows)
            _ = ReadingInsights.nearlyFinished(in: rows)
        }
    }

    /// The heaviest thing on the Reading screen: every tag of every read series,
    /// tallied. A thousand entries at forty tags each is forty thousand
    /// dictionary touches, and it is written as a computed property.
    func testTagVerdicts() {
        let rows = library()
        measure {
            _ = ReadingInsights.verdicts(in: rows)
        }
    }

    /// Chapters and hours. Cheap, but on the same screen and in the same body.
    func testReadingTotals() {
        let rows = library()
        measure {
            _ = ReadingInsights.chaptersRead(in: rows)
            _ = ReadingInsights.hoursRead(in: rows)
        }
    }

    /// What the Library screen holds in memory once it has the whole library.
    ///
    /// The entries carry their whole series each, tags included — which is why
    /// the same data is 24.7 MB over the wire.
    func testLibraryFootprint() {
        measure(metrics: [XCTMemoryMetric()]) {
            let rows = library()
            XCTAssertEqual(rows.count, Self.size)
        }
    }
}

/// The same work, as the screens actually run it.
///
/// The measurements above are the cost of the calculations. These are the cost
/// of a redraw — which is the number that matters, because SwiftUI evaluates a
/// body far more often than a person changes anything.
final class RedrawPerformanceTests: XCTestCase {
    @MainActor
    func testLibraryRedraw() async {
        let model = LibraryModel(library: BigLibrary(size: 1_000))
        await model.load()

        // What a body pass touches: the filtered list, the shape bar, the jump
        // rail. Stored now, so this is reading three properties rather than
        // sorting a thousand entries.
        measure {
            for _ in 0..<50 {
                _ = model.listed.count
                _ = model.shape.count
                _ = model.jumpTargets.count
            }
        }
    }

    @MainActor
    func testFilterChange() async {
        let model = LibraryModel(library: BigLibrary(size: 1_000))
        await model.load()

        // Changing a filter is when the work is genuinely needed, and it is the
        // one moment a reader is waiting on it.
        measure {
            model.filter = .completed
            model.filter = nil
        }
    }

    private final class BigLibrary: LibraryProviding, @unchecked Sendable {
        let size: Int
        init(size: Int) { self.size = size }

        func libraryPage(page: Int, limit: Int) async throws(APIError) -> [LibraryEntry] {
            let start = (page - 1) * limit
            guard start < size else { return [] }
            let states = LibraryEntry.State.allCases
            return (start..<min(start + limit, size)).map { index in
                LibraryEntry(
                    id: index, seriesId: index, state: states[index % states.count],
                    progressChapter: Double(index % 200), progressVolume: nil,
                    rating: Double(index % 101), note: nil, startDate: nil,
                    finishDate: nil, numberOfRereads: nil, priority: nil,
                    isPrivate: nil, readLink: nil,
                    series: Series(
                        id: index, state: "active", mergedWith: nil,
                        titles: [SeriesTitle(
                            language: "en", traits: ["official"],
                            title: "The Series \(index)", isPrimary: true
                        )],
                        cover: Cover(raw: nil, x150: nil, x250: nil, x350: nil,
                                     blurhash: nil, width: nil, height: nil),
                        description: nil, authors: nil, artists: nil,
                        status: "releasing", rating: nil, type: "manhwa",
                        contentRating: nil, totalChapters: 200, finalVolume: nil,
                        publishers: nil, anime: nil, source: nil
                    )
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
