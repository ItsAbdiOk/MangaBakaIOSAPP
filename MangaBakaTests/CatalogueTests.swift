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
        let first = await service.genres()
        let second = await service.genres()

        #expect(URLProtocolStub.requests.count == 1)
        // One request is only a saving if the second answer is the first one.
        // A cache that stored the response and returned [] passed this before.
        #expect(first.map(\.label) == ["Action"])
        #expect(second == first)
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

    /// `founded`/`closed` are `string|null, format: date` on the wire, not the
    /// `Int?`/`Bool?` this used to type them as — verified live 2026-09-13,
    /// `/v1/publishers/search?q=Kodansha` sends `"founded": "2008-07-01"` on
    /// Kodansha USA. Fails without the fix: decoding `"founded":"2008-07-01"`
    /// into an `Int?` throws, `[PublisherRecord]` is one array under `try?`
    /// (`CatalogueService.swift:130`), and `searchPublishers` returns nil —
    /// expected to fail with: `publishers?.first?.name == "A-1 Pictures (English)"`,
    /// since `publishers` itself would be nil.
    @Test("Publishers decode a founding date, and a closing one")
    func decodesPublishers() async {
        URLProtocolStub.setHandler { _ in
            .respond(.init(body: Data("""
            {"status":200,"data":[
              {"id":84,"type":"publisher","sub_type":"both","aliases":null,
               "parent_id":null,"name":"A-1 Pictures (English)","languages":null,
               "country_of_origin":"JP","founded":"2008-07-01","closed":null},
              {"id":5,"type":"publisher","sub_type":"both","aliases":null,
               "parent_id":null,"name":"Tokyopop","languages":null,
               "country_of_origin":"US","founded":"1997-01-01","closed":"2011-05-01"}
            ]}
            """.utf8)))
        }
        defer { URLProtocolStub.reset() }

        let publishers = await makeService().searchPublishers("a-1")
        #expect(publishers?.first?.name == "A-1 Pictures (English)")
        #expect(publishers?.first?.countryOfOrigin == "JP")
        #expect(publishers?.first?.founded == "2008-07-01")
        #expect(publishers?.first?.closed == nil)
        #expect(publishers?.last?.closed == "2011-05-01")
    }

    /// `q=Ize Press (Yen Press)` answers `[]` live (measured 2026-09-13) — the
    /// directory does not index the composite string a series' English-print
    /// credit sometimes is. Fails without the fix: `findPublisher` gives up
    /// after that one empty search and returns nil, rather than also trying
    /// "Ize Press" and "Yen Press" on their own.
    @Test("A composite 'imprint (parent)' name is also tried as its two halves")
    func findsPublisherFromCompositeName() async {
        URLProtocolStub.setHandler { request in
            let query = request.url?.query ?? ""
            if query.contains("Yen%20Press") || query.contains("Yen+Press") {
                return .respond(.init(body: Data("""
                {"status":200,"data":[{"id":18,"name":"Yen Press"}]}
                """.utf8)))
            }
            return .respond(.init(body: Data(#"{"status":200,"data":[]}"#.utf8)))
        }
        defer { URLProtocolStub.reset() }

        let found = await makeService().findPublisher(named: "Ize Press (Yen Press)")
        #expect(found?.name == "Yen Press")
    }

    /// `q=Kodansha` answers `["Kodansha USA","Kodansha Manga","Kodansha"]`
    /// live (measured 2026-09-13) — the exact match is third, not first.
    /// Fails without the fix: `?? hits.first` picks "Kodansha USA".
    @Test("An exact name match wins even when it is not the first result")
    func exactMatchBeatsFirstResult() async {
        URLProtocolStub.setHandler { _ in
            .respond(.init(body: Data("""
            {"status":200,"data":[
              {"id":1,"name":"Kodansha USA"},
              {"id":2,"name":"Kodansha Manga"},
              {"id":3,"name":"Kodansha"}
            ]}
            """.utf8)))
        }
        defer { URLProtocolStub.reset() }

        let found = await makeService().findPublisher(named: "Kodansha")
        #expect(found?.name == "Kodansha")
    }

    /// Same three results, a name none of them are. Fails without the fix:
    /// `?? hits.first` decorates the page with "Kodansha USA", a different
    /// publisher that merely starts the same way.
    @Test("A name matching nothing in the results is nil, not the first result")
    func noMatchIsNilNotFirstResult() async {
        URLProtocolStub.setHandler { _ in
            .respond(.init(body: Data("""
            {"status":200,"data":[
              {"id":1,"name":"Kodansha USA"},
              {"id":2,"name":"Kodansha Manga"},
              {"id":3,"name":"Kodansha"}
            ]}
            """.utf8)))
        }
        defer { URLProtocolStub.reset() }

        let found = await makeService().findPublisher(named: "Kodansha Comics")
        #expect(found == nil)
    }

    /// S9: the name is trimmed before it reaches the wire, even though the
    /// server also trims — being explicit here means the app does not depend
    /// on that.
    @Test("A publisher name is trimmed before it is sent")
    func findPublisherTrimsTheName() async {
        URLProtocolStub.setHandler { _ in
            .respond(.init(body: Data(#"{"status":200,"data":[{"id":1,"name":"Seven Seas"}]}"#.utf8)))
        }
        defer { URLProtocolStub.reset() }

        _ = await makeService().findPublisher(named: "  Seven Seas  ")
        let sentQuery = URLProtocolStub.requests.first?.url?.query ?? ""
        #expect(!sentQuery.contains("%20%20") && !sentQuery.contains("++"))
    }

    @Test("A failed catalogue fetch degrades to empty rather than throwing")
    func failureIsEmpty() async {
        URLProtocolStub.setHandler { _ in .fail(URLError(.notConnectedToInternet)) }
        defer { URLProtocolStub.reset() }

        #expect(await makeService().genres().isEmpty)
        #expect(await makeService().tags().isEmpty)
    }

    /// W12: `genres()`/`tags()` still answer `[]` on failure — every existing
    /// caller is unaffected — but a caller that cares can now tell "nothing
    /// there" from "the network failed" through this additive flag.
    @Test("A failed genres/tags fetch is flagged, not just silently empty")
    func fetchFailureIsFlagged() async {
        URLProtocolStub.setHandler { _ in .fail(URLError(.notConnectedToInternet)) }
        defer { URLProtocolStub.reset() }

        let service = makeService()
        #expect(await service.genres().isEmpty)
        #expect(await service.genresFetchFailed == true)
        #expect(await service.tags().isEmpty)
        #expect(await service.tagsFetchFailed == true)
    }

    @Test("A successful genres/tags fetch clears the failure flag")
    func fetchSuccessClearsFlag() async {
        URLProtocolStub.setHandler { _ in
            .respond(.init(body: Data(#"{"status":200,"data":[]}"#.utf8)))
        }
        defer { URLProtocolStub.reset() }

        let service = makeService()
        _ = await service.genres()
        #expect(await service.genresFetchFailed == false)
        _ = await service.tags()
        #expect(await service.tagsFetchFailed == false)
    }

    /// A failed search is nil, not empty: the screen says so instead of
    /// claiming no publisher has that name.
    @Test("A failed publisher search is distinguishable from no matches")
    func publisherFailureIsNil() async {
        URLProtocolStub.setHandler { _ in .fail(URLError(.networkConnectionLost)) }
        defer { URLProtocolStub.reset() }
        #expect(await makeService().searchPublishers("seven") == nil)
    }

    /// One dropped packet at launch used to cache an empty vocabulary for the
    /// whole process: every Browse screen after it showed no genres and no
    /// tags, and the only way back was to relaunch.
    @Test("A failed fetch is not cached; the next ask tries again")
    func failureIsRetried() async {
        let queue = ResponseQueue()
        URLProtocolStub.setHandler { _ in queue.next() }
        defer { URLProtocolStub.reset() }

        let service = makeService()
        queue.fail = true
        #expect(await service.genres().isEmpty)
        #expect(await service.tags().isEmpty)

        queue.fail = false
        #expect(await service.genres().count == 1, "The retry must reach the network")
        #expect(await service.tags().count == 1)
    }

    /// `TagTaxonomy.bundled()` answers `[]` both when the packaged resource
    /// is missing/corrupt and when it is genuinely empty; `loadFailed` is the
    /// additive signal that tells the two apart. Whatever the test bundle's
    /// `Bundle.main` actually holds, the two must agree: no rows only when
    /// the load itself failed.
    @Test("The bundled taxonomy's empty and failed states agree with each other")
    func bundledTaxonomyReportsFailureConsistently() {
        if TagTaxonomy.bundled().isEmpty {
            #expect(TagTaxonomy.loadFailed)
        } else {
            #expect(!TagTaxonomy.loadFailed)
        }
    }

    /// Switchable between failing and answering, from inside the stub's
    /// `@Sendable` handler.
    private final class ResponseQueue: @unchecked Sendable {
        private let lock = NSLock()
        private var failing = false
        var fail: Bool {
            get { lock.lock(); defer { lock.unlock() }; return failing }
            set { lock.lock(); defer { lock.unlock() }; failing = newValue }
        }

        func next() -> URLProtocolStub.Outcome {
            if fail { return .fail(URLError(.networkConnectionLost)) }
            // The real keys (`V1_Series_Tag`, matching `tagPayload` above):
            // `merged_with`, not `merged_into`; `name_path`, not `full_name`.
            // Every field is optional, so the wrong keys used to decode fine
            // and this retry proved itself against a payload that has never
            // existed on the wire.
            return .respond(.init(body: Data(#"""
            {"status":200,"data":[{"id":1,"name":"Action","label":"Action","value":"action",
             "name_path":"Action","level":0,"parent_id":null,"series_count":10,"merged_with":null}]}
            """#.utf8)))
        }
    }
}
