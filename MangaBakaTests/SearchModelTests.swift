import Foundation
import Testing
@testable import MangaBaka

/// A stub that records what it was asked and can be made slow, so debounce
/// behaviour is testable without real time or a real network.
private final class RecordingRepository: StubRepositoryBase, @unchecked Sendable {
    private(set) var searchCount = 0
    private(set) var lastQuery: SearchQuery?
    var result = FeedResult(series: [], origin: .network)

    override func search(_ query: SearchQuery) async -> FeedResult {
        searchCount += 1
        lastQuery = query
        return result
    }
}

@Suite("Search model")
@MainActor
struct SearchModelTests {
    private func series(_ id: Int) -> Series {
        SeriesFactory.make(id: id, title: "S\(id)", cover: .sized)
    }

    /// Regression: `search()` used to cancel the debounce task it was running
    /// inside. The request died with NSURLErrorCancelled and `isSearching`
    /// stayed true forever — the reader saw a spinner that never resolved and
    /// no error explaining why.
    @Test("A debounced search completes and clears the loading state")
    func debouncedSearchCompletes() async throws {
        let repository = RecordingRepository()
        repository.result = FeedResult(series: [series(1)], origin: .network)
        let model = SearchModel(repository: repository)

        model.query.text = "solo"
        model.queryDidChange()
        try await Task.sleep(for: .milliseconds(600))

        #expect(repository.searchCount == 1, "The debounced search must actually run")
        #expect(model.results.count == 1)
        #expect(model.isSearching == false, "The spinner must not be left running")
    }

    @Test("The loading state clears even when nothing was found")
    func clearsLoadingOnEmpty() async {
        let repository = RecordingRepository()
        let model = SearchModel(repository: repository)
        model.query.text = "nothing"

        await model.search()

        #expect(model.isSearching == false)
        #expect(model.results.isEmpty)
    }

    @Test("A burst of keystrokes produces one request, not one per key")
    func debounceCollapsesABurst() async throws {
        let repository = RecordingRepository()
        let model = SearchModel(repository: repository)

        for text in ["s", "so", "sol", "solo"] {
            model.query.text = text
            model.queryDidChange()
        }
        try await Task.sleep(for: .milliseconds(600))

        #expect(repository.searchCount == 1, "30 req/min is shared with strangers on the same network")
        #expect(repository.lastQuery?.text == "solo")
    }

    @Test("Clearing the field drops results without calling the API")
    func clearingIsLocal() async {
        let repository = RecordingRepository()
        let model = SearchModel(repository: repository)
        model.query.text = ""

        model.queryDidChange()

        #expect(repository.searchCount == 0)
        #expect(model.results.isEmpty)
        #expect(model.isSearching == false)
    }
}
