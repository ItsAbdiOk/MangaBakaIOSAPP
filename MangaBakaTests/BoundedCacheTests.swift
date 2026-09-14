import Foundation
import Testing
@testable import MangaBaka

/// `SeriesRepository.cachedImages` and `cachedRelationships` were plain
/// dictionaries held "for as long as the app is running" — one entry per
/// series page opened, and `cachedRelationships` had no path that ever removed
/// one (work-list 54).
///
/// EXPECTED TO FAIL ON THE OLD CODE with: `BoundedCache` did not exist, so
/// this does not compile — a compile failure, not a behavioural one, and worth
/// saying plainly. The behavioural claim the old code *would* have failed is
/// `#expect(cache.count == 3)`: a dictionary given four keys holds four,
/// forever.
@Suite("A repository cache forgets its oldest entry")
struct BoundedCacheTests {
    @Test("Past the limit, the least recently used entry goes")
    func evictsTheLeastRecentlyUsed() {
        var cache = BoundedCache<String>(limit: 3)
        for id in 1...3 { cache.insert("v\(id)", for: id) }

        // Reading 1 makes 2 the oldest, which is the whole reason this evicts
        // by use rather than by insertion: the series the reader keeps going
        // back to is the one worth keeping.
        #expect(cache.value(for: 1) == "v1")
        cache.insert("v4", for: 4)

        #expect(cache.count == 3)
        #expect(cache.value(for: 2) == nil, "2 was the least recently used")
        #expect(cache.value(for: 1) == "v1")
        #expect(cache.value(for: 3) == "v3")
        #expect(cache.value(for: 4) == "v4")
    }

    @Test("Re-inserting a key already held does not grow the cache")
    func reinsertingDoesNotGrow() {
        var cache = BoundedCache<String>(limit: 2)
        cache.insert("a", for: 1)
        cache.insert("b", for: 1)

        #expect(cache.count == 1)
        #expect(cache.value(for: 1) == "b")
    }

    @Test("Clearing empties it, which is what an .images invalidation does")
    func removeAllEmptiesIt() {
        var cache = BoundedCache<String>(limit: 4)
        cache.insert("a", for: 1)
        cache.removeAll()

        #expect(cache.isEmpty)
        #expect(cache.value(for: 1) == nil)
    }

    /// The control for the cap itself: far more inserts than the limit must
    /// still leave exactly the limit, and the newest must be among them.
    /// Without this, an eviction loop that ran once per insert rather than
    /// until the count fits would pass the first test and leak here.
    @Test("A thousand inserts leave the limit, not a thousand")
    func staysAtTheLimit() {
        var cache = BoundedCache<Int>(limit: 200)
        for id in 1...1_000 { cache.insert(id, for: id) }

        #expect(cache.count == 200)
        #expect(cache.value(for: 1_000) == 1_000)
        #expect(cache.value(for: 1) == nil)
    }
}
