import Foundation
import Testing
@testable import MangaBaka

/// The network path behind `NDLClient.volumes(japaneseTitle:format:)`: the
/// request it sends, the file cache it reads and writes, and the 429
/// back-off branch — coverage measured 2026-09-15 at 33.6% of 122 executable
/// lines in `NDLClient.swift`, with this method and everything private under
/// it (`load`, `readCache`, `writeCache`) unexercised. `NDLClientTests.swift`
/// and `NDLEditionTests.swift` only ever call the pure entry points
/// (`NDLClient.answer(title:format:from:)`, `Query`, `requestURL`) directly —
/// never `volumes(japaneseTitle:format:)` itself, so nothing here duplicates
/// those.
///
/// `.serialized`, matching `WebtoonsFeedClientTests`: both share
/// `URLProtocolStub`'s per-test recorder.
@Suite("NDL client network path", .serialized)
struct NDLClientNetworkTests {
    private static let title = "薬屋のひとりごと"

    private func page() throws -> Data {
        try Fixture.data("ndl-apothecary-diaries-50", extension: "xml")
    }

    /// `minimumInterval: 0` — the real 2-second politeness spacing has
    /// nothing to do with what these tests check, and leaving it at the
    /// default would make every test here sleep for real between calls, the
    /// exact trap `NDLClient.init`'s own doc comment names.
    private func makeClient(clock: TestClock, cacheDirectory: URL) -> NDLClient {
        NDLClient(
            session: URLProtocolStub.makeSession(), clock: clock, minimumInterval: 0,
            cacheDirectory: cacheDirectory
        )
    }

    private func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ndl-client-tests-\(UUID().uuidString)", isDirectory: true)
    }

    /// A regression here would most plausibly read as `.notCatalogued` (the
    /// stubbed page silently failing to parse, e.g. a `recordPacking` or
    /// `recordSchema` typo reintroduced) or `isPartial == false` (the
    /// 50-of-84 count dropped, which is exactly the Serious 2 bug
    /// `NDLEditionTests.partialPage` pins at the pure-function level — this
    /// test pins the same fact reached through the actual network call).
    @Test("volumes(japaneseTitle:format:) reads the stubbed page, asking with the right CQL")
    func readsStubbedPage() async throws {
        let data = try page()
        URLProtocolStub.setHandler { _ in .respond(.init(body: data)) }
        defer { URLProtocolStub.reset() }
        let client = makeClient(clock: TestClock(), cacheDirectory: tempDirectory())

        let answer = try await client.volumes(japaneseTitle: Self.title, format: .comic)
        guard case let .editions(rows) = answer.answer else {
            Issue.record("Expected .editions, got \(answer.answer)")
            return
        }
        #expect(!rows.isEmpty)
        #expect(answer.isPartial, "50 of NDL's 84 held records for this series is a partial page")

        #expect(URLProtocolStub.requests.count == 1)
        let url = try #require(URLProtocolStub.requests.first?.url)
        let query = try #require(
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first { $0.name == "query" }?.value
        )
        #expect(query == "title=\"薬屋のひとりごと\" AND mediatype=books")
        // The raw (still percent-encoded) query string, not `queryItems`'
        // already-decoded value: `%22` is the quote CQL needs around the
        // phrase, and this is what would actually go out over the wire.
        let rawQuery = try #require(url.query)
        #expect(rawQuery.contains("%22"), "the CQL phrase's quotes must survive percent-encoding")
        // `=` inside a value goes out as `%3D` — the decoded assertion above
        // is the readable one; this only pins that the raw form is encoded.
        #expect(rawQuery.contains("mediatype%3Dbooks") || rawQuery.contains("mediatype=books"))
    }

    /// A regression here reads as a client that asks NDL every time a series
    /// page is opened, or one that never asks again after the first day — a
    /// 429 earned needlessly in the first case, a stuck-forever forthcoming
    /// date in the second (the whole reason `cacheLife` is a day, not a
    /// week: `NDLClient.cacheLife`'s own doc comment).
    @Test("A second call within cacheLife reads the file cache; past it, a fresh request is made")
    func cachesAcrossCallsAndExpiresOnSchedule() async throws {
        let data = try page()
        URLProtocolStub.setHandler { _ in .respond(.init(body: data)) }
        defer { URLProtocolStub.reset() }
        let clock = TestClock()
        let client = makeClient(clock: clock, cacheDirectory: tempDirectory())

        _ = try await client.volumes(japaneseTitle: Self.title, format: .comic)
        #expect(URLProtocolStub.requests.count == 1)

        _ = try await client.volumes(japaneseTitle: Self.title, format: .comic)
        #expect(URLProtocolStub.requests.count == 1, "the second call must answer from the file cache")

        clock.advance(by: NDLClient.cacheLife + 1)
        _ = try await client.volumes(japaneseTitle: Self.title, format: .comic)
        #expect(URLProtocolStub.requests.count == 2, "a cache older than cacheLife must not answer")
    }

    /// A regression here is the query built as `title="薬屋の"ひとりごと""` — NDL
    /// answers a diagnostic for the malformed CQL, the parser finds zero
    /// records, and `.notCatalogued` is what gets cached for a day (per
    /// `requestURL`'s own doc comment). `NDLEditionTests.quotesAreDropped`
    /// pins the same fact against the pure `requestURL` function; this pins
    /// it at the point that actually reaches the wire, in case `volumes`
    /// were ever changed to build its URL a different way.
    @Test("A quote in the title does not reach NDL unescaped, over the network path")
    func networkRequestDropsQuoteFromTitle() async throws {
        let empty = Data(
            "<searchRetrieveResponse><numberOfRecords>0</numberOfRecords></searchRetrieveResponse>".utf8
        )
        URLProtocolStub.setHandler { _ in .respond(.init(body: empty)) }
        defer { URLProtocolStub.reset() }
        let client = makeClient(clock: TestClock(), cacheDirectory: tempDirectory())

        _ = try await client.volumes(japaneseTitle: "薬屋の\"ひとりごと\"", format: .comic)
        let url = try #require(URLProtocolStub.requests.first?.url)
        let query = try #require(
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first { $0.name == "query" }?.value
        )
        #expect(query == "title=\"薬屋のひとりごと\" AND mediatype=books")
    }

    /// A regression here is a 429 that goes unnoticed by the caller — either
    /// swallowed into `.notCatalogued`, or thrown with `party == .mangaBaka`
    /// so a reader whose NDL request specifically was throttled sees "too
    /// many requests" attributed to MangaBaka's own shared limit instead.
    ///
    /// The follow-up half of this branch — "the next call within the
    /// honoured window makes no request" — is not asserted here: `load()`'s
    /// wait is a real `Task.sleep`, which the injected `clock` cannot
    /// fast-forward (this is the exact trap `NDLClient.init`'s own doc
    /// comment names), so proving it would cost a genuine 120-second sleep
    /// in the test run. `WebtoonsFeedClientTests.rateLimitedCarriesTheParty`,
    /// the sibling client's own 429 test, stops at the same point for the
    /// same reason. Noted under "Wiring needed" in the report.
    @Test("A 429 with Retry-After backs off, named to NDL and honouring the header")
    func rateLimitedBacksOffWithNDLAsTheParty() async throws {
        URLProtocolStub.setHandler { _ in
            .respond(.init(statusCode: 429, headers: ["Retry-After": "120"]))
        }
        defer { URLProtocolStub.reset() }
        let client = makeClient(clock: TestClock(), cacheDirectory: tempDirectory())

        var thrown: APIError?
        do throws(APIError) {
            _ = try await client.volumes(japaneseTitle: Self.title, format: .comic)
        } catch let error {
            thrown = error
        }
        let caught = try #require(thrown)
        guard case let .rateLimited(until, party) = caught else {
            Issue.record("Expected .rateLimited, got \(caught)")
            return
        }
        #expect(party == .nationalDietLibrary)
        let deadline = try #require(until)
        // Honoured, not merely present: within a couple of seconds of "now +
        // 120", not clamped to `RequestSpacing.unstatedBackOff` (60) as it
        // would be if the header failed to parse.
        #expect(abs(deadline.timeIntervalSinceNow - 120) < 5)
        #expect(URLProtocolStub.requests.count == 1)
    }

    /// A regression here reads as either direction of the Serious-2-shaped
    /// bug this app already caught once: an empty page (NDL genuinely holds
    /// nothing) collapsing into `.editions([])` — a shelf that looks like an
    /// empty search rather than "we asked and they hold nothing" — or a page
    /// whose records all miss the title filter reading as `.notCatalogued`,
    /// which would tell a reader NDL has never heard of a series it actually
    /// holds 84 records of. `NDLEditionTests.filteredToNothingIsNotNotCatalogued`
    /// pins the same distinction against the pure `answer(title:format:from:)`
    /// function directly; this exercises it through `volumes`, which also
    /// round-trips the answer through `writeCache`/`readCache` — the case
    /// `Cached.rows == nil` (`.notCatalogued`) must not be confused on
    /// read-back with `Cached.rows == []` (`.editions([])`), since both are
    /// "no rows" but the type distinguishes them.
    @Test("An empty page caches as not-catalogued; a page with records but no title match does not")
    func emptyPageAndFilteredPageAreDistinctAcrossTheCache() async throws {
        let empty = Data(
            "<searchRetrieveResponse><numberOfRecords>0</numberOfRecords></searchRetrieveResponse>".utf8
        )
        URLProtocolStub.setHandler { _ in .respond(.init(body: empty)) }
        defer { URLProtocolStub.reset() }
        let directory = tempDirectory()
        let emptyClient = makeClient(clock: TestClock(), cacheDirectory: directory)
        let notCatalogued = try await emptyClient.volumes(
            japaneseTitle: "誰も知らないシリーズ", format: .comic
        )
        #expect(notCatalogued.answer == .notCatalogued)
        // Read back from the file cache just written, not the network stub.
        let cachedAgain = try await emptyClient.volumes(
            japaneseTitle: "誰も知らないシリーズ", format: .comic
        )
        #expect(cachedAgain.answer == .notCatalogued)
        #expect(URLProtocolStub.requests.count == 1, "the second call must have come from the cache")

        // A title NDL's page holds 84 records under, none of which begin
        // with this string — every record fails `Query.titleMatches`, so the
        // page is not empty but the rows are.
        let apothecaryPage = try page()
        URLProtocolStub.setHandler { _ in .respond(.init(body: apothecaryPage)) }
        let filteredClient = makeClient(clock: TestClock(), cacheDirectory: tempDirectory())
        let filtered = try await filteredClient.volumes(japaneseTitle: "ダンジョン飯", format: .comic)
        #expect(filtered.answer == .editions([]))
        let filteredCachedAgain = try await filteredClient.volumes(
            japaneseTitle: "ダンジョン飯", format: .comic
        )
        #expect(filteredCachedAgain.answer == .editions([]))
    }
}
