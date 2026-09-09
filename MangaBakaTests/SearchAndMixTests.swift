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
        _ = try await makeRepository().search(query)

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
        _ = try await makeRepository().search(query)

        let sent = try items(from: URLProtocolStub.requests.first)
        #expect(sent.filter { $0.name == "type" }.count == 2)
        #expect(sent.filter { $0.name == "status" }.count == 1)
        #expect(!sent.contains { ($0.value ?? "").contains(",") && $0.name == "type" })
    }

    @Test("Search applies the content-rating filter server-side")
    func searchFiltersContent() async throws {
        URLProtocolStub.setHandler { [payload = emptyPayload] _ in .respond(.init(body: payload)) }
        defer { URLProtocolStub.reset() }

        _ = try await makeRepository().search(SearchQuery(text: "x"))

        let ratings = try items(from: URLProtocolStub.requests.first)
            .filter { $0.name == "content_rating" }
        #expect(Set(ratings.compactMap(\.value)) == ["safe", "suggestive"])
    }

    /// Comma-joining the seeds is rejected outright: "Invalid input: expected
    /// number, received NaN at series[0]", HTTP 400, verified against the live
    /// endpoint on 2026-09-09. The bug survived because a single seed contains
    /// no comma — the stack only broke once there were two things to blend.
    @Test("Mix seeds are sent as repeated keys, never comma-joined")
    func mixSeedsAreRepeated() async throws {
        URLProtocolStub.setHandler { [payload = emptyPayload] _ in .respond(.init(body: payload)) }
        defer { URLProtocolStub.reset() }

        let repository = try makeRepository()
        _ = await repository.feed(.mix(seeds: [11, 22, 33]), forceRefresh: true)

        let sent = try items(from: URLProtocolStub.requests.first)
        let seeds = sent.filter { $0.name == "series" }
        #expect(seeds.count == 3)
        #expect(seeds.compactMap(\.value) == ["11", "22", "33"])
        #expect(!seeds.contains { ($0.value ?? "").contains(",") })
    }

    @Test("The mix endpoint used directly sends repeated seeds too")
    func directMixSeedsAreRepeated() async throws {
        URLProtocolStub.setHandler { [payload = emptyPayload] _ in .respond(.init(body: payload)) }
        defer { URLProtocolStub.reset() }

        let repository = try makeRepository()
        _ = await repository.mix(seeds: [11, 22], filters: SearchQuery())

        let seeds = try items(from: URLProtocolStub.requests.first)
            .filter { $0.name == "series" }
        #expect(seeds.compactMap(\.value) == ["11", "22"])
    }

    /// The API rejects a seedless mix with HTTP 400. Spending a request to be
    /// told that is pure waste against a shared per-IP budget.
    @Test("A seedless mix never reaches the network")
    func seedlessMixMakesNoRequest() async throws {
        URLProtocolStub.setHandler { [payload = emptyPayload] _ in .respond(.init(body: payload)) }
        defer { URLProtocolStub.reset() }

        let results = try await makeRepository().mix(seeds: [], filters: SearchQuery())

        #expect(results.isEmpty)
        #expect(URLProtocolStub.requests.isEmpty, "No seeds means no request at all")
    }

    /// This test used to assert the opposite, on the strength of a comment
    /// rather than a request. Both were wrong, and the wrong test is why the
    /// bug survived: it locked in the encoding that the API rejects.
    @Test("A blend still carries the content filter")
    func mixKeepsContentFilter() async throws {
        URLProtocolStub.setHandler { [payload = emptyPayload] _ in .respond(.init(body: payload)) }
        defer { URLProtocolStub.reset() }

        let repository = try makeRepository()
        _ = await repository.mix(seeds: [1, 2, 3], filters: SearchQuery())

        let sent = try items(from: URLProtocolStub.requests.first)
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
        _ = try await makeRepository().mix(seeds: [7], filters: filters)

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

        let results = try await makeRepository().mix(seeds: [3397], filters: SearchQuery())

        #expect(results.count == 1)
        #expect(results.first?.series.displayTitle == "Blend")
        #expect(results.first?.reason == "Directly related")
    }

    /// A reason is shown only when the API gave a basis for one.
    @Test("No match data means no invented reason")
    func noReasonWhenNoBasis() {
        let series = SeriesFactory.make()
        let bare = Recommendation(
            series: series, score: nil, sharedTags: nil, sharedTagsTotal: nil,
            matchedAuthor: false, matchedRelated: false
        )
        #expect(bare.reason == nil)
    }
}

/// The stack card shows tag chips, and the lean v2 schema omits tags entirely,
/// so the surprise path has to ask for the full one or the chips silently never
/// render. Verified against the live API 2026-09-09: lean returns no tags,
/// `schema=full` returns 30.
@Suite("Stack card data", .serialized)
struct StackCardDataTests {
    private let baseURL = URL(string: "https://api.example.invalid").unsafeTestURL

    @Test("The surprise feed asks for the schema that carries tags")
    func surpriseAsksForTags() async throws {
        URLProtocolStub.setHandler { _ in
            .respond(.init(body: Data(#"{"status":200,"data":[]}"#.utf8)))
        }
        defer { URLProtocolStub.reset() }

        let repository = SeriesRepository(
            client: APIClient(
                baseURL: baseURL,
                session: URLProtocolStub.makeSession(),
                tokenProvider: UnauthenticatedTokenProvider()
            ),
            database: try AppDatabase.inMemory(),
            clock: TestClock()
        )
        _ = await repository.feed(.surprise, forceRefresh: true)

        let url = try #require(URLProtocolStub.requests.first?.url)
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.first { $0.name == "schema" }?.value == "full")
    }

    /// Tags arrive as plain strings from v1 and as objects from v2's full
    /// schema. Both have to land as names or the chips are empty on one path.
    @Test("Tag names decode from both API shapes")
    func tagsDecodeFromBothShapes() throws {
        let decoder = Fixture.decoder()
        let v1 = try decoder.decode(Series.self, from: Data("""
        {"id":1,"state":"active","cover":{},"tags":["Revenge","Historical"]}
        """.utf8))
        #expect(v1.tags == ["Revenge", "Historical"])

        let v2 = try decoder.decode(Series.self, from: Data("""
        {"id":1,"state":"active","cover":{},
         "tags":[{"id":38,"name":"Revenge"},{"id":39,"name":"Historical"}]}
        """.utf8))
        #expect(v2.tags == ["Revenge", "Historical"])
    }

    /// No endpoint carries year, rating count and tags together, so the meta
    /// line has to render whichever parts arrived.
    @Test("Year and rating count decode whether string or number")
    func metaFieldsAreLenient() throws {
        let decoder = Fixture.decoder()
        let asNumbers = try decoder.decode(Series.self, from: Data("""
        {"id":1,"state":"active","cover":{},"year":2005,"rating_count":1128}
        """.utf8))
        #expect(asNumbers.year == 2005)
        #expect(asNumbers.ratingCount == 1128)

        let asStrings = try decoder.decode(Series.self, from: Data("""
        {"id":1,"state":"active","cover":{},"year":"2005","rating_count":"1128"}
        """.utf8))
        #expect(asStrings.year == 2005)
        #expect(asStrings.ratingCount == 1128)
    }
}

/// Saved lenses filter by tag, which is a parameter the app had never sent.
@Suite("Search lenses", .serialized)
struct SearchLensTests {
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

    private func items(from request: URLRequest?) throws -> [URLQueryItem] {
        let url = try #require(request?.url)
        return try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
    }

    /// Repeated keys, like every other list parameter on this API. The two that
    /// were comma-joined on a guess both returned HTTP 400.
    @Test("Tags are sent as repeated keys, with a mode only when combining")
    func tagsAreRepeated() async throws {
        URLProtocolStub.setHandler { _ in
            .respond(.init(body: Data(#"{"status":200,"data":[]}"#.utf8)))
        }
        defer { URLProtocolStub.reset() }

        let repository = try makeRepository()
        var query = SearchQuery()
        query.tags = ["Regression", "Comedy"]
        query.tagMode = "and"
        _ = await repository.search(query)

        let sent = try items(from: URLProtocolStub.requests.first)
        #expect(sent.filter { $0.name == "tag" }.compactMap(\.value) == ["Regression", "Comedy"])
        #expect(sent.first { $0.name == "tag_mode" }?.value == "and")
        #expect(!sent.contains { $0.name == "tag" && ($0.value ?? "").contains(",") })
    }

    /// One tag cannot be combined with anything, so a mode would be noise.
    @Test("A single tag sends no mode")
    func singleTagSendsNoMode() async throws {
        URLProtocolStub.setHandler { _ in
            .respond(.init(body: Data(#"{"status":200,"data":[]}"#.utf8)))
        }
        defer { URLProtocolStub.reset() }

        let repository = try makeRepository()
        var query = SearchQuery()
        query.tags = ["Seinen"]
        query.tagMode = "and"
        _ = await repository.search(query)

        let names = try items(from: URLProtocolStub.requests.first).map(\.name)
        #expect(names.contains("tag"))
        #expect(!names.contains("tag_mode"))
    }

    /// A lens is only useful if it actually narrows anything; an empty query
    /// would return before reaching the network and the screen would sit on its
    /// idle state looking broken — which is exactly how "Surprise me" failed.
    @Test("Every preset lens is a real query", arguments: SearchLens.presets)
    func presetsAreNotEmpty(_ lens: SearchLens) {
        #expect(!lens.query.isEmpty, "\(lens.name) would never reach the network")
        #expect(!lens.rule.isEmpty)
    }
}
