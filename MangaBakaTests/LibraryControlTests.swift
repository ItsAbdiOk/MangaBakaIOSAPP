import Foundation
import Testing
@testable import MangaBaka

/// Adding, rating and recording progress all existed before this, but only
/// inside a sheet reachable from Library → a shelf → a row. A series found
/// through Discover, Search, the Stack or a Mix could be read about at length
/// and never added to anything. These cover the control that closes that gap.
@Suite("Library control on the detail screen")
@MainActor
struct LibraryControlTests {
    private final class FakeLibrary: LibraryProviding, @unchecked Sendable {
        var entries: [LibraryEntry] = []
        private(set) var added: [(id: Int, state: LibraryEntry.State)] = []
        private(set) var changes: [(id: Int, change: LibraryChange)] = []
        private(set) var removed: [Int] = []
        private(set) var reads = 0
        var failure: APIError?

        func recommendationStatus() async -> RecommendationStatus? { nil }
        func recommendations(
            limit: Int, page: Int, excluding: [Int]
        ) async -> [PersonalRecommendation] { [] }
        func hiddenTagIDs() async -> Set<Int>? { [] }
        func topGenres() async -> [TopGenre] { [] }

        func library(page: Int, limit: Int) async -> [LibraryEntry] {
            reads += 1
            return entries
        }

        func add(seriesId: Int, state: LibraryEntry.State) async throws(APIError) -> Bool {
            if let failure { throw failure }
            added.append((seriesId, state))
            entries.append(Self.entry(seriesId: seriesId, state: state))
            return true
        }

        func update(seriesId: Int, change: LibraryChange) async throws(APIError) {
            if let failure { throw failure }
            changes.append((seriesId, change))
            guard let index = entries.firstIndex(where: { $0.seriesId == seriesId }) else { return }
            let old = entries[index]
            entries[index] = Self.entry(
                seriesId: seriesId,
                state: change.state ?? old.state,
                chapter: change.progressChapter ?? old.progressChapter
            )
        }

        func remove(seriesId: Int) async throws(APIError) {
            if let failure { throw failure }
            removed.append(seriesId)
            entries.removeAll { $0.seriesId == seriesId }
        }

        /// Built directly rather than decoded. These are test doubles standing
        /// in for what the server holds, and going through JSON would only be
        /// testing the decoder, which has its own suite.
        static func entry(
            seriesId: Int,
            state: LibraryEntry.State,
            chapter: Double? = nil
        ) -> LibraryEntry {
            LibraryEntry(
                id: seriesId,
                seriesId: seriesId,
                state: state,
                progressChapter: chapter,
                progressVolume: nil,
                rating: nil,
                note: nil,
                startDate: nil,
                finishDate: nil,
                numberOfRereads: nil,
                priority: nil,
                isPrivate: nil,
                readLink: nil,
                series: nil
            )
        }
    }

    private func model(_ library: FakeLibrary, id: Int = 7) -> LibraryControlModel {
        LibraryControlModel(library: library, store: LibraryModel(library: library), seriesId: id)
    }

    /// The control renders nothing until the library has answered. Flashing
    /// "Add to library" at someone who already has the series saved, then
    /// swapping it for their real state, reads as the app losing their data.
    @Test("Nothing is claimed about a series before the library has answered")
    func unknownUntilLoaded() async {
        let library = FakeLibrary()
        let subject = model(library)
        #expect(!subject.isKnown)
        #expect(subject.current == nil)

        await subject.load()
        #expect(subject.isKnown)
        #expect(subject.current == nil)
    }

    @Test("A series already in the library shows its real state, not Add")
    func findsExistingEntry() async {
        let library = FakeLibrary()
        library.entries = [FakeLibrary.entry(seriesId: 7, state: .reading, chapter: 12)]
        let subject = model(library)

        await subject.load()
        #expect(subject.current?.state == .reading)
        #expect(subject.current?.progressChapter == 12)
    }

    /// The library is paged with no by-series lookup, so the read is the
    /// expensive part. Re-reading on every redraw would hammer a rate limit
    /// shared with strangers.
    /// The shared store pages once and caches; the control must not restart
    /// that on every redraw. Re-reading a 937-entry library ten pages at a time
    /// per series page opened would spend a rate limit shared with strangers.
    @Test("The library is paged once, not on every redraw")
    func loadIsIdempotent() async {
        let library = FakeLibrary()
        let subject = model(library)
        await subject.load()
        let afterFirst = library.reads
        await subject.load()
        await subject.load()
        #expect(library.reads == afterFirst)
    }

    @Test("Adding writes the chosen state and re-reads what the server holds")
    func addsWithChosenState() async {
        let library = FakeLibrary()
        let subject = model(library)
        await subject.load()

        await subject.add(state: .planToRead)
        #expect(library.added.map(\.state) == [.planToRead])
        #expect(subject.current?.state == .planToRead)
        #expect(subject.failure == nil)
    }

    /// One tap for the commonest edit there is. The value has to come from what
    /// the server holds, not from a counter the view keeps.
    @Test("Plus one advances from the stored chapter")
    func advancesChapter() async {
        let library = FakeLibrary()
        library.entries = [FakeLibrary.entry(seriesId: 7, state: .reading, chapter: 12)]
        let subject = model(library)
        await subject.load()

        await subject.advanceChapter()
        #expect(library.changes.count == 1)
        #expect(library.changes[0].change.progressChapter == .some(13))
        #expect(subject.current?.progressChapter == 13)
    }

    /// An entry with no progress recorded starts at one, not at two and not at
    /// nothing.
    @Test("Plus one on an unread entry records chapter 1")
    func advancesFromNothing() async {
        let library = FakeLibrary()
        library.entries = [FakeLibrary.entry(seriesId: 7, state: .reading)]
        let subject = model(library)
        await subject.load()

        await subject.advanceChapter()
        #expect(library.changes[0].change.progressChapter == .some(1))
    }

    /// Nothing to advance and nothing to guess at. Writing chapter 1 against a
    /// series the reader never saved would invent an entry they did not ask for.
    @Test("Plus one does nothing for a series that is not in the library")
    func advanceNeedsAnEntry() async {
        let library = FakeLibrary()
        let subject = model(library)
        await subject.load()

        await subject.advanceChapter()
        #expect(library.changes.isEmpty)
    }

    /// A PATCH merges, so sending a field the reader did not touch overwrites
    /// it. An empty change must never reach the network at all.
    @Test("An empty change is never sent")
    func emptyChangeIsNotSent() async {
        let library = FakeLibrary()
        library.entries = [FakeLibrary.entry(seriesId: 7, state: .reading)]
        let subject = model(library)
        await subject.load()

        let failure = await subject.apply(LibraryChange())
        #expect(failure == nil)
        #expect(library.changes.isEmpty)
    }

    @Test("A failed add says so rather than looking as though it worked")
    func failureIsReported() async {
        let library = FakeLibrary()
        library.failure = .offline
        let subject = model(library)
        await subject.load()

        await subject.add(state: .reading)
        #expect(subject.failure != nil)
        #expect(subject.current == nil)
    }

    @Test("Removing leaves the control offering to add it back")
    func removeReturnsToAdd() async {
        let library = FakeLibrary()
        library.entries = [FakeLibrary.entry(seriesId: 7, state: .dropped)]
        let subject = model(library)
        await subject.load()

        await subject.remove()
        #expect(library.removed == [7])
        #expect(subject.isKnown)
        #expect(subject.current == nil)
    }
}

/// The control has to be on the screen the reader is actually looking at, and
/// every library state has to be offerable. A wired-up model behind an
/// unreachable view is the exact bug this closes.
@Suite("Library control is reachable", .enabled(if: SourceTree.isAvailable))
struct LibraryControlReachabilityTests {
    @Test("The detail screen carries the control")
    func detailShowsIt() throws {
        let source = try SourceTree.read("MangaBaka/Features/Detail/SeriesDetailView.swift")
        #expect(source.contains("LibraryControl(series: series, library: library, store: libraryStore)"))
    }

    @Test("Every library state can be chosen when adding")
    func everyStateOffered() throws {
        let source = try SourceTree.read("MangaBaka/Features/Detail/LibraryControl.swift")
        #expect(source.contains("LibraryEntry.State.allCases"))
        #expect(source.contains("LibraryEditSheet(entry: entry, series: series)"))
    }
}
