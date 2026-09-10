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
    private var running: Task<Void, Never>?
    private let repository: any SeriesRepositoryProtocol

    init(repository: any SeriesRepositoryProtocol) {
        self.repository = repository
    }

    /// Fetches counts for lenses not yet counted this session.
    func load(_ lenses: [SearchLens]) {
        let pending = lenses.filter { !asked.contains($0.id) }
        guard !pending.isEmpty, running == nil else { return }
        pending.forEach { asked.insert($0.id) }

        running = Task { [repository] in
            for lens in pending {
                if Task.isCancelled { return }
                let total = await repository.count(lens.query)
                if let total { counts[lens.id] = total }
                try? await Task.sleep(for: Self.spacing)
            }
            running = nil
        }
    }

    /// Forgets a lens's count, so an edited lens is recounted rather than
    /// showing the old question's answer.
    func invalidate(_ id: String) {
        asked.remove(id)
        counts[id] = nil
    }

    func cancel() {
        running?.cancel()
        running = nil
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
