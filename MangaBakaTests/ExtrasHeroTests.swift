import Foundation
import Testing
@testable import MangaBaka

/// `extras(for:hero:)` hands the hero its two foreground legs before the
/// three `.background` ones return (review perf DT1, 2026-09-15). Fails on
/// the old code with `heroCalls == 0` before the tail: the five legs were
/// awaited together and `hero` did not exist.
@Suite("Extras: hero first, tail after", .serialized)
struct ExtrasHeroTests {
    private let baseURL = URL(string: "https://api.example.invalid").unsafeTestURL

    private static let works = Data("""
    {"status":200,"data":[{"id":"w1","sequence_string":"1","sequence_numeric":1}],
     "pagination":{"count":1}}
    """.utf8)
    private static let news = Data("""
    {"status":200,"data":[{"id":1,"title":"News","url":"https://example.invalid/n","source_name":"ann",
     "published_at":"2026-09-01T10:00:00.000Z","primary":true}]}
    """.utf8)

    private func bareSeries(id: Int) -> Data {
        Data("""
        {"status":200,"data":{"id":\(id),"state":"active","merged_with":null,"titles":null,
         "cover":{"raw":null,"x150":null,"x250":null,"x350":null,"blurhash":null,"width":null,"height":null},
         "description":"A blurb.","tags":["Action"]}}
        """.utf8)
    }

    @Test("The hero gets the full record and first works page; the whole answer carries the tail")
    func heroBeforeTail() async throws {
        let series = bareSeries(id: 9)
        URLProtocolStub.setHandler { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/9") { return .respond(.init(body: series)) }
            if path.hasSuffix("/works") { return .respond(.init(body: Self.works)) }
            if path.hasSuffix("/news") { return .respond(.init(body: Self.news)) }
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

        let heroSeen = HeroRecorder()
        let whole = await repository.extras(for: 9) { hero in await heroSeen.record(hero) }
        let hero = try #require(await heroSeen.first)
        #expect(hero.full?.description == "A blurb.")
        #expect(hero.tags == ["Action"])
        #expect(hero.volumes.count == 1)
        #expect(hero.news.isEmpty, "the tail is not in the hero")
        #expect(whole.news.count == 1)
        #expect(whole.volumes.count == 1)
        #expect(whole.failure == nil)
    }

    /// Review perf PS "missing 2" (2026-09-15). Fails on the old code with
    /// `secondOpenRecordRequests == 1`: a partial answer was never cached, so
    /// the second open paid the record, the works and every tail leg again.
    @Test("A throttled tail leg is cached as missing, and only that leg is re-asked")
    func partialAnswerIsCachedWithItsMissingLeg() async throws {
        let series = bareSeries(id: 9)
        let newsFails = Failing()
        URLProtocolStub.setHandler { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/9") { return .respond(.init(body: series)) }
            if path.hasSuffix("/works") { return .respond(.init(body: Self.works)) }
            if path.hasSuffix("/news") {
                if newsFails.value {
                    return .respond(.init(
                        statusCode: 429, body: Data(#"{"status":429}"#.utf8), headers: ["Retry-After": "0"]
                    ))
                }
                return .respond(.init(body: Self.news))
            }
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

        let first = await repository.extras(for: 9)
        #expect(first.failure != nil)
        #expect(first.missingLegs == [.news])
        #expect(first.volumes.count == 1, "the good legs are kept")
        let cachedRow = try await repository.readDetailCache(9)
        #expect(cachedRow?.missingLegs == [.news], "cached, with the gap named")

        newsFails.value = false
        let before = URLProtocolStub.requests.count
        let second = await repository.extras(for: 9)
        let since = URLProtocolStub.requests.dropFirst(before).compactMap { $0.url?.path }
        #expect(since.allSatisfy { $0.hasSuffix("/news") }, "only the missing leg: \(since)")
        #expect(second.news.count == 1)
        #expect(second.missingLegs.isEmpty)
        #expect(try await repository.readDetailCache(9)?.missingLegs.isEmpty == true, "the row is whole now")
    }

    private final class Failing: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = true
        var value: Bool {
            get { lock.withLock { flag } }
            set { lock.withLock { flag = newValue } }
        }
    }

    private actor HeroRecorder {
        var first: SeriesExtras?
        func record(_ extras: SeriesExtras) { if first == nil { first = extras } }
    }
}
