import Foundation

/// Backing state for the Search screen.
///
/// Every keystroke updates `query`, but the network call is debounced: the API
/// caps search at 30 requests a minute per IP, and that budget is shared with
/// everyone else on the same network (a carrier NAT, a campus Wi-Fi). Firing a
/// request per keystroke would burn through it in a couple of words typed and
/// starve other people's searches, not just waste this app's own quota.
@MainActor
@Observable
final class SearchModel {
    var query = SearchQuery()
    private(set) var results: [Series] = []
    private(set) var isSearching = false
    private(set) var message: String?

    private let repository: any SeriesRepositoryProtocol
    private var debounceTask: Task<Void, Never>?

    init(repository: any SeriesRepositoryProtocol) {
        self.repository = repository
    }

    /// Called on every edit to `query` from the view. Cancels whatever debounce
    /// or in-flight search is pending and starts a fresh 300ms wait, so only
    /// the last keystroke in a burst ever reaches the network.
    func queryDidChange() {
        debounceTask?.cancel()
        guard !query.isEmpty else {
            results = []
            message = nil
            isSearching = false
            return
        }
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await self?.search()
        }
    }

    /// Runs the search immediately, bypassing debounce. Used for explicit
    /// triggers: submitting the field, applying filters, or "Surprise me".
    ///
    /// Deliberately does NOT cancel `debounceTask`. It used to, which meant a
    /// debounced search cancelled the very task it was running inside: the
    /// request died with NSURLErrorCancelled, the cancellation guard returned
    /// early, and `isSearching` stayed true forever — an eternal spinner with
    /// no results and no error. Cancelling the pending debounce is the caller's
    /// business, not this method's.
    func search() async {
        guard !query.isEmpty else {
            results = []
            message = nil
            isSearching = false
            return
        }
        isSearching = true
        // A deferred reset, so no early return can strand the spinner again.
        defer { isSearching = false }

        let result = await repository.search(query)
        guard !Task.isCancelled else { return }
        results = result.series
        message = result.series.isEmpty ? result.blockingError?.userFacingMessage : nil
    }

    /// Drops a pending debounce without touching an in-flight search. Call this
    /// before an explicit `search()` so a queued keystroke cannot re-fire after
    /// the reader has already submitted.
    func cancelPendingDebounce() {
        debounceTask?.cancel()
    }
}
