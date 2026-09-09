import Foundation

/// Backing state for the Discover screen.
///
/// Loads several feeds at once. Each row reports its own state, so one failing
/// endpoint leaves the rest of the screen intact rather than blanking it —
/// which matters here, because the rate limit is shared and partial failure is
/// an ordinary occurrence, not an exceptional one.
@MainActor
@Observable
final class DiscoverModel {
    struct Row: Identifiable, Equatable {
        let kind: FeedKind
        let title: String
        var series: [Series] = []
        var staleReason: String?
        var isLoading = true

        var id: String { kind.cacheKey }
    }

    private(set) var rows: [Row] = [
        Row(kind: .rising, title: "Rising this week"),
        Row(kind: .hiddenGems, title: "Hidden gems"),
        Row(kind: .trending, title: "Trending")
    ]

    /// True only when every row failed with nothing cached — the one case that
    /// deserves a whole-screen error.
    var isCompletelyEmpty: Bool {
        !rows.contains { !$0.series.isEmpty } && !rows.contains(where: \.isLoading)
    }

    /// Why the screen is empty. Carried as the error itself rather than a
    /// string, so the view can choose a symbol and phrasing that match the
    /// actual cause instead of assuming everything is an outage.
    private(set) var failure: APIError?

    private let repository: any SeriesRepositoryProtocol

    init(repository: any SeriesRepositoryProtocol) {
        self.repository = repository
    }

    func load(forceRefresh: Bool = false) async {
        await withTaskGroup(of: (Int, FeedResult).self) { group in
            for (index, row) in rows.enumerated() {
                group.addTask { [repository] in
                    (index, await repository.feed(row.kind, forceRefresh: forceRefresh))
                }
            }
            var firstFailure: APIError?
            for await (index, result) in group {
                rows[index].series = result.series
                rows[index].isLoading = false
                if case let .staleAfter(error) = result.origin {
                    rows[index].staleReason = result.series.isEmpty ? nil : error.userFacingMessage
                    firstFailure = firstFailure ?? error
                } else {
                    rows[index].staleReason = nil
                }
            }
            failure = firstFailure
        }
    }
}
