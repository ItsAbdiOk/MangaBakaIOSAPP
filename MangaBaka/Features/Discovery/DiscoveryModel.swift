import Foundation

/// Backing state for the discovery surface.
///
/// Loads from the network directly for now. The on-device cache described in
/// the design doc slots in behind this without changing the view: the model
/// will ask a repository instead of the client, and the repository decides
/// whether to hit the network.
@MainActor
@Observable
final class DiscoveryModel {
    enum State: Equatable {
        case idle
        case loading
        case loaded([Series])
        /// Carries a user-safe message plus whatever could still be shown.
        case failed(message: String, stale: [Series])
    }

    private(set) var state: State = .idle
    private let client: APIClient

    init(client: APIClient) {
        self.client = client
    }

    func load() async {
        if case .loading = state { return }

        // Keep whatever is on screen so a failure degrades to stale content
        // rather than a blank page.
        let existing: [Series] = if case let .loaded(series) = state { series } else { [] }
        state = .loading

        do {
            // `limit` maxes at 20 on this endpoint, and the response is CDN
            // cached for a day, so asking for the maximum costs nothing extra.
            let series: [Series] = try await client.get(
                "/v2/series/discover/rising",
                query: ["limit": "20"]
            )
            state = .loaded(series.filter(\.isDiscoverable))
        } catch {
            state = .failed(message: error.userFacingMessage, stale: existing)
        }
    }
}
