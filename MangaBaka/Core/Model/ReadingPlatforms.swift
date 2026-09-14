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
/// **Audited entry by entry against 5.2.3 on 2026-09-14**, once the app was
/// confirmed to be going to the App Store, taking the strict reading: an
/// official publisher or licensed platform stays, an aggregator goes. The
/// result is a negative one and worth recording so nobody re-runs it: **no
/// aggregator was found.** Fourteen of the entries nobody here could name on
/// sight were checked with one live request each and turned out to be
/// official — `manga-park.com` is Hakusensha's マンガPark and not MangaPark
/// the scanlation site, `junemanga.com` is Digital Manga's Juné imprint
/// store, `jumptoon.com` is Shueisha's, `bs-garden.com` and `hanaoto.net` are
/// publishers' own magazine sites, and `qtoon.co.kr`, `mootoon.co.kr`,
/// `anytoon.co.kr`, `peanutoon.com`, `lalatoon.com`, `komogi.com`,
/// `wecomics.in.th` and `webcomicsapp.com` are commercial platforms. The rest
/// were taken on recognition, which is not a licence check — say so rather
/// than calling this list cleared.
///
/// One removal: `ono.live`, at the line below where it used to sit.
///
/// One residual, left alone deliberately: `seiga.nicovideo.jp` is a reader
/// subdomain *and* a user-upload surface — the official and the user-drawn
/// works share `/watch/mg…`, so there is no path split that keeps the first
/// and drops the second. Removing it would break real official Nico manga
/// links; scoping it would be a guess dressed as a rule. Recorded as
/// unresolved rather than fixed wrongly. (Note this is the creator's own
/// upload, not a reupload, so it is a weaker case than the portal roots
/// finding 74 named.)
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
        guard let url, let host = url.host()?.lowercased(), !host.isEmpty else { return false }
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        guard allowed.contains(where: { bare == $0 || bare.hasSuffix("." + $0) }) else { return false }
        // A bare host root ("https://webtoons.com/") is not an offer to read
        // a series — it is the platform's front door. A genuine reading link
        // always names at least one path segment.
        let segments = url.path.split(separator: "/", omittingEmptySubsequences: true)
        guard let firstSegment = segments.first else { return false }
        // Most entries above are reading-only hosts, so any non-empty path is
        // fine. `scopedPathPrefixes` covers the rare host — Crunchyroll — that
        // is a reading surface at one path and something far bigger everywhere
        // else on the same registrable domain, so a host match alone would
        // fail open exactly the way finding 74 (wire review, 2026-09-14)
        // describes.
        let scoped = scopedPathPrefixes.first { bare == $0.key || bare.hasSuffix("." + $0.key) }
        if let scoped {
            return firstSegment == scoped.value
        }
        return true
    }

    /// Hosts allowed above whose comics surface is one path on an otherwise
    /// much larger site, keyed by registrable domain (or reader subdomain) to
    /// the required first path segment.
    private static let scopedPathPrefixes: [String: String] = [
        // Crunchyroll Manga shut down its own app in December 2023 and
        // relaunched, browser included, on 2025-10-15 at `crunchyroll.com/manga`
        // rather than a subdomain of its own (Wikipedia, "Crunchyroll Manga",
        // retrieved 2026-09-14; the file could not be re-sampled against a live
        // link, so this is the launch announcement, not a captured `webplatform`
        // value). `crunchyroll.com` is otherwise crunchyroll's video-streaming
        // site — the thing `allows`'s plain host+path check would otherwise wave
        // an episode page through as "Read it" for. A guess pending a captured
        // sample; if a real `webplatform | crunchyroll.com` link turns up with a
        // different path, this needs updating, not the rejection of the entry.
        "crunchyroll.com": "manga"
    ]

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
        // `ono.live` was removed 2026-09-14 in the 5.2.3 audit. It is the one
        // entry in this list I could not identify: a live request answers 202
        // with an empty body and no title, there is no recognisable publisher
        // or platform behind the name, and nothing in the 2026-09-12 sample
        // records what it served. The allowlist's whole value is that it
        // fails closed, so an entry nobody can defend is the one kind that
        // must not stay. If a real `webplatform | ono.live` link turns up
        // with evidence of who runs it, add it back with that evidence.
        "mangetsu-manga.fr", "webnovel.com", "webcomicsapp.com",
        "mangatoon.mobi", "junemanga.com", "manga-park.com", "azuki.co",
        // Kakao's licensed Japanese platform — 3397's only Japanese reading
        // link (`webplatform | ja | piccoma.com`) was hidden outright before
        // this; measured against `/v1/series/3397/full`, 2026-09-13.
        "piccoma.com",
        // Lezhin runs a separate registrable domain per territory rather than
        // subdomains, so each is its own entry.
        "lezhin.com", "lezhinus.com", "lezhin.es", "lezhin.jp", "lezhinfr.com",
        "lezhinth.com", "lezhinde.com"
    ]

    /// `naver.com`, `daum.net` and `kakao.com` are portal roots, not reading
    /// platforms — a suffix match on the bare domain would also admit
    /// `blog.naver.com` and `cafe.daum.net`, a contributor's own aggregator
    /// page under the licensed host's name. Only the specific reader
    /// subdomains are listed; `kakaowebtoon.com` is a separate registrable
    /// domain and keeps its own broad entry below.
    private static let koreanPlatforms: Set<String> = [
        "comic.naver.com", "webtoon.kakao.com", "page.kakao.com", "webtoon.daum.net",
        "kakaowebtoon.com", "comico.jp",
        "comico.kr", "bomtoon.com", "bomtoon.tw", "ridibooks.com", "munpia.com",
        "toomics.com", "toptoon.com", "lalatoon.com", "peanutoon.com", "qtoon.co.kr",
        "anytoon.co.kr", "onestory.co.kr", "mootoon.co.kr", "beltoon.jp",
        "beltoon.com", "jumptoon.com", "wecomics.in.th"
    ]

    /// Japanese publishers and their magazine sites. One entry per publisher
    /// wherever the magazines are subdomains; per-site where they are not.
    ///
    /// `pixiv.net` and `nicovideo.jp` are portal roots the same way the
    /// Korean ones are — `*.pixiv.net` covers a contributor's personal
    /// gallery, not just the licensed reader — so only the specific reader
    /// subdomain is listed for each. `line.me` is the same shape: LINE is a
    /// messaging and payments platform with `store.line.me`, `shop.line.me`
    /// and more far outside comics, so only its manga reader subdomain is
    /// listed (wire review finding 74, 2026-09-14; `manga.line.me` responds —
    /// checked live with `curl -sI`, a 412 from what looks like bot
    /// protection, which confirms the host exists and answers, not what it
    /// serves — no sample link was re-captured to confirm the path shape).
    private static let japanesePublishers: Set<String> = [
        "shueisha.co.jp", "shonenjumpplus.com", "shonenjump.com", "kodansha.com",
        "kodansha.co.jp", "comic-days.com", "shonenmagazine.com", "yanmaga.jp",
        "magcomi.com", "mangacross.jp", "kuragebunch.com", "kurage-bunch.com",
        "comicbunch.com", "younganimal.com", "youngchampion.jp", "comic-action.com",
        "futabanet.jp", "comic.pixiv.net", "comic-walker.com", "manga-up.com",
        "ganganonline.com", "seiga.nicovideo.jp", "sunday-webry.com", "websunday.net",
        "urasunday.com", "bigcomics.jp", "manga-one.com", "manga-mee.jp",
        "hanayume.com", "hanaoto.net", "comic-fuz.com", "comic-growl.com",
        "comic-y-ours.com", "comic-alive.jp", "dengeki.com", "ichijin-plus.com",
        "ichicomi.com", "takecomic.jp", "feelweb.jp", "ganma.jp", "mechacomic.jp",
        "gcnovels.jp", "mwbunko.com", "sai-zen-sen.jp", "tonarinoyj.jp", "ynjn.jp",
        "flowercomics.jp", "championcross.jp", "lala.ne.jp", "rimacomiplus.jp",
        "comicbox.co.jp", "komogi.com", "bs-garden.com", "moae.jp", "bookwalker.jp",
        "booklive.jp", "ebookjapan.yahoo.co.jp", "ebookrenta.com", "k-manga.jp",
        "manga.line.me"
    ]

    /// `bilibili.com` is a portal root too — `space.bilibili.com` is any
    /// user's profile page, not the licensed comics reader.
    ///
    /// iQIYI's comics are not a subdomain of `iqiyi.com` at all — they live on
    /// a separate registrable domain, `comic.iq.com` (`iq.com` is iQIYI's
    /// international streaming site, the same portal problem `iqiyi.com`
    /// itself would be; searched 2026-09-14, no live sample re-captured).
    /// `iqiyi.com` admitted any subdomain and any path on the streaming site
    /// itself — wire review finding 74. `comic.iq.com` answered a plain
    /// request with a 404, which confirms the host exists and requires a real
    /// path, consistent with (but not proof of) a comics reader.
    private static let chinesePlatforms: Set<String> = [
        "manga.bilibili.com", "kuaikanmanhua.com", "ac.qq.com", "comic.iq.com",
        "ching-win.com.tw"
    ]
}
