import Foundation

/// The live number beside each saved lens on Search's idle screen.
///
/// **A lens stores filters, not results**, so its count moves — that is the
/// point of showing one. "148 now" says the question still has an answer and
/// roughly how big it is, which is the difference between a saved search and a
/// bookmark.
///
/// **What it costs, and why it is built this way.** One count query per lens,
/// on a screen a reader lands on constantly. The rate limit is per IP and
/// shared with strangers on the same network, so this fetches:
///
/// - only when the idle screen is actually shown, never on launch,
/// - once per session per lens, cached thereafter,
/// - one at a time with a pause between, rather than a burst of six,
/// - and never for a lens whose row is not on screen.
///
/// Abdi chose the counted design knowingly on 2026-09-10, and the fallback the
/// design board offers is written down: drop the counts, show each lens's
/// filter summary instead. **If this turns out to cost too much, that is the
/// first thing to take off — and he should be told rather than it changing
/// quietly.**
@MainActor
@Observable
final class LensCounts {
    /// Nil means not fetched or not answered. Never confused with zero: a lens
    /// showing "0 now" is saying it found nothing, which is a real and much
    /// worse statement than saying nothing.
    private(set) var counts: [String: Int] = [:]

    /// Between requests. Enough that six lenses are a trickle rather than a
    /// burst against a limit shared with strangers.
    private static let spacing = Duration.milliseconds(250)

    private var asked: Set<String> = []
    /// Lenses waiting their turn, shared between calls to `load`.
    ///
    /// **Why a queue and not a per-call snapshot.** `load` used to capture
    /// its `pending` list once and hand it to a fresh `Task`, bailing out
    /// entirely (`guard running == nil`) whenever a walk was already going —
    /// so a lens saved *while* the idle screen's first walk was still
    /// counting the others got silently dropped: it was neither `asked` nor
    /// part of the running task's fixed list, and nothing asked for it again
    /// until the idle screen was torn down and rebuilt (gap 53). Draining a
    /// queue instead means a second `load` call during a walk only has to
    /// append to it — the running task's own loop picks the addition up on
    /// its next iteration, same as any lens it started with.
    private var queued: [SearchLens] = []
    /// The lens the walk is asking about right now, if any — between being
    /// taken off `queued` and either `asked` (it answered) or dropped (it
    /// failed). Without this, a `load` call arriving in that exact window
    /// would see the lens as neither queued nor asked and queue a second,
    /// redundant count request for the one already in flight.
    private var inFlight: Set<String> = []
    private var running: Task<Void, Never>?
    private let repository: any SeriesRepositoryProtocol

    /// What the spacing between counts sleeps against. Injected so a test can
    /// move time rather than sleep through six real 250 ms pauses (item 129).
    ///
    /// Spelled with its module because this one does not: `MangaBaka` has its
    /// own `Clock` protocol (`Core/Persistence/Clock.swift`, a source of
    /// "now" for cache expiry), and an unqualified `Clock` resolves to that.
    nonisolated let clock: any _Concurrency.Clock<Duration>

    init(
        repository: any SeriesRepositoryProtocol,
        clock: any _Concurrency.Clock<Duration> = ContinuousClock()
    ) {
        self.repository = repository
        self.clock = clock
    }

    /// Fetches counts for lenses not yet counted this session, queueing
    /// behind any walk already running rather than being dropped by it.
    ///
    /// A lens is "asked" once an answer lands, not once the walk starts.
    /// Marking all of them up front meant a walk cancelled by leaving the
    /// screen abandoned the lenses it had not reached for the session, and a
    /// count that did not come back was never asked for again — a
    /// cancellation and a failure both treated as answers.
    func load(_ lenses: [SearchLens]) {
        let queuedIDs = Set(queued.map(\.id))
        let pending = lenses.filter {
            !asked.contains($0.id) && !queuedIDs.contains($0.id) && !inFlight.contains($0.id)
        }
        queued.append(contentsOf: pending)
        // A walk is already draining `queued` — nothing more to start. But a
        // queue left behind by a cancelled walk has no walker, so the guard
        // is on the walker, not on whether this call added anything: with
        // the old `pending.isEmpty` early return, a second load after a
        // cancel found every lens already queued and started nothing.
        guard running == nil, !queued.isEmpty else { return }

        running = Task { [repository, clock] in
            // `defer` rather than resetting `running` only after the loop
            // exits normally: the 429-stop below is a new early `return`, and
            // without this it would leave `running` pointing at a finished
            // task forever, wedging every later `load()` call's `guard
            // running == nil` shut for the rest of the session.
            defer { running = nil }
            while !queued.isEmpty {
                if Task.isCancelled { return }
                let lens = queued.removeFirst()
                inFlight.insert(lens.id)
                // 2026-09-13: background priority. This walk is the app's own
                // idea, run the instant the idle screen appears — it must not
                // spend the same 30/min search window a reader's own typed
                // search needs.
                let total = await repository.count(lens.query, priority: .background)
                inFlight.remove(lens.id)
                guard let total else {
                    // A nil answer here is almost always the search window
                    // refusing this — `count` doesn't say which, but walking
                    // the rest of the queue would only ask each remaining
                    // lens the same question and get the same refusal one at
                    // a time (never retry into a 429). Stop; the lens this
                    // failed for, and everything still in `queued`, are
                    // neither `asked` nor removed from consideration, so the
                    // next `load()` call retries them.
                    return
                }
                counts[lens.id] = total
                asked.insert(lens.id)
                try? await clock.sleep(for: Self.spacing)
            }
        }
    }

    /// Forgets a lens's count, so an edited lens is recounted rather than
    /// showing the old question's answer. Also drops it from the queue: an
    /// edited-then-deleted lens re-added under a new id would otherwise sit
    /// behind a stale entry for the id that no longer exists.
    func invalidate(_ id: String) {
        asked.remove(id)
        queued.removeAll { $0.id == id }
        counts[id] = nil
    }

    func cancel() {
        running?.cancel()
        running = nil
        // The lens the cancelled walk was counting never reports back into
        // `asked`, so it must not stay marked in flight either.
        inFlight.removeAll()
    }

    /// A single ad hoc count for a query being built on the idle screen's
    /// filter panel — not a saved lens, so it bypasses `load`'s queue,
    /// dedup and cache entirely. This is one request for one query at a
    /// time, debounced by the caller (`FilterPanel`); nothing here needs to
    /// remember it happened.
    ///
    /// `.background`, like the lens walk above, and for the same reason: a
    /// preview is not a search. At the default `.userInitiated` it drew on
    /// the ten slots `RateLimitGate` reserves for the reader's own typed
    /// query, so a reader who toggled thirty chips in a minute was refused
    /// their next search by their own previews (review 2026-09-13, E F3 —
    /// the mechanism is certain; the thirty-toggle pace is a plausible-use
    /// claim, not a measurement). Background waits rather than fails, and
    /// the caller already cancels a superseded count.
    func count(_ query: SearchQuery) async -> Int? {
        await repository.count(query, priority: .background)
    }
}

/// What the reader searched for recently, on this device.
///
/// Raw terms, not lenses: a lens is a saved question, and this is just the last
/// few things typed. Shown as the search field's own suggestions while it is
/// empty (`SearchField`, since 2026-09-13; before that rows on the idle
/// screen, and before that chips alongside the presets that crowded the
/// screen — see `SearchLens`'s doc comment). `remove` and `clear` outlive
/// the rows that called them: the suggestion list has no × of its own, and
/// the store's rules are the store's, not the screen's.
@MainActor
@Observable
final class RecentSearches {
    private static let key = "search.recent"
    /// Six stored, so the history survives longer than the screen shows —
    /// only the newest four ever render (`visible(limit:)`), per Abdi's
    /// 2026-09-13 ask to keep "the last three or four searches" without
    /// throwing away what falls off the visible list.
    private static let limit = 6
    /// How many rows the idle screen actually draws. A guess at "three or
    /// four" read literally as the smaller number that still shows something
    /// useful without competing with Filters below it. `nonisolated` so
    /// `visible(_:limit:)` below can default to it without becoming
    /// actor-isolated itself.
    nonisolated static let visibleLimit = 4

    private(set) var terms: [String] = []
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        terms = defaults.stringArray(forKey: Self.key) ?? []
    }

    /// Records a term, moving a repeat to the front rather than listing it
    /// twice. Blank and whitespace-only searches are not searches, and
    /// neither is anything under `SearchQuery.minimumTextLength` — the same
    /// floor the request has, so nothing is remembered that could not have
    /// been asked, and nothing asked is too short to remember.
    func record(_ term: String) {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= SearchQuery.minimumTextLength else { return }
        terms.removeAll { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
        terms.insert(trimmed, at: 0)
        if terms.count > Self.limit { terms = Array(terms.prefix(Self.limit)) }
        defaults.set(terms, forKey: Self.key)
    }

    /// Drops one term the reader dismissed with its row's "×", rather than
    /// the whole list.
    func remove(_ term: String) {
        terms.removeAll { $0 == term }
        defaults.set(terms, forKey: Self.key)
    }

    func clear() {
        terms = []
        defaults.removeObject(forKey: Self.key)
    }

    /// The rows the idle screen actually draws: the newest `limit`, out of
    /// however many are stored. Pure and `nonisolated static` so it is
    /// testable without a live `RecentSearches` instance.
    nonisolated static func visible(_ terms: [String], limit: Int = RecentSearches.visibleLimit) -> [String] {
        Array(terms.prefix(max(0, limit)))
    }
}
