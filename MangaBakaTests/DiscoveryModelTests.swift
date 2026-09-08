import Foundation
import Testing
@testable import MangaBaka

@Suite("Discovery state transitions", .serialized)
struct DiscoveryModelTests {
    private let baseURL = URL(string: "https://api.example.invalid").unsafeTestURL

    private func makeModel() async -> DiscoveryModel {
        await DiscoveryModel(
            client: APIClient(
                baseURL: baseURL,
                session: URLProtocolStub.makeSession(),
                tokenProvider: UnauthenticatedTokenProvider()
            )
        )
    }

    private let oneActiveSeries = Data("""
    {"status":200,"data":[
      {"id":1,"state":"active","merged_with":null,
       "titles":[{"language":"en","traits":["official"],"title":"Active","is_primary":true}],
       "cover":{"raw":null,"x150":null,"x250":null,"x350":null,
                "blurhash":null,"width":200,"height":300},
       "description":null,"authors":null,"artists":null,"status":null,
       "rating":null,"type":null,"content_rating":null},
      {"id":2,"state":"merged","merged_with":1,"titles":null,
       "cover":{"raw":null,"x150":null,"x250":null,"x350":null,
                "blurhash":null,"width":null,"height":null},
       "description":null,"authors":null,"artists":null,"status":null,
       "rating":null,"type":null,"content_rating":null}
    ]}
    """.utf8)

    @Test("Starts idle")
    func startsIdle() async {
        let model = await makeModel()
        #expect(await model.state == .idle)
    }

    /// Merged and deleted series exist only so clients can update stored IDs.
    /// Showing them in discovery would surface dead entries.
    @Test("Merged and deleted series are filtered out of the feed")
    func filtersNonActiveSeries() async {
        URLProtocolStub.setHandler { [payload = oneActiveSeries] _ in
            .respond(.init(body: payload))
        }
        defer { URLProtocolStub.reset() }

        let model = await makeModel()
        await model.load()

        guard case let .loaded(series) = await model.state else {
            Issue.record("Expected .loaded, got \(await model.state)")
            return
        }
        #expect(series.count == 1)
        #expect(series.first?.id == 1)
    }

    @Test("A first-load failure reports the error with no stale content")
    func failsCleanlyOnFirstLoad() async {
        URLProtocolStub.setHandler { _ in .fail(URLError(.notConnectedToInternet)) }
        defer { URLProtocolStub.reset() }

        let model = await makeModel()
        await model.load()

        guard case let .failed(message, stale) = await model.state else {
            Issue.record("Expected .failed, got \(await model.state)")
            return
        }
        #expect(stale.isEmpty)
        #expect(message == APIError.offline.userFacingMessage)
    }

    /// The behaviour that matters on a train: going offline must not wipe the
    /// screen. Content the reader was already looking at stays visible.
    @Test("Going offline after a successful load keeps the content on screen")
    func keepsStaleContentOnFailure() async {
        URLProtocolStub.setHandler { [payload = oneActiveSeries] _ in
            .respond(.init(body: payload))
        }
        let model = await makeModel()
        await model.load()
        URLProtocolStub.reset()

        URLProtocolStub.setHandler { _ in .fail(URLError(.notConnectedToInternet)) }
        defer { URLProtocolStub.reset() }
        await model.load()

        guard case let .failed(_, stale) = await model.state else {
            Issue.record("Expected .failed, got \(await model.state)")
            return
        }
        #expect(stale.count == 1, "Content the reader was viewing must survive going offline")
    }

    @Test("An empty feed is a loaded-but-empty state, not an error")
    func emptyFeedIsNotAnError() async {
        URLProtocolStub.setHandler { _ in
            .respond(.init(body: Data(#"{"status":200,"data":[]}"#.utf8)))
        }
        defer { URLProtocolStub.reset() }

        let model = await makeModel()
        await model.load()

        #expect(await model.state == .loaded([]))
    }
}
