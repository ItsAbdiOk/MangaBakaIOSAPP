import Foundation

/// Backing state for the discovery surface.
///
/// Reads through `SeriesRepository`, which decides for itself whether to serve
/// cache or hit the network. This type deliberately knows nothing about that
/// decision — it only cares whether it has content to show.
@MainActor
@Observable
final class DiscoveryModel {
    enum State: Equatable {
        case idle
        case loading
        /// Content to show. `staleReason` is non-nil when the network failed
        /// and this came from cache, so the UI can say why it may be dated.
        case loaded([Series], staleReason: String?)
        /// Nothing to show at all, and here is why.
        case failed(message: String)
    }

    private(set) var state: State = .idle
    private let repository: any SeriesRepositoryProtocol

    init(repository: any SeriesRepositoryProtocol) {
        self.repository = repository
    }

    func load(forceRefresh: Bool = false) async {
        if case .loading = state { return }
        state = .loading

        let result = await repository.feed(.rising, forceRefresh: forceRefresh)

        if let blocking = result.blockingError {
            state = .failed(message: blocking.userFacingMessage)
            return
        }
        let staleReason: String? = if case let .staleAfter(error) = result.origin {
            error.userFacingMessage
        } else {
            nil
        }
        state = .loaded(result.series, staleReason: staleReason)
    }
}
