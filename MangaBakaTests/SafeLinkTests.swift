import Foundation
import Testing
@testable import MangaBaka

/// MangaBaka's data is community-maintained, so every URL the app might open
/// was typed in by someone else. Opening an arbitrary scheme on a reader's
/// behalf hands a contributor the ability to trigger another installed app.
@Suite("Link safety", .enabled(if: SourceTree.isAvailable))
struct SafeLinkTests {
    @Test("Ordinary web links are allowed")
    func allowsWebLinks() {
        #expect(SafeLink.web(URL(string: "https://manta.net/en/series/x")) != nil)
        #expect(SafeLink.web(URL(string: "http://example.com/a")) != nil)
        #expect(SafeLink.web(URL(string: "HTTPS://Example.com/a")) != nil, "Scheme is case-insensitive")
    }

    @Test(
        "Non-web schemes are refused",
        arguments: [
            "javascript:alert(1)",
            "file:///etc/passwd",
            "data:text/html;base64,PHNjcmlwdD4=",
            "itms-apps://apps.apple.com/app/id1",
            "shortcuts://run-shortcut?name=Wipe",
            "tel:+15551234",
            "sms:+15551234",
            "mailto:someone@example.com",
            "someapp://transfer?amount=1000"
        ]
    )
    func refusesOtherSchemes(raw: String) {
        #expect(
            SafeLink.web(URL(string: raw)) == nil,
            "\(raw) must never be opened on the reader's behalf"
        )
    }

    /// A scheme-relative or hostless URL is not a web link whatever it claims.
    @Test("Hostless and malformed URLs are refused")
    func refusesHostless() {
        #expect(SafeLink.web(URL(string: "https://")) == nil)
        #expect(SafeLink.web(URL(string: "/relative/path")) == nil)
        #expect(SafeLink.web(nil) == nil)
    }

    /// The filtering must be on the model, so no view can accidentally open the
    /// raw URL by reaching past it.
    @Test("Series links and news expose a filtered URL")
    func modelsFilter() throws {
        let link = try Fixture.decoder().decode(SeriesLink.self, from: Data("""
        {"id":"a","url":"javascript:alert(1)","name":"x","name_display":"X",
         "type":"webplatform","language":"en"}
        """.utf8))
        #expect(link.url != nil, "The raw value is still recorded")
        #expect(link.safeURL == nil, "But it is never offered for opening")

        let news = try Fixture.decoder().decode(NewsItem.self, from: Data("""
        {"id":1,"title":"T","url":"shortcuts://run-shortcut?name=X",
         "source_name":"ann","published_at":null,"primary":true}
        """.utf8))
        #expect(news.safeURL == nil)
    }

    /// The views must use the filtered accessor, not the raw one.
    @Test("The links view never opens a raw URL")
    func viewUsesFilteredURL() throws {
        let source = try SourceTree.read("MangaBaka/Features/Detail/LinksSection.swift")

        #expect(source.contains("link.safeURL"))
        #expect(source.contains("item.safeURL"))
        // The raw accessor must not appear at all: `safeURL` is the only way
        // a URL should reach openURL from this view.
        #expect(!source.contains("link.url "), "The raw URL must not reach openURL")
        #expect(!source.contains("item.url "), "The raw URL must not reach openURL")
        #expect(!source.contains("$0.url != nil"), "Filtering must use safeURL")
    }
}

@Suite("Authenticated responses are not cached to disk", .serialized)
struct AuthenticatedCacheTests {
    private let baseURL = URL(string: "https://api.example.invalid").unsafeTestURL

    private func makeClient() -> APIClient {
        APIClient(
            baseURL: baseURL,
            session: URLProtocolStub.makeSession(),
            tokenProvider: UnauthenticatedTokenProvider()
        )
    }

    /// MangaBaka does send "private, no-store" on these today, but that is
    /// their guarantee to change rather than ours to depend on.
    @Test("Requests for the reader's own data bypass the cache")
    func personalDataBypassesCache() async throws {
        URLProtocolStub.setHandler { _ in
            .respond(.init(body: Data(#"{"status":200,"data":[]}"#.utf8)))
        }
        defer { URLProtocolStub.reset() }

        let _: [Int] = try await makeClient().get("/v1/my/library")

        let policy = URLProtocolStub.requests.first?.cachePolicy
        #expect(policy == .reloadIgnoringLocalAndRemoteCacheData)
    }

    /// Public content should still cache — that is what keeps the app fast and
    /// keeps requests off a shared rate limit.
    @Test("Public requests still use the cache")
    func publicDataStillCaches() async throws {
        URLProtocolStub.setHandler { _ in
            .respond(.init(body: Data(#"{"status":200,"data":[]}"#.utf8)))
        }
        defer { URLProtocolStub.reset() }

        let _: [Int] = try await makeClient().get("/v2/series/discover/rising")

        #expect(URLProtocolStub.requests.first?.cachePolicy == .useProtocolCachePolicy)
    }
}
