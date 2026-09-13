import Foundation
import Testing
@testable import MangaBaka

/// Guards the design doc's success criterion: a browsing session must stay far
/// inside MangaBaka's per-IP rate limit (30 req/min for search, 180 default).
///
/// The limit is shared by everyone behind the same NAT, so being frugal is not
/// only about staying under a cap — it is about not starving other readers on
/// the same mobile network.
@Suite("Request budget", .serialized)
struct RequestBudgetTests {
    private let baseURL = URL(string: "https://api.example.invalid").unsafeTestURL

    private func payload(count: Int) -> Data {
        let items = (0..<count).map { index in
            """
            {"id":\(index + 1),"state":"active","merged_with":null,
             "titles":[{"language":"en","traits":["official"],
                        "title":"S\(index)","is_primary":true}],
             "cover":{"raw":null,"x150":null,"x250":null,"x350":null,
                      "blurhash":null,"width":200,"height":300},
             "description":null,"authors":null,"artists":null,"status":null,
             "rating":null,"type":null,"content_rating":null}
            """
        }
        return Data(#"{"status":200,"data":[\#(items.joined(separator: ","))]}"#.utf8)
    }

    private func makeRepository() throws -> SeriesRepository {
        SeriesRepository(
            client: APIClient(
                baseURL: baseURL,
                session: URLProtocolStub.makeSession(),
                tokenProvider: UnauthenticatedTokenProvider()
            ),
            database: try AppDatabase.inMemory(),
            clock: TestClock()
        )
    }

    @Test("A cold feed load costs exactly one request")
    func coldLoadCostsOneRequest() async throws {
        URLProtocolStub.setHandler { [data = payload(count: 20)] _ in .respond(.init(body: data)) }
        defer { URLProtocolStub.reset() }

        let result = try await makeRepository().feed(.rising, forceRefresh: false)
        #expect(URLProtocolStub.requests.count == 1)
        // The request has to have bought something. A decode regression that
        // cached an empty feed would keep the count at one and the screen empty.
        #expect(result.series.count == 20)
    }

    /// The endpoint caps `limit` at 20 and the CDN holds the response for a
    /// day, so asking for less wastes budget for no benefit.
    @Test("The feed requests the maximum page size the endpoint allows")
    func requestsMaximumPageSize() async throws {
        URLProtocolStub.setHandler { [data = payload(count: 20)] _ in .respond(.init(body: data)) }
        defer { URLProtocolStub.reset() }

        _ = try await makeRepository().feed(.rising, forceRefresh: false)

        let url = try #require(URLProtocolStub.requests.first?.url?.absoluteString)
        #expect(url.contains("limit=20"))
    }

    /// The headline bound from the design doc, and the cache makes it easy:
    /// five feed reads at 20 cards each is 100 cards, on one request.
    @Test("A 100-card browsing session costs one request, well under the budget of 6")
    func hundredCardSessionStaysUnderBudget() async throws {
        URLProtocolStub.setHandler { [data = payload(count: 20)] _ in .respond(.init(body: data)) }
        defer { URLProtocolStub.reset() }

        let repository = try makeRepository()
        var cards = 0
        for _ in 0..<5 { cards += await repository.feed(.rising, forceRefresh: false).series.count }

        #expect(cards == 100, "The claim is a hundred cards; the count is what makes it one")
        #expect(URLProtocolStub.requests.count == 1,
                "100 cards cost \(URLProtocolStub.requests.count) requests; the cache should make it 1")
        #expect(URLProtocolStub.requests.count <= 6)
    }

    /// Even a reader who pulls to refresh repeatedly stays far inside 30/min.
    @Test("Five explicit refreshes cost five requests, not more")
    func refreshesCostOneEach() async throws {
        URLProtocolStub.setHandler { [data = payload(count: 20)] _ in .respond(.init(body: data)) }
        defer { URLProtocolStub.reset() }

        let repository = try makeRepository()
        for _ in 0..<5 { _ = await repository.feed(.rising, forceRefresh: true) }

        #expect(URLProtocolStub.requests.count == 5)
    }

    // MARK: - Search

    /// The suite's doc comment names "30 req/min for search" and, until
    /// 2026-09-13, every test above loaded `.rising` — the 180/min feed,
    /// not the 30/min window that actually bites (search review, tests
    /// finding 10). This is the Search tab's own budget: the flow a reader
    /// actually performs, through the real `SeriesRepository` and client,
    /// counted on the wire.
    ///
    /// The flow: six keystrokes 80ms apart (a real reader types at
    /// 80-150ms; the model's debounce is 300ms, so one request), open the
    /// filter sheet with the query still set (the panel asks for a preview
    /// count — `FilterPanel.swift:120`), then settle two chip toggles (one
    /// preview count each, after the panel's 350ms debounce). The panel is a
    /// SwiftUI view and cannot be driven here, so its two decisions —
    /// "count on appear with a non-empty query" and "count once per settled
    /// change" — are replayed as the `LensCounts.count` calls it makes.
    ///
    /// Batch 3 (the `.searchable` redesign) is measured against this number
    /// before and after; if it moves, the summary at
    /// `docs/reviews/search/SUMMARY.md` §8 says why it may.
    @Test("Typing a word, opening filters and toggling two chips costs four search-family requests")
    @MainActor
    func searchSessionCostsFourRequests() async throws {
        // Captured live 2026-09-13 20:27 UTC:
        // `GET https://api.mangabaka.org/v2/series/search?q=solo%20leveling&limit=1`
        // → 200, `pagination.count == 9`, one `SeriesV2` row (3397). The
        // first recorded `/v2/series/search` page in `Fixtures/` (summary
        // #44) — every earlier search-path test answered `{"data":[]}`.
        let body = try Fixture.data("search-solo-leveling")
        URLProtocolStub.setHandler { _ in .respond(.init(body: body)) }
        defer { URLProtocolStub.reset() }

        let repository = try makeRepository()
        let model = SearchModel(repository: repository)
        let counts = LensCounts(repository: repository)

        for typed in ["s", "so", "sol", "solo", "solo ", "solo l"] {
            model.query.text = typed
            model.queryDidChange()
            try await Task.sleep(for: .milliseconds(80))
        }
        // Past the 300ms debounce and the stubbed round trip.
        try await Task.sleep(for: .milliseconds(700))
        #expect(model.results.count == 1, "the one request has to have bought the page")

        // Open the sheet: the panel previews the count for the current query.
        let onOpen = await counts.count(model.query)
        #expect(onOpen == 9, "the count must read the fixture's own pagination.count")

        // Two chip toggles, each settled past the panel's debounce.
        model.query.types = ["manga"]
        _ = await counts.count(model.query)
        model.query.types = ["manga", "manhwa"]
        _ = await counts.count(model.query)

        let searchFamily = URLProtocolStub.requests.filter {
            $0.url?.path.contains("/series/search") == true
        }
        #expect(searchFamily.count == 4, "\(searchFamily.count) of the shared 30/min window for one flow")
        #expect(URLProtocolStub.requests.count == searchFamily.count, "nothing else may go out in this flow")

        // The three counts are one-row pages, not full pages: same window
        // slot, a fraction of the bytes.
        // `limit` is always `SearchQuery.queryItems`' first item.
        let queries = searchFamily.compactMap { $0.url?.query }
        #expect(queries.filter { $0.hasPrefix("limit=1&") }.count == 3)
        #expect(queries.filter { $0.hasPrefix("limit=30&") }.count == 1)
    }

    /// The same flow, against a stub that records *which* overload each ask
    /// arrived through — the wire cannot show priority, and the real gate is
    /// private to the client. The typed search is the reader's own and goes
    /// out `.userInitiated` (the real repository's plain `search(_:)` is
    /// defined as that); the three preview counts are the app's own idea and
    /// must go out `.background`, capped below the full window, or a reader
    /// flicking through rating segments spends the slots their own search
    /// needs (summary #4, `RateLimitGate`'s doc comment).
    ///
    /// Expected to fail on HEAD with: `countPriorities == [.background,
    /// .background, .background]` → actual `[nil, nil, nil]`, because
    /// `LensCounts.count(_:)` still calls the priority-less
    /// `repository.count(query)` (`LensCounts.swift:143`). Passes once Batch
    /// 1 Lane B lands the `.background` there.
    @Test("The typed search is the only user-initiated ask; every preview count is background")
    @MainActor
    func searchSessionCountsAreBackground() async throws {
        let repository = PriorityRecordingRepository()
        let model = SearchModel(repository: repository)
        let counts = LensCounts(repository: repository)

        model.query.text = "solo l"
        await model.search()
        _ = await counts.count(model.query)
        model.query.types = ["manga"]
        _ = await counts.count(model.query)
        model.query.types = ["manga", "manhwa"]
        _ = await counts.count(model.query)

        #expect(repository.searchPriorities.count == 1)
        #expect(repository.countPriorities == [.background, .background, .background])
        #expect(repository.searchFamilyAsks == 4, "the same four the wire test counts")
    }
}
