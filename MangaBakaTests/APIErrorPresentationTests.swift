import Foundation
import Testing
@testable import MangaBaka

/// How failures read to a reader. These matter more than they look: the rate
/// limit is shared per IP, so the app will regularly refuse people who did
/// nothing, and blaming them for it is both wrong and infuriating.
@Suite("Error presentation")
struct APIErrorPresentationTests {
    @Test("A rate limit never blames the reader")
    func rateLimitIsBlameless() {
        for retry in [nil, TimeInterval(5), TimeInterval(300)] {
            let message = APIError.rateLimited(retryAfter: retry).userFacingMessage.lowercased()
            #expect(!message.contains("you "))
            #expect(!message.contains("your "))
            #expect(!message.contains("too many requests"), "That phrasing implicates the reader")
        }
    }

    @Test("A wait is expressed in plain units")
    func humanDurations() {
        #expect(APIError.rateLimited(retryAfter: 1).userFacingMessage.contains("1 second"))
        #expect(APIError.rateLimited(retryAfter: 30).userFacingMessage.contains("30 seconds"))
        #expect(APIError.rateLimited(retryAfter: 120).userFacingMessage.contains("2 minutes"))
        #expect(APIError.rateLimited(retryAfter: 60).userFacingMessage.contains("1 minute"))
    }

    @Test("With no Retry-After the message promises no specific time")
    func noFalsePrecision() {
        let message = APIError.rateLimited(retryAfter: nil).userFacingMessage
        #expect(!message.contains("second"))
        #expect(!message.contains("minute"))
    }

    /// A rate limit or an outage says nothing about whether cached content is
    /// still accurate, so it stays on screen. A decode failure means the shape
    /// changed, and showing the old copy may mislead.
    @Test("Only some failures leave stale content worth showing")
    func staleUsefulness() {
        #expect(APIError.offline.staleContentRemainsUseful)
        #expect(APIError.rateLimited(retryAfter: nil).staleContentRemainsUseful)
        #expect(APIError.server(status: 500, message: "x").staleContentRemainsUseful)
        #expect(!APIError.decoding(underlying: "x").staleContentRemainsUseful)
        #expect(!APIError.transport(underlying: "x").staleContentRemainsUseful)
    }

    @Test("Technical detail never reaches the reader")
    func noInternalsLeak() {
        let decoding = APIError.decoding(underlying: "keyNotFound(CodingKeys(stringValue: \"id\"))")
        let transport = APIError.transport(underlying: "NSURLErrorDomain -1200")
        #expect(!decoding.userFacingMessage.contains("CodingKeys"))
        #expect(!transport.userFacingMessage.contains("NSURLError"))
    }

    /// The API documents `message` as safe to show verbatim, so a server error
    /// must not be replaced with a generic one.
    @Test("A server's own message survives to the reader")
    func serverMessagePassesThrough() {
        let error = APIError.server(status: 404, message: "That series doesn't exist.")
        #expect(error.userFacingMessage == "That series doesn't exist.")
    }

    @Test("Each failure gets a symbol matching its cause")
    func symbolsDiffer() {
        let symbols = [
            APIError.offline,
            .rateLimited(retryAfter: nil),
            .server(status: 500, message: "x"),
            .decoding(underlying: "x")
        ].map(\.symbolName)
        #expect(Set(symbols).count == symbols.count, "A shared symbol tells the reader nothing")
    }
}

/// "Unauthenticated." names a state the reader cannot act on. Signing in is a
/// fix they can carry out, and the app has a screen for it — so the message
/// says where to go. Every other status keeps the API's own wording, which the
/// API documents as safe to show verbatim.
@Suite("An auth failure says what to do about it")
struct AuthErrorPresentationTests {
    @Test("401 and 403 point at Settings", arguments: [401, 403])
    func authErrorsAreActionable(_ status: Int) {
        let error = APIError.server(status: status, message: "Unauthenticated.")
        #expect(error.needsAccount)
        #expect(error.userFacingMessage.contains("Settings"))
        #expect(!error.userFacingMessage.contains("Unauthenticated"))
        #expect(error.symbolName == "person.crop.circle.badge.plus")
    }

    @Test("Other statuses keep the API's own words", arguments: [400, 404, 422, 500])
    func otherStatusesAreVerbatim(_ status: Int) {
        let error = APIError.server(status: status, message: "That series does not exist.")
        #expect(!error.needsAccount)
        #expect(error.userFacingMessage == "That series does not exist.")
    }
}
