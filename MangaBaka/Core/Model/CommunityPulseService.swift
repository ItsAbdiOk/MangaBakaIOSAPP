import Foundation

/// Fetches the community pulse, once.
///
/// Once per launch on purpose. The figures move by the week, the rate limit is
/// per IP and shared with strangers on the same network, and a number that
/// changes while you are looking at it is worse than one that does not.
@MainActor
@Observable
final class CommunityPulseService {
    private(set) var pulse: CommunityPulse?
    /// Tried and failed. The card shows nothing rather than an error: this is
    /// a grace note, and a screen that apologises for failing to show one has
    /// made it more important than it is.
    private(set) var didFail = false

    private let client: APIClient
    private var hasLoaded = false

    init(client: APIClient) {
        self.client = client
    }

    func load() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        do {
            pulse = try await client.getBare("/v0/frontpage/community-pulse", as: CommunityPulse.self)
        } catch {
            didFail = true
        }
    }
}
