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

    /// When the last attempt failed, so a screen that re-appears cannot spend
    /// a request per appearance on a host that just refused one.
    private var failedAt: Date?

    /// **A guess: 60 seconds.** Nothing on record says how long a pulse
    /// failure lasts. It is chosen to be longer than a reader can plausibly
    /// leave and return to Discover by hand, and shorter than the interval at
    /// which the figures themselves move (weeks, per the type's own comment) —
    /// so the retry is still there for offline-then-online, and a tab flick
    /// costs nothing.
    private static let retryInterval: TimeInterval = 60

    /// Test-only: so a test can wait out the floor without a second copy of
    /// the number, which is how the two would come to disagree.
    static var retryIntervalForTesting: TimeInterval { retryInterval }

    private let client: APIClient
    private let clock: any Clock

    init(client: APIClient, clock: any Clock = SystemClock()) {
        self.client = client
        self.clock = clock
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
    ///
    /// The retry that guard makes possible was, until 2026-09-14, unbounded:
    /// `DiscoverView.swift:148` calls `load()` on every appearance, so a host
    /// that is refusing — offline, a 429 — was asked again on every tab flick,
    /// once per appearance, forever. `failedAt` keeps the retry and spaces it.
    func load() async {
        guard pulse == nil else { return }
        let now = clock.now
        if let failedAt, now.timeIntervalSince(failedAt) <= Self.retryInterval { return }
        do {
            pulse = try await client.getRoot("/v0/frontpage/community-pulse", as: CommunityPulse.self)
            didFail = false
            self.failedAt = nil
        } catch {
            didFail = true
            self.failedAt = now
        }
    }
}
