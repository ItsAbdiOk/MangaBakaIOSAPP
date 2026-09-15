import Testing
@testable import MangaBaka

/// `.transport` (a 20 s timeout, a DNS failure, TLS) used to say the cached
/// copy was not safe to keep showing, same as `.decoding` — wire review
/// W6/P6, 2026-09-15. A transport failure says nothing about whether the
/// shape changed; only `.decoding` does.
@Suite("APIError staleness after W6")
struct APIErrorWireFixTests {
    /// Fails on the pre-fix code with `false`: `.transport` sat in the same
    /// branch as `.decoding`, so a timed-out `full` leg hid the 6-hour cached
    /// copy the series page was already holding.
    @Test("A transport failure still says the stale copy is worth keeping")
    func transportKeepsStaleContentUseful() {
        let error = APIError.transport(underlying: "The request timed out.")
        #expect(error.staleContentRemainsUseful)
    }

    /// The control: a decode failure means the shape itself changed, so the
    /// cache may no longer be accurate — this must stay `false`.
    @Test("A decoding failure still discards the stale copy")
    func decodingStillDiscardsStaleContent() {
        let error = APIError.decoding(underlying: "keyNotFound(...)")
        #expect(!error.staleContentRemainsUseful)
    }

    /// Every other case was already `true` before this fix and must stay so.
    @Test("Offline, rate-limited, server and cancelled are unaffected")
    func otherCasesUnaffected() {
        #expect(APIError.offline.staleContentRemainsUseful)
        #expect(APIError.rateLimited(until: nil).staleContentRemainsUseful)
        #expect(APIError.server(status: 500, message: "").staleContentRemainsUseful)
        #expect(APIError.cancelled.staleContentRemainsUseful)
    }
}
