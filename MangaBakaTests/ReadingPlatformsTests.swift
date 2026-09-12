import Foundation
import Testing
@testable import MangaBaka

/// The allowlist behind "Read it".
///
/// MangaBaka's links are community-maintained, so a contributor can point a
/// `webplatform` link anywhere and this app would render it as a tappable chip
/// offering to take someone there. Guideline 5.2.3 makes that the app's
/// problem. Abdi's call (2026-09-12): hide an unrecognised host completely
/// rather than showing it as untappable text.
@Suite("Reading platform allowlist")
struct ReadingPlatformsTests {
    private func link(
        _ host: String, type: String = "webplatform", language: String = "en"
    ) -> SeriesLink {
        SeriesLink(
            id: host,
            url: URL(string: "https://\(host)/series/1"),
            name: host,
            nameDisplay: nil,
            type: type,
            language: language
        )
    }

    @Test("A licensed platform is allowed")
    func knownPlatforms() {
        #expect(ReadingPlatforms.allows(URL(string: "https://webtoons.com/en/x")))
        #expect(ReadingPlatforms.allows(URL(string: "https://tapas.io/series/x")))
        #expect(ReadingPlatforms.allows(URL(string: "https://manta.net/en/series/x")))
    }

    /// One entry per publisher, not per magazine: Shueisha alone appeared in
    /// the sample as mangaplus, mangamillion, zebrack-comic and cocohana.
    @Test("A subdomain of an allowed host is allowed, and so is a www. prefix")
    func subdomainsAndWWW() {
        #expect(ReadingPlatforms.allows(URL(string: "https://mangaplus.shueisha.co.jp/titles/1")))
        #expect(ReadingPlatforms.allows(URL(string: "https://zebrack-comic.shueisha.co.jp/t/1")))
        #expect(ReadingPlatforms.allows(URL(string: "https://th.kakaowebtoon.com/content/x")))
        #expect(ReadingPlatforms.allows(URL(string: "https://www.tappytoon.com/en/book/x")))
    }

    /// The whole point. Nothing in the 450-series sample was an aggregator, so
    /// this is the case the list exists to fail on before it ever appears.
    @Test("An unrecognised host is not allowed")
    func unknownHostsRejected() {
        #expect(!ReadingPlatforms.allows(URL(string: "https://some-aggregator.example/read/1")))
        #expect(!ReadingPlatforms.allows(URL(string: "https://webtoons.com.evil.example/x")))
        #expect(!ReadingPlatforms.allows(URL(string: "https://notwebtoons.com/x")))
    }

    /// A suffix match must be on a label boundary, or "evilwebtoons.com" passes
    /// as "webtoons.com". The dot in `hasSuffix(".")` is what does that.
    @Test("A host that merely ends in an allowed name is not allowed")
    func suffixIsLabelBoundary() {
        #expect(!ReadingPlatforms.allows(URL(string: "https://fakelezhin.com/x")))
        #expect(ReadingPlatforms.allows(URL(string: "https://comic.naver.com/x")))
    }

    /// An archived copy of a reader page is the unauthorised-access case
    /// whoever archived it. It was in the live sample once, typed webplatform.
    @Test("An archive of a reader page is not somewhere to read")
    func archiveIsRejected() {
        #expect(!ReadingPlatforms.allows(URL(string: "https://web.archive.org/web/2/http://x")))
    }

    @Test("Nothing without a web scheme or a host is allowed")
    func schemeStillApplies() {
        #expect(!ReadingPlatforms.allows(URL(string: "shortcuts://run?name=x")))
        #expect(!ReadingPlatforms.allows(nil))
    }

    // MARK: - What the page actually renders

    @Test("An unknown platform is dropped from the reading row entirely")
    func readableDropsUnknown() {
        let links = [link("webtoons.com"), link("some-aggregator.example"), link("tapas.io")]
        let readable = SeriesLink.readable(links, in: "en")
        #expect(readable.map { $0.name } == ["webtoons.com", "tapas.io"])
    }

    /// The control: with only allowed platforms the row is exactly what it was
    /// before the allowlist existed, so the filter is not quietly eating rows.
    @Test("A row of allowed platforms is untouched")
    func readableKeepsKnown() {
        let links = [link("webtoons.com"), link("tapas.io"), link("manta.net")]
        #expect(SeriesLink.readable(links, in: "en").count == 3)
    }

    @Test("An unknown platform is dropped from the links section too")
    func groupedDropsUnknown() {
        let groups = SeriesLink.grouped([link("webtoons.com"), link("some-aggregator.example")])
        let readIt = groups.first { $0.heading == "Read it" }
        #expect(readIt?.links.map { $0.name } == ["webtoons.com"])
    }

    /// A heading with nothing under it would be a claim the data no longer
    /// supports, so the group has to go, not just its rows.
    @Test("The heading disappears when every platform under it was dropped")
    func groupVanishesWhenEmptied() {
        let groups = SeriesLink.grouped([link("some-aggregator.example"), link("also.example")])
        #expect(groups.isEmpty)
    }

    /// The allowlist is scoped to reading links. Publishers are a long tail no
    /// fixed list could cover — 160 viz.com, 82 yenpress.com and 300-odd more
    /// in the sample — and a wiki is not an offer to read.
    @Test("Publisher, info and social links are not held to the allowlist")
    func otherKindsUnaffected() {
        let groups = SeriesLink.grouped([
            link("viz.com", type: "publisher"),
            link("en.wikipedia.org", type: "info"),
            link("x.com", type: "social")
        ])
        #expect(groups.map(\.heading) == ["Publishers", "More about it", "Social"])
    }

    /// ...but they are still scheme-filtered, which is what `safeURL` always did.
    @Test("A publisher link with an app scheme is still refused")
    func otherKindsStillSchemeFiltered() {
        let bad = SeriesLink(
            id: "x", url: URL(string: "shortcuts://run?name=pwn"), name: "x",
            nameDisplay: nil, type: "publisher", language: "en"
        )
        #expect(SeriesLink.grouped([bad]).isEmpty)
    }
}
