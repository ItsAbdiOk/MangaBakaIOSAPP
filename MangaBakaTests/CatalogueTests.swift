import Foundation
import Testing
@testable import MangaBaka

@Suite("Catalogue", .serialized)
struct CatalogueTests {
    private let baseURL = URL(string: "https://api.example.invalid").unsafeTestURL

    private func makeService() -> CatalogueService {
        CatalogueService(client: APIClient(
            baseURL: baseURL,
            session: URLProtocolStub.makeSession(),
            tokenProvider: UnauthenticatedTokenProvider()
        ))
    }

    @Test("Genres decode from their label/value pairs")
    func decodesGenres() async {
        URLProtocolStub.setHandler { _ in
            .respond(.init(body: Data("""
            {"status":200,"data":[{"label":"Action","value":"action"},
                                  {"label":"Slice of Life","value":"slice_of_life"}]}
            """.utf8)))
        }
        defer { URLProtocolStub.reset() }

        let genres = await makeService().genres()
        #expect(genres.map(\.value) == ["action", "slice_of_life"])
        #expect(genres.first?.label == "Action")
    }

    /// Genres and tags change rarely and the tag list is large. Re-fetching
    /// while browsing would spend a rate limit shared with strangers.
    @Test("The catalogue is fetched once, not per screen")
    func cachesAfterFirstFetch() async {
        URLProtocolStub.setHandler { _ in
            .respond(.init(body: Data(#"{"status":200,"data":[{"label":"Action","value":"action"}]}"#.utf8)))
        }
        defer { URLProtocolStub.reset() }

        let service = makeService()
        _ = await service.genres()
        _ = await service.genres()

        #expect(URLProtocolStub.requests.count == 1)
    }

    private let tagPayload = Data("""
    {"status":200,"data":[
      {"id":537,"parent_id":null,"merged_with":null,"name":"Activities",
       "name_path":"Activities","description":"Hobbies and pastimes.","level":0,
       "series_count":9000,"is_genre":false,"is_spoiler":false,"content_rating":null},
      {"id":538,"parent_id":537,"merged_with":null,"name":"Boxing",
       "name_path":"Activities > Sports > Boxing","description":null,"level":2,
       "series_count":120,"is_genre":false,"is_spoiler":false,"content_rating":null},
      {"id":539,"parent_id":537,"merged_with":700,"name":"Merged Away",
       "name_path":"Activities > Merged Away","description":null,"level":1,
       "series_count":5,"is_genre":false,"is_spoiler":false,"content_rating":null}
    ]}
    """.utf8)

    @Test("Tags decode with their hierarchy intact")
    func decodesTagTree() async {
        URLProtocolStub.setHandler { [tagPayload] _ in .respond(.init(body: tagPayload)) }
        defer { URLProtocolStub.reset() }

        let tags = await makeService().tags()

        let root = tags.first { $0.id == 537 }
        #expect(root?.isRoot == true)
        #expect(root?.level == 0)
        let leaf = tags.first { $0.id == 538 }
        #expect(leaf?.parentId == 537)
        #expect(leaf?.namePath == "Activities > Sports > Boxing")
    }

    /// A merged tag points at a survivor. Showing it would send the reader to
    /// a dead end, and linking to it would query a tag nothing uses.
    @Test("Merged tags are excluded")
    func excludesMergedTags() async {
        URLProtocolStub.setHandler { [tagPayload] _ in .respond(.init(body: tagPayload)) }
        defer { URLProtocolStub.reset() }

        let tags = await makeService().tags()
        #expect(!tags.contains { $0.id == 539 })
        #expect(tags.count == 2)
    }

    /// A tag on three series does not deserve the same row as one on nine
    /// thousand, so the list is ordered by how much it is actually used.
    @Test("Tags are ordered by how many series carry them")
    func ordersByUsage() async {
        URLProtocolStub.setHandler { [tagPayload] _ in .respond(.init(body: tagPayload)) }
        defer { URLProtocolStub.reset() }

        let tags = await makeService().tags()
        #expect(tags.map(\.seriesCount) == [9000, 120])
    }

    @Test("Children are found by parent, for walking the tree")
    func findsChildren() async {
        URLProtocolStub.setHandler { [tagPayload] _ in .respond(.init(body: tagPayload)) }
        defer { URLProtocolStub.reset() }

        let service = makeService()
        #expect(await service.children(of: nil).map(\.id) == [537])
        #expect(await service.children(of: 537).map(\.id) == [538])
    }

    @Test("Publishers decode, including a closed one")
    func decodesPublishers() async {
        URLProtocolStub.setHandler { _ in
            .respond(.init(body: Data("""
            {"status":200,"data":[
              {"id":84,"type":"publisher","sub_type":"both","aliases":null,
               "parent_id":null,"name":"A-1 Pictures (English)","languages":null,
               "country_of_origin":"JP","founded":2005,"closed":false}
            ]}
            """.utf8)))
        }
        defer { URLProtocolStub.reset() }

        let publishers = await makeService().searchPublishers("a-1")
        #expect(publishers.first?.name == "A-1 Pictures (English)")
        #expect(publishers.first?.countryOfOrigin == "JP")
        #expect(publishers.first?.closed == false)
    }

    @Test("A failed catalogue fetch degrades to empty rather than throwing")
    func failureIsEmpty() async {
        URLProtocolStub.setHandler { _ in .fail(URLError(.notConnectedToInternet)) }
        defer { URLProtocolStub.reset() }

        #expect(await makeService().genres().isEmpty)
        #expect(await makeService().tags().isEmpty)
    }
}
