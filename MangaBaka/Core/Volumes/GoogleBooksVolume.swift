import Foundation

/// One volume of a series, as Google Books' catalogue describes it.
///
/// Google is data only here, not a second storefront — Apple Books is the
/// destination for these iOS readers (Abdi, 2026-09-11). This type exists to
/// fill the gap Apple leaves: a series Apple does not sell gets no cover at
/// all today, and Google's catalogue is broad enough to have art for most of
/// them.
struct GoogleBooksVolume: Codable, Identifiable, Sendable, Equatable {
    let id: String
    let number: Int
    let title: String
    /// "en", "ko" — from `volumeInfo.language`, so these flow through the same
    /// `Series.coverLanguages` narrowing as MangaBaka's own covers.
    let language: String?
    let thumbnailURL: URL?
    /// Where this exact result lives on Google Books. Required on screen by
    /// Google's branding terms (see `GoogleVolumesRow`) — every volume shown
    /// must open its own link, `canonicalVolumeLink` preferred over `infoLink`
    /// because it is the stabler of the two in Google's own docs.
    let pageURL: URL?

    var cover: Cover {
        Cover(raw: thumbnailURL, x150: nil, x250: nil, x350: nil, blurhash: nil, width: nil, height: nil)
    }

    /// This volume as a gallery entry, alongside Apple's and MangaBaka's own.
    /// Nil when Google sent no usable art — a volume with no artwork must be
    /// dropped, not rendered as a grey rectangle (measured live, 2026-09-12:
    /// "Solo Leveling, Vol. 1 (comic)" from Ize Press had no `imageLinks` at
    /// all).
    var galleryImage: SeriesImage? {
        guard thumbnailURL != nil else { return nil }
        return SeriesImage(
            imageID: nil,
            seriesId: nil,
            type: "volume",
            index: String(number),
            indexNumeric: Double(number),
            language: language,
            contentRating: nil,
            image: cover
        )
    }
}

/// One row of the Google Books API's answer, as it arrives.
struct GoogleBooksItem: Decodable, Sendable, Equatable {
    let id: String
    let volumeInfo: VolumeInfo

    struct VolumeInfo: Decodable, Sendable, Equatable {
        let title: String
        let language: String?
        let infoLink: URL?
        let canonicalVolumeLink: URL?
        let imageLinks: ImageLinks?

        struct ImageLinks: Decodable, Sendable, Equatable {
            let thumbnail: URL?
            let smallThumbnail: URL?
        }
    }
}

/// Which results are volumes of *this* series, and nothing else.
///
/// Mirrors `AppleBooksMatch` deliberately rather than writing a second,
/// looser matcher: Google's results mix editions and spin-offs the same way
/// Apple's do — "(comic)" and "(novel)" interleaved, "Solo Leveling:
/// Ragnarok" beside "Solo Leveling" (verified live, 2026-09-12, q=intitle:
/// "solo leveling", 300 totalItems). A wrong cover under "Volume 3" is worse
/// than an empty spine here too.
enum GoogleBooksMatch {
    /// One volume per number — the first result for it — sorted by number.
    static func volumes(
        in items: [GoogleBooksItem], titles: [String], isNovel: Bool
    ) -> [GoogleBooksVolume] {
        let wanted = Set(titles.map(AppleBooksMatch.normalise).filter { !$0.isEmpty })
        guard !wanted.isEmpty else { return [] }
        var byNumber: [Int: GoogleBooksVolume] = [:]
        for item in items {
            guard let parts = AppleBooksMatch.split(item.volumeInfo.title),
                  wanted.contains(AppleBooksMatch.normalise(parts.title))
            else { continue }
            if let tag = parts.tag, tag.contains("novel") != isNovel { continue }
            guard byNumber[parts.number] == nil else { continue }
            byNumber[parts.number] = GoogleBooksVolume(
                id: item.id,
                number: parts.number,
                title: item.volumeInfo.title,
                language: item.volumeInfo.language,
                thumbnailURL: largeThumbnail(item.volumeInfo.imageLinks),
                pageURL: SafeLink.web(item.volumeInfo.canonicalVolumeLink ?? item.volumeInfo.infoLink)
            )
        }
        return byNumber.values.sorted { $0.number < $1.number }
    }

    /// Google's `thumbnail` is 128x184 and `http://`, not `https://` — ATS
    /// blocks the plain scheme outright, and 128px is unusable in a
    /// full-screen gallery next to Apple's 600px art. `fife=w800` is an
    /// undocumented Google image-serving parameter; measured against a live
    /// thumbnail URL on 2026-09-12:
    ///   unmodified:  13,617 bytes,  128x184
    ///   `&zoom=0`:  742,168 bytes, 2812x4036 (too big to page through)
    ///   `&zoom=3`:   70,870 bytes,  575x825
    ///   `&fife=w800`: 125,714 bytes, 800x1148  ← used here
    /// Undocumented and could stop working; falls back to the plain
    /// `thumbnail` (still rewritten to https) if there is no `imageLinks` at
    /// all to upgrade.
    static func largeThumbnail(_ links: GoogleBooksItem.VolumeInfo.ImageLinks?) -> URL? {
        guard let raw = links?.thumbnail ?? links?.smallThumbnail else { return nil }
        guard let https = toHTTPS(raw) else { return nil }
        guard var components = URLComponents(url: https, resolvingAgainstBaseURL: false) else { return https }
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "fife", value: "w800"))
        components.queryItems = items
        return components.url ?? https
    }

    /// `http://books.google.com/...` → `https://books.google.com/...`. ATS
    /// refuses the plain-http form outright; the host serves https fine
    /// (verified 2026-09-12).
    static func toHTTPS(_ url: URL) -> URL? {
        guard url.scheme?.lowercased() == "http" else { return url }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = "https"
        return components.url
    }
}
