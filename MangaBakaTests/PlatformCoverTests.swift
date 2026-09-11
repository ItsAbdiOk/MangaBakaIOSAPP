import Foundation
import Testing
@testable import MangaBaka

/// The platform's own cover, read from the one tag its page publishes for
/// sharing.
@Suite("Platform cover", .serialized, .enabled(if: SourceTree.isAvailable))
struct PlatformCoverTests {
    private func link(_ url: String) -> SeriesLink {
        SeriesLink(id: url, url: URL(string: url), name: nil, nameDisplay: nil,
                   type: "webplatform", language: "en")
    }

    /// The tag as Webtoons and Tapas write it (2026-09-11), and the other
    /// attribute order, and an escaped ampersand.
    @Test("og:image is read whichever way the tag is written")
    func parsesTag() {
        let webtoons = #"<meta property="og:image" content="https://swebtoon-phinf.pstatic.net/a/b.jpg?type=crop540_540" />"#
        #expect(PlatformCoverClient.ogImage(in: webtoons)?.host() == "swebtoon-phinf.pstatic.net")
        let reversed = #"<meta content="https://us-a.tapas.io/sa/71/x.jpg&amp;v=2" property='og:image'>"#
        #expect(PlatformCoverClient.ogImage(in: reversed)?.absoluteString == "https://us-a.tapas.io/sa/71/x.jpg&v=2")
        #expect(PlatformCoverClient.ogImage(in: "<meta property=\"og:title\" content=\"x\">") == nil)
        #expect(PlatformCoverClient.ogImage(in: #"<meta property="og:image" content="javascript:x">"#) == nil)
    }

    @Test("Only a Webtoons or Tapas page is read, once, with our own user agent")
    func fetchesOnce() async {
        let html = Data(#"<html><meta property="og:image" content="https://us-a.tapas.io/c.jpg"></html>"#.utf8)
        URLProtocolStub.setHandler { _ in .respond(.init(body: html)) }
        defer { URLProtocolStub.reset() }
        let client = PlatformCoverClient(session: URLProtocolStub.makeSession())
        let links = [link("https://manta.net/en/series/x"), link("https://tapas.io/series/x/info")]

        let first = await client.cover(from: links)
        let second = await client.cover(from: links)

        #expect(first?.absoluteString == "https://us-a.tapas.io/c.jpg")
        #expect(second == first)
        #expect(URLProtocolStub.requests.count == 1)
        #expect(URLProtocolStub.requests.first?.url?.host() == "tapas.io")
        let agent = URLProtocolStub.requests.first?.value(forHTTPHeaderField: "User-Agent")
        #expect(agent?.hasPrefix("MangaBakaIOS") == true)
        #expect(URLProtocolStub.requests.first?.value(forHTTPHeaderField: "Referer") == nil)
        #expect(await client.cover(from: [link("https://manta.net/en/series/x")]) == nil)
    }

    /// One switch, one file, one call site: `isEnabled` off leaves the page
    /// exactly as it was, and deleting the client and its call is the
    /// whole removal. Abdi, 2026-09-11: "make it so we can cleanly remove it
    /// if Naver or Tapas ever complains."
    @Test("Removable: one flag, and the merge only adds an image MangaBaka lacks")
    func removable() throws {
        #expect(PlatformCoverClient.isEnabled)
        let covers = try SourceTree.read("MangaBaka/Features/Detail/SeriesDetailView+Covers.swift")
        #expect(covers.contains("platformCoverURL != shown.cover.raw"))
        #expect(covers.contains("!out.contains(where: { $0.image.raw == platformCoverURL })"))
        let store = try SourceTree.read("MangaBaka/Features/Detail/SeriesDetailView+Store.swift")
        #expect(store.contains("platformCoverURL = await platformCover.cover(from: extras.links)"))
    }
}
