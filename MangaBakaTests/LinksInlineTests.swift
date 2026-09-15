import Foundation
import Testing
@testable import MangaBaka

/// `/v1/series/{id}` carries the series' links inline (`links_v2`), and
/// `fetchExtras` reads them from there instead of spending a ninth request
/// on `/links` — checked live 2026-09-15: same 21 ids on series 2060, and
/// every field `SeriesLink` reads is inline. Serialized for the stub.
@Suite("Links come from the full record", .serialized)
struct LinksInlineTests {
    private let baseURL = URL(string: "https://api.example.invalid").unsafeTestURL

    /// A record shaped as the live one is, with two `links_v2` rows.
    private func body(id: Int) -> Data {
        Data("""
        {"status":200,"data":{"id":\(id),"state":"active","merged_with":null,"titles":null,
         "cover":{"raw":null,"x150":null,"x250":null,"x350":null,"blurhash":null,"width":null,"height":null},
         "description":null,"authors":null,"artists":null,"status":null,"rating":null,"type":null,
         "content_rating":null,"total_chapters":null,"final_volume":null,
         "publishers":null,"anime":null,"source":null,
         "links_v2":[
           {"id":"a","url":"https://namu.wiki/w/x","name":"namu.wiki","name_display":"Namuwiki",
            "type":"info","language":"ko"},
           {"id":"b","url":"https://example.invalid/read","name":"example","name_display":"Example",
            "type":"read","language":"en"}
         ]}}
        """.utf8)
    }

    @Test("extras reads links_v2 and never asks /links")
    func linksAreInline() async throws {
        URLProtocolStub.setHandler { [body = body(id: 2060)] request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/2060") { return .respond(.init(body: body)) }
            return .respond(.init(body: Data(#"{"status":200,"data":[]}"#.utf8)))
        }
        defer { URLProtocolStub.reset() }
        let repository = SeriesRepository(
            client: APIClient(
                baseURL: baseURL, session: URLProtocolStub.makeSession(),
                tokenProvider: UnauthenticatedTokenProvider()
            ),
            database: try AppDatabase.inMemory(), clock: TestClock()
        )

        let extras = await repository.extras(for: 2060)
        #expect(extras.failure == nil)
        #expect(extras.links.map(\.id) == ["a", "b"])
        #expect(extras.links.first?.nameDisplay == "Namuwiki")
        let paths = URLProtocolStub.requests.compactMap { $0.url?.path }
        #expect(!paths.contains { $0.hasSuffix("/links") }, "the /links leg is gone: \(paths)")
        #expect(paths.count == 5, "full, works, news, relationships, collections: \(paths)")
    }

    /// A record cached before `links_v2` existed decodes with nil links,
    /// not a decode failure that would empty the whole detail cache row.
    @Test("A record without links_v2 still decodes")
    func absentIsNil() throws {
        let data = Data("""
        {"id":1,"state":"active","merged_with":null,"titles":null,
         "cover":{"raw":null,"x150":null,"x250":null,"x350":null,"blurhash":null,"width":null,"height":null}}
        """.utf8)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let series = try decoder.decode(Series.self, from: data)
        #expect(series.linksV2 == nil)
    }
}
