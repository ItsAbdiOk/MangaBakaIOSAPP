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
        let path = "/v1/series/\(seriesId)/works"
        let first: (elements: [SeriesWork], pagination: Pagination?) =
            try await client.getLossyWithPagination(path, query: Self.worksQuery(page: 1))
        guard let total = first.pagination?.count, total > Self.worksPageSize else {
            return (first.elements, first.pagination?.count ?? first.elements.count)
        }
        let lastPage = (total + Self.worksPageSize - 1) / Self.worksPageSize
        guard lastPage > 1 else { return (first.elements, total) }
        let last: [SeriesWork] = (try? await client.getLossy(
            path, query: Self.worksQuery(page: lastPage), priority: .background
        )) ?? []
        // Sequence-sorted so the two pages read as one list; `volumes(from:)`
        // groups by sequence string and would otherwise keep page order.
        let firstIDs = Set(first.elements.map(\.id))
        return (first.elements + last.filter { !firstIDs.contains($0.id) }, total)
    }

    nonisolated static func worksQuery(page: Int) -> [URLQueryItem] {
        [
            URLQueryItem(name: "limit", value: String(worksPageSize)),
            URLQueryItem(name: "page", value: String(page))
        ]
    }
}
