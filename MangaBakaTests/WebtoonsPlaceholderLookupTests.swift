import Testing
import Foundation
@testable import MangaBaka

/// Item 44: resolving a Webtoons placeholder link used to GET a page it never
/// read.
///
/// 84% of the Webtoons links in a real library are placeholders, so most first
/// opens ran this. The lookup exists only to read `response.url` after the
/// redirect, and a GET downloads a full `no-store` HTML listing page to get
/// there — for a made-up `/en/x/y/` path that is also what Webtoons sees in
/// its own logs. Measured from a Mac and confirmed from a phone (U18): HEAD
/// answers `301`, `content-length: 0`, with the same `location`.
@Suite("Webtoons placeholder lookup", .serialized)
struct WebtoonsPlaceholderLookupTests {
    /// The shape `WebtoonsFeedParser.lookupURL` builds from a placeholder —
    /// see `placeholderBecomesLookup` in `WebtoonsFeedTests`.
    private let placeholder = SeriesLink(
        id: "1", url: URL(string: "https://www.webtoons.com/-/-/-/list?title_no=5188"),
        name: "webtoons", nameDisplay: nil, type: "webplatform", language: "en"
    )

    private let rss = Data(#"""
    <?xml version="1.0"?>
    <rss version="2.0"><channel><title>Estate Developer</title>
    <item><title>Episode 12</title><pubDate>Thu, 11 Sep 2026 15:00:00 GMT</pubDate></item>
    </channel></rss>
    """#.utf8)

    /// Expected failure before the fix: the first recorded request's
    /// `httpMethod` is "GET", and its response body — a whole listing page in
    /// production — is downloaded and discarded.
    @Test("The placeholder lookup asks with HEAD, not GET")
    func lookupUsesHead() async {
        nonisolated(unsafe) var lookupMethod: String?
        URLProtocolStub.setHandler { request in
            // The lookup: `/en/x/y/list?title_no=5188`, the made-up path
            // `WebtoonsFeedParser.lookupURL` builds for a placeholder.
            if request.url?.path().hasSuffix("/list") == true {
                lookupMethod = request.httpMethod
                return .respond(.init(statusCode: 200, body: Data()))
            }
            return .respond(.init(body: rss))
        }
        defer { URLProtocolStub.reset() }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("webtoons-head-\(UUID().uuidString)", isDirectory: true)
        let client = WebtoonsFeedClient(
            session: URLProtocolStub.makeSession(), clock: TestClock(), cacheDirectory: directory
        )

        _ = await client.feed(for: SeriesFactory.make(id: 5188, title: "Estate Developer"),
                              links: [placeholder])

        #expect(!URLProtocolStub.requests.isEmpty, "control: the lookup was actually attempted")
        #expect(lookupMethod == "HEAD")
    }
}
