import Foundation
import Testing
@testable import MangaBaka

/// Item 11 / wire W10: `CatalogueService.genres()` decoded `[Genre]` strictly
/// while its two siblings in the same file used `getLossy`.
///
/// Its own file rather than `CatalogueTests` only because that one is at the
/// 400-line ceiling.
///
/// Why it matters more here than at an ordinary call site: this is a
/// *vocabulary* endpoint, on the path of several browse surfaces at once, so
/// one unexpected row emptied the genre list everywhere rather than costing
/// one entry. `CatalogueService.publishers()`'s own comment records that exact
/// failure happening in production once.
@Suite("Catalogue lenient decoding", .serialized)
struct CatalogueLenientDecodeTests {
    private let baseURL = URL(string: "https://api.example.invalid").unsafeTestURL

    private func makeService() -> CatalogueService {
        CatalogueService(client: APIClient(
            baseURL: baseURL,
            session: URLProtocolStub.makeSession(),
            tokenProvider: UnauthenticatedTokenProvider()
        ))
    }

    /// `"value": 42` where a `String` is declared — the same shape as the four
    /// "model disagrees with the payload" defects the 2026-09-11 review found.
    ///
    /// Expected to fail on the old code with a wrong *value*, not a compile
    /// error (`get` and `getLossy` have the same signature here): `genres()`
    /// returned `.failed`, so `.value` is nil and the list reads empty where
    /// this wants two rows.
    @Test("One malformed genre row costs that row, not the vocabulary")
    func oneBadGenreRowDoesNotEmptyTheList() async {
        let body = #"{"status":200,"data":["#
            + #"{"label":"Action","value":"action"},"#
            + #"{"label":"Adventure","value":42},"#
            + #"{"label":"Comedy","value":"comedy"}]}"#
        URLProtocolStub.setHandler { _ in .respond(.init(body: Data(body.utf8))) }
        defer { URLProtocolStub.reset() }

        let genres = await makeService().genres().value ?? []
        #expect(genres.map(\.value) == ["action", "comedy"])
    }

    /// The control: the same payload with the bad row repaired decodes every
    /// row, so the assertion above is about lenience and not about a decode
    /// that has quietly started dropping things.
    @Test("Control: a clean payload drops nothing")
    func cleanGenrePayloadDropsNothing() async {
        let body = #"{"status":200,"data":["#
            + #"{"label":"Action","value":"action"},"#
            + #"{"label":"Adventure","value":"adventure"},"#
            + #"{"label":"Comedy","value":"comedy"}]}"#
        URLProtocolStub.setHandler { _ in .respond(.init(body: Data(body.utf8))) }
        defer { URLProtocolStub.reset() }

        let genres = await makeService().genres().value ?? []
        #expect(genres.map(\.value) == ["action", "adventure", "comedy"])
    }
}
