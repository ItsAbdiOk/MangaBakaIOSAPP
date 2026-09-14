import Foundation

/// Every failure the API layer can produce, named individually.
///
/// Deliberately not a catch-all: each case carries what the UI needs to
/// respond correctly. `rateLimited` in particular must not read as the user's
/// fault, because MangaBaka rate limits per IP — another person on the same
/// carrier NAT can exhaust the budget.
enum APIError: Error, Equatable {
    /// No network path. The caller should fall back to cached content.
    ///
    /// Carries no `Party`: losing the network is a device-level condition,
    /// not something any one server did, so there is nothing to name.
    case offline

    /// HTTP 429. Back off and serve cache.
    /// - Parameters:
    ///   - until: the deadline the window reopens, when the server (or the
    ///     gate's own backoff) gave one. A `Date` rather than the seconds
    ///     that used to sit here, so a countdown view can tick against it
    ///     with `TimelineView` instead of freezing the instant it was read —
    ///     see `retryAfter` below for what this replaced.
    ///   - party: who imposed the limit. Every third-party client can also
    ///     429 (AniList, Shikimori, MangaUpdates all do), and the body text
    ///     used to say "MangaBaka is throttling this connection" regardless.
    case rateLimited(until: Date?, party: Party = .mangaBaka)

    /// A non-2xx response carrying the API's own message.
    ///
    /// MangaBaka documents `message` as safe to show end users verbatim:
    /// "The `message` field can be safely shown to end-users, as it generally
    /// does not contain technical terminology." That guarantee is MangaBaka's
    /// own, not any other party's, so a non-MangaBaka `party` never passes its
    /// `message` through verbatim — see `userFacingMessage`.
    case server(status: Int, message: String, party: Party = .mangaBaka)

    /// The response was not valid JSON, or did not match the expected shape.
    case decoding(underlying: String, party: Party = .mangaBaka)

    /// Anything URLSession reported that is not covered above.
    case transport(underlying: String, party: Party = .mangaBaka)

    /// The request was cancelled — the reader left the screen, a newer
    /// request superseded it, or a `Task` was torn down. Not a failure of
    /// anything: the request simply stopped mattering. Named separately from
    /// `.transport` so `staleContentRemainsUseful` can say yes and callers can
    /// tell "the network is broken" from "nobody's waiting for this answer
    /// anymore" and drop it silently instead of flashing an error over
    /// content the reader is still looking at.
    ///
    /// `headline`/`userFacingMessage` exist only so every `APIError` has one —
    /// no caller should ever put a cancellation on screen.
    case cancelled

    /// Who answered — MangaBaka itself, or a third party MangaBaka's schedule
    /// and character data are stitched together from.
    ///
    /// `mangaBaka` is the default everywhere a `Party` is threaded through, so
    /// every construction site that predates this type keeps compiling
    /// unchanged.
    enum Party: Sendable, Equatable {
        case mangaBaka
        /// MangaBaka's own search endpoint specifically, not MangaBaka in
        /// general. 2026-09-13: `RateLimitGate` started backing search off
        /// separately from every other MangaBaka path (a 429 earned by
        /// search must not close the series page), and the copy needs to say
        /// which one paused — "Too many requests, briefly" for a reader whose
        /// series page just failed to load reads as the whole connection
        /// being throttled, when only search was. Not a real third party:
        /// `displayName` still says "MangaBaka", and this exists purely so
        /// `userFacingMessage`/`headline` can special-case it. Modelled as a
        /// `Party` rather than a new `rateLimited` associated value on
        /// purpose — `.rateLimited(until:party:)` already has ~25 call and
        /// pattern-match sites across the app (schedule clients, character
        /// clients, `FailureState`, several test suites); widening its
        /// associated-value tuple breaks every `case let .rateLimited(x, y)`
        /// there (arity must match exactly — verified, it does not degrade
        /// gracefully), where `Party` gaining a case only requires an
        /// exhaustive `switch Party` to be updated, and the only one in the
        /// app lives in this file.
        case mangaBakaSearch
        case aniList
        case shikimori
        case appleBooks
        case googleBooks
        case openLibrary
        case webtoons
        // `.naver` was here until 2026-09-14. Nothing could produce it: the
        // only client that named Naver as the failing party was deleted with
        // its private endpoint — see the tombstone in
        // `ReleaseFeedService.swift`.
        case gigaViewer
        case mangaUpdates
        /// Anime News Network's Encyclopedia API — the English print volume
        /// dates and ISBNs behind `ANNClient` (added 2026-09-14).
        case animeNewsNetwork
        /// NDL Search, Japan's national library catalogue — the Japanese and
        /// forthcoming print volumes behind `NDLClient` (added 2026-09-14).
        case nationalDietLibrary

        var displayName: String {
            switch self {
            case .mangaBaka, .mangaBakaSearch: "MangaBaka"
            case .aniList: "AniList"
            case .shikimori: "Shikimori"
            case .appleBooks: "Apple Books"
            case .googleBooks: "Google Books"
            case .openLibrary: "Open Library"
            case .webtoons: "Webtoons"
            case .gigaViewer: "GigaViewer"
            case .mangaUpdates: "MangaUpdates"
            case .animeNewsNetwork: "Anime News Network"
            // Not the Japanese name the credit uses
            // (`BookEdition.Source.credit`): this string lands mid-sentence
            // in an English failure message.
            case .nationalDietLibrary: "Japan's National Diet Library"
            }
        }
    }

    /// Who this particular failure came from. `.mangaBaka` for every case that
    /// carries no `Party` of its own (`.offline`, `.cancelled`), since neither
    /// names a server.
    var party: Party {
        switch self {
        case .offline, .cancelled: .mangaBaka
        case let .rateLimited(_, party): party
        case let .server(_, _, party): party
        case let .decoding(_, party): party
        case let .transport(_, party): party
        }
    }

    /// Compatibility constructor for the seconds-based payload this case used
    /// to carry directly. Every existing third-party client throws
    /// `.rateLimited(retryAfter: someSeconds)`; this keeps that call
    /// compiling and converts to the `Date` the case now stores.
    ///
    /// New call sites — `RateLimitGate`, `APIClient` — should prefer
    /// `.rateLimited(until:party:)` directly, since they already have the
    /// deadline rather than a duration to convert.
    static func rateLimited(retryAfter seconds: TimeInterval?, party: Party = .mangaBaka) -> APIError {
        // A third-party `Retry-After` is a hostile or merely broken input —
        // `Party` exists to distrust it — and `AniListClient`,
        // `MangaUpdatesClient` and friends all pass this straight from the
        // wire with no cap of their own. A finite-but-astronomical value
        // (`1e300`) sails past `isFinite` and turns into a `Date` so far in
        // the future that `humanDuration` traps computing minutes from it
        // (`Int((wholeSeconds / 60).rounded())` on ~1e298). Clamping here,
        // at the one place every caller's seconds become a `Date`, means
        // every reader of `rateLimitDeadline`/`countdown` downstream can
        // assume the deadline is sane without re-checking it themselves.
        // Same ceiling MangaBaka's own 429s are held to — see
        // `RateLimitGate.maxHonouredRetryAfter` — for the same reason: no
        // plausible real backoff needs longer, and no bad value should be
        // able to strand the app past it. (wire review #2/#8, 2026-09-14)
        let clamped = seconds.flatMap {
            $0.isFinite ? min(max($0, 0), RateLimitGate.maxHonouredRetryAfter) : nil
        }
        return .rateLimited(until: clamped.map { Date().addingTimeInterval($0) }, party: party)
    }

    /// The deadline a countdown should tick against, or nil for anything
    /// that is not a rate limit — or a rate limit nobody dated. A `Date`
    /// rather than `countdown`'s string so `Countdown` can re-read it every
    /// second; `FailureState` had this as a private copy and the stale bar
    /// over live results could not reach it, which is why that bar showed
    /// the string frozen at render instead (review R F9, 2026-09-13).
    var rateLimitDeadline: Date? {
        guard case let .rateLimited(until, _) = self else { return nil }
        return until
    }

    /// The seconds remaining, computed from `until` against the current time,
    /// for callers written against the old seconds-based payload. Recomputed
    /// on every access rather than cached, because "seconds remaining" is
    /// only ever true at the instant it's read.
    var retryAfter: TimeInterval? {
        guard case let .rateLimited(until, _) = self, let until else { return nil }
        return max(until.timeIntervalSinceNow, 0)
    }

    /// A short, plain phrase for a wait, e.g. "30 seconds" or "2 minutes".
    ///
    /// Rounds to the nearest whole second *before* choosing the seconds-or-
    /// minutes branch. `countdown` now feeds this a live
    /// `until.timeIntervalSinceNow` rather than a value fixed at throw time,
    /// so a caller asking for "60 seconds away" a few microseconds later gets
    /// 59.9999-something — rounding after the branch test would read that as
    /// "60 seconds" instead of "1 minute".
    private static func humanDuration(_ seconds: TimeInterval) -> String {
        let wholeSeconds = seconds.rounded()
        if wholeSeconds < 60 {
            // `rateLimited(retryAfter:party:)` clamps every seconds value
            // that becomes a `Date` before this ever runs, so `wholeSeconds`
            // should already be small — but `countdown` recomputes from
            // `until.timeIntervalSinceNow` live, and `Int(_:)` on a plain
            // `Double` still traps outside ±9.2e18. `Int(wholeOrClamped:)`
            // is the same belt-and-braces the clamp above already is (wire
            // review #2/#8, 2026-09-14).
            let rounded = max(Int(wholeOrClamped: wholeSeconds), 1)
            return "\(rounded) second\(rounded == 1 ? "" : "s")"
        }
        let minutes = max(Int(wholeOrClamped: (wholeSeconds / 60).rounded()), 1)
        return "\(minutes) minute\(minutes == 1 ? "" : "s")"
    }

    /// Whether showing stale content alongside this error is the right call.
    /// A rate limit or an outage says nothing about the cached copy, so the
    /// content stays; a decoding failure means the shape changed, and stale
    /// content may be misleading. A cancellation says nothing about the
    /// content either — the reader simply isn't waiting on this answer
    /// anymore, so whatever is already on screen is still exactly as good.
    var staleContentRemainsUseful: Bool {
        switch self {
        case .offline, .rateLimited, .server, .cancelled: true
        case .decoding, .transport: false
        }
    }

    /// Whether the reader can fix this by connecting an account. Only ever
    /// true for MangaBaka itself: a third party rejecting a request is never
    /// fixed by the reader's MangaBaka token.
    var needsAccount: Bool {
        if case let .server(status, _, party) = self, party == .mangaBaka {
            return status == 401 || status == 403
        }
        return false
    }

    /// A symbol suited to the cause, so the screen reads at a glance.
    var symbolName: String {
        switch self {
        case .offline: "wifi.slash"
        case .rateLimited: "hourglass"
        case .server: needsAccount ? "person.crop.circle.badge.plus" : "exclamationmark.triangle"
        case .decoding, .transport: "questionmark.circle"
        case .cancelled: "xmark.circle"
        }
    }

    /// A message safe to display. Never surfaces technical detail for cases
    /// where the user can act, and never blames the user for a shared limit.
    ///
    /// Wording from the design board, 2026-09-10. Each one names what happened,
    /// then what is still true — because on every one of these screens
    /// something *is* still true, and a reader who is told only about the
    /// failure assumes the whole app is broken.
    var userFacingMessage: String {
        switch self {
        case .offline:
            "Showing what was downloaded. Nothing new can load until you're back."
        case .rateLimited(_, .mangaBakaSearch):
            // Distinct from the plain MangaBaka case below: a reader on the
            // series page whose search-window budget got spent by background
            // work should not read "MangaBaka is throttling this connection"
            // as if the whole page had failed — only search is paused, and
            // everything already on screen keeps working.
            """
            Search is paused, briefly. The limit is shared by everyone on \
            your network, and everything else on this page keeps working.
            """
        case let .rateLimited(_, party) where party != .mangaBaka:
            // Not "shared by everyone on your network": that fact is
            // MangaBaka's own admission about its own per-IP limit, and
            // nothing on record says a third party's limit works the same
            // way, so it is not repeated for one.
            """
            \(party.displayName) is asking us to slow down. Nothing is wrong on \
            this phone, and what you already have is still here.
            """
        case .rateLimited:
            // Never phrased as the reader's fault. The limit is per IP and
            // shared, so this can be triggered entirely by a stranger on the
            // same network — and that sentence is in the body rather than a
            // footnote because it is the only line in the family that defends
            // the reader.
            """
            MangaBaka is throttling this connection. The limit is shared by \
            everyone on your network, so this may not be you at all.
            """
        // 401 and 403 have a fix the reader can actually carry out, and the
        // API's own message for them ("Unauthenticated.") names a state, not
        // an action.
        case let .server(_, message, party):
            if needsAccount {
                """
                Your library, recommendations and schedule are tied to a \
                MangaBaka token. Discovery, search and the stack keep working \
                without one.
                """
            } else if party == .mangaBaka {
                if !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // The API's own words when it has any. It documents these
                    // as safe to show, and "That series doesn't exist." tells
                    // a reader something the design board's generic line
                    // cannot. The board wrote for the case where the server
                    // says nothing useful; it did not know the server often
                    // says something better.
                    message
                } else {
                    """
                    Their server answered with an error. Nothing is wrong on this \
                    phone, and what you already have is still here.
                    """
                }
            } else {
                // A third party's own wording is never passed through
                // verbatim: MangaBaka documents its `message` as reader-safe,
                // nothing on record makes the same promise for anyone else,
                // and in practice these read like "AniList returned 403." —
                // a status code, not a sentence a reader can use.
                """
                \(party.displayName) answered with an error. Nothing is wrong on \
                this phone, and what you already have is still here.
                """
            }
        case .decoding:
            """
            The answer wasn't in a shape this version understands. Cached \
            copies were cleared, because they may no longer be accurate.
            """
        case .transport:
            "The request didn't complete."
        case .cancelled:
            // Never meant to reach a screen — the whole point of this case is
            // that callers drop it silently — but it needs real words rather
            // than an empty string in case one forgets to check.
            "This didn't finish, because something else happened first."
        }
    }

    /// The headline above `userFacingMessage`.
    ///
    /// Decode and transport share one, deliberately: a reader cannot act on the
    /// difference between them, and two near-identical screens only invite them
    /// to hunt for one.
    var headline: String {
        switch self {
        case .offline: "You're offline"
        case .rateLimited(_, .mangaBaka): "Too many requests, briefly"
        case .rateLimited(_, .mangaBakaSearch): "Search is paused, briefly"
        case let .rateLimited(_, party): "\(party.displayName) had a problem"
        case let .server(_, _, party):
            if needsAccount {
                "This part needs an account"
            } else if party == .mangaBaka {
                "MangaBaka had a problem"
            } else {
                "\(party.displayName) had a problem"
            }
        case .decoding, .transport: "Something went wrong"
        case .cancelled: "Cancelled"
        }
    }

    /// "Retrying in 38s.", when the server said how long to wait.
    ///
    /// Its own property rather than part of the message because it is the one
    /// piece of this family that is a live number: it belongs at the end of the
    /// body in bold, and it is absent when the server did not say.
    var countdown: String? {
        guard case let .rateLimited(until, _) = self,
              let until
        else { return nil }
        let remaining = until.timeIntervalSinceNow
        guard remaining.isFinite, remaining > 0 else { return nil }
        return "Retrying in \(Self.humanDuration(remaining))."
    }
}
