import Foundation
import Testing
@testable import MangaBaka

/// The four signatures round 1 owes the other lanes, and the two source-side
/// bugs behind them: items 18 (wire half), 32, 62 (the parameter), 64 and 65.
@Suite("Repository wiring the shell and the views call", .serialized)
struct RepositoryWiringTests {
    private let baseURL = URL(string: "https://api.example.invalid").unsafeTestURL

    private func makeRepository(
        blockedTags: [Int] = [],
        clock: TestClock = TestClock()
    ) throws -> SeriesRepository {
        SeriesRepository(
            client: APIClient(
                baseURL: baseURL,
                session: URLProtocolStub.makeSession(),
                tokenProvider: UnauthenticatedTokenProvider()
            ),
            database: try AppDatabase.inMemory(),
            clock: clock,
            blockedTags: blockedTags
        )
    }

    private let emptyPayload = Data(#"{"status":200,"data":[]}"#.utf8)

    private func items(from request: URLRequest?) throws -> [URLQueryItem] {
        let url = try #require(request?.url)
        return try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
    }

    /// Item 62. The blocked tags used to arrive through a detached `Task`
    /// racing Discover's first `feed()`, and the first-application guard meant
    /// a feed fetched under the defaults was cached for up to 24 h and *not*
    /// discarded when the real values landed — so a reader with a blocked tag
    /// could get a wrong Discover row that persisted.
    ///
    /// Expected to fail before item 62 with: no `blockedTags:` parameter on
    /// `SeriesRepository.init`, so this does not compile; once it exists but
    /// is applied late, `tag_not=42` is absent from the first request.
    @Test("Blocked tags reach the very first request")
    func blockedTagsAreConstructorState() async throws {
        URLProtocolStub.setHandler { [payload = emptyPayload] _ in .respond(.init(body: payload)) }
        defer { URLProtocolStub.reset() }

        let repository = try makeRepository(blockedTags: [42])
        _ = await repository.feed(.rising, forceRefresh: true)

        let sent = try items(from: URLProtocolStub.requests.first)
        #expect(sent.contains { $0.name == "tag_not" && $0.value == "42" })
    }

    /// Item 18, wire half. MEASURED 2026-09-14: `/v1/series/mix` with
    /// `tag=Isekai` returns the unfiltered blend while `tag=94` filters, so a
    /// name sent to mix is a chip that lights up and changes nothing.
    ///
    /// Expected to fail before item 18 with: the sent `tag` value being the
    /// literal string "Isekai" (via `SearchQuery.wireTagIDs`' send-the-name
    /// fallback for a tag the bundle cannot resolve), and no `tagIDs:`
    /// parameter on `mix` at all.
    @Test("Mix sends tag ids, never tag names")
    func mixSendsTagIDs() async throws {
        URLProtocolStub.setHandler { _ in
            .respond(.init(body: Data(#"{"status":200,"data":[]}"#.utf8)))
        }
        defer { URLProtocolStub.reset() }

        var filters = SearchQuery()
        // A name the bundled taxonomy cannot resolve: the 2,686-tag bundle
        // covers well under half of the API's 7,146.
        filters.tags = ["A Tag That Is Not In The Bundle"]
        let repository = try makeRepository()
        _ = await repository.mix(seeds: [7], filters: filters, excludedTags: [], tagIDs: [94])

        let sent = try items(from: URLProtocolStub.requests.first)
        let tags = sent.filter { $0.name == "tag" }.compactMap(\.value)
        #expect(tags == ["94"])
        #expect(!tags.contains("A Tag That Is Not In The Bundle"))
    }

    /// The pure half of the same rule, so the wire assertion above has a unit
    /// underneath it. `mixTagQuery` keeps a numeric tag the query already
    /// carried, drops a name, adds the caller's ids, and rebuilds `tag_mode`.
    @Test("mixTagQuery keeps ids, drops names, rebuilds tag_mode")
    func mixTagQueryRules() {
        let input = [
            URLQueryItem(name: "tag", value: "39"),
            URLQueryItem(name: "tag", value: "Isekai"),
            URLQueryItem(name: "tag_mode", value: "and"),
            URLQueryItem(name: "type", value: "manga")
        ]
        let out = SeriesRepository.mixTagQuery(replacingTagsIn: input, with: [94])
        #expect(out.filter { $0.name == "tag" }.compactMap(\.value) == ["39", "94"])
        #expect(out.filter { $0.name == "tag_mode" }.count == 1)
        #expect(out.contains { $0.name == "type" && $0.value == "manga" })

        // One surviving tag means `tag_mode` is noise, and a duplicate id is
        // one filter rather than two `and`ed copies of itself.
        let single = SeriesRepository.mixTagQuery(
            replacingTagsIn: [URLQueryItem(name: "tag", value: "94")], with: [94]
        )
        #expect(single.filter { $0.name == "tag" }.count == 1)
        #expect(single.allSatisfy { $0.name != "tag_mode" })
    }

    /// Item 64. `refreshReminders` awaited `cachedExtras(for:)` once per
    /// library entry — 939 actor hops on the launch path, each its own SQLite
    /// read and a whole `SeriesExtras` decode.
    ///
    /// Expected to fail before item 64 with: no `cachedExtrasLinks(for:)` at
    /// all, so this does not compile.
    @Test("Cached links for many series come back in one call")
    func cachedExtrasLinksIsBatched() async throws {
        let repository = try makeRepository()
        let link = SeriesLink(
            id: "1", url: URL(string: "https://example.invalid"), name: "manta.net",
            nameDisplay: "Manta", type: "webplatform", language: "en"
        )
        try await repository.writeDetailCache(SeriesExtras(links: [link]), for: 3397)
        try await repository.writeDetailCache(SeriesExtras(links: []), for: 8)

        let links = await repository.cachedExtrasLinks(for: [3397, 8, 999])
        #expect(links[3397]?.count == 1)
        #expect(links[8]?.isEmpty == true)
        // A series with nothing cached is absent, the same answer a nil
        // `cachedExtras` gave — not an empty array, which would read as
        // "asked and it has none".
        #expect(links[999] == nil)
    }

    /// The control: past the six-hour window the same rows are absent, so the
    /// batched read applies the freshness rule `readDetailCache` applies and
    /// has not simply stopped checking.
    @Test("Cached links older than the detail window are not returned")
    func cachedExtrasLinksRespectsFreshness() async throws {
        let clock = TestClock()
        let repository = try makeRepository(clock: clock)
        try await repository.writeDetailCache(SeriesExtras(links: []), for: 3397)
        clock.advance(by: 6 * 60 * 60 + 1)
        #expect(await repository.cachedExtrasLinks(for: [3397]).isEmpty)
    }

    /// Item 65. `SeriesWebLink.seriesID(from:)` returned any `Int`, `-5` and
    /// `0` included, each of which cost a request and an error toast for a
    /// link that could never have been valid.
    ///
    /// Expected to fail before item 65 with: `-5` and `0` coming back instead
    /// of nil.
    @Test("A non-positive series id in a link is not a series id")
    func rejectsNonPositiveIDs() throws {
        #expect(SeriesWebLink.seriesID(from: try #require(URL(string: "mangabaka://series/-5"))) == nil)
        #expect(SeriesWebLink.seriesID(from: try #require(URL(string: "mangabaka://series/0"))) == nil)
        #expect(
            SeriesWebLink.seriesID(from: try #require(URL(string: "https://mangabaka.org/0"))) == nil
        )
        // The control: a real id still resolves, on both forms.
        #expect(
            SeriesWebLink.seriesID(from: try #require(URL(string: "mangabaka://series/3397"))) == 3397
        )
        #expect(
            SeriesWebLink.seriesID(
                from: try #require(URL(string: "https://mangabaka.org/manhwa/3397/Solo-Leveling"))
            ) == 3397
        )
    }
}
