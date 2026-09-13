import Foundation

/// Counting, as opposed to fetching.
///
/// Its own file because the repository's body is at the lint's ceiling, and
/// because this is a different question from the rest of it: everything else
/// here asks *what matches*, and this asks only *how many*.
extension SeriesRepository {
    /// How many series a saved search would return right now.
    ///
    /// The reader's standing filters are applied, exactly as they are for a
    /// real search — a count that ignored them would promise results the same
    /// filters then hide, which is worse than no count at all.
    ///
    /// Nil on any failure. A lens whose count could not be fetched shows no
    /// count; it does not show zero.
    ///
    /// **This overload is foreground.** `.userInitiated` draws on the ten
    /// slots `RateLimitGate.reserve` keeps for the reader's own search, so it
    /// is right only for a count the reader is looking at right now
    /// (`PublisherView`'s page total). A count the app asks for on its own —
    /// a lens row, a filter-panel preview — must pass `.background` to the
    /// overload below. `LensCounts.count(_:)` called this one until
    /// 2026-09-13 and a reader's own previews could refuse their next typed
    /// search (review E F3); the lens walk had been moved the same day, and
    /// this call site was the one missed.
    func count(_ query: SearchQuery) async -> Int? {
        await count(query, priority: .userInitiated)
    }

    func count(_ query: SearchQuery, priority: RequestPriority) async -> Int? {
        var narrowed = query
        // One item, because only the total is wanted. The API reports the total
        // in its pagination block whatever the page size.
        narrowed.limit = 1
        narrowed.page = 1

        var items = narrowed.queryItems
        items.append(contentsOf: filterQuery(overridingTypes: narrowed.types))
        return try? await client.total("/v2/series/search", query: items, priority: priority)
    }
}
