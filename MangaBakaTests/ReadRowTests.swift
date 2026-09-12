import Foundation
import Testing
@testable import MangaBaka

/// "Read in English": the platforms in the reader's language, and nothing else.
///
/// Series 3397 lists thirteen platforms in seven languages (live, 2026-09-11).
/// A reader in English wants the four that are — Manta, Tapas, WEBCOMICS,
/// tappytoon, WebNovel — not Piccoma in Japanese or Delitoon in French.
@Suite("Read in your language")
struct ReadRowTests {
    /// A real licensed platform by default. A `webplatform` link is held to
    /// `ReadingPlatforms` now, so a fictional host never reaches the row and
    /// these language expectations would all read as empty.
    private func link(
        _ name: String, type: String = "webplatform", language: String? = "en",
        url: String = "https://manta.net/en/series/1"
    ) -> SeriesLink {
        SeriesLink(id: name, url: URL(string: url), name: name, nameDisplay: name,
                   type: type, language: language)
    }

    @Test("Only reading platforms in the reader's language, in the API's order")
    func filtersByKindAndLanguage() {
        let links = [
            link("Manta"), link("KakaoPage", language: "ko"), link("Piccoma", language: "ja"),
            link("Tapas"), link("Yen Press", type: "publisher"), link("Wikipedia", type: "info"),
            link("Delitoon", language: "fr"), link("WebNovel")
        ]
        let names = SeriesLink.readable(links, in: "en").map(\.title)
        #expect(names == ["Manta", "Tapas", "WebNovel"])
    }

    /// The API writes "pt-br" for Planet Manga; the device says "pt".
    @Test("Regional tags match on the language alone")
    func regionIgnored() {
        let links = [link("Planet Manga", language: "pt-br"), link("Manta", language: "en")]
        #expect(SeriesLink.readable(links, in: "pt").map(\.title) == ["Planet Manga"])
        #expect(SeriesLink.readable(links, in: "pt-PT").map(\.title) == ["Planet Manga"])
        #expect(SeriesLink.primarySubtag("pt-BR") == "pt")
        #expect(SeriesLink.primarySubtag(" EN ") == "en")
    }

    /// ONE PIECE lists MANGA Plus five times in English: the main run, the
    /// colour edition, the spin-offs. One chip, the first listing.
    @Test("A platform listed several times is one chip, the first listing")
    func onePerPlatform() {
        let links = [
            link("MANGA Plus", url: "https://mangaplus.shueisha.co.jp/titles/100020"),
            link("MANGA Plus", url: "https://mangaplus.shueisha.co.jp/titles/100079"),
            link("Crunchyroll", url: "https://crunchyroll.com/x"),
            link("MANGA Plus", url: "https://mangaplus.shueisha.co.jp/titles/100140")
        ]
        let readable = SeriesLink.readable(links, in: "en")
        #expect(readable.map(\.title) == ["MANGA Plus", "Crunchyroll"])
        #expect(readable.first?.url?.absoluteString.hasSuffix("100020") == true)
    }

    /// A webtoon with no print release has the platform as its only shelf,
    /// and "free" is what a reader wants to know about it. Only settled
    /// facts get a label.
    @Test("Cost is noted only where it is a settled fact")
    func costNotes() {
        #expect(link("Webtoons", url: "https://www.webtoons.com/en/x").withName("www.webtoons.com").costNote == "Free")
        #expect(link("Tapas").withName("tapas.io").costNote == "Free to start")
        #expect(link("Manta").withName("manta.net").costNote == "Subscription")
        #expect(link("KakaoPage").withName("page.kakao.com").costNote == nil)
    }

    /// These URLs come from other people. A `kakao://` scheme would open
    /// another app with none of the deliberation a web link implies.
    @Test("A link with no web URL is not offered, whatever its language")
    func unsafeDropped() {
        let links = [
            link("Manta", url: "kakao://content/1"),
            link("Tapas", url: "https://tapas.io/series/x"),
            link("Nowhere", language: nil)
        ]
        #expect(SeriesLink.readable(links, in: "en").map(\.title) == ["Tapas"])
        #expect(SeriesLink.readable(links, in: "").isEmpty)
    }
}

@Suite("The read row opens the title's own link", .enabled(if: SourceTree.isAvailable))
struct ReadRowSourceTests {
    /// Through the system, so a platform's app opens on the title when it is
    /// installed and Safari on the same page when it is not. Never a URL
    /// that did not pass `safeURL`.
    @Test("Chips open through openURL, and only a safe URL")
    func opensSafely() throws {
        let source = try SourceTree.read("MangaBaka/Features/Detail/ReadRow.swift")
        #expect(source.contains("if let url = link.safeURL { openURL(url) }"))
        #expect(!source.contains("UIApplication.shared.open"))
    }

    @Test("The row sits under the actions on the series page")
    func placedUnderActions() throws {
        let source = try SourceTree.read("MangaBaka/Features/Detail/SeriesDetailView.swift")
        #expect(source.contains("actions\n"))
        let actions = try #require(source.range(of: "                actions\n"))
        let row = try #require(source.range(of: "ReadRow(links: extras.links)"))
        let strip = try #require(source.range(of: "DetailStatsStrip(series: shown"))
        #expect(actions.upperBound < row.lowerBound && row.upperBound < strip.lowerBound)
    }
}

private extension SeriesLink {
    func withName(_ name: String) -> SeriesLink {
        SeriesLink(id: id, url: url, name: name, nameDisplay: nameDisplay, type: type, language: language)
    }
}
