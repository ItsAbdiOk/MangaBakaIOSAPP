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
    func count(_ query: SearchQuery) async -> Int? {
        var narrowed = query
        // One item, because only the total is wanted. The API reports the total
        // in its pagination block whatever the page size.
        narrowed.limit = 1
        narrowed.page = 1

        var items = narrowed.queryItems
        items.append(contentsOf: (contentRatings ?? []).map {
            URLQueryItem(name: "content_rating", value: $0)
        })
        if narrowed.types.isEmpty {
            items.append(contentsOf: formats.map { URLQueryItem(name: "type", value: $0) })
        }
        items.append(contentsOf: blockedTags.map {
            URLQueryItem(name: "tag_not", value: String($0))
        })
        return try? await client.total("/v2/series/search", query: items)
    }
}
