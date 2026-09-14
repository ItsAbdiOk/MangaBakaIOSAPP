import Foundation

/// Holds requests back after the API says we are over its limit, and before
/// it ever has the chance to.
///
/// MangaBaka rate limits per IP — 30 requests a minute for search, 180
/// otherwise — and that budget is shared with everyone behind the same address:
/// a carrier NAT, a campus network, a household. Retrying into a 429 does not
/// only waste this app's quota, it keeps other people's requests failing too.
///
/// So a 429 is remembered and the client refuses locally until the window
/// passes, rather than discovering the same refusal over and over. Each
/// family additionally gets a local sliding-window count, enforced *before*
/// the 30th (or 181st) request of the minute is even sent — a client that
/// already knows its own budget should not have to spend a real request to be
/// told it is over. Until item 31 only search had that window; the 180/min
/// general limit was published here in this very comment and enforced by
/// nothing, so the launch path found it by earning a 429.
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
/// `RequestPriority.background` is now capped at `family.limit -
/// family.reserve` slots, in whichever family it belongs to, and waits for
/// room instead of either failing or competing for the last few slots against
/// a request the reader is looking at right now.
actor RateLimitGate {
    /// Which of MangaBaka's two published limits a path counts against. A
    /// 429 or a local budget check applies to one, never both — the two are
    /// enforced independently by the server itself (30/min search, 180/min
    /// everything else), so this app's own memory of them has to match.
    enum Family: Sendable, Hashable, CaseIterable {
        case search
        case general

        /// Requests a minute MangaBaka publishes for this family. These two
        /// numbers are the API's, not a guess: 30/min for search, 180/min for
        /// everything else. Both are per IP, so the budget is shared with
        /// everyone behind the same address.
        var limit: Int {
            switch self {
            case .search: 30
            case .general: 180
            }
        }

        /// Slots held back from `.background` so a request the reader is
        /// looking at never has to queue behind invisible work.
        ///
        /// **Both are a guess.** Nothing measures what split keeps a
        /// foreground request from ever waiting; `NetworkLedger` is where the
        /// evidence would come from once it shows how the two kinds of
        /// traffic actually interleave. Search's 10 is the figure that has
        /// been in place since 2026-09-13. General's 60 is this change's own
        /// guess, chosen as the same one-third proportion — the launch path
        /// alone (the Spotlight reindex, reminder links, publisher-follow
        /// checks) can put dozens of general requests in flight while the
        /// reader is opening a series page, which is exactly the collision
        /// the reserve exists for.
        var reserve: Int {
            switch self {
            case .search: 10
            case .general: 60
            }
        }

        /// The window both limits are expressed over.
        var window: TimeInterval { 60 }

        /// Who a refusal in this family is attributed to, for the screen.
        var party: APIError.Party { self == .search ? .mangaBakaSearch : .mangaBaka }
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

    /// Timestamps of the requests let through in roughly the last window,
    /// per family. Pruned to that window on every check, so neither list ever
    /// grows past its family's limit.
    ///
    /// **The general window is new (item 31).** Until this change only search
    /// had a local sliding window; the 180/min general limit was published,
    /// documented in this file's own doc comment, and enforced by nothing —
    /// the app discovered it by earning a 429, which is exactly the "spend a
    /// real request to be told you are over" the search window exists to
    /// avoid, and it is shared with everyone behind the same IP.
    private var timestamps: [Family: [Date]] = [:]

    /// FIFO ticket queue for `.background` requests waiting on room, per
    /// family. A `userInitiated` request never enters this queue — it is
    /// checked against the full window directly, which is what lets it "go
    /// out next" ahead of anything background already waiting (build note:
    /// "a simple FIFO where user-initiated jumps the queue").
    private var backgroundQueue: [Family: [UUID]] = [:]

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
    ///
    /// Kept as names because tests and comments across the project use them.
    /// The values live on `Family` now, so there is one place to change.
    static let searchLimit = Family.search.limit
    static let searchWindow: TimeInterval = Family.search.window

    /// See `Family.reserve`, which this now reads from — the number is a
    /// guess and is labelled as one there.
    static let reserve = Family.search.reserve

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
    /// - Returns: the timestamp just appended to this path's family window —
    ///   **either family**, search or general — so a caller that turns out not
    ///   to have needed the slot (a URLCache hit that never touched the
    ///   network, or an attempt that never left the device at all) can hand it
    ///   back to `refund(path:reservedAt:)` precisely, rather than guessing
    ///   which entry was its own among requests running concurrently. Nil only
    ///   when nothing was appended — a `.background` reservation that claimed
    ///   no timestamp of its own.
    ///
    ///   Until 2026-09-14 this said the return was "the timestamp appended to
    ///   `searchTimestamps`" and nil "for a general-family path, which never
    ///   reserves anything to begin with". There is no `searchTimestamps` any
    ///   more — it is `timestamps: [Family: [Date]]` — and general-family paths
    ///   have had their own 180/min window since the same day, so the old text
    ///   told the reader the exact opposite of what the code below does, and
    ///   that `APIClient`'s refunds were no-ops for them.
    @discardableResult
    func reserveSlot(for path: String, priority: RequestPriority) async throws(APIError) -> Date? {
        let family = Self.family(for: path)
        try throwIfBlocked(family)

        if priority == .userInitiated {
            prune(family)
            var held = timestamps[family] ?? []
            guard held.count >= family.limit else {
                let reservedAt = clock.now
                held.append(reservedAt)
                timestamps[family] = held
                return reservedAt
            }
            // The oldest request in the window is the one whose expiry frees
            // the next slot, so that is when this family reopens.
            throw APIError.rateLimited(
                until: held[0].addingTimeInterval(family.window),
                party: family.party
            )
        }

        return try await waitForBackgroundSlot(family)
    }

    /// Hands back a slot `reserveSlot` reserved on this caller's behalf,
    /// because it turned out to need none of the server's real budget. The
    /// family is looked up from the path below, so this covers the general
    /// window as well as the search one — it is not search-only, whatever the
    /// name of `searchTimestampCountForTesting` suggests.
    ///
    /// - a URLCache hit answered the request without a network round trip
    ///   (wire review #30) — `reserveSlot` and the ledger both ran before
    ///   `APIClient.perform` could know that, so both a search slot and a
    ///   ledger row were spent on a request MangaBaka never saw; or
    /// - the attempt never left the device at all: `.offline` or
    ///   `.cancelled` (wire review #13, folded into #30's fix since both are
    ///   "the slot was reserved for nothing"). Deliberately *not* the generic
    ///   `.transport` case: a TLS or DNS failure may well have reached the
    ///   host, so that slot stays spent.
    ///
    ///   `recordSuccess`'s own comment
    ///   already draws this line for *failed* requests that did reach the
    ///   server — those still count, because the local budget tracks
    ///   MangaBaka's own request count, not this app's error rate. An
    ///   attempt that never reached MangaBaka is not one of its requests at
    ///   all, so it should never have counted against MangaBaka's window in
    ///   the first place.
    ///
    /// Removes exactly the timestamp `reservedAt` names, not merely "the
    /// last one" — concurrent search requests can interleave between
    /// `reserveSlot` and the refund of an earlier one, and removing the
    /// wrong entry would refund someone else's slot instead of this
    /// caller's own.
    func refund(path: String, reservedAt: Date?) {
        let family = Self.family(for: path)
        guard let reservedAt, var held = timestamps[family],
              let index = held.firstIndex(of: reservedAt)
        else { return }
        held.remove(at: index)
        timestamps[family] = held
    }

    /// Test-only: the number of search-window timestamps currently held.
    /// Exposed so a test can prove `refund` actually removes the slot it
    /// names, rather than inferring it indirectly by nearly exhausting a
    /// 30-slot window.
    var searchTimestampCountForTesting: Int { (timestamps[.search] ?? []).count }

    /// Test-only: the same count for either family, so the general window
    /// item 31 added can be asserted the same way the search one is.
    func timestampCountForTesting(_ family: Family) -> Int { (timestamps[family] ?? []).count }

    /// The 429-backoff half of `reserveSlot`, split out only so `reserveSlot`
    /// itself stays a single, readable sequence of "is this refused, is there room,
    /// otherwise wait".
    private func throwIfBlocked(_ family: Family) throws(APIError) {
        guard let until = blockedUntil[family] else { return }
        guard until > clock.now else {
            blockedUntil[family] = nil
            return
        }
        throw APIError.rateLimited(until: until, party: family.party)
    }

    private func prune(_ family: Family) {
        let cutoff = clock.now.addingTimeInterval(-family.window)
        timestamps[family]?.removeAll { $0 <= cutoff }
    }

    /// Waits in `backgroundQueue`'s arrival order for one of the
    /// `searchLimit - reserve` slots background traffic is allowed, polling
    /// rather than being woken precisely — see `backgroundPollInterval`.
    /// Honours cancellation: a caller whose `Task` is cancelled while
    /// waiting — the reader left the screen this background work was for —
    /// throws `.cancelled` and never sends.
    private func waitForBackgroundSlot(_ family: Family) async throws(APIError) -> Date {
        let ticket = UUID()
        backgroundQueue[family, default: []].append(ticket)
        defer { backgroundQueue[family]?.removeAll { $0 == ticket } }

        while true {
            if Task.isCancelled { throw APIError.cancelled }
            // A 429 earned by someone else's request (the limits are per-IP,
            // not per-request) while this one was waiting must still stop it.
            try throwIfBlocked(family)
            prune(family)
            let held = timestamps[family] ?? []
            if backgroundQueue[family]?.first == ticket,
               held.count < family.limit - family.reserve {
                let reservedAt = clock.now
                timestamps[family] = held + [reservedAt]
                return reservedAt
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
    /// - Returns: the deadline just recorded — the one date every screen
    ///   should count down against. Returned rather than recomputed by the
    ///   caller because `APIClient` used to build its own from the header
    ///   alone, so a 429 with no `Retry-After` (the schema's `V1_Error_429`
    ///   promises none) reached the reader as `until: nil` — a static
    ///   "Search is paused" with no countdown and no automatic retry — while
    ///   this gate had already worked out exactly when it would reopen.
    @discardableResult
    func recordRateLimit(retryAfter: TimeInterval?, path: String) -> Date {
        let family = Self.family(for: path)
        let count = (consecutiveRateLimits[family] ?? 0) + 1
        consecutiveRateLimits[family] = count
        let fallback = min(pow(2, Double(count)), 60)
        let wait = min(retryAfter ?? fallback, Self.maxHonouredRetryAfter)
        let until = clock.now.addingTimeInterval(wait)
        blockedUntil[family] = until
        return until
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
