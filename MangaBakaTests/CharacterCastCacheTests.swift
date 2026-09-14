import Foundation
import Testing
@testable import MangaBaka

/// Item 27 and Abdi's Q5 answer: the merged cast is cached, and bounded.
///
/// Shares the stub helpers (`aniListBody`, `shikimoriBody`, `route`,
/// `characterService`) that are file-scope in `CharacterSourceTests.swift`.
@Suite("Character cast cache and cap", .serialized)
struct CharacterCastCacheTests {
    /// The cast was the only third-party answer on the series page with no
    /// cache at all, so every reopen and every pager swipe cost AniList and
    /// Shikimori one request each — and it is the one place a third party
    /// could watch the reader's browsing path in full, twice over.
    ///
    /// Expected failure before the fix: `URLProtocolStub.requests.count` is 4
    /// (two hosts, twice), not 2.
    @Test("Opening the same series twice costs one request per source, not two")
    func repeatOpenIsServedFromCache() async {
        defer { URLProtocolStub.reset() }
        route(
            aniList: { .respond(.init(body: aniListBody(names: ["Preferred"]))) },
            shikimori: { .respond(.init(body: shikimoriBody(names: ["Fallback"]))) }
        )

        let subject = characterService()
        let first = await subject.characters(aniListID: 1, shikimoriID: 2)
        let requestsAfterFirst = URLProtocolStub.requests.count
        let second = await subject.characters(aniListID: 1, shikimoriID: 2)

        #expect(URLProtocolStub.requests.count == requestsAfterFirst, "no new request at all")
        #expect(second == first, "and the same answer, not an emptier one")
        #expect(requestsAfterFirst == 2, "control: the first open really did ask both sources")
    }

    /// A cast where every source that was asked failed is not an answer worth
    /// keeping for a day — that is the 15-minute outage memory's job, and
    /// caching the emptiness would outlast the outage by 23 hours.
    @Test("A cast where every asked source failed is not cached")
    func totalFailureIsNotCached() async {
        defer { URLProtocolStub.reset() }
        route(
            aniList: { .fail(URLError(.notConnectedToInternet)) },
            shikimori: { .fail(URLError(.notConnectedToInternet)) }
        )

        let subject = characterService()
        let first = await subject.characters(aniListID: 1, shikimoriID: 2)
        #expect(first.failed, "control: both sources failed")
        let requestsAfterFirst = URLProtocolStub.requests.count

        _ = await subject.characters(aniListID: 1, shikimoriID: 2)
        #expect(URLProtocolStub.requests.count > requestsAfterFirst, "asked again, not remembered as empty")
    }

    /// `clearOutageMemory()` is the account-change and manual-retry hook. A
    /// cached union built while one source was down is exactly what a retry is
    /// trying to get past.
    @Test("Clearing the outage memory clears the cast cache too")
    func clearingOutageMemoryDropsTheCache() async {
        defer { URLProtocolStub.reset() }
        route(
            aniList: { .respond(.init(body: aniListBody(names: ["Preferred"]))) },
            shikimori: { .respond(.init(body: shikimoriBody(names: ["Fallback"]))) }
        )

        let subject = characterService()
        _ = await subject.characters(aniListID: 1, shikimoriID: 2)
        let requestsAfterFirst = URLProtocolStub.requests.count

        await subject.clearOutageMemory()
        _ = await subject.characters(aniListID: 1, shikimoriID: 2)
        #expect(URLProtocolStub.requests.count > requestsAfterFirst)
    }

    /// Abdi's Q5 answer. The union appended *every* unmatched Shikimori
    /// character after AniList's 20, and Solo Leveling's Shikimori cast is 95
    /// — so one row could reach 40+ portrait fetches. The cap is 30, a guess.
    ///
    /// Expected failure before the fix: `merged.characters.count` is 60
    /// (20 + 40), and the last name is "S40".
    @Test("The merged cast stops at the cap instead of appending a whole second cast")
    func mergedCastIsCapped() async {
        defer { URLProtocolStub.reset() }
        let aniListNames = (1...20).map { "A\($0)" }
        let shikimoriNames = (1...40).map { "S\($0)" }
        route(
            aniList: { .respond(.init(body: aniListBody(names: aniListNames))) },
            shikimori: { .respond(.init(body: shikimoriBody(names: shikimoriNames))) }
        )

        let merged = await characterService().characters(aniListID: 1, shikimoriID: 2)

        #expect(merged.characters.count == CharacterService.mergedCastLimit)
        // AniList's cast still leads, in AniList's own order — the cap trims
        // the tail, it does not reshuffle the head.
        #expect(merged.characters.prefix(20).map(\.name) == aniListNames)
        #expect(merged.characters.last?.name == "S10")
    }
}
