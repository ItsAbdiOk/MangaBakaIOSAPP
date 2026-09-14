import Foundation
import Testing
@testable import MangaBaka

/// A stub that counts what it was asked.
private final class CountingRepository: StubRepositoryBase, @unchecked Sendable {
    private(set) var searchCount = 0
    var result = FeedResult(series: [SeriesFactory.make(id: 1, title: "S1")], origin: .network)

    override func search(_ query: SearchQuery) async -> FeedResult {
        searchCount += 1
        return result
    }
}

/// The search field's tokens and scopes (UX#6, 2026-09-13): the two pure
/// directions between the field and the query, so the round trip has a test
/// without a live `.searchable` field (this project has no ViewInspector).
@Suite("Search tokens and scopes")
struct SearchTokenTests {
    private var query: SearchQuery {
        var query = SearchQuery(text: "one piece")
        query.tags = ["Isekai", "Regression"]
        query.genres = ["slice_of_life"]
        query.publisher = "Seven Seas"
        query.statuses = ["releasing"]
        return query
    }

    /// Expected to fail on HEAD~ with: no such type `SearchToken`.
    @Test("The query's tags, genres and publisher are its tokens, in that order")
    func tokensReadTheQuery() {
        let tokens = SearchToken.tokens(for: query)
        #expect(tokens == [
            .tag("Isekai"), .tag("Regression"), .genre("slice_of_life"), .publisher("Seven Seas")
        ])
        #expect(tokens.map(\.label) == ["Isekai", "Regression", "Slice Of Life", "Seven Seas"])
        #expect(SearchToken.tokens(for: SearchQuery(text: "one")).isEmpty)
    }

    @Test("Writing the tokens back reproduces the query, and removing one removes only it")
    func tokensWriteTheQuery() {
        let original = query
        let roundTrip = SearchToken.applying(SearchToken.tokens(for: original), to: original)
        #expect(roundTrip == original)

        let without = SearchToken.applying([.tag("Regression"), .publisher("Seven Seas")], to: original)
        #expect(without.tags == ["Regression"])
        #expect(without.genres.isEmpty)
        #expect(without.publisher == "Seven Seas")
        #expect(without.text == "one piece", "the text is not a token and must survive")
        #expect(without.statuses == ["releasing"], "the panel's own filters must survive")
    }

    /// The scope bar is single-select; the panel's Type chips are not. One
    /// type reads as its scope, none or several as All.
    @Test("A scope is one type; several types read as All")
    func scopesAndTypes() {
        #expect(SearchScope.scope(for: ["manhwa"]) == .manhwa)
        #expect(SearchScope.scope(for: []) == .all)
        #expect(SearchScope.scope(for: ["manga", "manhwa"]) == .all)
        #expect(SearchScope.scope(for: ["Oel"]) == .oel)
        #expect(SearchScope.types(for: .oel) == ["oel"])
        #expect(SearchScope.types(for: .all).isEmpty)
        // "OEL", not "Oel": the series page's own spelling, reused.
        #expect(SearchScope.oel.label == "OEL")
        #expect(SearchScope.all.label == "All")
    }
}

/// What the model does for the field's Cancel, a removed token, and a
/// too-short query.
@Suite("Search field asks")
@MainActor
struct SearchFieldAskTests {
    /// Cancel: the platform empties the text; the model drops the tokens
    /// and the asked state with it. Expected to fail on HEAD~ with: no such
    /// method `cancelSearch`.
    @Test("Cancel clears the text and tokens and returns to idle")
    func cancelReturnsToIdle() async {
        let repository = CountingRepository()
        let model = SearchModel(repository: repository)
        model.query.text = "one"
        model.query.tags = ["Isekai"]
        model.query.publisher = "Seven Seas"
        model.query.statuses = ["releasing"]
        await model.search()
        #expect(model.hasAsked && !model.results.isEmpty, "sanity: something was asked and answered")

        model.cancelSearch()

        #expect(!model.hasAsked)
        #expect(model.results.isEmpty)
        #expect(model.query.text == nil)
        #expect(model.query.tags.isEmpty)
        #expect(model.query.publisher == nil)
        #expect(model.query.statuses == ["releasing"], "Cancel clears the field, not the panel")
        #expect(repository.searchCount == 1, "Cancel sends nothing")
    }

    /// A token removed mid-search re-asks; one removed on the idle panel
    /// does not — the panel is not an ask (UX#1).
    @Test("A changed token re-asks only once something was asked")
    func tokenChangeReasksAfterAnAsk() async throws {
        let repository = CountingRepository()
        let model = SearchModel(repository: repository)
        model.query.tags = ["Isekai"]
        model.filtersDidChange()
        // A single `Task.yield()` only proves the debounced Task has not run
        // *yet* — a regression that fired the search immediately, or after
        // one hop, would still read 0 here. Sleep past the 300ms debounce
        // instead, as `minimumLength` below already does.
        try await Task.sleep(for: .milliseconds(600))
        #expect(repository.searchCount == 0, "nothing asked, nothing sent")

        await model.search()
        #expect(repository.searchCount == 1)
        model.query.tags = []
        model.query.text = "one"
        model.filtersDidChange()
        let deadline = Date().addingTimeInterval(2)
        while repository.searchCount < 2, Date() < deadline { await Task.yield() }
        #expect(repository.searchCount == 2, "a token change over results is a new ask")
    }

    /// LW §2: one character fired a request and showed "30 shown" over
    /// titles with no "a" in them. Expected to fail on HEAD~ with:
    /// `repository.searchCount == 0` → actual `1`, and `!model.hasAsked`
    /// → actual `true`.
    @Test("One character is idle; two is a request")
    func minimumLength() async throws {
        let repository = CountingRepository()
        let model = SearchModel(repository: repository)

        model.query.text = "o"
        model.queryDidChange()
        #expect(!model.hasAsked, "one character is not a question")
        #expect(!model.isPending)
        // Past the 300 ms debounce at 2× margin.
        try await Task.sleep(for: .milliseconds(600))
        #expect(repository.searchCount == 0)

        // Return on one character sends nothing either.
        await model.search()
        #expect(repository.searchCount == 0)
        #expect(!model.hasAsked)

        model.query.text = "on"
        model.queryDidChange()
        #expect(model.hasAsked && model.isPending)
        try await Task.sleep(for: .milliseconds(600))
        #expect(repository.searchCount == 1)
    }

    /// E "Minimum length": the request's floor and Recent's floor are one
    /// number, so nothing asked is too short to remember and nothing
    /// remembered was too short to ask.
    @Test("The request minimum and the Recent minimum agree")
    func recentAgreesWithRequest() throws {
        let store = try #require(UserDefaults(suiteName: "SearchTokenTests.recents"))
        store.removePersistentDomain(forName: "SearchTokenTests.recents")
        let recents = RecentSearches(defaults: store)
        let short = String(repeating: "a", count: SearchQuery.minimumTextLength - 1)
        let enough = String(repeating: "a", count: SearchQuery.minimumTextLength)

        recents.record(short)
        recents.record(enough)

        #expect(recents.terms == [enough])
        #expect(SearchQuery(text: short).askedText == nil)
        #expect(SearchQuery(text: enough).askedText == enough)
        #expect(!SearchQuery(text: short).queryItems.contains { $0.name == "q" })
    }
}
