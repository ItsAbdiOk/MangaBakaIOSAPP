import Foundation
import Testing
@testable import MangaBaka

/// What happens when one of Browse's two vocabulary requests fails and the
/// other does not.
@Suite("Browse vocabulary retry", .serialized)
@MainActor
struct BrowseVocabularyRetryTests {
    private let baseURL = URL(string: "https://api.example.invalid").unsafeTestURL

    private func makeCatalogue() -> CatalogueService {
        CatalogueService(client: APIClient(
            baseURL: baseURL,
            session: URLProtocolStub.makeSession(),
            tokenProvider: UnauthenticatedTokenProvider()
        ))
    }

    /// `load()` returned early whenever `tags` was non-empty, so a
    /// genres-only failure — one of the two requests failing while the other
    /// answered — left the genre row empty for the rest of the session with
    /// nothing that would ever try again. `CatalogueService` dedupes
    /// in-flight asks and does not cache a failure, so the retry is one
    /// request (item 53).
    @Test("A genres-only failure is asked again")
    func genresOnlyFailureIsRetried() async throws {
        let tagsBody = try Fixture.data("tags-page1")
        URLProtocolStub.setHandler { request in
            let path = request.url?.path ?? ""
            if path.contains("genres") {
                return .respond(.init(statusCode: 500, body: Data(#"{"status":500}"#.utf8)))
            }
            return .respond(.init(body: tagsBody))
        }
        defer { URLProtocolStub.reset() }

        let model = BrowseModel(catalogue: makeCatalogue())
        await model.load()
        let afterFirst = URLProtocolStub.requests.filter { ($0.url?.path ?? "").contains("genres") }.count
        await model.load()
        let afterSecond = URLProtocolStub.requests.filter { ($0.url?.path ?? "").contains("genres") }.count

        #expect(afterFirst >= 1)
        // Greater-than rather than exactly two: `APIClient` may retry a 5xx
        // itself, and this is asserting that a second `load()` asks at all.
        #expect(afterSecond > afterFirst, "The genre row must get a second chance")
    }

    /// The control: when both halves answer, the second visit costs nothing.
    /// A guard that always re-asks would be a rate-limit regression, not a
    /// fix.
    @Test("A complete vocabulary is not fetched twice")
    func completeVocabularyIsNotRefetched() async throws {
        let tagsBody = try Fixture.data("tags-page1")
        let genresBody = try Fixture.data("genres-2026-09-13")
        URLProtocolStub.setHandler { request in
            let path = request.url?.path ?? ""
            return .respond(.init(body: path.contains("genres") ? genresBody : tagsBody))
        }
        defer { URLProtocolStub.reset() }

        let model = BrowseModel(catalogue: makeCatalogue())
        await model.load()
        let afterFirst = URLProtocolStub.requests.count
        await model.load()

        #expect(URLProtocolStub.requests.count == afterFirst)
    }
}
