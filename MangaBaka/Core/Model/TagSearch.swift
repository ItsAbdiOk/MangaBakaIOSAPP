import Foundation

/// Finding one tag among 7,127.
///
/// Both tag pickers used to filter the 500 tags they had already loaded, which
/// is not a search: `/v1/tags?limit=500` does not contain Romance, so typing it
/// emptied the screen. Measured against the live API on 2026-09-10.
///
/// Local matches appear immediately and the API's answer merges in behind them,
/// so typing stays instant and still finds the other 6,627.
@MainActor
@Observable
final class TagSearch {
    /// The already-loaded popular tags, filtered locally while the request is
    /// in the air. Set by the screen that loaded them.
    var loaded: [Tag] = []

    private(set) var results: [Tag] = []
    private(set) var isSearching = false
    /// The request failed, as distinct from finding nothing. A screen must be
    /// able to say "could not search" rather than "no such tag".
    private(set) var didFail = false

    /// How a remote search is actually performed.
    ///
    /// A function rather than the service, so the debounce and the failure
    /// path can be tested. Those are the two halves that matter and neither is
    /// reachable through a real `CatalogueService` without a network: the file
    /// sat at 15.4% covered, with only the pure merge exercised.
    private let search: (String) async -> [Tag]?
    private var task: Task<Void, Never>?

    /// How long typing settles before a request goes out. Long enough that a
    /// word is one request rather than seven.
    static let debounce: Duration = .milliseconds(250)

    init(catalogue: CatalogueService) {
        self.search = { await catalogue.searchTags($0) }
    }

    init(search: @escaping (String) async -> [Tag]?) {
        self.search = search
    }

    /// What to show for the current query. Empty query means the popular list.
    func update(query: String) {
        task?.cancel()
        didFail = false

        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            results = []
            isSearching = false
            return
        }

        // Immediately, from what is already here. The remote answer replaces
        // this a moment later; it never replaces it with less.
        results = loaded.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
        isSearching = true

        task = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled, let self else { return }
            let remote = await search(trimmed)
            guard !Task.isCancelled else { return }
            isSearching = false
            guard let remote else {
                // Keep whatever local matches are on screen; only claim failure
                // when there is nothing to show at all.
                didFail = results.isEmpty
                return
            }
            results = Self.merge(local: results, remote: remote)
        }
    }

    /// What to say when a search came back with nothing.
    ///
    /// One sentence, in one place. Both tag pickers wrote their own copy of
    /// this ternary, which is two chances for "could not search" and "no such
    /// tag" to drift apart — and they are different claims: one is about the
    /// network, the other is about the tag.
    func emptyMessage(for query: String) -> String {
        didFail ? "Could not search tags just now." : "No tag matches \"\(query)\"."
    }

    /// Local hits first — they are the popular tags, and the reader is most
    /// likely to mean one of them — then everything else the API found.
    nonisolated static func merge(local: [Tag], remote: [Tag]) -> [Tag] {
        var seen = Set(local.map(\.id))
        var merged = local
        for tag in remote where !seen.contains(tag.id) {
            seen.insert(tag.id)
            merged.append(tag)
        }
        return merged
    }
}
