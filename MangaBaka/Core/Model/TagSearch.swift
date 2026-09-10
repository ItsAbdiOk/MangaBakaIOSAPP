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

    private let catalogue: CatalogueService
    private var task: Task<Void, Never>?

    init(catalogue: CatalogueService) {
        self.catalogue = catalogue
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
            // Long enough that typing a word is one request, not seven.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            let remote = await catalogue.searchTags(trimmed)
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
