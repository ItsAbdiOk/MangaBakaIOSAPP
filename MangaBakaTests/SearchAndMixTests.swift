import Foundation
import Testing
@testable import MangaBaka

/// Search and mix send parameters the API is fussy about. These assert the
/// shape of the outgoing URL, because that is precisely the class of bug that
/// slipped through before: a comma-joined content_rating broke every feed while
/// lint and every other test stayed green.
@Suite("Search and mix requests", .serialized)
struct SearchAndMixTests {
    private let baseURL = URL(string: "https://api.example.invalid").unsafeTestURL

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

    private let emptyPayload = Data(#"{"status":200,"data":[]}"#.utf8)

    private func items(from request: URLRequest?) throws -> [URLQueryItem] {
        let url = try #require(request?.url)
        return try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
    }

    @Test("An untouched filter is not sent, so it cannot narrow results by accident")
    func omitsUnsetFilters() async throws {
        URLProtocolStub.setHandler { [payload = emptyPayload] _ in .respond(.init(body: payload)) }
        defer { URLProtocolStub.reset() }

        var query = SearchQuery()
        query.text = "solo"
        _ = await try makeRepository().search(query)

        let names = Set(try items(from: URLProtocolStub.requests.first).map(\.name))
        #expect(names.contains("q"))
        #expect(!names.contains("type"))
        #expect(!names.contains("status"))
        #expect(!names.contains("rating_lower"))
    }

    @Test("Multi-select filters are sent as repeated keys")
    func multiSelectIsRepeated() async throws {
        URLProtocolStub.setHandler { [payload = emptyPayload] _ in .respond(.init(body: payload)) }
        defer { URLProtocolStub.reset() }

        var query = SearchQuery()
        query.types = ["manga", "manhwa"]
        query.statuses = ["releasing"]
        _ = await try makeRepository().search(query)

        let sent = try items(from: URLProtocolStub.requests.first)
        #expect(sent.filter { $0.name == "type" }.count == 2)
        #expect(sent.filter { $0.name == "status" }.count == 1)
        #expect(!sent.contains { ($0.value ?? "").contains(",") && $0.name == "type" })
    }

    @Test("Search applies the content-rating filter server-side")
    func searchFiltersContent() async throws {
        URLProtocolStub.setHandler { [payload = emptyPayload] _ in .respond(.init(body: payload)) }
        defer { URLProtocolStub.reset() }

        _ = await try makeRepository().search(SearchQuery(text: "x"))

        let ratings = try items(from: URLProtocolStub.requests.first)
            .filter { $0.name == "content_rating" }
        #expect(Set(ratings.compactMap(\.value)) == ["safe", "suggestive"])
    }

    /// The API rejects a seedless mix with HTTP 400. Spending a request to be
    /// told that is pure waste against a shared per-IP budget.
    @Test("A seedless mix never reaches the network")
    func seedlessMixMakesNoRequest() async throws {
        URLProtocolStub.setHandler { [payload = emptyPayload] _ in .respond(.init(body: payload)) }
        defer { URLProtocolStub.reset() }

        let results = await try makeRepository().mix(seeds: [], filters: SearchQuery())

        #expect(results.isEmpty)
        #expect(URLProtocolStub.requests.isEmpty, "No seeds means no request at all")
    }

    /// `series` genuinely is comma-separated, unlike content_rating. The API is
    /// inconsistent, so each parameter is encoded the way that parameter wants.
    @Test("Mix seeds are comma-joined into a single series parameter")
    func mixSeedsAreCommaJoined() async throws {
        URLProtocolStub.setHandler { [payload = emptyPayload] _ in .respond(.init(body: payload)) }
        defer { URLProtocolStub.reset() }

        _ = await try makeRepository().mix(seeds: [1, 2, 3], filters: SearchQuery())

        let sent = try items(from: URLProtocolStub.requests.first)
        let seeds = try #require(sent.first { $0.name == "series" }?.value)
        #expect(seeds == "1,2,3")
        #expect(sent.contains { $0.name == "content_rating" }, "Filtering still applies to mix")
    }

    /// Free text and sort belong to search, not to a blend. Passing them
    /// through would quietly change what the mix means.
    @Test("Mix drops search-only parameters")
    func mixDropsSearchOnlyParameters() async throws {
        URLProtocolStub.setHandler { [payload = emptyPayload] _ in .respond(.init(body: payload)) }
        defer { URLProtocolStub.reset() }

        var filters = SearchQuery()
        filters.text = "ignored"
        filters.sort = "random"
        filters.types = ["manga"]
        _ = await try makeRepository().mix(seeds: [7], filters: filters)

        let names = Set(try items(from: URLProtocolStub.requests.first).map(\.name))
        #expect(!names.contains("q"))
        #expect(!names.contains("sort_by"))
        #expect(names.contains("type"), "Real filters still apply")
    }

    @Test("Mix unwraps the recommendation and keeps the reason it matched")
    func mixKeepsReason() async throws {
        let body = Data("""
        {"status":200,"data":[
          {"score":0.58,"cosine":0.4,"matched_author":false,"matched_related":true,
           "shared_tags":[{"id":1,"name":"Necromancy"}],"shared_tags_total":88,
           "series":{"id":9,"state":"active","merged_with":null,
             "titles":[{"language":"en","traits":["official"],"title":"Blend","is_primary":true}],
             "cover":{"raw":null,"x150":null,"x250":null,"x350":null,
                      "blurhash":null,"width":200,"height":300},
             "description":null,"authors":null,"artists":null,"status":null,
             "rating":null,"type":null,"content_rating":null,
             "total_chapters":null,"final_volume":null}}
        ]}
        """.utf8)
        URLProtocolStub.setHandler { _ in .respond(.init(body: body)) }
        defer { URLProtocolStub.reset() }

        let results = await try makeRepository().mix(seeds: [3397], filters: SearchQuery())

        #expect(results.count == 1)
        #expect(results.first?.series.displayTitle == "Blend")
        #expect(results.first?.reason == "Directly related")
    }

    /// A reason is shown only when the API gave a basis for one.
    @Test("No match data means no invented reason")
    func noReasonWhenNoBasis() {
        let cover = Cover(raw: nil, x150: nil, x250: nil, x350: nil,
                          blurhash: nil, width: nil, height: nil)
        let series = Series(
            id: 1, state: "active", mergedWith: nil, titles: nil, cover: cover,
            description: nil, authors: nil, artists: nil, status: nil,
            rating: nil, type: nil, contentRating: nil,
            totalChapters: nil, finalVolume: nil
        )
        let bare = Recommendation(
            series: series, score: nil, sharedTags: nil, sharedTagsTotal: nil,
            matchedAuthor: false, matchedRelated: false
        )
        #expect(bare.reason == nil)
    }
}
