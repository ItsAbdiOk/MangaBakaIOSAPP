import Foundation
import Testing
@testable import MangaBaka

/// The round-2 review's library findings: the edit lost mid-walk, the
/// discarded walk that still commits, the page-cap copy shown during a healthy
/// walk, the stale failure bar, and the duplicate id that traps a dictionary.
///
/// A separate file from `LibraryModelPagingTests` only to keep both under
/// SwiftLint's `file_length`; the stubs here are gated where those are not.
@Suite("Library walk, round two")
@MainActor
struct LibraryWalkRoundTwoTests {
    // MARK: - Work-list 4: the page-cap copy during a healthy walk

    /// `isLoading` goes false when the *first* page lands — that is what makes
    /// the screen appear in 270 ms instead of three and a half seconds — so
    /// `LibraryView.partialLoad` read it as "the walk is over" and fell
    /// through to "Showing the first 100" for every page after the first.
    ///
    /// Expected to fail before the fix with: `value of type 'LibraryModel' has
    /// no member 'isWalking'`. With `isWalking` stubbed as a constant `false`
    /// it fails instead on `#expect(observed.isWalking)`.
    @Test("A walk still fetching pages says so, even after the first page is drawn")
    func walkingIsNotLoading() async throws {
        let library = GatedLibrary(total: 300, gateAfterPage: 1)
        let model = LibraryModel(library: library, snapshot: LibrarySnapshot(library: library))
        let walk = Task { await model.load() }

        let observed = await library.waitForGate()
        #expect(!model.isLoading, "the first page is drawn, so the spinner is done")
        #expect(model.isWalking, "but pages 2 and 3 have not landed")
        #expect(observed.entries == 100)

        library.openGate()
        await walk.value
        #expect(!model.isWalking)
        #expect(model.isComplete)
    }

    // MARK: - Work-list 5: the stale failure bar through a retry

    /// Expected to fail before the fix with: `partialFailure` still
    /// `.offline` after `reload()` had drawn its first clean page — the bar
    /// said "Some of your library didn't load" through the whole new walk.
    @Test("Retry clears the previous walk's failure before the new one starts")
    func reloadClearsTheStaleFailure() async throws {
        let library = FlakyLibrary(total: 300, failOnPage: 3)
        let model = LibraryModel(library: library, snapshot: LibrarySnapshot(library: library))
        await model.load()
        #expect(model.partialFailure == .offline)

        library.failOnPage = nil
        await model.reload()
        #expect(model.failure == nil)
        #expect(model.partialFailure == nil)
        #expect(model.entries.count == 300)
    }

    // MARK: - Work-list 15: an edit saved between two pages

    /// The walk assigns `entries = rows` per page, so a patch applied between
    /// two pages was overwritten by the next one — and the snapshot then
    /// cached the pre-edit row for six hours.
    ///
    /// Expected to fail before the fix with: `model.entries.first { $0.seriesId
    /// == 1 }?.rating` == nil rather than 80 — page 2 replaced the patched row.
    @Test("An edit saved mid-walk survives the pages that land after it")
    func editSurvivesTheWalk() async throws {
        let library = GatedLibrary(total: 300, gateAfterPage: 1)
        let snapshot = LibrarySnapshot(library: library)
        let model = LibraryModel(library: library, snapshot: snapshot)
        let walk = Task { await model.load() }

        _ = await library.waitForGate()
        var change = LibraryChange()
        change.rating = .some(80)
        await model.apply(change, to: 1)

        library.openGate()
        await walk.value

        #expect(model.entries.first { $0.seriesId == 1 }?.rating == 80)
        let cached = await snapshot.all().first { $0.seriesId == 1 }
        #expect(cached?.rating == 80, "and the six-hour cache holds the edit, not the row before it")
    }

    /// The control: the same edit applied after the walk has finished has
    /// always worked, and still does — so the test above is measuring the
    /// mid-walk case and not the patch mechanism in general.
    @Test("Control: the same edit after the walk still lands")
    func editAfterTheWalkStillLands() async throws {
        let library = GatedLibrary(total: 300, gateAfterPage: 1)
        let model = LibraryModel(library: library, snapshot: LibrarySnapshot(library: library))
        let walk = Task { await model.load() }
        _ = await library.waitForGate()
        library.openGate()
        await walk.value

        var change = LibraryChange()
        change.rating = .some(80)
        await model.apply(change, to: 1)
        #expect(model.entries.first { $0.seriesId == 1 }?.rating == 80)
    }

    // MARK: - Work-list 16: the discarded walk that commits anyway

    /// Sign-out cancels the walk and empties the table; the walk's own
    /// continuation then cached its result and wrote it back to disk, so the
    /// previous account's library survived the sign-out.
    ///
    /// Expected to fail before the fix with: `entries` non-empty — the
    /// discarded walk's 300 rows, cached after `invalidate()` had cleared
    /// everything.
    @Test("A walk discarded by sign-out does not commit after it finishes")
    func discardedWalkDoesNotCommit() async throws {
        let library = GatedLibrary(total: 300, gateAfterPage: 1)
        let snapshot = LibrarySnapshot(library: library)
        let walk = Task { await snapshot.load() }

        _ = await library.waitForGate()
        await snapshot.invalidate()
        library.openGate()
        _ = await walk.value

        let after = await snapshot.cachedResult
        #expect(after == nil, "the discarded walk must not become the cached library")
    }

    // MARK: - Work-list 17: a repeated id across a page boundary

    /// An entry written while the walk is in flight can move across the page
    /// boundary and arrive twice. `LibraryImport` and `LibraryTransferSection`
    /// both build a `Dictionary(uniqueKeysWithValues:)` over the result, which
    /// traps on a repeated key.
    ///
    /// Expected to fail before the fix with: 200 entries and 199 distinct ids,
    /// then a trap inside `Dictionary(uniqueKeysWithValues:)`.
    @Test("A repeated id across pages is dropped rather than carried")
    func repeatedIDIsDeduped() async throws {
        // Full pages, or the walk stops at the first short one. Page 2
        // repeats page 1's last id, which is what an entry written mid-walk
        // does when it shifts across the boundary.
        let size = LibrarySnapshot.pageSize
        let library = RepeatingLibrary(pages: [
            Array(1...size),
            Array(size...(size * 2 - 1))
        ])
        let snapshot = LibrarySnapshot(library: library)
        let all = await snapshot.all()

        #expect(Set(all.map(\.seriesId)).count == all.count, "no repeated id survives the walk")
        #expect(all.count == size * 2 - 1)
        // The trap this exists to stop: both import paths key on `seriesId`.
        let keyed = Dictionary(all.map { ($0.seriesId, $0) }, uniquingKeysWith: { first, _ in first })
        #expect(keyed.count == all.count)
    }

    // MARK: - Work-list 85: a rating change moves the revision

    /// Insights and Wrapped key their recompute on count-plus-completedness,
    /// which a rating or state change does not move — so "It finished without
    /// telling you" kept listing a series just marked Completed.
    ///
    /// Expected to fail before the fix with: no `revision` member at all.
    @Test("Patching one entry moves the revision the derived screens key on")
    func patchMovesTheRevision() async throws {
        let library = FlakyLibrary(total: 3)
        let model = LibraryModel(library: library, snapshot: LibrarySnapshot(library: library))
        await model.load()
        let before = model.revision

        var change = LibraryChange()
        change.state = .completed
        await model.apply(change, to: 1)
        #expect(model.revision > before)
    }

    // MARK: - Work-list 94: "Pick back up" keeps its order

    /// `sort` is not documented stable and most entries share priority 0, so
    /// two calls over identical data could disagree.
    ///
    /// Expected to fail before the fix with: nothing, most runs — which is
    /// the point of a tiebreak. The assertion that bites is the explicit
    /// ordering: without it, equal-priority rows keep input order, so
    /// reversing the input reverses the output.
    @Test("Entries at equal priority are ordered by series id, not by arrival")
    func inProgressHasATiebreak() async throws {
        let library = RepeatingLibrary(pages: [[3, 1, 2]])
        let model = LibraryModel(library: library, snapshot: LibrarySnapshot(library: library))
        await model.load()
        #expect(model.inProgress.map(\.seriesId) == [1, 2, 3], "arrival order was 3, 1, 2")
    }

    // MARK: - Stubs

    /// A walk that stops after `gateAfterPage` until it is released.
    private final class GatedLibrary: LibraryProviding, @unchecked Sendable {
        struct Observation: Sendable { let entries: Int }

        let total: Int
        let gateAfterPage: Int
        private let lock = NSLock()
        private var waiter: CheckedContinuation<Observation, Never>?
        private var parkedAt: Observation?
        private var release: CheckedContinuation<Void, Never>?
        private var isOpen = false
        private var served = 0

        init(total: Int, gateAfterPage: Int) {
            self.total = total
            self.gateAfterPage = gateAfterPage
        }

        /// Resumes once the walk is parked on the gate, reporting how many
        /// entries it had emitted by then. Tolerates being called either
        /// before or after the walk arrives — a continuation stored only on
        /// one of those orderings is a test that hangs on a slow machine.
        func waitForGate() async -> Observation {
            await withCheckedContinuation { continuation in
                lock.lock()
                if let parkedAt {
                    lock.unlock()
                    continuation.resume(returning: parkedAt)
                } else {
                    waiter = continuation
                    lock.unlock()
                }
            }
        }

        func openGate() {
            lock.lock()
            isOpen = true
            let waiting = release
            release = nil
            lock.unlock()
            waiting?.resume()
        }

        func libraryPage(page: Int, limit: Int) async throws(APIError) -> [LibraryEntry] {
            if page == gateAfterPage + 1 {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    lock.lock()
                    let observation = Observation(entries: served)
                    parkedAt = observation
                    let announce = waiter
                    waiter = nil
                    if isOpen {
                        lock.unlock()
                        announce?.resume(returning: observation)
                        continuation.resume()
                        return
                    }
                    release = continuation
                    lock.unlock()
                    announce?.resume(returning: observation)
                }
            }
            let start = (page - 1) * limit
            guard start < total else { return [] }
            let rows = (start..<min(start + limit, total)).map { Self.entry(id: $0 + 1) }
            lock.withLock { served += rows.count }
            return rows
        }

        /// Reading, with one chapter recorded, so these rows are also what
        /// `LibraryModel.inProgress` selects. Priority is left nil — every
        /// row ties, which is the case the tiebreak is for.
        nonisolated static func entry(id: Int) -> LibraryEntry {
            LibraryEntry(
                id: id, seriesId: id, state: .reading, progressChapter: 1,
                progressVolume: nil, rating: nil, note: nil, startDate: nil,
                finishDate: nil, numberOfRereads: nil, priority: nil,
                isPrivate: nil, readLink: nil, series: nil
            )
        }

        func library(page: Int, limit: Int) async -> [LibraryEntry] {
            (try? await libraryPage(page: page, limit: limit)) ?? []
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

    /// A plain paged walk whose failure can be switched off between runs.
    private final class FlakyLibrary: LibraryProviding, @unchecked Sendable {
        let total: Int
        private let lock = NSLock()
        private var storedFailOnPage: Int?

        init(total: Int, failOnPage: Int? = nil) {
            self.total = total
            storedFailOnPage = failOnPage
        }

        var failOnPage: Int? {
            get { lock.withLock { storedFailOnPage } }
            set { lock.withLock { storedFailOnPage = newValue } }
        }

        func libraryPage(page: Int, limit: Int) async throws(APIError) -> [LibraryEntry] {
            if let failOnPage, page >= failOnPage { throw APIError.offline }
            let start = (page - 1) * limit
            guard start < total else { return [] }
            return (start..<min(start + limit, total)).map { GatedLibrary.entry(id: $0 + 1) }
        }
        func library(page: Int, limit: Int) async -> [LibraryEntry] {
            (try? await libraryPage(page: page, limit: limit)) ?? []
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

    /// Serves the exact ids given, page by page — including a repeat.
    private final class RepeatingLibrary: LibraryProviding, @unchecked Sendable {
        let pages: [[Int]]
        init(pages: [[Int]]) { self.pages = pages }

        func libraryPage(page: Int, limit: Int) async throws(APIError) -> [LibraryEntry] {
            guard page <= pages.count else { return [] }
            return pages[page - 1].map { GatedLibrary.entry(id: $0) }
        }
        func library(page: Int, limit: Int) async -> [LibraryEntry] {
            (try? await libraryPage(page: page, limit: limit)) ?? []
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
