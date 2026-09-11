import Foundation

/// The cover a reading platform shows for a series, from its own page.
///
/// Abdi, 2026-09-11: wanted, after the terms discussion, for series MangaBaka
/// has one cover for — "data straight from the source". Built to the
/// smallest shape that does that: one GET of the series page Webtoons or
/// Tapas already links, the `og:image` tag that page publishes for sharing,
/// nothing else read. No episode pages, no headers pretending to be a
/// browser — checked 2026-09-11: both CDNs serve the image to a plain
/// request, so nothing is circumvented. `isEnabled` is the switch if a
/// platform objects.
///
/// Webtoons' image is a 540×540 poster crop, not a portrait cover; Tapas'
/// is the cover. Either is shown as one more image in the fan and gallery,
/// and only when it differs from what MangaBaka already has.
actor PlatformCoverClient {
    static let isEnabled = true

    /// Hosts whose series pages are read. A link to any other platform is
    /// left alone.
    static let platforms: [String: String] = [
        "www.webtoons.com": "Webtoons",
        "webtoons.com": "Webtoons",
        "tapas.io": "Tapas"
    ]

    /// Pages are 45–185 KB; anything past this is not a series page.
    static let byteCap = 512 * 1024

    private let session: URLSession
    private var known: [URL: URL?] = [:]

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// The first platform link's cover, or nil.
    func cover(from links: [SeriesLink]) async -> URL? {
        guard Self.isEnabled,
              let page = links.lazy.compactMap(\.safeURL)
                  .first(where: { Self.platforms[$0.host()?.lowercased() ?? ""] != nil })
        else { return nil }
        if let cached = known[page] { return cached }
        let found = await fetch(page)
        known[page] = found
        return found
    }

    private func fetch(_ page: URL) async -> URL? {
        var request = URLRequest(url: page)
        request.setValue(MangaUpdatesClient.userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true,
              data.count <= Self.byteCap,
              let html = String(data: data, encoding: .utf8)
        else { return nil }
        return Self.ogImage(in: html)
    }

    /// The `og:image` content, whichever order the attributes come in.
    nonisolated static func ogImage(in html: String) -> URL? {
        let propertyFirst = /<meta[^>]*property=["']og:image["'][^>]*content=["']([^"']+)["']/
        let contentFirst = /<meta[^>]*content=["']([^"']+)["'][^>]*property=["']og:image["']/
        let found = html.firstMatch(of: propertyFirst)?.output.1
            ?? html.firstMatch(of: contentFirst)?.output.1
        guard let found else { return nil }
        let raw = String(found).replacingOccurrences(of: "&amp;", with: "&")
        return SafeLink.web(URL(string: raw))
    }
}
