import Testing
import Foundation
@testable import MangaBaka

/// "If I hide novels, I don't want to see novels ANYWHERE." — Abdi, 2026-09-10.
///
/// He was right that it was broken, and the reason is worth keeping: the two
/// discover endpoints ignore `type=` entirely. Measured against the live API on
/// 2026-09-10 — `/v2/series/discover/rising?limit=20&type=manga` answered with
/// fourteen manhwa and six manga, and `hidden-gems?type=manga` returned a novel.
/// Search honours the parameter, which is why the setting looked like it worked
/// everywhere until you looked at Discover.
@Suite("The format filter holds everywhere", .serialized)
struct FormatFilterTests {
    private func repository(
        database: AppDatabase? = nil,
        formats: [String] = []
    ) throws -> SeriesRepository {
        let store = try database ?? AppDatabase.inMemory()
        return SeriesRepository(
            client: APIClient(
                baseURL: URL(string: "https://api.example.invalid").unsafeTestURL,
                session: URLProtocolStub.makeSession(),
                tokenProvider: UnauthenticatedTokenProvider()
            ),
            database: store,
            formats: formats
        )
    }

    private func page(_ types: [String]) -> Data {
        let rows = types.enumerated().map { index, type in
            """
            {"id": \(index + 1), "state": "active", "cover": {}, "type": "\(type)"}
            """
        }
        return Data("""
        {"status": 200, "data": [\(rows.joined(separator: ","))]}
        """.utf8)
    }

    @Test("A server that ignores the format parameter does not get to decide")
    func filtersWhatTheServerReturnsAnyway() async throws {
        // Exactly the live response shape: asked for manga, sent manhwa back.
        URLProtocolStub.setHandler { _ in
            .respond(.init(statusCode: 200, body: self.page(["manga", "manhwa", "novel"])))
        }
        defer { URLProtocolStub.reset() }

        let repository = try repository()
        await repository.updateFormats(["manga"])
        let result = await repository.feed(.rising, forceRefresh: true)

        #expect(result.series.map(\.type) == ["manga"])
    }

    /// The suite is named "holds everywhere" and until 2026-09-13 every test
    /// in it loaded `.rising` — Search, the one endpoint that *does* honour
    /// `type=`, was never exercised, so the local `allowsFormat` post-filter
    /// on `SeriesRepository.search` was untested (search review, tests
    /// finding 10). The stub plays a server that ignores the parameter, the
    /// way discover does, so the assertion is on the local filter alone; a
    /// second assertion pins that `type=manga` still goes out on the wire,
    /// because for search the server-side half is the one that actually
    /// saves the request budget.
    @Test("Search drops what the format filter excludes, and still asks the server to")
    func searchFiltersWhatTheServerReturns() async throws {
        URLProtocolStub.setHandler { _ in
            .respond(.init(statusCode: 200, body: self.page(["manga", "manhwa", "novel"])))
        }
        defer { URLProtocolStub.reset() }

        let repository = try repository()
        await repository.updateFormats(["manga"])
        let result = await repository.search(SearchQuery(text: "solo"))

        #expect(result.series.map(\.type) == ["manga"])
        let url = try #require(URLProtocolStub.requests.last?.url?.absoluteString)
        #expect(url.contains("/v2/series/search"))
        #expect(url.contains("type=manga"), "the standing format preference must reach the search request")
    }

    @Test("No format chosen means every format is allowed")
    func emptyMeansEverything() async throws {
        URLProtocolStub.setHandler { _ in
            .respond(.init(statusCode: 200, body: self.page(["manga", "manhwa", "novel"])))
        }
        defer { URLProtocolStub.reset() }

        let repository = try repository()
        let result = await repository.feed(.rising, forceRefresh: true)

        #expect(result.series.count == 3)
    }

    @Test("A series the API did not classify is kept, not hidden")
    func unknownTypeSurvives() async throws {
        // Dropping a series because the API said nothing about it would hide
        // things nobody chose to hide, and the reader would have no way to find
        // out why they were missing.
        URLProtocolStub.setHandler { _ in
            .respond(.init(statusCode: 200, body: Data("""
            {"status": 200, "data": [{"id": 1, "state": "active", "cover": {}}]}
            """.utf8)))
        }
        defer { URLProtocolStub.reset() }

        let repository = try repository()
        await repository.updateFormats(["manga"])
        let result = await repository.feed(.rising, forceRefresh: true)

        #expect(result.series.count == 1)
    }

    /// Changing the setting *now* discards the feed cache outright — see
    /// `CacheScope` and `apply`: a format change invalidates feeds, and a
    /// feed is discarded whole rather than filtered in place.
    ///
    /// This test used to assert `["manga"]` here, i.e. that the cached feed
    /// survived the change and was merely filtered on the way out. That was
    /// true only because of the `shouldDiscard` first-application guard,
    /// which item 62 removed: the first `updateFormats` of a process was
    /// swallowed as "not a change". With the guard gone this is a real
    /// change, and the whole cached feed goes — including the manga row.
    @Test("Turning a format on discards the feed cached under the old setting")
    func changingTheFormatDiscardsTheCache() async throws {
        URLProtocolStub.setHandler { _ in
            .respond(.init(statusCode: 200, body: self.page(["manga", "novel"])))
        }
        let repository = try repository()
        _ = await repository.feed(.rising, forceRefresh: true)
        URLProtocolStub.reset()

        // Offline from here: whatever comes back now comes from the cache.
        URLProtocolStub.setHandler { _ in .fail(URLError(.notConnectedToInternet)) }
        defer { URLProtocolStub.reset() }

        await repository.updateFormats(["manga"])
        let result = await repository.feed(.rising, forceRefresh: true)

        #expect(result.series.isEmpty, "a format change invalidates the feed cache — see CacheScope")
    }

    /// The other half of "the filter holds everywhere", and the half the test
    /// above used to cover: a feed *already* on disk, read by a process whose
    /// format setting differs from the one it was written under, is filtered
    /// on the way out (`readCacheWithDate`). This is the real-world shape of
    /// that case now that the stored settings reach `init` rather than
    /// arriving as a change afterwards — a relaunch, not a settings change.
    @Test("A feed cached under a wider setting is filtered when read back under a narrower one")
    func cacheIsFilteredOnTheWayOut() async throws {
        URLProtocolStub.setHandler { _ in
            .respond(.init(statusCode: 200, body: self.page(["manga", "novel"])))
        }
        // One database, two repositories: the second stands for the next
        // launch, built with the narrower setting already in hand.
        let database = try AppDatabase.inMemory()
        let writer = try repository(database: database)
        _ = await writer.feed(.rising, forceRefresh: true)
        URLProtocolStub.reset()

        URLProtocolStub.setHandler { _ in .fail(URLError(.notConnectedToInternet)) }
        defer { URLProtocolStub.reset() }

        let relaunched = try repository(database: database, formats: ["manga"])
        let result = await relaunched.feed(.rising, forceRefresh: true)

        #expect(
            result.series.map(\.type) == ["manga"],
            "a cached feed was written under the old setting; the new one still applies to it"
        )
    }
}

/// The cache the app documents as its offline story, and which every launch
/// was quietly throwing away.
@Suite("Applying stored filters at launch is not a change", .serialized)
struct FilterApplicationTests {
    private func repository(
        contentRatings: [String]? = ["safe", "suggestive"],
        formats: [String] = [],
        blockedTags: [Int] = []
    ) throws -> SeriesRepository {
        SeriesRepository(
            client: APIClient(
                baseURL: URL(string: "https://api.example.invalid").unsafeTestURL,
                session: URLProtocolStub.makeSession(),
                tokenProvider: UnauthenticatedTokenProvider()
            ),
            database: try AppDatabase.inMemory(),
            contentRatings: contentRatings,
            formats: formats,
            blockedTags: blockedTags
        )
    }

    private static let body = Data("""
    {"status": 200, "data": [{"id": 1, "state": "active", "cover": {}, "type": "manga"}]}
    """.utf8)

    /// Item 62 changed *where* the stored settings arrive: the preference
    /// stores are read first and their values passed to `init`, so the
    /// repository never holds the empty starting state that used to make
    /// every launch look like three filter changes. The `shouldDiscard`
    /// first-application guard that papered over that is gone with it.
    ///
    /// This test used to build the repository empty and then hand it the
    /// stored values — the old launch sequence, which only kept its cache
    /// because of the guard. It now builds the repository the way
    /// `AppServices` does and re-applies the same values afterwards, which
    /// is what a launch still does and which must not count as a change.
    @Test("A cached feed survives the launch that applies the stored settings")
    func firstApplicationKeepsTheCache() async throws {
        URLProtocolStub.setHandler { _ in .respond(.init(statusCode: 200, body: Self.body)) }
        let repository = try repository(
            contentRatings: ["safe", "suggestive"], formats: ["manga"], blockedTags: [12]
        )
        _ = await repository.feed(.rising, forceRefresh: true)
        URLProtocolStub.reset()

        // What MangaBakaApp does on every launch once the stores have read
        // from disk: hand the repository the values it was built with. The
        // cache on disk was written under exactly these, so nothing here is
        // a change and nothing may be discarded.
        await repository.updateContentRatings(["safe", "suggestive"])
        await repository.updateFormats(["manga"])
        await repository.updateBlockedTags([12])

        URLProtocolStub.setHandler { _ in .fail(URLError(.notConnectedToInternet)) }
        defer { URLProtocolStub.reset() }
        let offline = await repository.feed(.rising, forceRefresh: true)

        #expect(offline.series.count == 1, "the cache was written under these very settings")
    }

    @Test("Changing a setting afterwards still discards")
    func realChangesStillDiscard() async throws {
        URLProtocolStub.setHandler { _ in .respond(.init(statusCode: 200, body: Self.body)) }
        let repository = try repository()
        await repository.updateFormats(["manga"])
        _ = await repository.feed(.rising, forceRefresh: true)
        URLProtocolStub.reset()

        // The reader actually changing it is the case the discard exists for:
        // a cached feed was fetched under the old filter and would otherwise
        // keep showing exactly what they just excluded.
        await repository.updateFormats(["manhwa"])

        URLProtocolStub.setHandler { _ in .fail(URLError(.notConnectedToInternet)) }
        defer { URLProtocolStub.reset() }
        let offline = await repository.feed(.rising, forceRefresh: true)

        #expect(offline.series.isEmpty)
    }
}
