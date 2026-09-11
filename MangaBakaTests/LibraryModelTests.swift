import Foundation
import Testing
@testable import MangaBaka

/// How the library is arranged, which is the one design decision on that screen
/// with a measurement behind it.
@Suite("Library shelves")
@MainActor
struct LibraryModelTests {
    private func entry(
        _ id: Int,
        _ state: LibraryEntry.State,
        chapter: Double? = nil,
        rating: Double? = nil,
        note: String? = nil,
        total: Double? = nil
    ) throws -> LibraryEntry {
        let noteJSON = note.map { "\"\($0)\"" } ?? "null"
        let ratingJSON = rating.map { String($0) } ?? "null"
        let chapterJSON = chapter.map { String($0) } ?? "null"
        let totalJSON = total.map { ",\"total_chapters\":\($0)" } ?? ""
        return try Fixture.decoder().decode(LibraryEntry.self, from: Data("""
        {"id":\(id),"series_id":\(id),"state":"\(state.rawValue)",
         "progress_chapter":\(chapterJSON),"rating":\(ratingJSON),"note":\(noteJSON),
         "Series":{"id":\(id),"state":"active","cover":{}\(totalJSON),
                   "titles":[{"language":"en","traits":["official"],
                              "title":"S\(id)","is_primary":true}]}}
        """.utf8))
    }

    /// The measurement that settled this: 46% of a real library is dropped and
    /// 8% is being read. Reading-order shelves would put a 71-item shelf above
    /// a 429-item one and misrepresent the library.
    @Test("Shelves are ordered by size, not by reading order")
    func shelvesAreSizeOrdered() throws {
        let entries =
            (try (1...5).map { try entry($0, .dropped) })
            + (try (10...12).map { try entry($0, .paused) })
            + [try entry(20, .reading)]

        let shelves = LibraryModel.shelves(from: entries)
        #expect(shelves.map(\.state) == [.dropped, .paused, .reading])
        #expect(shelves.map(\.count) == [5, 3, 1])
    }

    /// Every shelf's note should say something true about its contents rather
    /// than restate its name.
    @Test("A shelf note is built from what is on it")
    func noteDescribesContents() throws {
        let dropped = [
            try entry(1, .dropped, note: "lost the plot"),
            try entry(2, .dropped)
        ]
        let shelf = try #require(LibraryModel.shelves(from: dropped).first)
        #expect(shelf.note.contains("1"), "should count the notes it actually has")
    }

    /// Paused put 226 series in "pick back up" on a real library. Pausing is a
    /// deliberate act of setting something down, not an invitation.
    @Test("Pick back up is reading and rereading only, and needs real progress")
    func inProgressNeedsProgress() async throws {
        let model = LibraryModel(library: StubLibrary(entries: [
            try entry(1, .reading, chapter: 17),
            try entry(2, .reading),
            try entry(3, .completed, chapter: 40),
            try entry(4, .paused, chapter: 22),
            try entry(5, .rereading, chapter: 3)
        ]))
        await model.load()

        #expect(model.inProgress.map(\.seriesId).sorted() == [1, 5])
    }

    /// The subtitle used to count shelves. It counts what is rated now: the
    /// shape bar says how the library is divided far better than a number of
    /// shelves did, and how much of it you have formed an opinion on is a thing
    /// nothing else on the screen answers.
    @Test("The subtitle says how much of the library is rated")
    func subtitleCountsRatings() async throws {
        let model = LibraryModel(library: StubLibrary(entries: [
            try entry(1, .reading, rating: 80),
            try entry(2, .dropped),
            try entry(3, .completed, rating: 100)
        ]))
        await model.load()

        #expect(model.subtitle == "3 series · 2 rated")
    }

    @Test("An empty library says so rather than counting to zero")
    func emptySubtitle() async throws {
        let model = LibraryModel(library: StubLibrary(entries: []))
        await model.load()
        #expect(model.subtitle == "Nothing here yet")
    }

    /// The closing line states the shape of the library rather than flattering
    /// it.
    @Test("The shape line reports reading against the whole library")
    func shapeLine() async throws {
        let model = LibraryModel(library: StubLibrary(entries:
            (try (1...9).map { try entry($0, .dropped) }) + [try entry(10, .reading)]
        ))
        await model.load()

        let line = try #require(model.shapeLine)
        #expect(line.contains("Reading is 1 of 10"))
    }

    @Test("No entries reads as no account rather than an empty library")
    func noAccount() async throws {
        let model = LibraryModel(library: StubLibrary(entries: []))
        await model.load()
        #expect(!model.hasAccount)
    }

    @Test("A library past a thousand entries loads all of it")
    func loadsPastTheOldCeiling() async throws {
        // 1,204, the number the design board uses. The old loop stopped at ten
        // pages of a hundred, so anything past 1,000 vanished with no error —
        // and Abdi's own library is 937, sixty-four short of that ceiling.
        let paged = PagedLibrary(total: 1_204)
        let model = LibraryModel(library: paged)
        await model.load()

        #expect(model.entries.count == 1_204)
        #expect(model.isComplete, "a library that fits inside the cap is complete")
    }

    @Test("A library past even the new cap says it is incomplete")
    func admitsTruncation() async throws {
        // The cap exists so a misbehaving server cannot spin this loop forever.
        // What matters is that hitting it is admitted rather than presented as
        // the whole library — the mistake that once offered "Add to library"
        // for a series already in it.
        let model = LibraryModel(library: PagedLibrary(total: 9_000))
        await model.load()

        #expect(!model.isComplete)
    }

    /// A library that actually pages, unlike `StubLibrary`.
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

/// The dropped shelf's filters, which are the reason that shelf is navigable at
/// 429 items.
@Suite("Dropped filters")
struct DroppedFilterTests {
    private func entry(chapter: Double?, rating: Double?, note: String?) throws -> LibraryEntry {
        let noteJSON = note.map { "\"\($0)\"" } ?? "null"
        let chapterJSON = chapter.map { String($0) } ?? "null"
        let ratingJSON = rating.map { String($0) } ?? "null"
        return try Fixture.decoder().decode(LibraryEntry.self, from: Data("""
        {"id":1,"series_id":1,"state":"dropped",
         "progress_chapter":\(chapterJSON),"rating":\(ratingJSON),"note":\(noteJSON)}
        """.utf8))
    }

    @Test("Has a note matches only entries carrying one")
    func hasNote() throws {
        #expect(ShelfDetailView.Filter.hasNote.matches(
            try entry(chapter: nil, rating: nil, note: "gave up")
        ))
        #expect(!ShelfDetailView.Filter.hasNote.matches(
            try entry(chapter: nil, rating: nil, note: nil)
        ))
        #expect(!ShelfDetailView.Filter.hasNote.matches(
            try entry(chapter: nil, rating: nil, note: "")
        ))
    }

    @Test("Never rated matches only unrated entries")
    func neverRated() throws {
        #expect(ShelfDetailView.Filter.neverRated.matches(
            try entry(chapter: 5, rating: nil, note: nil)
        ))
        #expect(!ShelfDetailView.Filter.neverRated.matches(
            try entry(chapter: 5, rating: 40, note: nil)
        ))
    }

    /// "Left before ch 10" means started and abandoned early. Something never
    /// opened at all is a different thing and should not match.
    @Test("Left early excludes what was never started")
    func leftEarly() throws {
        #expect(ShelfDetailView.Filter.leftEarly.matches(
            try entry(chapter: 4, rating: nil, note: nil)
        ))
        #expect(!ShelfDetailView.Filter.leftEarly.matches(
            try entry(chapter: nil, rating: nil, note: nil)
        ))
        #expect(!ShelfDetailView.Filter.leftEarly.matches(
            try entry(chapter: 40, rating: nil, note: nil)
        ))
    }
}

/// A filter that can never match anything is a control that does nothing.
@Suite("Shelf filters offered")
struct ShelfFilterAvailabilityTests {
    private func entry(note: String?) throws -> LibraryEntry {
        let noteJSON = note.map { "\"\($0)\"" } ?? "null"
        return try Fixture.decoder().decode(LibraryEntry.self, from: Data("""
        {"id":1,"series_id":1,"state":"dropped","note":\(noteJSON)}
        """.utf8))
    }

    /// Measured on the real library: one entry of 937 carries a note, and none
    /// of them are on the dropped shelf, so the chip read "Has a note 0".
    @Test("A filter matching nothing is not offered")
    func emptyFilterIsHidden() throws {
        let none = [try entry(note: nil), try entry(note: "")]
        #expect(!none.contains(where: ShelfDetailView.Filter.hasNote.matches))

        let some = [try entry(note: "gave up"), try entry(note: nil)]
        #expect(some.contains(where: ShelfDetailView.Filter.hasNote.matches))
    }
}

/// Searching your own library, which at 937 entries is the difference between
/// a list and an archive.
@Suite("Library search")
@MainActor
struct LibrarySearchTests {
    private func entry(_ id: Int, _ title: String, _ state: LibraryEntry.State) throws -> LibraryEntry {
        try Fixture.decoder().decode(LibraryEntry.self, from: Data("""
        {"id":\(id),"series_id":\(id),"state":"\(state.rawValue)",
         "Series":{"id":\(id),"state":"active","cover":{},
                   "titles":[{"language":"en","traits":["official"],
                              "title":"\(title)","is_primary":true}]}}
        """.utf8))
    }

    private func model(_ entries: [LibraryEntry]) async -> LibraryModel {
        let model = LibraryModel(library: Stub(entries: entries))
        await model.load()
        return model
    }

    private final class Stub: LibraryProviding, @unchecked Sendable {
        let entries: [LibraryEntry]
        init(entries: [LibraryEntry]) { self.entries = entries }
        func library(page: Int, limit: Int) async -> [LibraryEntry] { page == 1 ? entries : [] }
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

    @Test("An empty search shows every shelf unchanged")
    func emptySearchShowsAll() async throws {
        let subject = await model([
            try entry(1, "Solo Leveling", .reading),
            try entry(2, "Omniscient Reader", .dropped)
        ])
        #expect(!subject.isSearching)
        #expect(subject.visibleShelves.count == 2)
    }

    /// Results stay grouped by shelf, so a hit keeps the context of where it
    /// lives — which is most of what a library search is for.
    @Test("A search narrows shelves and drops the empty ones")
    func narrowsAndDrops() async throws {
        let subject = await model([
            try entry(1, "Solo Leveling", .reading),
            try entry(2, "Omniscient Reader", .dropped),
            try entry(3, "Solo Max-Level Newbie", .dropped)
        ])
        subject.searchText = "solo"

        #expect(subject.isSearching)
        #expect(subject.matchCount == 2)
        // Reading has one match, dropped has one; the shelf with none is gone.
        #expect(Set(subject.visibleShelves.map(\.state)) == [.reading, .dropped])
        #expect(subject.visibleShelves.allSatisfy { !$0.entries.isEmpty })
    }

    @Test("Matching ignores case and whitespace around the query")
    func matchingIsForgiving() async throws {
        let subject = await model([try entry(1, "Solo Leveling", .reading)])
        subject.searchText = "  LEVELING  "
        #expect(subject.matchCount == 1)
    }

    /// A search matching nothing is a real answer, not an empty library.
    @Test("No matches reports zero rather than falling back to everything")
    func noMatches() async throws {
        let subject = await model([try entry(1, "Solo Leveling", .reading)])
        subject.searchText = "berserk"
        #expect(subject.matchCount == 0)
        #expect(subject.visibleShelves.isEmpty)
    }
}
