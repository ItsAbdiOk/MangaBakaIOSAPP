import Foundation
import Testing
@testable import MangaBaka

/// Item 74 (wire review, `docs/reviews/full/wire.md` finding 10, 2026-09-14):
/// `line.me`, `iqiyi.com` and `crunchyroll.com` were listed as registrable
/// roots, so `allows` admitted any subdomain and any non-empty path on each —
/// a LINE share link, an iQIYI video page, or a Crunchyroll streaming page all
/// rendered under "Read it", against the file's own rule for naver, daum,
/// kakao, pixiv, nicovideo and bilibili (only the reader subdomain is listed
/// for a portal). `ReadingPlatformsTests.swift` (existing, not owned here)
/// covers the platforms that were already correct; this file covers only the
/// three that were not.
@Suite("Reading platform allowlist — scoped hosts")
struct ReadingPlatformsScopedHostsTests {
    /// Before the fix, `iqiyi.com` was a bare root: any path on any
    /// subdomain — including the video site's own player pages — passed.
    /// Expected failure before the fix: `#expect(... == false)` fails because
    /// `allows` returns `true` for `www.iqiyi.com/v_xyz`.
    @Test("An iQIYI video page is not a reading platform")
    func iqiyiVideoPageIsRejected() {
        #expect(ReadingPlatforms.allows(URL(string: "https://www.iqiyi.com/v_xyz")) == false)
    }

    /// The actual comics surface — a distinct registrable domain, `iq.com`,
    /// not a subdomain of `iqiyi.com` — is still allowed.
    @Test("iQIYI's comics reader is still allowed")
    func iqiyiComicsReaderIsAllowed() {
        #expect(ReadingPlatforms.allows(URL(string: "https://comic.iq.com/comic/abc123")))
    }

    /// Before the fix, `line.me` was a bare root: `store.line.me`,
    /// `shop.line.me` and every other LINE surface passed. Expected failure
    /// before the fix: `allows` returns `true` for `store.line.me/...`.
    @Test("A LINE storefront link is not a reading platform")
    func lineStorefrontIsRejected() {
        #expect(ReadingPlatforms.allows(URL(string: "https://store.line.me/stickershop/1")) == false)
    }

    @Test("LINE's manga reader is still allowed")
    func lineMangaReaderIsAllowed() {
        #expect(ReadingPlatforms.allows(URL(string: "https://manga.line.me/product/1")))
    }

    /// Before the fix, `crunchyroll.com` was a bare root: any path, including
    /// an anime episode's own watch page, passed. Expected failure before the
    /// fix: `allows` returns `true` for `crunchyroll.com/watch/...`.
    @Test("A Crunchyroll video page is not a reading platform")
    func crunchyrollVideoPageIsRejected() {
        #expect(ReadingPlatforms.allows(URL(string: "https://www.crunchyroll.com/watch/GRDQPM90Y/pilot")) == false)
    }

    /// Crunchyroll's manga reader relaunched 2025-10-15 at a path on the same
    /// domain, `crunchyroll.com/manga`, not its own subdomain — the one entry
    /// in this file where "reader subdomain" was not available and a path
    /// scope was used instead.
    @Test("Crunchyroll's manga path is still allowed")
    func crunchyrollMangaPathIsAllowed() {
        #expect(ReadingPlatforms.allows(URL(string: "https://www.crunchyroll.com/manga/some-series")))
    }

    /// A path under crunchyroll.com that merely starts with "manga" as a
    /// prefix of a different segment must not slip past a naive string check.
    @Test("A crunchyroll.com path that only resembles /manga is rejected")
    func crunchyrollLookalikePathIsRejected() {
        #expect(ReadingPlatforms.allows(URL(string: "https://www.crunchyroll.com/manga-news/some-article")) == false)
    }
}
