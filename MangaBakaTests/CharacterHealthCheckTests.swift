import Foundation
import Testing
@testable import MangaBaka

/// `CharacterService.primeAniListHealth()` — the app-launch check that primes
/// the same 15-minute outage memory the ordinary cast fetch already keeps, so
/// the first series page opened after a launch does not pay AniList's own
/// timeout before falling back to Shikimori.
///
/// Its own file, split out of `CharacterSourceTests.swift`, purely for
/// SwiftLint's 250-line type-body cap — that suite was already at its ceiling
/// before these three tests existed.
@Suite("AniList health check", .serialized)
struct CharacterHealthCheckTests {
    private func aniListBody(names: [String]) -> Data {
        let edges = names.enumerated().map { index, name in
            """
            {"role": "MAIN",
             "node": {"id": \(index + 1), "name": {"full": "\(name)"},
                      "image": {"large": "https://s4.anilist.co/x.png", "medium": null}}}
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

    private func route(
        aniList: @escaping @Sendable () -> URLProtocolStub.Outcome,
        shikimori: @escaping @Sendable () -> URLProtocolStub.Outcome
    ) {
        URLProtocolStub.setHandler { request in
            (request.url?.host()?.contains("anilist") == true) ? aniList() : shikimori()
        }
    }

    private func service() -> CharacterService {
        let session = URLProtocolStub.makeSession()
        return CharacterService(
            aniList: AniListClient(session: session),
            shikimori: ShikimoriClient(session: session)
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

    /// The whole point of `primeAniListHealth`: a refusal caught before any
    /// series page asks for a cast means the first one opened skips straight
    /// to Shikimori, at no extra cost — proven here by counting AniList
    /// requests across the priming call and the cast request that follows,
    /// not just checking the outcome.
    @Test("A refusal at launch is remembered, so the first series page skips AniList")
    func healthCheckPrimesOutageMemory() async {
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

        let subject = service()
        await subject.primeAniListHealth()
        #expect(counter.calls == 1, "The health check itself is one request")

        let cast = await subject.characters(aniListID: 1, shikimoriID: 2)
        #expect(cast.map(\.name) == ["Fallback"])
        #expect(counter.calls == 1, "The primed outage means the cast request never touches AniList again")
    }

    /// Control: a launch where AniList answers normally must not poison the
    /// outage memory — otherwise every launch would silently prefer
    /// Shikimori regardless of what the health check found.
    @Test("A healthy launch leaves AniList available")
    func healthCheckLeavesHealthyAniListAvailable() async {
        defer { URLProtocolStub.reset() }
        route(
            aniList: { .respond(.init(body: aniListBody(names: ["Jin-woo Sung"]))) },
            shikimori: { .respond(.init(body: shikimoriBody(names: ["Wrong source"]))) }
        )

        let subject = service()
        await subject.primeAniListHealth()
        let cast = await subject.characters(aniListID: 1, shikimoriID: 2)
        #expect(cast.map(\.name) == ["Jin-woo Sung"])
    }

    /// Same rule the ordinary cast fetch already follows: a transport
    /// failure at launch (no network yet, a cold start racing Wi-Fi) says
    /// nothing about AniList itself, and must not be remembered as an outage.
    @Test("A transport failure at launch is not remembered as an outage")
    func healthCheckTransportFailureIsNotAnOutage() async {
        defer { URLProtocolStub.reset() }
        let counter = AniListCounter()
        let aniList = aniListBody(names: ["Preferred"])
        URLProtocolStub.setHandler { request in
            guard request.url?.host()?.contains("anilist") == true else {
                return .respond(.init(body: Data("[]".utf8)))
            }
            return counter.bump() == 1
                ? .fail(URLError(.notConnectedToInternet))
                : .respond(.init(body: aniList))
        }

        let subject = service()
        await subject.primeAniListHealth()
        let cast = await subject.characters(aniListID: 1, shikimoriID: 2)
        #expect(
            cast.map(\.name) == ["Preferred"],
            "AniList must still be asked after a transport failure at launch"
        )
    }
}
