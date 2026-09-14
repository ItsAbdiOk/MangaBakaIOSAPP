import Foundation

/// A small in-memory map, keyed by series id, that forgets its least recently
/// used entry once it is full.
///
/// **Why it exists.** `SeriesRepository.cachedImages` and
/// `cachedRelationships` were plain dictionaries held "for as long as the app
/// is running", one entry per series page opened, and `cachedRelationships`
/// had no path that ever removed an entry at all (work-list 54). They hold
/// URLs and ids rather than bitmaps, so the per-entry cost is small — but
/// small times unbounded is still unbounded, and a long browsing session is
/// exactly the shape that finds it.
///
/// Not an `NSCache`: these are value types in an `actor`, and `NSCache` evicts
/// on its own schedule under memory pressure, which would mean a cache whose
/// contents cannot be reasoned about from the call site. A fixed cap that
/// drops the oldest read is predictable and is all this needs.
struct BoundedCache<Value> {
    /// How many series to remember.
    ///
    /// **A guess.** Two hundred is "far more series than one browsing session
    /// opens, and still bounded" — the same shape of number as
    /// `LibrarySnapshot.pageCap`. Nothing has measured the real depth of a
    /// session; what would settle it is the distinct-series count between two
    /// launches, which needs a device.
    static var defaultLimit: Int { 200 }

    private var storage: [Int: Value] = [:]
    /// Least recently used first. Linear, deliberately: at 200 entries the
    /// array work is trivial next to the request this cache exists to avoid,
    /// and a linked list here would be more code than the problem is worth.
    private var recency: [Int] = []
    private let limit: Int

    init(limit: Int = BoundedCache.defaultLimit) {
        self.limit = limit
    }

    var count: Int { storage.count }
    var isEmpty: Bool { storage.isEmpty }

    /// Reads an entry and marks it as the most recently used.
    ///
    /// `mutating` for that reason — a plain subscript `get` could not record
    /// the read, and a cache that evicts by insertion order rather than by use
    /// would drop the series the reader keeps going back to.
    mutating func value(for key: Int) -> Value? {
        guard let value = storage[key] else { return nil }
        touch(key)
        return value
    }

    mutating func insert(_ value: Value, for key: Int) {
        storage[key] = value
        touch(key)
        while storage.count > limit, let oldest = recency.first {
            recency.removeFirst()
            storage[oldest] = nil
        }
    }

    mutating func removeAll() {
        storage.removeAll()
        recency.removeAll()
    }

    private mutating func touch(_ key: Int) {
        if let index = recency.firstIndex(of: key) { recency.remove(at: index) }
        recency.append(key)
    }
}
