import Foundation

/// Which publisher a release date came from, and what to call them on screen.
///
/// Named for the same reason the volumes shelf names Apple and Google: a date
/// the reader can attribute is a date they can judge. It also explains the
/// asymmetry they will otherwise notice and mistrust — one series showing a
/// full weekly schedule and the next showing three bare rows is not the app
/// being inconsistent, it is two publishers exposing different amounts, and
/// the header is where that gets said.
///
/// Only platforms actually confirmed to serve release data appear here. A host
/// that has not been probed gets no entry and therefore no section, which is
/// the safe direction: an unnamed source is one the reader cannot weigh.
enum ReleaseSource: String, Equatable, Sendable, Codable, CaseIterable {
    case webtoons
    case naverWebtoon
    /// GigaViewer, the Hatena-built engine behind seven Japanese publisher
    /// sites. There is no per-series feed — see `GigaViewerFeedClient` — so
    /// this source is attributed by whichever host's magazine RSS answered,
    /// via `displayName(forHost:)` rather than one fixed name.
    case gigaViewer

    /// What the reader sees. The platform's own English name where it has one
    /// — a reader who follows the link lands on a page calling itself this.
    /// `.gigaViewer` has no single name — see `displayName(forHost:)`.
    var displayName: String {
        switch self {
        case .webtoons: "Webtoons"
        case .naverWebtoon: "Naver Webtoon"
        case .gigaViewer: "Shonen Jump+"
        }
    }

    /// The section header, e.g. "Releases · Webtoons".
    ///
    /// Mirrors `VolumeShelf.attribution`, which names its stores in the header
    /// rather than in a footnote, so the two sections on one page read the
    /// same way.
    var attribution: String { "Releases · \(displayName)" }

    /// The seven GigaViewer hosts confirmed to answer a magazine-wide RSS feed
    /// at `<host>/rss` (measured 2026-09-13). Each publisher's own name for
    /// itself, since "GigaViewer" is the engine, not a brand a reader knows.
    ///
    /// "Magazine Pocket" for shonenmagazine.com is **a guess** — the site's own
    /// branding was not confirmed as thoroughly as the other six.
    static let gigaViewerHostNames: [String: String] = [
        "tonarinoyj.jp": "Tonari no Young Jump",
        "shonenjumpplus.com": "Shonen Jump+",
        "comic-days.com": "Comic Days",
        "magcomi.com": "MAGCOMI",
        "shonenmagazine.com": "Magazine Pocket",
        "comic-gardo.com": "Comic Gardo",
        "comic-earthstar.com": "Comic Earth Star"
    ]

    /// Registrable domains this source serves, matched on a label boundary the
    /// way `ReadingPlatforms` does — one entry covers every subdomain.
    ///
    /// Measured 2026-09-12/13 against the live sites:
    /// - `webtoons.com` answers an RSS feed per series (20 entries, exact
    ///   timestamps).
    /// - `comic.naver.com` answers JSON at `/api/article/list?titleId=`, and
    ///   carries `totalCount` and `finished` that the English side does not.
    /// - The seven GigaViewer hosts each answer a magazine-wide RSS at
    ///   `/rss` — see `GigaViewerFeedClient`. Per-episode JSON was tried and
    ///   rejected: see docs/release-sources-2026-09-12.md, 2026-09-13 section.
    private var hosts: [String] {
        switch self {
        case .webtoons: ["webtoons.com"]
        case .naverWebtoon: ["comic.naver.com"]
        case .gigaViewer: Array(Self.gigaViewerHostNames.keys)
        }
    }

    /// The source serving a link, or nil when nothing here does.
    static func serving(_ url: URL?) -> ReleaseSource? {
        guard let host = url?.host()?.lowercased(), !host.isEmpty else { return nil }
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return allCases.first { source in
            source.hosts.contains { bare == $0 || bare.hasSuffix("." + $0) }
        }
    }
}
