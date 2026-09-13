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

    init(repository: any SeriesRepositoryProtocol) {
        self.repository = repository
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

        running = Task { [repository] in
            while !queued.isEmpty {
                if Task.isCancelled { return }
                let lens = queued.removeFirst()
                inFlight.insert(lens.id)
                let total = await repository.count(lens.query)
                inFlight.remove(lens.id)
                if let total {
                    counts[lens.id] = total
                    asked.insert(lens.id)
                }
                try? await Task.sleep(for: Self.spacing)
            }
            running = nil
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
}

/// What the reader searched for recently, on this device.
///
/// Raw terms, not lenses: a lens is a saved question, and this is just the last
/// few things typed. They are shown as chips rather than rows for exactly that
/// reason — a chip is a shortcut that fills the field, a row is a thing with a
/// count that can break.
@MainActor
@Observable
final class RecentSearches {
    private static let key = "search.recent"
    /// Six. Enough to catch the thing you typed and lost, few enough that the
    /// section never competes with the lenses above it.
    private static let limit = 6

    private(set) var terms: [String] = []
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        terms = defaults.stringArray(forKey: Self.key) ?? []
    }

    /// Records a term, moving a repeat to the front rather than listing it
    /// twice. Blank and whitespace-only searches are not searches.
    func record(_ term: String) {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 1 else { return }
        terms.removeAll { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
        terms.insert(trimmed, at: 0)
        if terms.count > Self.limit { terms = Array(terms.prefix(Self.limit)) }
        defaults.set(terms, forKey: Self.key)
    }

    func clear() {
        terms = []
        defaults.removeObject(forKey: Self.key)
    }
}
