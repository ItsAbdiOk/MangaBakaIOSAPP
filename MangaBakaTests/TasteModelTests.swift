import Foundation
import Testing
@testable import MangaBaka

/// The taste profile counts the reader's own library. Nothing here is inferred,
/// so the arithmetic has to be right or the screen states something false about
/// someone.
@Suite("Taste profile")
@MainActor
struct TasteModelTests {
    private final class StubLibrary: LibraryProviding, @unchecked Sendable {
        var genres: [TopGenre] = []
        func topGenres() async -> [TopGenre]? { genres }
        func recommendationStatus() async -> RecommendationStatus? { nil }
        func recommendations(
            limit: Int, page: Int, excluding: [Int]
        ) async -> [PersonalRecommendation] { [] }
        func library(page: Int, limit: Int) async -> [LibraryEntry] { [] }
        func hiddenTagIDs() async -> Set<Int>? { [] }
        func update(seriesId: Int, change: LibraryChange) async throws(APIError) {}
        func add(seriesId: Int, state: LibraryEntry.State) async throws(APIError) -> Bool { true }
        func remove(seriesId: Int) async throws(APIError) {}
    }

    private func entry(_ id: Int, _ state: LibraryEntry.State, rating: Double?) throws -> LibraryEntry {
        try Fixture.decoder().decode(LibraryEntry.self, from: Data("""
        {"id":\(id),"series_id":\(id),"state":"\(state.rawValue)",
         "rating":\(rating.map { String($0) } ?? "null")}
        """.utf8))
    }

    private func model(_ entries: [LibraryEntry], genres: [TopGenre] = []) async -> TasteModel {
        let library = StubLibrary()
        library.genres = genres
        let model = TasteModel(library: library)
        await model.load(entries: entries)
        return model
    }

    /// Ratings are stored 0-100 but land on 20/40/60/80/100. Bucketing to five
    /// is the only honest reading of that.
    @Test("Ratings bucket into five steps")
    func bucketsRatings() async throws {
        let entries = [
            try entry(1, .dropped, rating: 20),
            try entry(2, .dropped, rating: 20),
            try entry(3, .completed, rating: 100),
            try entry(4, .completed, rating: nil)
        ]
        let subject = await model(entries)

        #expect(subject.ratingHistogram == [2, 0, 0, 0, 1])
        #expect(subject.ratedCount == 3, "an unrated entry is not a zero-star rating")
    }

    /// A stray 50 exists in the real data. It has to land somewhere sensible
    /// rather than crashing or falling outside the five.
    @Test("An off-step rating still lands inside the five")
    func offStepRating() async throws {
        let subject = await model([try entry(1, .dropped, rating: 50)])
        #expect(subject.ratingHistogram.reduce(0, +) == 1)
        #expect(subject.ratingHistogram[2] == 1, "50 rounds to the middle step")
    }

    /// On the real library the commonest rating is the LOWEST one, which is the
    /// interesting part and must not be quietly presented as the highest.
    @Test("The commonest rating is reported even when it is the lowest")
    func commonestCanBeLowest() async throws {
        let entries = try (1...5).map { try entry($0, .dropped, rating: 20) }
            + [try entry(9, .completed, rating: 100)]
        let subject = await model(entries)

        #expect(subject.commonestRating == 1)
        let line = try #require(subject.ratingLine)
        #expect(line.contains("one star"))
        #expect(line.contains("83%"))
    }

    @Test("With nothing rated there is no rating line rather than a zero")
    func noRatingsNoLine() async throws {
        let subject = await model([try entry(1, .dropped, rating: nil)])
        #expect(subject.ratingLine == nil)
        #expect(subject.commonestRating == nil)
    }

    /// The shape line names the biggest shelf, which on a real library is
    /// "Dropped" — the screen should say so rather than lead with reading.
    @Test("The shape line names the biggest shelf and its share")
    func shapeLine() async throws {
        let entries = try (1...9).map { try entry($0, .dropped, rating: nil) }
        let subject = await model(entries + [try entry(10, .reading, rating: nil)])

        let line = try #require(subject.shapeLine)
        #expect(line.contains("Dropped"))
        #expect(line.contains("90%"))
    }

    @Test("An empty library says nothing rather than dividing by zero")
    func emptyLibrary() async {
        let subject = await model([])
        #expect(subject.shapeLine == nil)
        #expect(subject.ratingLine == nil)
        #expect(!subject.hasAnything)
    }
}
