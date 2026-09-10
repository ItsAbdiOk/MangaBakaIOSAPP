import SwiftUI

/// The models that live for the length of a session rather than for a screen.
///
/// Both of these have to outlive the view that shows them, and for the same
/// reason: they hold answers that cost a request. A lens count fetched when the
/// reader opened Search must still be there when they come back to it, and the
/// recently-viewed list must not reload itself every time Discover appears.
///
/// Held together in one place because `RootView` was accumulating a
/// lazily-initialised `@State` and a matching accessor function for each of
/// them, which is four things to read where there should be one.
@MainActor
@Observable
final class SessionModels {
    let recentlyViewed: RecentlyViewedModel
    let counts: LensCounts

    init(
        repository: any SeriesRepositoryProtocol,
        history: HistoryStore,
        allowedRatings: @escaping () -> [String]
    ) {
        recentlyViewed = RecentlyViewedModel(history: history, allowedRatings: allowedRatings)
        counts = LensCounts(repository: repository)
    }
}
