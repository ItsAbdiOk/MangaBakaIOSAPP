import Foundation
import Testing
@testable import MangaBaka

/// MangaBaka's data is community-maintained, so every URL the app might open
/// was typed in by someone else. Opening an arbitrary scheme on a reader's
/// behalf hands a contributor the ability to trigger another installed app.
///
/// The gate moved from the suite to the two tests that need it on
/// 2026-09-14. It was on the suite, so the scheme allow-list below — the
/// rule this file exists for — was skipped on every Xcode Cloud build,
/// because `SourceTree.isAvailable` is false wherever the checkout is not
/// reachable from inside the simulator. Nothing reports the difference
/// between a local run and a cloud one, so it read as green both times.
/// Four tests that decode a URL and call `SafeLink.web` never needed the
/// checkout at all.
@Suite("Link safety")
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
    ///
    /// The positive half stays a call-site pin — whether `LinksSection`'s
    /// button hands `openURL` the filtered value is not readable from outside
    /// SwiftUI, and only a UI test tapping the row could prove it. The
    /// negative half does not stay pinned to this one file: see
    /// `noFileReadsARawLinkURL` below.
    @Test("The links view uses the filtered accessor", .enabled(if: SourceTree.isAvailable))
    func viewUsesFilteredURL() throws {
        let source = try SourceTree.read("MangaBaka/Features/Detail/LinksSection.swift")

        #expect(source.contains("link.safeURL"))
        #expect(source.contains("item.safeURL"))
    }

    /// The same three negative checks, asked of the whole app rather than of
    /// the one file that happened to have the bug.
    ///
    /// They were scoped to `LinksSection.swift` and that is precisely the
    /// n−1 shape `XcconfigAssertions.swift:6-13` names as this project's
    /// characteristic defect: `PublisherView.swift:240` and `ReadRow.swift:61`
    /// open `SeriesLink`s too, and neither was covered. A new screen that
    /// lists links is the case that matters, and no per-file pin can see one.
    ///
    /// The rule is "nothing reads the raw accessor", not "nothing calls
    /// openURL": `RemindersSection`, `AppleVolumesRow` and `VolumesSection`
    /// legitimately open URLs that never came off the wire as free text.
    ///
    /// Cost, stated rather than discovered later: `link` and `item` are
    /// ordinary names, so an unrelated type with a `url` property bound to
    /// either would fail this and need renaming or an exemption here. As of
    /// 2026-09-14 the whole tree has zero matches, so nothing is exempted.
    ///
    /// Expected to fail without the fix — reverting `ReadRow.swift:61` to
    /// `if let url = link.url { openURL(url) }` — with: "ReadRow.swift reads
    /// a raw link URL". The old per-file test passes that revert.
    @Test("No file anywhere reads a raw link or news URL", .enabled(if: SourceTree.isAvailable))
    func noFileReadsARawLinkURL() throws {
        let files = try SourceTree.swiftFiles(under: "MangaBaka")
        #expect(!files.isEmpty, "No sources found: the loop below would pass on nothing")
        var exercised = 0
        for file in files {
            let source = try SourceTree.read(file)
            if source.contains("safeURL") { exercised += 1 }
            for raw in ["link.url", "item.url", "$0.url"] {
                #expect(
                    !source.contains(raw),
                    "\(file) reads a raw link URL (\(raw)); only safeURL may reach openURL"
                )
            }
        }
        // `safeURL` has to still exist somewhere, or the rule above is
        // satisfied by an app that opens no links at all.
        #expect(exercised > 0, "Nothing in the app names safeURL; the rule was never exercised")
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
