import Foundation
import Testing
@testable import MangaBaka

/// Security properties that are easy to break by accident and invisible when
/// broken. Each of these was verified by hand during a review; these are the
/// guards so the next change cannot quietly undo one.
@Suite("Security invariants", .serialized)
struct SecurityTests {
    /// MangaUpdates needs no account, so the app must not send it one. Adding
    /// an auth header "just in case" would hand a MangaBaka credential to a
    /// different company.
    @Test("No credential is ever sent to MangaUpdates")
    func mangaUpdatesGetsNoCredential() async throws {
        URLProtocolStub.setHandler { _ in
            .respond(.init(body: Data(#"{"results":[]}"#.utf8)))
        }
        defer { URLProtocolStub.reset() }

        let client = MangaUpdatesClient(
            baseURL: URL(string: "https://mu.example.invalid/v1").unsafeTestURL,
            session: URLProtocolStub.makeSession(),
            clock: TestClock()
        )
        _ = try? await client.releases(seriesNumber: 16_945_653_113)

        let request = try #require(URLProtocolStub.requests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "x-api-key") == nil)
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
    }

    /// The series id identifies something the reader is reading. In the body it
    /// is not a URL cache key and not in any proxy's access log; in the query
    /// string it would be both.
    @Test("The series being looked up travels in the body, not the URL")
    func seriesIdIsNotInTheURL() async throws {
        URLProtocolStub.setHandler { _ in
            .respond(.init(body: Data(#"{"results":[]}"#.utf8)))
        }
        defer { URLProtocolStub.reset() }

        let client = MangaUpdatesClient(
            baseURL: URL(string: "https://mu.example.invalid/v1").unsafeTestURL,
            session: URLProtocolStub.makeSession(),
            clock: TestClock()
        )
        _ = try? await client.releases(seriesNumber: 16_945_653_113)

        let request = try #require(URLProtocolStub.requests.first)
        let url = try #require(request.url?.absoluteString)
        #expect(!url.contains("16945653113"))
        #expect(request.httpMethod == "POST")
    }

    /// Their terms ask for reasonable spacing and do not name a number. Slower
    /// than necessary is the correct error: a ban costs the feature entirely.
    @Test("Requests to MangaUpdates are spaced")
    func requestsAreSpaced() {
        #expect(MangaUpdatesClient.minimumInterval >= 3.0)
    }

    /// A token never expires and is not scoped, so anyone holding a Release
    /// build could act as its owner. The config forces it empty; this is the
    /// guard on the config.
    @Test("A Release build cannot carry a personal access token",
          .enabled(if: SourceTree.isAvailable))
    func releaseCannotCarryAToken() throws {
        let release = try SourceTree.read("Configs/Release.xcconfig")
        #expect(release.contains("MB_PAT ="))
        // The word appears in a comment explaining why it is absent, so the
        // check is on the include itself rather than the mention.
        let includesSecrets = release
            .split(separator: "\n")
            .contains { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return trimmed.hasPrefix("#include") && trimmed.contains("Secrets")
            }
        #expect(!includesSecrets, "Release must not include the file holding a real token")
    }

    /// The rule is what the request CARRIES, not where it is going.
    /// `/v1/series/mix` is public by path, but once it carries the reader's
    /// account id the URL is a cache key containing that id.
    @Test("Identity-bearing parameters are named and never cached")
    func identityIsNeverCached() throws {
        let source = try SourceTree.read("MangaBaka/Core/Networking/APIClient.swift")
        for parameter in ["exclude_user_library", "blend_user_id"] {
            #expect(source.contains(parameter), "\(parameter) is not treated as identity")
        }
        #expect(source.contains("carriesIdentity"))
    }

    /// A stored error message is written to the device and read back later.
    /// It must never be a raw transport error, which can carry a full URL.
    @Test("Stored failure messages are fixed strings, not raw errors")
    func failureMessagesAreSafe() {
        let transport = APIError.transport(underlying: "https://api.example.invalid?token=secret")
        #expect(!transport.userFacingMessage.contains("secret"))
        #expect(!transport.userFacingMessage.contains("http"))

        let decoding = APIError.decoding(underlying: "keyNotFound(token)")
        #expect(!decoding.userFacingMessage.contains("token"))
    }
}
