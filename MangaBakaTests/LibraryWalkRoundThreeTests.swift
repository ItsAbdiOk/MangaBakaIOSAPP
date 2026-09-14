import Foundation
import Testing
@testable import MangaBaka

/// The round-3 review's library-walk findings: a page published to a walk that
/// was already cancelled, and the second caller of a shared walk getting rows
/// the first one had already patched.
///
/// Split out of `LibraryWalkRoundTwoTests` only to stay under SwiftLint's
/// `type_body_length`; `GatedLibrary` is shared with that file rather than
/// copied.
@Suite("Library walk, round three")
@MainActor
struct LibraryWalkRoundThreeTests {
    private typealias GatedLibrary = LibraryWalkRoundTwoTests.GatedLibrary

    // MARK: - Work-list 25: a page that lands after the cancellation

    /// `walk` checked cancellation at the top of the page, then awaited, then
    /// published. A cancellation landing *during* the request — which is what
    /// a sign-out or an account change is, via `invalidate()` — still handed
    /// that page to the observer the cancellation was issued for. Contained
    /// today only by `LibraryModel`'s own generation counter, which is one
    /// caller's private defence and not this one's to rely on.
    ///
    /// EXPECTED TO FAIL ON THE OLD CODE with: `#expect(pages.value == 1)`
    /// reading **2** — page 2 is appended and `onPage` is called with the
    /// previous account's 200 rows after `invalidate()` has already cleared
    /// the table.
    @Test("A page that arrives after the walk is cancelled is not published")
    func aCancelledWalkDoesNotPublishItsLastPage() async throws {
        let library = GatedLibrary(total: 300, gateAfterPage: 1)
        let snapshot = LibrarySnapshot(library: library)
        let pages = PageCounter()
        await snapshot.observePages { _ in pages.increment() }

        let walk = Task { await snapshot.load() }
        _ = await library.waitForGate()
        #expect(pages.value == 1, "page 1 landed before the gate, as it must")

        // The real cancellation path: `invalidate()` cancels the in-flight
        // walk. Cancelling the outer `Task` would not reach it — `load()`
        // starts an unstructured task, which does not inherit cancellation.
        await snapshot.invalidate()
        library.openGate()
        _ = await walk.value

        #expect(pages.value == 1, "page 2 was published to a cancelled walk's observer")
    }

    // MARK: - Work-list 26: the second caller of a shared walk

    /// Three callers arrive at once on launch. Only the one that created the
    /// task ran `replayPending`; the other two got the raw walk, so which of
    /// them saw the reader's mid-walk edit was a race.
    ///
    /// EXPECTED TO FAIL ON THE OLD CODE with: the *joining* caller's
    /// `#expect(... == 80)` reading **nil** — its `return await inFlight.value`
    /// handed back the walk's own rows, before the replay the creator applied
    /// a moment later.
    @Test("Both callers of one shared walk see an edit stashed during it")
    func concurrentCallersBothSeeTheReplay() async throws {
        let library = GatedLibrary(total: 300, gateAfterPage: 1)
        let snapshot = LibrarySnapshot(library: library)

        let creator = Task { await snapshot.load() }
        _ = await library.waitForGate()
        // Arrives while the walk is parked, so it takes the `inFlight` branch
        // rather than the cache.
        let joiner = Task { await snapshot.load() }
        await Task.yield()

        var change = LibraryChange()
        change.rating = .some(80)
        await snapshot.apply(seriesId: 1, change: change)
        library.openGate()

        let fromCreator = await creator.value
        let fromJoiner = await joiner.value
        #expect(fromCreator.entries.first { $0.seriesId == 1 }?.rating == 80)
        #expect(
            fromJoiner.entries.first { $0.seriesId == 1 }?.rating == 80,
            "the second caller of the same walk got un-replayed rows"
        )
    }

    /// Counts `onPage` calls from whatever isolation the walk publishes on.
    private final class PageCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func increment() {
            lock.lock(); defer { lock.unlock() }
            count += 1
        }

        var value: Int {
            lock.lock(); defer { lock.unlock() }
            return count
        }
    }
}
