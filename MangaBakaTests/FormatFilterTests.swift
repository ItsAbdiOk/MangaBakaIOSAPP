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
    private func repository() throws -> SeriesRepository {
        SeriesRepository(
            client: APIClient(
                baseURL: URL(string: "https://api.example.invalid").unsafeTestURL,
                session: URLProtocolStub.makeSession(),
                tokenProvider: UnauthenticatedTokenProvider()
            ),
            database: try AppDatabase.inMemory()
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

    @Test("Turning a format off empties it from what is already cached")
    func appliesToTheCacheToo() async throws {
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
    private func repository() throws -> SeriesRepository {
        SeriesRepository(
            client: APIClient(
                baseURL: URL(string: "https://api.example.invalid").unsafeTestURL,
                session: URLProtocolStub.makeSession(),
                tokenProvider: UnauthenticatedTokenProvider()
            ),
            database: try AppDatabase.inMemory()
        )
    }

    private static let body = Data("""
    {"status": 200, "data": [{"id": 1, "state": "active", "cover": {}, "type": "manga"}]}
    """.utf8)

    @Test("A cached feed survives the launch that applies the stored settings")
    func firstApplicationKeepsTheCache() async throws {
        URLProtocolStub.setHandler { _ in .respond(.init(statusCode: 200, body: Self.body)) }
        let repository = try repository()
        _ = await repository.feed(.rising, forceRefresh: true)
        URLProtocolStub.reset()

        // What MangaBakaApp does on every launch: hand the repository the
        // values the stores read from disk. It starts empty, so all three
        // differ — and all three used to wipe the cache before the first screen
        // drew, which is why the app has never once rendered offline.
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
