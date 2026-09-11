import Foundation

/// One volume of a series as sold on Apple Books: the cover, the price, and
/// the link to buy it.
///
/// Apple Books is the destination because these are iOS readers (Abdi,
/// 2026-09-11); Google Books is data only. The iTunes Search API is public,
/// keyless, and answers with one result per volume sold, 600px art, and a
/// store link — which for the series it carries is the whole of roadmap
/// item 4 in one request. MangaBaka's own `/images` is too sparse to lead
/// with: ONE PIECE has 4 English volume covers there, of 115.
struct AppleBooksVolume: Codable, Identifiable, Sendable, Equatable {
    /// Apple's track id.
    let id: Int
    let number: Int
    let title: String
    let artworkURL: URL?
    let storeURL: URL?
    let price: Double?
    /// "£6.99", in the store's own formatting.
    let formattedPrice: String?
    let releaseDate: Date?

    var cover: Cover {
        Cover(raw: artworkURL, x150: nil, x250: nil, x350: nil, blurhash: nil, width: nil, height: nil)
    }
}

/// One row of the iTunes Search API's answer, as it arrives.
struct AppleBooksResult: Decodable, Sendable, Equatable {
    let trackId: Int
    let trackName: String
    let artworkUrl100: URL?
    let trackViewUrl: URL?
    let price: Double?
    let formattedPrice: String?
    let releaseDate: Date?
}

/// Which results are volumes of *this* series, and nothing else.
///
/// Strict on purpose: a wrong cover under "Volume 3" is worse than an empty
/// spine. The result's name must be the series' title — or one of its other
/// titles — followed directly by a volume marker: "Solo Leveling, Vol. 8
/// (comic)". "Solo Leveling: Ragnarok, Vol. 1" is a different series and is
/// rejected because ": Ragnarok" sits between the title and the marker. The
/// "(novel)" editions Yen Press sells beside the comic are rejected unless
/// the series is itself a novel. Verified against the live answer for
/// "solo leveling" in the GB store, 2026-09-11: 60 results, 15 comic volumes
/// plus novels and Ragnarok.
enum AppleBooksMatch {
    /// One volume per number — the first result for it, which the store
    /// ranks by relevance — sorted by number.
    static func volumes(
        in results: [AppleBooksResult],
        titles: [String],
        isNovel: Bool
    ) -> [AppleBooksVolume] {
        let wanted = Set(titles.map(normalise).filter { !$0.isEmpty })
        guard !wanted.isEmpty else { return [] }
        var byNumber: [Int: AppleBooksVolume] = [:]
        for result in results {
            guard let parts = split(result.trackName), wanted.contains(normalise(parts.title))
            else { continue }
            if let tag = parts.tag, tag.contains("novel") != isNovel { continue }
            guard byNumber[parts.number] == nil else { continue }
            byNumber[parts.number] = AppleBooksVolume(
                id: result.trackId,
                number: parts.number,
                title: result.trackName,
                artworkURL: result.artworkUrl100.flatMap(enlarge),
                storeURL: result.trackViewUrl.flatMap(SafeLink.web),
                price: result.price,
                formattedPrice: result.formattedPrice,
                releaseDate: result.releaseDate
            )
        }
        return byNumber.values.sorted { $0.number < $1.number }
    }

    struct Parts: Equatable {
        let title: String
        let number: Int
        /// Whatever sits in trailing brackets, lowercased: "comic", "novel".
        let tag: String?
    }

    /// "Solo Leveling, Vol. 8 (comic)" → ("Solo Leveling", 8, "comic").
    /// The marker may be "Vol.", "Vol", "Volume" or "#".
    static func split(_ name: String) -> Parts? {
        guard let match = name.wholeMatch(of: pattern) else { return nil }
        guard let number = Int(match.output.2) else { return nil }
        let tag = match.output.3.map { $0.lowercased() }
        return Parts(title: String(match.output.1), number: number, tag: tag)
    }

    // Built per call: a Regex is not Sendable, so it cannot be a static
    // constant. Cheap enough — the store answers at most 200 names.
    // swiftlint:disable:next large_tuple
    private static var pattern: Regex<(Substring, Substring, Substring, Substring?)> {
        /^(.+?)[,:]?\s+(?:vol\.?|volume|#)\s*(\d+)\s*(?:\(([^)]+)\))?\s*$/.ignoresCase()
    }

    /// Case, punctuation and spacing do not make two titles different.
    static func normalise(_ title: String) -> String {
        title.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// The API hands back 100×100 art; the same path serves 600×600.
    /// Undocumented but long-standing, and the 100px fallback still loads if
    /// it ever stops.
    static func enlarge(_ url: URL) -> URL? {
        URL(string: url.absoluteString.replacingOccurrences(of: "100x100bb", with: "600x600bb"))
    }
}
