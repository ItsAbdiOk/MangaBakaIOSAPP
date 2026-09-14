import Foundation
import Testing
@testable import MangaBaka

/// The three stores item 107 moved off the launch path.
///
/// The point of the item is that a screen nobody opens should cost nothing
/// before the first frame. That is a claim about *when* an object is built,
/// and the only honest way to check it is to build one and watch — not to
/// grep `AppServices.swift` for the word `Deferred`, which would pass on a
/// file that spelled it right and did it wrong.
@Suite("Launch-path deferral")
@MainActor
struct LaunchPathDeferralTests {
    /// Somewhere to count builds from inside an escaping closure without
    /// relying on a captured local, which reads ambiguously under strict
    /// concurrency.
    private final class Counter {
        var builds = 0
    }

    @Test("Nothing is built until something asks")
    func nothingIsBuiltUntilAsked() {
        let counter = Counter()
        let deferred = Deferred<Int> {
            counter.builds += 1
            return 7
        }

        #expect(counter.builds == 0, "constructing the box must not run the builder")
        #expect(deferred.isBuilt == false)

        #expect(deferred.value == 7)
        #expect(counter.builds == 1)
        #expect(deferred.isBuilt)
    }

    /// Built once, not once per ask. `SearchLensStore` and `RecentSearches`
    /// own the reader's saved lenses and recent terms; two instances would
    /// mean a lens saved on the Search tab was invisible on Mix until a
    /// relaunch, which is worse than the eager construction this replaced.
    @Test("The second ask gets the first answer, not a second object")
    func builtOnceAndShared() {
        let counter = Counter()
        let deferred = Deferred<NSObject> {
            counter.builds += 1
            return NSObject()
        }

        let first = deferred.value
        let second = deferred.value

        #expect(counter.builds == 1)
        #expect(first === second)
    }

    /// The production expressions themselves, not copies of them — see
    /// `AppServices.deferredLenses`'s doc comment for why these are named
    /// factories at all.
    ///
    /// What this does *not* prove: that `AppServices`'s stored properties
    /// still use these factories. Nothing in the test bundle can construct an
    /// `AppServices` (its `init` opens the real SQLite file and builds a live
    /// `APIClient`), so that half is held by the compiler — the properties are
    /// typed `Deferred<…>` and `RootView` takes `Deferred<…>`, so an eager
    /// `SearchLensStore()` no longer type-checks anywhere on the path.
    @Test("Every factory AppServices uses hands back an unbuilt store")
    func appServicesFactoriesAreUnbuilt() {
        #expect(AppServices.deferredLenses().isBuilt == false)
        #expect(AppServices.deferredRecents().isBuilt == false)
        // Not `.value`-ed below, unlike the other two: `PublisherFollows()`
        // creates the Application Support directory, and a test should not
        // leave a directory behind to prove a store was not built.
        #expect(AppServices.deferredPublisherFollows().isBuilt == false)
    }

    @Test("Asking a real factory builds the real store, once")
    func askingAFactoryBuildsIt() {
        // `RecentSearches` of the three, because its whole cost is one
        // `UserDefaults.stringArray` read: nothing is written, no file is
        // created, and the suite leaves no trace.
        let deferred = AppServices.deferredRecents()
        let store = deferred.value

        #expect(deferred.isBuilt)
        #expect(deferred.value === store)
    }
}
