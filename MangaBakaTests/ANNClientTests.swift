import Foundation
import Testing
@testable import MangaBaka

/// `ANNClient` on the wire: what it asks for, what it does with the answers
/// ANN actually gives, and the requests it refuses to spend.
///
/// `.serialized` like every other `URLProtocolStub` suite — the stub keys on
/// the running test, and ordering within a suite is what keeps the
/// request-count assertions meaningful.
@Suite("ANN client", .serialized)
struct ANNClientTests {
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ann-tests-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeClient(clock: any Clock = TestClock(), directory: URL? = nil) -> ANNClient {
        ANNClient(
            session: URLProtocolStub.makeSession(), clock: clock,
            cacheDirectory: directory ?? temporaryDirectory()
        )
    }

    /// A series with MangaBaka's ANN id on it. Verified live 2026-09-14:
    /// `/v1/series/377` carries `"anime_news_network": {"id": 1223}`.
    private func series(annID: String?, type: String = "manga") -> Series {
        SeriesFactory.make(
            id: 377, title: "One Piece", type: type,
            source: annID.map {
                ["anime_news_network": Series.TrackerEntry(id: $0, rating: nil, ratingNormalized: nil)]
            }
        )
    }

    private func fixture() throws -> Data {
        try Fixture.data("ann-delicious-in-dungeon-17164", extension: "xml")
    }

    /// The whole reason there is no bundled 760 KB title dump and no title
    /// search: MangaBaka already hands us the id.
    @Test("The id comes from MangaBaka's own source map, and a missing one spends no request")
    func idComesFromMangaBaka() async throws {
        #expect(ANNClient.encyclopediaID(for: series(annID: "1223")) == 1223)
        #expect(ANNClient.encyclopediaID(for: series(annID: nil)) == nil)

        URLProtocolStub.setHandler { _ in .respond(.init(body: Data())) }
        defer { URLProtocolStub.reset() }
        let answer = await makeClient().volumes(for: series(annID: nil))

        #expect(URLProtocolStub.requests.isEmpty, "No id means nothing to ask, not a guess by title")
        let value = try #require(answer.value)
        #expect(value.volumes.isEmpty)
        #expect(
            value.isCatalogued == false,
            "A series MangaBaka cannot map to ANN is not-catalogued, not an empty catalogue"
        )
    }

    @Test("One GET to ANN's CDN, with the numeric id in the title parameter")
    func requestShape() async throws {
        let body = try fixture()
        URLProtocolStub.setHandler { _ in .respond(.init(body: body)) }
        defer { URLProtocolStub.reset() }

        let answer = await makeClient().volumes(for: series(annID: "17164"))

        #expect(URLProtocolStub.requests.count == 1)
        let url = try #require(URLProtocolStub.requests.first?.url)
        #expect(url.host() == "cdn.animenewsnetwork.com")
        #expect(url.path() == "/encyclopedia/api.xml")
        // `title`, not `manga` and not `id`. ANN's parameter for a numeric
        // lookup is confusingly named; getting it wrong returns a name search.
        #expect(url.query() == "title=17164")
        #expect(answer.value?.volumes.count == 15)
        #expect(answer.value?.isCatalogued == true)
    }

    /// ANN answers a lookup that matched nothing with `<warning>` over a
    /// 200 — a successful request that is still a miss. It must not read as
    /// an outage, and it must not read as "this series has no more volumes".
    @Test("A warning over a 200 is not-catalogued, not a failure")
    func warningIsNotAFailure() async throws {
        let body = Data("<ann><warning>no results</warning></ann>".utf8)
        URLProtocolStub.setHandler { _ in .respond(.init(body: body)) }
        defer { URLProtocolStub.reset() }

        let answer = await makeClient().volumes(for: series(annID: "999999", type: "manhwa"))

        #expect(answer.error == nil, "A warning is an answer, not an outage")
        let value = try #require(answer.value)
        #expect(value.volumes.isEmpty)
        #expect(value.isCatalogued == false)
    }

    /// A 200 carrying something that is not Encyclopedia XML is a decoding
    /// failure, not an empty shelf. GCD's "Banned IP Notice" — an HTML page
    /// served with HTTP 200, measured on comics.org 2026-09-14 — is the
    /// reason this path is tested rather than assumed: a 200 is not a
    /// promise about the body.
    @Test("A 200 that is not Encyclopedia XML is a decoding failure, not an empty shelf")
    func nonXMLBody() async {
        let body = Data("<html><head><title>Banned IP Notice</title></head></html>".utf8)
        URLProtocolStub.setHandler { _ in .respond(.init(body: body)) }
        defer { URLProtocolStub.reset() }

        let answer = await makeClient().volumes(for: series(annID: "17164"))

        #expect(answer.value == nil)
        #expect(answer.error?.party == .animeNewsNetwork)
        if case .decoding = answer.error {} else {
            Issue.record("Expected a decoding failure, got \(String(describing: answer.error))")
        }
    }

    /// ANN documents 1 req/s and delays rather than refuses, but the
    /// `nodelay` variant answers 503 for the same condition — so both mean
    /// "slow down", and both must push the next slot out by the server's own
    /// header rather than by this client's guess.
    @Test("A 429 and a 503 both back off by the server's own Retry-After")
    func rateLimited() async throws {
        for status in [429, 503] {
            URLProtocolStub.setHandler { _ in
                .respond(.init(statusCode: status, body: Data(), headers: ["Retry-After": "120"]))
            }
            let clock = TestClock()
            let client = makeClient(clock: clock)

            let answer = await client.volumes(for: series(annID: "17164"))

            #expect(answer.error?.party == .animeNewsNetwork, "Status \(status)")
            #expect((answer.error?.retryAfter ?? 0) > 0, "Status \(status) must report a wait")
            let next = await client.nextAllowedForTesting
            #expect(
                next.timeIntervalSince(clock.now) >= 120,
                "Status \(status) must honour the server's own 120s"
            )
            URLProtocolStub.reset()
        }
    }

    /// ANN's own documentation asks that details be cached, and a week is the
    /// figure in it. One request per series per week is the whole politeness
    /// budget this source needs.
    @Test("The answer is cached for ANN's week, and re-asked only once it expires")
    func cachedForAWeek() async throws {
        let body = try fixture()
        URLProtocolStub.setHandler { _ in .respond(.init(body: body)) }
        defer { URLProtocolStub.reset() }
        let clock = TestClock()
        let directory = temporaryDirectory()
        let client = makeClient(clock: clock, directory: directory)
        let subject = series(annID: "17164")

        _ = await client.volumes(for: subject)
        #expect(URLProtocolStub.requests.count == 1)

        clock.advance(by: ANNClient.cacheLife - 60)
        let second = await client.volumes(for: subject)
        #expect(URLProtocolStub.requests.count == 1, "Still inside the week")
        #expect(second.value?.volumes.count == 15)
        // The cache's own write time becomes the `fetchedAt`, so a StaleBar
        // can say "volumes from 6 days ago" honestly rather than claiming
        // they arrived just now.
        if case let .loaded(_, fetchedAt, _) = second {
            #expect(fetchedAt < clock.now)
        } else {
            Issue.record("Expected a loaded answer from cache, got \(second)")
        }

        clock.advance(by: 120)
        _ = await client.volumes(for: subject)
        #expect(URLProtocolStub.requests.count == 2, "The week has passed")
    }
}
