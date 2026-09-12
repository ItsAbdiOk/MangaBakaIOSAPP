import Foundation

/// The platforms a "read it here" link is allowed to point at.
///
/// An allowlist rather than a blocklist, and the reason is App Review.
/// Guideline 5.2.3 treats facilitating access to pirated material as grounds
/// for rejection, and MangaBaka's links are community-maintained: anyone who
/// can edit a series can add a URL that this app would then render as a
/// tappable chip under a heading reading "Read it". A blocklist would have to
/// stay ahead of whatever gets added; an allowlist fails closed, which is the
/// only direction that is safe when the data comes from strangers.
///
/// **Measured, not guessed.** Every entry below was observed on a live
/// `webplatform` link while sampling 450 series from `/v1/series/search` on
/// 2026-09-12: 1,631 links across 132 distinct hosts. Every one of those 132
/// was an official publisher or licensed platform — there was no aggregator in
/// the sample at all. That is a real negative result and worth recording: the
/// risk this list exists for is *latent* in the data, not present in it. It is
/// the edit that has not happened yet that this guards against.
///
/// The single host from that sample deliberately left out is `web.archive.org`
/// (one series). An archived copy of a reader page is exactly the "unauthorised
/// access" case, whoever archived it.
///
/// Scoped to `webplatform` links on purpose. Publisher, info and social links
/// are not gated: the sample's publisher hosts are a long tail of real
/// publishers worldwide (160 viz.com, 82 yenpress.com, and 300-odd others that
/// no fixed list could anticipate), and gating them would empty the section to
/// protect against a risk that lives somewhere else. Those still pass
/// `SafeLink.web`, so the scheme check applies everywhere.
enum ReadingPlatforms {
    /// Whether a host is a platform this app will offer as somewhere to read.
    ///
    /// Matches the host itself or any subdomain of it, so one entry covers a
    /// publisher's regional and per-magazine sites: `shueisha.co.jp` admits
    /// `mangaplus.shueisha.co.jp` and `zebrack-comic.shueisha.co.jp` without
    /// either needing its own line. A leading `www.` is ignored.
    static func allows(_ url: URL?) -> Bool {
        guard let host = url?.host()?.lowercased(), !host.isEmpty else { return false }
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return allowed.contains { bare == $0 || bare.hasSuffix("." + $0) }
    }

    /// Registrable domains, grouped by who runs them. Subdomains are covered by
    /// the suffix match in `allows`, so only the root belongs here.
    static let allowed: Set<String> = globalPlatforms
        .union(koreanPlatforms)
        .union(japanesePublishers)
        .union(chinesePlatforms)

    /// Platforms serving English and European readers.
    private static let globalPlatforms: Set<String> = [
        "webtoons.com", "dongmanmanhua.cn", "tapas.io", "tappytoon.com", "manta.net",
        "crunchyroll.com", "inkr.com", "mangaplaza.com", "coolmic.me", "mangamo.com",
        "comikey.com", "mangas.io", "delitoon.com", "delitoon.de", "delitoonb.de",
        "ono.live", "mangetsu-manga.fr", "webnovel.com", "webcomicsapp.com",
        "mangatoon.mobi", "junemanga.com", "manga-park.com", "azuki.co",
        // Lezhin runs a separate registrable domain per territory rather than
        // subdomains, so each is its own entry.
        "lezhin.com", "lezhinus.com", "lezhin.es", "lezhin.jp", "lezhinfr.com",
        "lezhinth.com", "lezhinde.com"
    ]

    private static let koreanPlatforms: Set<String> = [
        "naver.com", "kakao.com", "kakaowebtoon.com", "daum.net", "comico.jp",
        "comico.kr", "bomtoon.com", "bomtoon.tw", "ridibooks.com", "munpia.com",
        "toomics.com", "toptoon.com", "lalatoon.com", "peanutoon.com", "qtoon.co.kr",
        "anytoon.co.kr", "onestory.co.kr", "mootoon.co.kr", "beltoon.jp",
        "beltoon.com", "jumptoon.com", "wecomics.in.th"
    ]

    /// Japanese publishers and their magazine sites. One entry per publisher
    /// wherever the magazines are subdomains; per-site where they are not.
    private static let japanesePublishers: Set<String> = [
        "shueisha.co.jp", "shonenjumpplus.com", "shonenjump.com", "kodansha.com",
        "kodansha.co.jp", "comic-days.com", "shonenmagazine.com", "yanmaga.jp",
        "magcomi.com", "mangacross.jp", "kuragebunch.com", "kurage-bunch.com",
        "comicbunch.com", "younganimal.com", "youngchampion.jp", "comic-action.com",
        "futabanet.jp", "pixiv.net", "comic-walker.com", "manga-up.com",
        "ganganonline.com", "nicovideo.jp", "sunday-webry.com", "websunday.net",
        "urasunday.com", "bigcomics.jp", "manga-one.com", "manga-mee.jp",
        "hanayume.com", "hanaoto.net", "comic-fuz.com", "comic-growl.com",
        "comic-y-ours.com", "comic-alive.jp", "dengeki.com", "ichijin-plus.com",
        "ichicomi.com", "takecomic.jp", "feelweb.jp", "ganma.jp", "mechacomic.jp",
        "gcnovels.jp", "mwbunko.com", "sai-zen-sen.jp", "tonarinoyj.jp", "ynjn.jp",
        "flowercomics.jp", "championcross.jp", "lala.ne.jp", "rimacomiplus.jp",
        "comicbox.co.jp", "komogi.com", "bs-garden.com", "moae.jp", "bookwalker.jp",
        "booklive.jp", "ebookjapan.yahoo.co.jp", "ebookrenta.com", "k-manga.jp",
        "line.me"
    ]

    private static let chinesePlatforms: Set<String> = [
        "bilibili.com", "kuaikanmanhua.com", "ac.qq.com", "iqiyi.com",
        "ching-win.com.tw"
    ]
}
