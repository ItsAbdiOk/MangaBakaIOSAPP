import Foundation

/// A series' page on mangabaka.org, both ways: the link the share sheet
/// sends, and the id inside a link the app is handed.
///
/// The API returns `canonical_url` ("https://mangabaka.org/manhwa/3397/
/// Solo-Leveling") but the spec does not document it and `Series` does not
/// carry it, so the link is built from what the app holds. The site redirects
/// `/<type>/<id>` and a bare `/<id>` to the canonical page with a 301 —
/// measured 2026-09-11 on 3397 — so either form lands on the right page; the
/// typed one is used when the type is known because it reads as the real
/// address rather than a shortcut.
///
/// Opening such a link in the app needs the association file on
/// mangabaka.org (`/.well-known/apple-app-site-association`, a 404 on
/// 2026-09-11) and the Associated Domains entitlement. Neither is in place;
/// `seriesID(from:)` and the `onOpenURL` handler are ready for when they are.
enum SeriesWebLink {
    static let host = "mangabaka.org"

    static func url(for series: Series) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        if let type = series.type, !type.isEmpty {
            components.path = "/\(type.lowercased())/\(series.id)"
        } else {
            components.path = "/\(series.id)"
        }
        return components.url
    }

    /// The series id in a mangabaka.org link, or nil for anything else.
    ///
    /// The first numeric path component: `/manhwa/3397/Solo-Leveling`,
    /// `/manhwa/3397`, `/3397`. Other hosts and other pages (`/settings/api`,
    /// `/pages/24` — no, that is a page id, not a series) are nil; the
    /// `pages` prefix is excluded by name because it is the one path the site
    /// uses a bare number under that is not a series.
    static func seriesID(from url: URL) -> Int? {
        guard url.host()?.lowercased() == host || url.host()?.lowercased() == "www.\(host)"
        else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.first != "pages" else { return nil }
        return parts.lazy.compactMap { Int($0) }.first
    }
}
