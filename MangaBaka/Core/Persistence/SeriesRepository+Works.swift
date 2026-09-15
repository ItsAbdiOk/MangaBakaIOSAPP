import Foundation

/// The works leg, in its own file because it is now two requests on a long
/// series and the reasoning does not fit beside the other legs.
extension SeriesRepository {
    /// The endpoint's ceiling; 400 above it (measured 2026-09-15 on
    /// `/images`, same validator wording).
    nonisolated static let worksPageSize = 50

    /// `/works` for a series: the first page, and — when there are more —
    /// the last page too.
    ///
    /// **Why the last page.** `/works` pages ascending by sequence, honours
    /// no sort parameter (`sort=`, `order=` are silently ignored — measured
    /// 2026-09-15 on ONE PIECE, 377) and defaulted to 25 a page. The app
    /// took page one: ONE PIECE's shelf read "Volumes 7" (25 printings of
    /// volumes 1–7), and volume 113, due 2026-11-10, sat on page 6 where
    /// neither the shelf nor the Next-volume widget ever looked. The first
    /// page is what a reader starting a series wants; the last is where
    /// the forthcoming volume lives. Both, not every page in between: a
    /// series with 267 printings would cost six requests a cold open.
    ///
    /// The second request is `.background` — it waits at the gate rather
    /// than throwing — and its failure is dropped rather than failing the
    /// leg: the first page is still a true answer, just the same partial
    /// one the app always gave.
    ///
    /// - Returns: the works in sequence order, and `total` — the endpoint's
    ///   own count, so a caller can tell 50 of 50 from 50 of 267.
    func fetchWorks(for seriesId: Int) async throws(APIError) -> (works: [SeriesWork], total: Int?) {
        let first = try await fetchWorksFirstPage(for: seriesId)
        guard let lastPage = first.lastPage else { return (first.works, first.total) }
        let last = try await fetchWorksLastPage(for: seriesId, page: lastPage)
        return (Self.joined(first.works, last), first.total)
    }

    /// The first page alone — what the shelf draws first. `lastPage` is the
    /// page the forthcoming volume lives on when there is one past this, so
    /// the caller can ask for it later at `.background` rather than inside
    /// the foreground leg (review perf DT11, 2026-09-15: the last page used
    /// to be awaited sequentially inside `full`'s leg and `try?`-swallowed,
    /// so a throttle on it silently left the badge at "113 over 50 rows").
    func fetchWorksFirstPage(for seriesId: Int) async throws(APIError) -> WorksFirstPage {
        let first: (elements: [SeriesWork], pagination: Pagination?) =
            try await client.getLossyWithPagination(
                "/v1/series/\(seriesId)/works", query: Self.worksQuery(page: 1)
            )
        guard let total = first.pagination?.count, total > Self.worksPageSize else {
            return WorksFirstPage(
                works: first.elements, total: first.pagination?.count ?? first.elements.count, lastPage: nil
            )
        }
        let lastPage = (total + Self.worksPageSize - 1) / Self.worksPageSize
        return WorksFirstPage(works: first.elements, total: total, lastPage: lastPage > 1 ? lastPage : nil)
    }

    struct WorksFirstPage: Sendable {
        let works: [SeriesWork]
        let total: Int?
        /// Nil when page one is the whole list.
        let lastPage: Int?
    }

    /// The last page, `.background`: it waits at the gate rather than
    /// throwing, and its failure is the caller's to record, not swallow.
    func fetchWorksLastPage(for seriesId: Int, page: Int) async throws(APIError) -> [SeriesWork] {
        try await client.getLossy(
            "/v1/series/\(seriesId)/works", query: Self.worksQuery(page: page), priority: .background
        )
    }

    /// Two pages as one list, first page's ids winning; `volumes(from:)`
    /// groups by sequence string and would otherwise keep page order.
    nonisolated static func joined(_ first: [SeriesWork], _ last: [SeriesWork]) -> [SeriesWork] {
        let firstIDs = Set(first.map(\.id))
        return first + last.filter { !firstIDs.contains($0.id) }
    }

    nonisolated static func worksQuery(page: Int) -> [URLQueryItem] {
        [
            URLQueryItem(name: "limit", value: String(worksPageSize)),
            URLQueryItem(name: "page", value: String(page))
        ]
    }
}
