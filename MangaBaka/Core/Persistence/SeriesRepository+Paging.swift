import Foundation

/// The two uncached, paged reads: a later page of a feed, and a search.
///
/// Split out of `SeriesRepository.swift` for the lint's 250-line ceiling on a
/// type body, the same reason `+Cache` and `+Count` exist. Not a widening of
/// who is meant to touch these.
///
/// Both answer with the API's own `pagination.next` in `FeedResult.hasMore`.
/// Neither can infer the end from how many rows it returns: both filter the
/// page locally for `isDiscoverable` and format after it arrives, so a page
/// that was full on the wire can reach a caller short — which is exactly how
/// a tag search got stuck at 30 results forever. See `FeedResult.hasMore`.
extension SeriesRepository {
    func feedPage(_ feed: FeedKind, page: Int) async -> FeedResult {
        guard feed.supportsPaging, page > 1 else {
            return FeedResult(series: [], origin: .network)
        }
        var query = [
            URLQueryItem(name: "limit", value: String(feed.limit)),
            URLQueryItem(name: "page", value: String(page))
        ]
        query.append(contentsOf: feed.extraQuery)
        query.append(contentsOf: filterQuery)
        do {
            let (series, pagination): ([Series], Pagination?) =
                try await client.getWithPagination(feed.path, query: query)
            return FeedResult(
                series: series.filter { $0.isDiscoverable && allowsFormat($0) },
                origin: .network,
                // Read by DiscoverModel.loadMore to end a row. A page whose
                // rows are all filtered out locally is not the end of the
                // feed, and the row's own length cannot tell the difference.
                hasMore: pagination?.next != nil,
                total: pagination?.count
            )
        } catch {
            return FeedResult(series: [], origin: .staleAfter(error))
        }
    }

    func search(_ query: SearchQuery) async -> FeedResult {
        var items = query.queryItems
        items.append(contentsOf: (contentRatings ?? []).map {
            URLQueryItem(name: "content_rating", value: $0)
        })
        // An explicit choice in the filter sheet wins over the standing
        // preference. Sending both would intersect them, so picking "novel" in
        // the sheet while novels are switched off in Settings would silently
        // return nothing at all rather than what was asked for.
        if query.types.isEmpty {
            items.append(contentsOf: formats.map { URLQueryItem(name: "type", value: $0) })
        }
        items.append(contentsOf: blockedTags.map {
            URLQueryItem(name: "tag_not", value: String($0))
        })
        do {
            let (series, pagination): ([Series], Pagination?) =
                try await client.getWithPagination("/v2/series/search", query: items)
            return FeedResult(
                series: series.filter { $0.isDiscoverable && allowsFormat($0) },
                origin: .network,
                // The API's own signal, not the filtered count — see
                // `FeedResult.hasMore`.
                hasMore: pagination?.next != nil,
                total: pagination?.count
            )
        } catch {
            return FeedResult(series: [], origin: .staleAfter(error))
        }
    }}
