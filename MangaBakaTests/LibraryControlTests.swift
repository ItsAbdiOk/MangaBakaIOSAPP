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
        /// Set to make the *walk itself* fail — distinct from `failure`,
        /// which only affects `add`/`update`/`remove` — so a test can prove
        /// gap 86: the control must not read "not in the library" out of a
        /// walk that never actually got anywhere.
        var walkFailure: APIError?

        func recommendationStatus() async throws(APIError) -> RecommendationStatus {
            throw APIError.offline
        }
        func recommendations(
            limit: Int, page: Int, excluding: [Int]
        ) async -> PersonalRecommendations { PersonalRecommendations() }
        func hiddenTagIDs() async -> Set<Int>? { [] }
        func topGenres() async -> [TopGenre]? { [] }

        func library(page: Int, limit: Int) async -> [LibraryEntry] {
            reads += 1
            return entries
        }

        func libraryPage(page: Int, limit: Int) async throws(APIError) -> [LibraryEntry] {
            if let walkFailure { throw walkFailure }
            return await library(page: page, limit: limit)
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

    /// Gap 86: `isKnown && current == nil` used to be indistinguishable from
    /// "the walk finished and this series genuinely is not saved" — which is
    /// exactly what a walk that never got anywhere also looks like from
    /// `entries.first { … }` against an empty array. A series the reader
    /// already has, opened while offline, offered "Add to library" live.
    @Test("A failed walk is reported as unknown, not as 'not in the library'")
    func failedWalkIsUnknown() async {
        let library = FakeLibrary()
        library.walkFailure = .offline
        let subject = model(library)

        await subject.load()
        #expect(!subject.isKnown, "today this reads isKnown == true — the bug")
        #expect(subject.current == nil)
        #expect(subject.checkFailure == .offline)
    }

    /// The retry `InlineFailure` offers has to actually walk again, not sit on
    /// the first failure forever.
    @Test("Retrying after a failed walk asks again")
    func retryAsksAgain() async {
        let library = FakeLibrary()
        library.walkFailure = .offline
        let subject = model(library)
        await subject.load()
        #expect(subject.checkFailure == .offline)

        library.walkFailure = nil
        library.entries = [FakeLibrary.entry(seriesId: 7, state: .reading, chapter: 3)]
        await subject.load()
        #expect(subject.checkFailure == nil)
        #expect(subject.current?.progressChapter == 3)
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

    /// Gap 87/96(j): a write used to trigger `refresh()` — a full re-walk of
    /// the shared library, 13 requests on a real account — just to reflect
    /// one changed field, and if that walk failed partway the control
    /// flipped from "Reading · ch 68" back to "Add to library" despite the
    /// write itself having landed. `apply(_:)` now patches the entry in
    /// place through `LibraryModel.apply(_:to:)` and never re-reads a page at
    /// all: `library.reads` — bumped once per page `library(page:limit:)`
    /// answers — must not move after a write.
    @Test("A write patches the entry in place; it never re-walks the library")
    func writeNeverReWalks() async {
        let library = FakeLibrary()
        library.entries = [FakeLibrary.entry(seriesId: 7, state: .reading, chapter: 68)]
        let subject = model(library)
        await subject.load()
        let readsAfterLoad = library.reads

        await subject.advanceChapter()
        #expect(subject.current?.progressChapter == 69, "the write should be visible immediately")
        #expect(
            library.reads == readsAfterLoad,
            "a write should never trigger another page read of the library"
        )
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
        let source = try SourceTree.read("MangaBaka/Features/Detail/SeriesDetailView+Actions.swift")
        // `shown`, not `series`: the merged series — see SeriesMergeTests. A
        // control handed a lean copy would offer to add a series whose chapter
        // count and status it does not know.
        #expect(source.contains("LibraryControl(series: shown, library: library, store: libraryStore)"))
    }

    @Test("Every library state can be chosen when adding")
    func everyStateOffered() throws {
        let source = try SourceTree.read("MangaBaka/Features/Detail/LibraryControl.swift")
        #expect(source.contains("LibraryEntry.State.allCases"))
        #expect(source.contains("LibraryEditSheet(entry: entry, series: series)"))
    }
}

/// Second-pass review (2026-09-14): item 31, the no-account state that was
/// computed and never read, and item 72, the two writes that never reached
/// the shared store. In an extension so the suite body stays under the
/// lint's ceiling; `FakeLibrary` is file-private and reachable from here.
extension LibraryControlTests {
    /// Item 31. `needsAccount` was set and read nowhere, so a reader with no
    /// token got no button and no line saying why. The decision now has a
    /// name the body switches on.
    ///
    /// Expected to fail before the fix: `LibraryControlModel.ControlState`
    /// does not exist — a compile failure. The old model exposed no value a
    /// test could have asserted was wrong: `needsAccount` was true, and the
    /// body simply did not look at it.
    @Test("No account is a state the control names, not silence")
    func noAccountIsNamed() async {
        let library = FakeLibrary()
        let store = LibraryModel(library: library, hasCredentials: { false })
        let subject = LibraryControlModel(library: library, store: store, seriesId: 7)
        #expect(subject.state == .unknown, "control: nothing is claimed before the store answers")

        await subject.load()
        #expect(store.screenState == .noAccount, "control: the store itself says no account")
        #expect(subject.state == .noAccount)
        #expect(subject.current == nil)
        #expect(!LibraryControlModel.noAccountLine.isEmpty)
    }

    @Test("The states rank: a saved entry, then a failed check, then no account, then Add")
    func stateOrder() async {
        let library = FakeLibrary()
        library.entries = [FakeLibrary.entry(seriesId: 7, state: .reading)]
        let subject = model(library)
        await subject.load()
        guard case let .saved(entry) = subject.state else {
            Issue.record("a listed series is .saved, got \(subject.state)")
            return
        }
        #expect(entry.seriesId == 7)

        let other = model(library, id: 9)
        await other.load()
        #expect(other.state == .canAdd)
    }

    /// Item 72. `add` used to patch only the control's own `entry`, so the
    /// Library tab did not list the series until its next walk.
    ///
    /// Expected to fail before the fix with: `store.entries.map(\.seriesId)
    /// == []` — the store still empty after the add.
    @Test("Adding from a series page lists it on the Library tab now")
    func addReachesTheStore() async {
        let library = FakeLibrary()
        let store = LibraryModel(library: library)
        let subject = LibraryControlModel(library: library, store: store, seriesId: 7)
        await subject.load()
        #expect(store.entries.isEmpty, "control")

        await subject.add(state: .planToRead)
        #expect(store.entries.map(\.seriesId) == [7])
        #expect(store.entries.first?.state == .planToRead)
        #expect(store.shelves.map(\.state) == [.planToRead])
        #expect(subject.current?.id == LibraryControlModel.placeholderID(for: 7),
                "the placeholder id, until the next walk brings the server's")
    }

    /// Expected to fail before the fix with: `store.entries.map(\.seriesId)
    /// == [7]` — the removed series still on the shelf.
    @Test("Removing from a series page takes it off the Library tab now")
    func removeReachesTheStore() async {
        let library = FakeLibrary()
        library.entries = [FakeLibrary.entry(seriesId: 7, state: .reading)]
        let store = LibraryModel(library: library)
        let subject = LibraryControlModel(library: library, store: store, seriesId: 7)
        await subject.load()
        #expect(store.entries.map(\.seriesId) == [7], "control")

        await subject.remove()
        #expect(store.entries.isEmpty)
        #expect(store.shelves.isEmpty)
        #expect(subject.current == nil)
    }

    /// A failed write reaches neither.
    @Test("A refused add or remove changes nothing on the Library tab")
    func refusedWriteChangesNothing() async {
        let library = FakeLibrary()
        library.entries = [FakeLibrary.entry(seriesId: 7, state: .reading)]
        library.failure = .offline
        let store = LibraryModel(library: library)
        let subject = LibraryControlModel(library: library, store: store, seriesId: 7)
        await subject.load()

        await subject.remove()
        #expect(store.entries.map(\.seriesId) == [7])
        #expect(subject.current?.seriesId == 7)
        #expect(subject.failure != nil)
    }
}
