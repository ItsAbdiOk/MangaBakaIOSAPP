import Foundation
import Testing
@testable import MangaBaka

/// `CharacterService`'s outage memory for AniList, and skipping a source
/// entirely when its id is nil. Split out of `CharacterSourceTests.swift`
/// when the union feature (2026-09-13) pushed that file's single struct over
/// the type-body-length cap; the stub helpers (`aniListBody`, `shikimoriBody`,
/// `route`, `characterService`, `AniListCounter`) are file-scope in that file
/// and shared here.
@Suite("Character outage memory", .serialized)
struct CharacterOutageTests {
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

        let subject = characterService()
        _ = await subject.characters(aniListID: 1, shikimoriID: 2)
        let afterFirst = URLProtocolStub.requests.count
        // The second ask is a *different* series. `CharacterService` caches a
        // merged cast per (aniListID, shikimoriID, limit) for 24 h since item
        // 27, so asking for the same pair twice proves nothing about the
        // outage memory — and the outage memory is service-wide, which is the
        // thing under test.
        _ = await subject.characters(aniListID: 3, shikimoriID: 4)

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

        let subject = characterService()
        _ = await subject.characters(aniListID: 1, shikimoriID: 2)
        // The second ask is a *different* series. `CharacterService` caches a
        // merged cast per (aniListID, shikimoriID, limit) for 24 h since item
        // 27, so asking for the same pair twice proves nothing about the
        // outage memory — and the outage memory is service-wide, which is the
        // thing under test.
        _ = await subject.characters(aniListID: 3, shikimoriID: 4)
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

        let subject = characterService()
        _ = await subject.characters(aniListID: 1, shikimoriID: 2)
        // The second ask is a *different* series. `CharacterService` caches a
        // merged cast per (aniListID, shikimoriID, limit) for 24 h since item
        // 27, so asking for the same pair twice proves nothing about the
        // outage memory — and the outage memory is service-wide, which is the
        // thing under test.
        let cast = await subject.characters(aniListID: 3, shikimoriID: 4)
        #expect(counter.calls == 2, "AniList must be asked again after a transport failure")
        // Shikimori is asked concurrently every time, union semantics or not,
        // so its non-matching "Fallback" is still in the merged cast.
        #expect(cast.characters.map(\.name) == ["Preferred", "Fallback"])
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
        let subject = characterService(clock: clock)
        _ = await subject.characters(aniListID: 1, shikimoriID: 2)
        // The second ask is a *different* series. `CharacterService` caches a
        // merged cast per (aniListID, shikimoriID, limit) for 24 h since item
        // 27, so asking for the same pair twice proves nothing about the
        // outage memory — and the outage memory is service-wide, which is the
        // thing under test.
        _ = await subject.characters(aniListID: 3, shikimoriID: 4)
        #expect(counter.calls == 1, "Inside the window the outage is remembered")

        clock.advance(by: CharacterService.outageMemory + 1)
        _ = await subject.characters(aniListID: 5, shikimoriID: 6)
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

        let subject = characterService()
        let cast = await subject.characters(aniListID: nil, shikimoriID: 2)
        #expect(cast.characters.map(\.name) == ["Only source"])
        #expect(cast.aniList == .notAsked)
        #expect(URLProtocolStub.requests.count == 1)
    }

    @Test("A series with neither id asks nobody")
    func neitherID() async {
        defer { URLProtocolStub.reset() }
        URLProtocolStub.setHandler { _ in .respond(.init(body: Data("[]".utf8))) }
        let cast = await characterService().characters(aniListID: nil, shikimoriID: nil)
        #expect(cast.characters.isEmpty)
        #expect(cast.aniList == .notAsked)
        #expect(cast.shikimori == .notAsked)
        #expect(!cast.failed, "never asking anyone is not the same as everyone failing")
        #expect(URLProtocolStub.requests.isEmpty)
    }
}
