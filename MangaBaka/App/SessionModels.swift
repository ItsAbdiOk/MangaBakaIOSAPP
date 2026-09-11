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
    /// The Library tab's model, held for the session.
    ///
    /// **It used to be a computed property**, so every body pass that reached
    /// for it built a fresh one — and a fresh one loads, registers itself for
    /// page updates, and replaces whichever model was listening before. The
    /// series page reaches for it on every redraw.
    let library: LibraryModel
    /// The database's own pulse, fetched once per launch.
    let pulse: CommunityPulseService

    init(
        repository: any SeriesRepositoryProtocol,
        history: HistoryStore,
        libraryService: any LibraryProviding,
        snapshot: LibrarySnapshot,
        client: APIClient,
        allowedRatings: @escaping () -> [String]
    ) {
        recentlyViewed = RecentlyViewedModel(history: history, allowedRatings: allowedRatings)
        counts = LensCounts(repository: repository)
        library = LibraryModel(library: libraryService, snapshot: snapshot)
        pulse = CommunityPulseService(client: client)
    }
}
