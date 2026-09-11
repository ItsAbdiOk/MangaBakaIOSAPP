import Foundation
import Testing
@testable import MangaBaka

/// AniList is the preferred source; Shikimori answers when it cannot.
///
/// **The AniList path cannot be verified against the live API.** Every request
/// to `graphql.anilist.co` returns HTTP 403 with AniList's own message about
/// being temporarily disabled, checked repeatedly on 2026-09-10. So these run
/// against recorded shapes taken from their published schema, not against a
/// response anyone has seen. That is a real limitation and worth re-checking
/// the day the API comes back: a field named differently from the schema would
/// pass here and fail there.
@Suite("Character sources", .serialized)
struct CharacterSourceTests {
    private func aniListBody(
        names: [String],
        role: String = "MAIN",
        image: String = "https://s4.anilist.co/file/anilistcdn/character/large/b1-x.png"
    ) -> Data {
        let edges = names.enumerated().map { index, name in
            """
            {"role": "\(role)",
             "node": {"id": \(index + 1), "name": {"full": "\(name)"},
                      "image": {"large": "\(image)", "medium": null}}}
            """
        }.joined(separator: ",")
        return Data("""
        {"data": {"Media": {"characters": {"edges": [\(edges)]}}}}
        """.utf8)
    }

    private func shikimoriBody(names: [String]) -> Data {
        let rows = names.enumerated().map { index, name in
            """
            {"roles": ["Main"],
             "character": {"id": \(index + 1), "name": "\(name)",
                           "image": {"x96": "/system/characters/x96/\(index + 1).jpg",
                                     "preview": null}}}
            """
        }.joined(separator: ",")
        return Data("[\(rows)]".utf8)
    }

    /// Routes by host so one stub can serve both APIs in the same test, which
    /// is the only way to prove the fallback actually reached the second one.
    private func route(
        aniList: @escaping @Sendable () -> URLProtocolStub.Outcome,
        shikimori: @escaping @Sendable () -> URLProtocolStub.Outcome
    ) {
        URLProtocolStub.setHandler { request in
            (request.url?.host()?.contains("anilist") == true) ? aniList() : shikimori()
        }
    }

    private func service(clock: any Clock = SystemClock()) -> CharacterService {
        let session = URLProtocolStub.makeSession()
        return CharacterService(
            aniList: AniListClient(session: session),
            shikimori: ShikimoriClient(session: session),
            clock: clock
        )
    }

    /// Counts requests to AniList while answering each with the outcome given.
    private final class AniListCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var calls: Int {
            lock.lock(); defer { lock.unlock() }
            return count
        }

        func bump() -> Int {
            lock.lock(); defer { lock.unlock() }
            count += 1
            return count
        }
    }

    // MARK: Preference

    @Test("AniList answers when it can, and Shikimori is never asked")
    func prefersAniList() async {
        defer { URLProtocolStub.reset() }
        route(
            aniList: { .respond(.init(body: aniListBody(names: ["Jin-woo Sung"]))) },
            shikimori: { .respond(.init(body: shikimoriBody(names: ["Wrong source"]))) }
        )

        let subject = service()
        let cast = await subject.characters(aniListID: 105_398, shikimoriID: 121_496)

        #expect(cast.map(\.name) == ["Jin-woo Sung"])
        #expect(await subject.lastOutcome == .aniList)
        #expect(URLProtocolStub.requests.count == 1)
    }

    // MARK: Fallback

    /// The live failure, reproduced: AniList's 403 with its own message.
    @Test("A disabled AniList falls back to Shikimori")
    func fallsBackOn403() async {
        defer { URLProtocolStub.reset() }
        route(
            aniList: {
                .respond(.init(statusCode: 403, body: Data("""
                {"errors":[{"message":"The AniList API has been temporarily disabled due to \
                severe stability issues","status":403}]}
                """.utf8)))
            },
            shikimori: { .respond(.init(body: shikimoriBody(names: ["Jin-woo Sung"]))) }
        )

        let subject = service()
        let cast = await subject.characters(aniListID: 105_398, shikimoriID: 121_496)

        #expect(cast.map(\.name) == ["Jin-woo Sung"])
        #expect(await subject.lastOutcome == .shikimori)
    }

    /// GraphQL reports failure inside an HTTP 200 as often as through a status
    /// code. Treating that body as success would show an empty row rather than
    /// falling back — a silent nothing, which is worse than a visible failure.
    @Test("A GraphQL error inside a 200 still falls back")
    func fallsBackOnGraphQLError() async {
        defer { URLProtocolStub.reset() }
        route(
            aniList: {
                .respond(.init(body: Data("""
                {"errors":[{"message":"Not Found"}],"data":{"Media":null}}
                """.utf8)))
            },
            shikimori: { .respond(.init(body: shikimoriBody(names: ["Fallback"]))) }
        )

        let subject = service()
        #expect(await subject.characters(aniListID: 1, shikimoriID: 2).map(\.name) == ["Fallback"])
        #expect(await subject.lastOutcome == .shikimori)
    }

    /// An empty cast is not a better answer than the other source's cast.
    @Test("An AniList response with no cast falls back")
    func fallsBackOnEmptyCast() async {
        defer { URLProtocolStub.reset() }
        route(
            aniList: { .respond(.init(body: Data(#"{"data":{"Media":{"characters":{"edges":[]}}}}"#.utf8))) },
            shikimori: { .respond(.init(body: shikimoriBody(names: ["Fallback"]))) }
        )

        let subject = service()
        #expect(await subject.characters(aniListID: 1, shikimoriID: 2).map(\.name) == ["Fallback"])
    }

    @Test("A network failure falls back")
    func fallsBackOnTransportError() async {
        defer { URLProtocolStub.reset() }
        route(
            aniList: { .fail(URLError(.notConnectedToInternet)) },
            shikimori: { .respond(.init(body: shikimoriBody(names: ["Fallback"]))) }
        )

        let subject = service()
        #expect(await subject.characters(aniListID: 1, shikimoriID: 2).map(\.name) == ["Fallback"])
    }

    // MARK: The fallback is silent

    /// The point of the whole arrangement. A reader has no stake in which of
    /// two trackers answered, so a failure on the preferred source must not
    /// surface as an error, a banner, or an empty row.
    @Test("Nothing about the fallback reaches the caller")
    func fallbackIsSilent() async {
        defer { URLProtocolStub.reset() }
        route(
            aniList: { .respond(.init(statusCode: 403, body: Data())) },
            shikimori: { .respond(.init(body: shikimoriBody(names: ["A", "B"]))) }
        )

        // The signature has no error channel at all: there is nowhere for a
        // failure to be reported to, by construction.
        let cast = await service().characters(aniListID: 1, shikimoriID: 2)
        #expect(cast.count == 2)
    }

    /// Both down is the one case that shows nothing — and it shows nothing
    /// rather than an error, for the same reason.
    @Test("Both sources failing yields an empty cast, not a failure")
    func bothDown() async {
        defer { URLProtocolStub.reset() }
        route(
            aniList: { .respond(.init(statusCode: 403, body: Data())) },
            shikimori: { .respond(.init(statusCode: 500, body: Data())) }
        )

        let subject = service()
        #expect(await subject.characters(aniListID: 1, shikimoriID: 2).isEmpty)
        #expect(await subject.lastOutcome == .none)
    }

    // MARK: Not paying for a known outage twice

    /// AniList being disabled is a state that lasts, and a reader should not
    /// wait for its timeout on every series page they open.
    @Test("A disabled AniList is not retried for the rest of the session")
    func outageIsRemembered() async {
        defer { URLProtocolStub.reset() }
        route(
            aniList: { .respond(.init(statusCode: 403, body: Data())) },
            shikimori: { .respond(.init(body: shikimoriBody(names: ["X"]))) }
        )

        let subject = service()
        _ = await subject.characters(aniListID: 1, shikimoriID: 2)
        let afterFirst = URLProtocolStub.requests.count
        _ = await subject.characters(aniListID: 1, shikimoriID: 2)

        // The second call makes one request, not two: Shikimori only.
        #expect(URLProtocolStub.requests.count == afterFirst + 1)
    }

    /// A rate limit is about us, not about the service being gone. Remembering
    /// it as an outage would drop AniList for the session over a burst.
    @Test("A rate limit does not count as an outage")
    func rateLimitIsNotAnOutage() async {
        defer { URLProtocolStub.reset() }
        nonisolated(unsafe) var aniListCalls = 0
        URLProtocolStub.setHandler { request in
            if request.url?.host()?.contains("anilist") == true {
                aniListCalls += 1
                return .respond(.init(statusCode: 429, body: Data(), headers: ["Retry-After": "1"]))
            }
            return .respond(.init(body: Data("[]".utf8)))
        }

        let subject = service()
        _ = await subject.characters(aniListID: 1, shikimoriID: 2)
        _ = await subject.characters(aniListID: 1, shikimoriID: 2)
        #expect(aniListCalls == 2)
    }

    /// A request cancelled because the reader left the page, or one dropped
    /// packet, says nothing about AniList. Remembering either as an outage
    /// silently dropped the preferred source for the whole session — the
    /// reader got worse portraits from then on and nothing ever said why.
    @Test("A cancelled or dropped request is not an outage")
    func transportFailureIsNotAnOutage() async {
        defer { URLProtocolStub.reset() }
        let counter = AniListCounter()
        let shikimori = shikimoriBody(names: ["Fallback"])
        let aniList = aniListBody(names: ["Preferred"])
        URLProtocolStub.setHandler { request in
            guard request.url?.host()?.contains("anilist") == true else {
                return .respond(.init(body: shikimori))
            }
            return counter.bump() == 1 ? .fail(URLError(.cancelled)) : .respond(.init(body: aniList))
        }

        let subject = service()
        _ = await subject.characters(aniListID: 1, shikimoriID: 2)
        let cast = await subject.characters(aniListID: 1, shikimoriID: 2)
        #expect(counter.calls == 2, "AniList must be asked again after a transport failure")
        #expect(cast.map(\.name) == ["Preferred"])
    }

    /// An outage ends. A session can outlive one — the app stays open across a
    /// day of reading — so the memory expires rather than lasting the session.
    @Test("The outage memory expires")
    func outageMemoryExpires() async {
        defer { URLProtocolStub.reset() }
        let counter = AniListCounter()
        let shikimori = shikimoriBody(names: ["Fallback"])
        URLProtocolStub.setHandler { request in
            guard request.url?.host()?.contains("anilist") == true else {
                return .respond(.init(body: shikimori))
            }
            _ = counter.bump()
            return .respond(.init(statusCode: 403, body: Data()))
        }

        let clock = TestClock()
        let subject = service(clock: clock)
        _ = await subject.characters(aniListID: 1, shikimoriID: 2)
        _ = await subject.characters(aniListID: 1, shikimoriID: 2)
        #expect(counter.calls == 1, "Inside the window the outage is remembered")

        clock.advance(by: CharacterService.outageMemory + 1)
        _ = await subject.characters(aniListID: 1, shikimoriID: 2)
        #expect(counter.calls == 2, "After the window AniList is tried again")
    }

    // MARK: Skipping a source entirely

    @Test("A series with no AniList id goes straight to Shikimori")
    func noAniListID() async {
        defer { URLProtocolStub.reset() }
        route(
            aniList: { .respond(.init(statusCode: 500, body: Data())) },
            shikimori: { .respond(.init(body: shikimoriBody(names: ["Only source"]))) }
        )

        let subject = service()
        #expect(await subject.characters(aniListID: nil, shikimoriID: 2).map(\.name) == ["Only source"])
        #expect(URLProtocolStub.requests.count == 1)
    }

    @Test("A series with neither id asks nobody")
    func neitherID() async {
        defer { URLProtocolStub.reset() }
        URLProtocolStub.setHandler { _ in .respond(.init(body: Data("[]".utf8))) }
        #expect(await service().characters(aniListID: nil, shikimoriID: nil).isEmpty)
        #expect(URLProtocolStub.requests.isEmpty)
    }
}

/// AniList's own response shape, decoded. Written from their published schema
/// rather than from a response, because the API is disabled — see the suite
/// above.
@Suite("AniList response shape")
struct AniListShapeTests {
    private func decode(_ json: String) -> AniListClient.Response {
        guard let decoded = try? JSONDecoder()
            .decode(AniListClient.Response.self, from: Data(json.utf8))
        else {
            fatalError("AniList fixture no longer decodes: \(json)")
        }
        return decoded
    }

    /// `Media` is capitalised in a GraphQL response and would otherwise decode
    /// as absent — the same trap as the library's capitalised `Series` key,
    /// which cost this app a silent decode failure once already.
    @Test("The capitalised Media key is decoded")
    func capitalisedMediaKey() {
        let response = decode("""
        {"data":{"Media":{"characters":{"edges":[
          {"role":"MAIN","node":{"id":1,"name":{"full":"A"},
           "image":{"large":"https://s4.anilist.co/x.png","medium":null}}}]}}}}
        """)
        #expect(response.data?.media?.characters?.edges?.count == 1)
    }

    /// AniList shouts its roles. The app compares against "Main".
    @Test("Roles are normalised to the app's casing")
    func roleCasing() {
        let response = decode("""
        {"data":{"Media":{"characters":{"edges":[
          {"role":"MAIN","node":{"id":1,"name":{"full":"A"},
           "image":{"large":"https://s4.anilist.co/x.png","medium":null}}},
          {"role":"SUPPORTING","node":{"id":2,"name":{"full":"B"},
           "image":{"large":"https://s4.anilist.co/y.png","medium":null}}}]}}}}
        """)
        let cast = AniListClient.cast(from: response, limit: 20)
        #expect(cast.map(\.role) == ["Main", "Supporting"])
        #expect(cast[0].isMain)
        #expect(!cast[1].isMain)
    }

    /// AniList substitutes a default silhouette rather than a null image, the
    /// same defect Shikimori's `missing_x96.jpg` produces.
    @Test("The default silhouette is not a portrait")
    func placeholderDropped() {
        let response = decode("""
        {"data":{"Media":{"characters":{"edges":[
          {"role":"MAIN","node":{"id":1,"name":{"full":"Faceless"},
           "image":{"large":"https://s4.anilist.co/file/anilistcdn/character/large/default.jpg",
                    "medium":null}}}]}}}}
        """)
        #expect(AniListClient.cast(from: response, limit: 20).isEmpty)
    }

    @Test("The placeholder is recognised by its path", arguments: [
        ("https://s4.anilist.co/file/anilistcdn/character/large/default.jpg", true),
        ("https://s4.anilist.co/file/anilistcdn/character/large/b88-x.png", false)
    ])
    func placeholderDetection(_ url: String, _ expected: Bool) {
        #expect(AniListClient.isPlaceholderPortrait(url) == expected)
    }

    /// AniList already sorts by [ROLE, RELEVANCE], so the app must not
    /// re-sort — doing so would discard their relevance ordering, which is
    /// better than anything the app can compute.
    @Test("AniList's own order is preserved")
    func orderPreserved() {
        let response = decode("""
        {"data":{"Media":{"characters":{"edges":[
          {"role":"MAIN","node":{"id":1,"name":{"full":"First"},
           "image":{"large":"https://s4.anilist.co/a.png","medium":null}}},
          {"role":"MAIN","node":{"id":2,"name":{"full":"Second"},
           "image":{"large":"https://s4.anilist.co/b.png","medium":null}}}]}}}}
        """)
        #expect(AniListClient.cast(from: response, limit: 20).map(\.name) == ["First", "Second"])
    }

    /// The query has to ask for MANGA. Without the type filter AniList matches
    /// an anime with the same id and returns its cast.
    @Test("The query is scoped to manga and sorted by role")
    func querySpecifics() {
        #expect(AniListClient.query.contains("type: MANGA"))
        #expect(AniListClient.query.contains("sort: [ROLE, RELEVANCE]"))
    }
}

/// The ids come out of MangaBaka's own `source` block, where every tracker id
/// is normalised to a string whatever shape it arrived in.
@Suite("Tracker ids")
struct TrackerIDTests {
    @Test("AniList and Shikimori ids are read from the source block")
    func readsIDs() throws {
        let series = try Fixture.decoder().decode(Series.self, from: Data("""
        {"id": 1, "state": "active", "cover": {},
         "source": {"anilist": {"id": 105398}, "shikimori": {"id": 121496}}}
        """.utf8))
        #expect(series.aniListID == 105_398)
        #expect(series.shikimoriID == 121_496)
    }

    /// `anime_planet` sends "solo-leveling". A non-numeric id is not an id this
    /// can use, and must read as absent rather than crashing or coercing.
    @Test("A non-numeric tracker id reads as absent")
    func nonNumericID() throws {
        let series = try Fixture.decoder().decode(Series.self, from: Data("""
        {"id": 1, "state": "active", "cover": {},
         "source": {"anilist": {"id": "not-a-number"}}}
        """.utf8))
        #expect(series.aniListID == nil)
    }

    @Test("A series with no source block has no ids")
    func noSource() {
        let series = SeriesFactory.make(id: 1)
        #expect(series.aniListID == nil)
        #expect(series.shikimoriID == nil)
    }
}
