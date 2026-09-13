import Foundation
import Testing
@testable import MangaBaka

/// AniList and Shikimori are unioned, AniList's cast leading.
///
/// Abdi, 2026-09-13, verbatim: "if a character is on AniList but not on
/// Shikimori, use AniList as the default. If it's on Shikimori but AniList
/// doesn't have that character, make sure you put it." Both sources are asked
/// concurrently — neither is a fallback for the other any more — and every
/// Shikimori character that does not fuzzy-match one already in AniList's
/// list (`CharacterNameMatch`) is appended after it. `SourceOutcome` still
/// distinguishes "asked and failed" from "asked and had nobody" from "never
/// asked", the same distinction the old fallback-only design already needed
/// for `lastOutcome`.
///
/// **The AniList path cannot be verified against the live API.** Every request
/// to `graphql.anilist.co` returns HTTP 403 with AniList's own message about
/// being temporarily disabled, checked repeatedly on 2026-09-10. So these run
/// against recorded shapes taken from their published schema, not against a
/// response anyone has seen. That is a real limitation and worth re-checking
/// the day the API comes back: a field named differently from the schema would
/// pass here and fail there.

/// Shared by both suites below (split apart when the union feature pushed the
/// original single struct over the type-body-length cap): stub response
/// builders, a host-routed handler, and a service factory wired to
/// `URLProtocolStub`.
func aniListBody(
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

func shikimoriBody(names: [String]) -> Data {
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

/// Routes by host so one stub can serve both APIs in the same test, which is
/// the only way to prove a request actually reached the second one.
func route(
    aniList: @escaping @Sendable () -> URLProtocolStub.Outcome,
    shikimori: @escaping @Sendable () -> URLProtocolStub.Outcome
) {
    URLProtocolStub.setHandler { request in
        (request.url?.host()?.contains("anilist") == true) ? aniList() : shikimori()
    }
}

func characterService(clock: any Clock = SystemClock()) -> CharacterService {
    let session = URLProtocolStub.makeSession()
    return CharacterService(
        aniList: AniListClient(session: session),
        shikimori: ShikimoriClient(session: session),
        clock: clock
    )
}

/// Counts requests to AniList while answering each with the outcome given.
final class AniListCounter: @unchecked Sendable {
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

@Suite("Character sources", .serialized)
struct CharacterSourceTests {
    // MARK: Union

    /// Both sources are asked concurrently now — neither is a fallback for
    /// the other. Before the union (verbatim, Abdi 2026-09-13), Shikimori was
    /// never asked once AniList answered; expected failure on the old code:
    /// `URLProtocolStub.requests.count == 1` (Shikimori skipped entirely),
    /// where this now asserts 2, and the Shikimori-only name still appears.
    @Test("AniList leads, and Shikimori's unmatched characters are appended")
    func unionAppendsUnmatchedShikimoriCharacters() async {
        defer { URLProtocolStub.reset() }
        route(
            aniList: { .respond(.init(body: aniListBody(names: ["Jin-woo Sung"]))) },
            shikimori: { .respond(.init(body: shikimoriBody(names: ["Igris"]))) }
        )

        let subject = characterService()
        let cast = await subject.characters(aniListID: 105_398, shikimoriID: 121_496)

        #expect(cast.characters.map(\.name) == ["Jin-woo Sung", "Igris"])
        #expect(await subject.lastOutcome == .union)
        #expect(URLProtocolStub.requests.count == 2)
        #expect(cast.aniList == .answered)
        #expect(cast.shikimori == .answered)
    }

    /// The reason for the union: a fuzzy-matched Shikimori character does not
    /// duplicate the one AniList already contributed.
    @Test("A Shikimori character that fuzzy-matches an AniList one is not duplicated")
    func matchedShikimoriCharacterIsNotDuplicated() async {
        defer { URLProtocolStub.reset() }
        route(
            aniList: { .respond(.init(body: aniListBody(names: ["Sung Jin-Woo"]))) },
            shikimori: { .respond(.init(body: shikimoriBody(names: ["Jinwoo Sung"]))) }
        )

        let subject = characterService()
        let cast = await subject.characters(aniListID: 105_398, shikimoriID: 121_496)
        #expect(cast.characters.map(\.name) == ["Sung Jin-Woo"])
    }

    // MARK: Fallback (one source failed)

    /// The live failure, reproduced: AniList's 403 with its own message.
    @Test("A disabled AniList's cast is Shikimori's, with AniList's outcome recorded as failed")
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

        let subject = characterService()
        let cast = await subject.characters(aniListID: 105_398, shikimoriID: 121_496)

        #expect(cast.characters.map(\.name) == ["Jin-woo Sung"])
        #expect(await subject.lastOutcome == .shikimori)
        guard case .failed = cast.aniList else {
            Issue.record("expected AniList's outcome to be .failed, got \(cast.aniList)")
            return
        }
        #expect(cast.shikimori == .answered)
        #expect(!cast.failed, "one source answering is not the same as both failing")
    }

    /// GraphQL reports failure inside an HTTP 200 as often as through a status
    /// code. Treating that body as success would show an empty row rather than
    /// showing Shikimori's cast — a silent nothing, which is worse than a
    /// visible failure.
    @Test("A GraphQL error inside a 200 still yields Shikimori's cast")
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

        let subject = characterService()
        #expect(await subject.characters(aniListID: 1, shikimoriID: 2).characters.map(\.name) == ["Fallback"])
        #expect(await subject.lastOutcome == .shikimori)
    }

    /// An empty AniList cast is a real answer, not a failure (gap 31) — it
    /// unions with whatever Shikimori has rather than either blacking out
    /// AniList or hiding behind a `.server` throw.
    ///
    /// Before the fix (docs/reviews/third-parties.md finding 2, 2026-09-13),
    /// `CharacterService` treated any `.server` error as an outage, so one
    /// series with an empty AniList cast blacked out AniList for every other
    /// series page for 15 minutes. Expected to fail before the fix with:
    /// "AniList must still be asked for a second, unrelated series" —
    /// `URLProtocolStub.requests` would show only the one Shikimori request
    /// for the second call, not one to each host.
    @Test("An AniList response with no cast unions with Shikimori's, and does not black out AniList")
    func emptyAniListCastUnionsWithShikimori() async {
        defer { URLProtocolStub.reset() }
        route(
            aniList: { .respond(.init(body: Data(#"{"data":{"Media":{"characters":{"edges":[]}}}}"#.utf8))) },
            shikimori: { .respond(.init(body: shikimoriBody(names: ["Fallback"]))) }
        )

        let subject = characterService()
        let first = await subject.characters(aniListID: 1, shikimoriID: 2)
        #expect(first.characters.map(\.name) == ["Fallback"])
        // An empty cast is a real, successful answer — not a failure.
        #expect(first.aniList == .answered)

        // A second, unrelated series must still ask AniList — the first
        // series having no cast says nothing about whether AniList is up.
        let beforeSecondCall = URLProtocolStub.requests.count
        _ = await subject.characters(aniListID: 3, shikimoriID: 4)
        let newCount = URLProtocolStub.requests.count - beforeSecondCall
        let secondCallHosts = URLProtocolStub.requests.suffix(newCount)
        #expect(secondCallHosts.contains { $0.url?.host()?.contains("anilist") == true })
    }

    /// A stale or unknown AniList id answers 404 — AniList itself correctly
    /// saying "no such series", not a refusal. Treating it as an outage would
    /// black out AniList for every other series over one bad id.
    @Test("A 404 for an unknown AniList id falls back without blacking out AniList")
    func fallsBackOn404WithoutOutage() async {
        defer { URLProtocolStub.reset() }
        let counter = AniListCounter()
        let shikimori = shikimoriBody(names: ["Fallback"])
        URLProtocolStub.setHandler { request in
            guard request.url?.host()?.contains("anilist") == true else {
                return .respond(.init(body: shikimori))
            }
            _ = counter.bump()
            return .respond(.init(statusCode: 404, body: Data()))
        }

        let subject = characterService()
        _ = await subject.characters(aniListID: 1, shikimoriID: 2)
        _ = await subject.characters(aniListID: 3, shikimoriID: 4)
        #expect(counter.calls == 2, "A 404 is not an outage; the second series must still ask AniList")
    }

    @Test("A network failure still yields Shikimori's cast")
    func fallsBackOnTransportError() async {
        defer { URLProtocolStub.reset() }
        route(
            aniList: { .fail(URLError(.notConnectedToInternet)) },
            shikimori: { .respond(.init(body: shikimoriBody(names: ["Fallback"]))) }
        )

        let subject = characterService()
        #expect(await subject.characters(aniListID: 1, shikimoriID: 2).characters.map(\.name) == ["Fallback"])
    }

    // MARK: A single failure is silent — nothing to fix, still something to show

    /// A reader has no stake in which of two trackers answered a given
    /// character, so one source failing while the other has something must
    /// not surface as an error or an empty row — `cast.failed` (batch 2's
    /// `InlineFailure` trigger) stays false whenever there is something to
    /// show.
    @Test("One source failing while the other answers is not reported as failed")
    func singleFailureIsSilent() async {
        defer { URLProtocolStub.reset() }
        route(
            aniList: { .respond(.init(statusCode: 403, body: Data())) },
            shikimori: { .respond(.init(body: shikimoriBody(names: ["A", "B"]))) }
        )

        let cast = await characterService().characters(aniListID: 1, shikimoriID: 2)
        #expect(cast.characters.count == 2)
        #expect(!cast.failed)
    }

    /// Both down is the one case with a real reason to say something — gap
    /// 17: `cast.failed` is true only when every source that was asked threw,
    /// so batch 2's `CharacterRow` can show `InlineFailure` instead of
    /// quietly having nothing, distinct from the merely-empty case above.
    @Test("Both sources failing yields an empty cast, reported as failed")
    func bothDown() async {
        defer { URLProtocolStub.reset() }
        route(
            aniList: { .respond(.init(statusCode: 403, body: Data())) },
            shikimori: { .respond(.init(statusCode: 500, body: Data())) }
        )

        let subject = characterService()
        let cast = await subject.characters(aniListID: 1, shikimoriID: 2)
        #expect(cast.characters.isEmpty)
        #expect(cast.failed)
        #expect(await subject.lastOutcome == .none)
    }

    /// Both sources answering empty is not the same as both failing — batch
    /// 2 must render an empty section, not `InlineFailure`, for a series
    /// that genuinely has no cast anywhere.
    @Test("Both sources answering empty is not reported as failed")
    func bothEmptyIsNotFailed() async {
        defer { URLProtocolStub.reset() }
        route(
            aniList: { .respond(.init(body: Data(#"{"data":{"Media":{"characters":{"edges":[]}}}}"#.utf8))) },
            shikimori: { .respond(.init(body: Data("[]".utf8))) }
        )

        let cast = await characterService().characters(aniListID: 1, shikimoriID: 2)
        #expect(cast.characters.isEmpty)
        #expect(!cast.failed)
        #expect(cast.aniList == .answered)
        #expect(cast.shikimori == .answered)
    }
}
