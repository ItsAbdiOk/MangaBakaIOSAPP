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

    init(client: APIClient) {
        self.client = client
    }

    /// Guarded on `pulse == nil` rather than a separate "have we tried yet"
    /// flag. The flag used to be set unconditionally on the first call
    /// regardless of outcome, which meant a launch-time failure — offline, a
    /// rate limit, anything transient — was remembered as permanent for the
    /// rest of the process: every later call to `load()` (a fresh pull on
    /// Discover, say) saw the flag already set and skipped the retry it
    /// existed to make possible (gap 48). Once `pulse` actually holds a
    /// value there is nothing left to retry, which is the only case this
    /// should still no-op.
    func load() async {
        guard pulse == nil else { return }
        do {
            pulse = try await client.getRoot("/v0/frontpage/community-pulse", as: CommunityPulse.self)
            didFail = false
        } catch {
            didFail = true
        }
    }
}
