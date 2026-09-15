import Foundation
import Testing
@testable import MangaBaka

/// The covers leg's failure is kept, not flattened to nil — the series page
/// waits out a throttle and re-asks only when it can see one (2026-09-15:
/// Omniscient Reader opened to a fan of one over a throttled `/images`, and
/// nothing ever asked again).
///
/// `.serialized`: shares `URLProtocolStub`'s per-test recorder with every
/// other stubbed suite.
@Suite("Covers leg keeps its failure", .serialized)
struct CoversLegTests {
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

    /// Control: a good page decodes to rows through the new entry point, so
    /// the failure cases below are not passing on an entry point that never
    /// reaches the network.
    @Test("Control — a page of covers is a success with its rows")
    func controlDecodes() async throws {
        let body = Data(#"""
        {"status":200,"data":[{"id":1,"series_id":2060,"type":"volume","index":"1",
         "index_numeric":1,"language":"en","content_rating":"safe",
         "image":{"raw":null,"x150":null,"x250":null,"x350":null,
                  "blurhash":null,"width":200,"height":300}}]}
        """#.utf8)
        URLProtocolStub.setHandler { _ in .respond(.init(body: body)) }
        defer { URLProtocolStub.reset() }
        let rows = try await makeRepository().imagesResult(for: 2060).get()
        #expect(rows.count == 1)
        #expect(rows.first?.language == "en")
    }

    /// The whole point: a 429 arrives as `.rateLimited` with its window, so
    /// `SeriesDetailView.loadCovers` can schedule the one re-ask. Before
    /// this, `images(for:)` answered nil and the page could not tell a
    /// throttle from a dropped connection.
    @Test("A 429 is a rateLimited failure carrying Retry-After, not nil")
    func throttleIsKept() async throws {
        URLProtocolStub.setHandler { _ in
            .respond(.init(statusCode: 429, headers: ["Retry-After": "30"]))
        }
        defer { URLProtocolStub.reset() }
        let result = try await makeRepository().imagesResult(for: 2060)
        guard case let .failure(error) = result else {
            Issue.record("Expected a failure, got \(result)")
            return
        }
        guard case .rateLimited = error else {
            Issue.record("Expected .rateLimited, got \(error)")
            return
        }
        let wait = try #require(error.retryAfter)
        #expect(abs(wait - 30) < 5)
    }

    /// The default for doubles that only answer `images(for:)`: nil is a
    /// transport failure (the kind the page retries by hand, never on a
    /// timer), and a page is a success.
    @Test("The protocol default maps nil to a transport failure")
    func defaultMapsNil() async {
        final class Failing: StubRepositoryBase, @unchecked Sendable {
            override func images(for seriesId: Int) async -> [SeriesImage]? { nil }
        }
        // `StubRepositoryBase` itself answers `[]`.
        let empty = StubRepositoryBase()
        guard case let .failure(error) = await Failing().imagesResult(for: 1) else {
            Issue.record("nil should be a failure")
            return
        }
        #expect(error.retryAfter == nil, "a transport failure has no window to wait out")
        guard case let .success(rows) = await empty.imagesResult(for: 1) else {
            Issue.record("[] should be a success")
            return
        }
        #expect(rows.isEmpty)
    }
}
