import Foundation
import Testing
@testable import MangaBaka

/// Item 117 (wire review, `docs/reviews/full/wire.md` finding 16, 2026-09-14):
/// `TagTaxonomy.loadResult` is a lazy static, so the first `bundled()` call
/// does a file read and a 2,686-row decode synchronously on whichever thread
/// asks — and two of the four callers are views. `TagTaxonomy.warm()` exists
/// so a background caller can force that work to happen before a view ever
/// asks for it.
///
/// This suite cannot demonstrate "opens the picker faster" — that needs the
/// app running and a stopwatch, not a unit test — so it proves the one thing
/// a unit test can: that `warm()` actually forces the same lazy load
/// `bundled()` would have, rather than being a no-op stub. Whether it saves
/// the guessed 10-30 ms on a real device is unmeasured, as the finding says.
@Suite("TagTaxonomy.warm forces the lazy load")
struct TagTaxonomyWarmTests {
    /// `warm()` and `bundled()` must agree, because they read the same
    /// process-lifetime cache (`loadResult`) — `warm()` populating a
    /// different value, or none at all, would mean a background "warm" call
    /// does not actually save the view-thread caller anything.
    @Test("warm() populates the same result bundled() reads")
    func warmMatchesBundled() {
        TagTaxonomy.warm()
        #expect(TagTaxonomy.loadFailed == false)
        #expect(!TagTaxonomy.bundled().isEmpty)
    }

    /// `warm()` takes no actor and returns `Void`, so it must be callable
    /// from a plain background task with no `await` — the whole point of
    /// giving `OfflineCatalogue`'s background setup a way to force the load
    /// before a view thread can.
    @Test("warm() is callable from a non-isolated background context")
    func warmIsCallableOffTheMainActor() async {
        await Task.detached {
            TagTaxonomy.warm()
        }.value
        #expect(!TagTaxonomy.bundled().isEmpty)
    }
}
