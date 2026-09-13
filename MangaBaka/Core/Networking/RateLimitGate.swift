import Foundation

/// Holds requests back after the API says we are over its limit, and — for
/// search — before it ever has the chance to.
///
/// MangaBaka rate limits per IP — 30 requests a minute for search, 180
/// otherwise — and that budget is shared with everyone behind the same address:
/// a carrier NAT, a campus network, a household. Retrying into a 429 does not
/// only waste this app's quota, it keeps other people's requests failing too.
///
/// So a 429 is remembered and the client refuses locally until the window
/// passes, rather than discovering the same refusal over and over. Search
/// additionally gets a local sliding-window count, enforced *before* the 30th
/// request of the minute is even sent — a client that already knows its own
/// budget should not have to spend a real request to be told it is over.
///
/// **Two independent budgets, not one.** 2026-09-13: a single 429 earned by
/// search used to back off *every* path — fixed once already for the local
/// sliding window (gap 8), but the actual 429 memory (`blockedUntil`) stayed
/// global, so a search refusal still closed the series page's `/v1/series/...`
/// legs, which have nothing to do with the 30/min search cap. `Family` scopes
/// both the 429 memory and the sliding window to the endpoint that actually
/// earned them.
///
/// **A reserve for the reader, not just for search.** 2026-09-13: background
/// work — lens counts, publisher-follow checks, a swipe-stack deal while the
/// reader is elsewhere — was free to spend the search window down to zero
/// before the reader ever typed anything, so "Too many requests, briefly"
/// could greet a reader who had done nothing but open the series page.
/// `RequestPriority.background` is now capped at `searchLimit - reserve`
/// slots and waits for room instead of either failing or competing for the
/// last few slots against a search the reader is looking at right now.
actor RateLimitGate {
    /// Which of MangaBaka's two published limits a path counts against. A
    /// 429 or a local budget check applies to one, never both — the two are
    /// enforced independently by the server itself (30/min search, 180/min
    /// everything else), so this app's own memory of them has to match.
    enum Family: Sendable, Hashable {
        case search
        case general
    }

    /// Any path this substring appears in is subject to the search family. A
    /// substring rather than an exact match because the API is versioned
    /// (`/v1/series/search`, `/v2/series/search` both exist on the wire).
    private static let searchPathMarker = "/series/search"

    static func family(for path: String) -> Family {
        path.contains(searchPathMarker) ? .search : .general
    }

    /// The 429 backoff, kept separately per family — see the type's doc
    /// comment.
    private var blockedUntil: [Family: Date] = [:]
    private var consecutiveRateLimits: [Family: Int] = [:]

    /// Timestamps of the search requests let through in roughly the last
    /// `searchWindow`. Pruned to that window on every check, so this never
    /// grows past `searchLimit` entries.
    private var searchTimestamps: [Date] = []

    /// FIFO ticket queue for `.background` requests waiting on room in the
    /// search window. A `userInitiated` request never enters this queue — it
    /// is checked against the full window directly, which is what lets it
    /// "go out next" ahead of anything background already waiting (build
    /// note: "a simple FIFO where user-initiated jumps the queue").
    private var backgroundQueue: [UUID] = []

    /// The clock is injected — the same `Clock` protocol `SeriesRepository`
    /// and friends use for cache-expiry tests — so both the 429 backoff and
    /// the sliding window can be tested by moving time forward deliberately
    /// instead of by sleeping. A test that sleeps for a minute to prove a
    /// 60-second window is slow and flaky; a test that advances a clock is
    /// neither.
    private let clock: Clock

    init(clock: Clock = SystemClock()) {
        self.clock = clock
    }

    /// A ceiling on how long the server's own `Retry-After` is honoured for.
    ///
    /// GUESS: nothing on record says what MangaBaka actually sends on a 429
    /// (the existing tests' `Retry-After: 30` is hand-written, not captured).
    /// Without some cap, a malformed or unusually large value — an
    /// HTTP-date parsed wrong, or a server-side misconfiguration — would lock
    /// every request in the process for however long it said, with the
    /// screen reading "Retrying in N minutes." 15 minutes is long enough that
    /// no plausible real backoff hits it, short enough that a bad value
    /// cannot strand the app for the rest of a reading session.
    static let maxHonouredRetryAfter: TimeInterval = 15 * 60

    /// MangaBaka documents search at 30 requests a minute — the tightest of
    /// its published limits, and the one the rest of the app's traffic (180/
    /// minute) has no business being blocked by. See gap 8: a single 429 on
    /// search used to close Discover, detail and the library because they all
    /// shared one refusal clock.
    static let searchLimit = 30
    static let searchWindow: TimeInterval = 60

    /// GUESS, labelled per the brief: nothing measures what split keeps a
    /// foreground search from ever queuing. 10 leaves background work up to
    /// 20 of the 30 slots — enough to make real progress on lens counts and
    /// follow checks — while guaranteeing at least 10 are always free the
    /// instant the reader actually searches. Revisit once `NetworkLedger`
    /// shows how the two kinds of traffic actually interleave in practice.
    static let reserve = 10

    /// How long a `.background` waiter sleeps between checks for a free slot,
    /// rather than being woken exactly when one frees. GUESS: precise
    /// wake-on-expiry scheduling would need a second clock-driven timer
    /// wired through the same injected `Clock` tests use, for a caller that
    /// by definition does not need to the millisecond — this is background
    /// work waiting on a window measured in tens of seconds.
    private static let backgroundPollInterval: Duration = .milliseconds(200)

    /// Blocks until `path` may be attempted at `priority`, or throws
    /// `.rateLimited` when the family it belongs to is already refused —
    /// either the server's own 429 hasn't lapsed, or (for `.userInitiated`
    /// only) the local search window is genuinely full.
    ///
    /// A `.background` request never throws for a full *search window* the
    /// way `.userInitiated` does: instead it waits for room, because the
    /// caller chose to be invisible to begin with and losing a lens count
    /// silently later is worse than surfacing an error for work nobody is
    /// looking at. It still throws immediately for an actual 429 backoff —
    /// see `recordRateLimit` — since that means the server itself has
    /// refused, and waiting out a real 429 without limit would just be a
    /// slower way of hammering it.
    func reserveSlot(for path: String, priority: RequestPriority) async throws(APIError) {
        let family = Self.family(for: path)
        try throwIfBlocked(family)

        guard family == .search else { return }

        if priority == .userInitiated {
            pruneSearchWindow()
            guard searchTimestamps.count >= Self.searchLimit else {
                searchTimestamps.append(clock.now)
                return
            }
            throw APIError.rateLimited(
                until: searchTimestamps[0].addingTimeInterval(Self.searchWindow),
                party: .mangaBakaSearch
            )
        }

        try await waitForBackgroundSlot()
    }

    /// The 429-backoff half of `reserveSlot`, split out only so `reserveSlot`
    /// itself stays a single, readable sequence of "is this refused, is there room,
    /// otherwise wait".
    private func throwIfBlocked(_ family: Family) throws(APIError) {
        guard let until = blockedUntil[family] else { return }
        guard until > clock.now else {
            blockedUntil[family] = nil
            return
        }
        throw APIError.rateLimited(until: until, party: family == .search ? .mangaBakaSearch : .mangaBaka)
    }

    private func pruneSearchWindow() {
        let cutoff = clock.now.addingTimeInterval(-Self.searchWindow)
        searchTimestamps.removeAll { $0 <= cutoff }
    }

    /// Waits in `backgroundQueue`'s arrival order for one of the
    /// `searchLimit - reserve` slots background traffic is allowed, polling
    /// rather than being woken precisely — see `backgroundPollInterval`.
    /// Honours cancellation: a caller whose `Task` is cancelled while
    /// waiting — the reader left the screen this background work was for —
    /// throws `.cancelled` and never sends.
    private func waitForBackgroundSlot() async throws(APIError) {
        let ticket = UUID()
        backgroundQueue.append(ticket)
        defer { backgroundQueue.removeAll { $0 == ticket } }

        while true {
            if Task.isCancelled { throw APIError.cancelled }
            // A 429 earned by someone else's request (search is per-IP, not
            // per-request) while this one was waiting must still stop it.
            try throwIfBlocked(.search)
            pruneSearchWindow()
            if backgroundQueue.first == ticket, searchTimestamps.count < Self.searchLimit - Self.reserve {
                searchTimestamps.append(clock.now)
                return
            }
            do {
                try await Task.sleep(for: Self.backgroundPollInterval)
            } catch {
                // `Task.sleep` throws on cancellation; there is no other
                // failure mode for a fixed, finite duration.
                throw APIError.cancelled
            }
        }
    }

    /// - Parameters:
    ///   - retryAfter: the server's own `Retry-After`, in seconds. Honoured
    ///     when given, because the server knows better than any local guess —
    ///     but capped, same as the fallback below it, so a bad value cannot
    ///     lock the app out for longer than a transient spike could ever
    ///     justify. Otherwise back off exponentially, capped so the app cannot
    ///     lock itself out for minutes over a transient spike.
    ///   - path: which family earned this refusal. Only that family is
    ///     backed off — see the type's doc comment.
    func recordRateLimit(retryAfter: TimeInterval?, path: String) {
        let family = Self.family(for: path)
        let count = (consecutiveRateLimits[family] ?? 0) + 1
        consecutiveRateLimits[family] = count
        let fallback = min(pow(2, Double(count)), 60)
        let wait = min(retryAfter ?? fallback, Self.maxHonouredRetryAfter)
        blockedUntil[family] = clock.now.addingTimeInterval(wait)
    }

    /// A success clears only the family it succeeded in — a fine result from
    /// a search path says nothing about whether a general one is still being
    /// refused, and vice versa. The search sliding window is untouched: it
    /// counts requests actually made, regardless of whether they succeeded,
    /// because the local budget it tracks is MangaBaka's request count, not
    /// its error rate.
    func recordSuccess(path: String) {
        let family = Self.family(for: path)
        consecutiveRateLimits[family] = 0
        blockedUntil[family] = nil
    }
}
