import Foundation

/// One of a series' covers.
///
/// A series has one cover on its page and often many more behind it: Solo
/// Leveling carries 24, the volume covers of four different editions in four
/// languages. `/v1/series/{id}/images` returns them all, each one wrapping the
/// same `Cover` shape the rest of the app already decodes.
struct SeriesImage: Decodable, Identifiable, Sendable, Equatable {
    let id: Int
    let seriesId: Int?
    /// "volume", "other".
    let type: String?
    /// Volume number as text, because a half-volume arrives as "1.1".
    let index: String?
    let indexNumeric: Double?
    /// "en", "ko", "pt-br".
    let language: String?
    /// Per image, not per series. A series rated safe can carry a suggestive
    /// alternate cover, so the reader's content filter has to be applied here
    /// too — the filter failing on exactly the thing it exists to hide is the
    /// bug this app has already shipped once, on personalised recommendations.
    let contentRating: String?
    let image: Cover

    /// "Vol. 3 · EN", or nothing when the API said neither.
    var caption: String? {
        let parts = [
            index.map { "Vol. \($0)" },
            language?.uppercased()
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

extension [SeriesImage] {
    /// The cover to lead with: an English edition if there is one, otherwise
    /// the series' own language.
    ///
    /// MangaBaka's series cover is whichever it picked, which for a Korean
    /// manhwa is usually the Korean volume one — handsome, and unreadable to
    /// most of the people looking at this app. An English edition cover is the
    /// one a reader recognises from a shop or a store page.
    ///
    /// Volume one within a language, because a series' identity is its first
    /// cover; volume nineteen is a picture of a character nobody has met yet.
    /// "other" images lose to volume covers for the same reason — they are
    /// promotional art, not the book.
    func preferredCover(nativeLanguage: String?) -> SeriesImage? {
        let ranked = ["en", nativeLanguage].compactMap { $0 }
        for language in ranked {
            let matches = filter { $0.language?.hasPrefix(language) == true }
            if let best = matches.min(by: Self.byEditionOrder) { return best }
        }
        return nil
    }

    /// Volume covers before promotional art, then by volume number.
    private static func byEditionOrder(_ lhs: SeriesImage, _ rhs: SeriesImage) -> Bool {
        let leftIsVolume = lhs.type == "volume"
        let rightIsVolume = rhs.type == "volume"
        if leftIsVolume != rightIsVolume { return leftIsVolume }
        return (lhs.indexNumeric ?? .greatestFiniteMagnitude)
            < (rhs.indexNumeric ?? .greatestFiniteMagnitude)
    }

    /// Covers the reader has allowed, ordered as a person would expect them.
    ///
    /// Volume order first, then language, so flicking through goes 1, 2, 3
    /// rather than jumping between editions. The API's own order is by id,
    /// which is upload order and means nothing to a reader.
    /// - Parameter allowedRatings: nil means no filter is set, which is how the
    ///   repository spells "everything" — not "nothing".
    func presentable(allowedRatings: [String]?) -> [SeriesImage] {
        filter { image in
            guard let allowedRatings else { return true }
            guard let rating = image.contentRating else { return true }
            return allowedRatings.contains(rating)
        }
        .sorted { lhs, rhs in
            let left = lhs.indexNumeric ?? .greatestFiniteMagnitude
            let right = rhs.indexNumeric ?? .greatestFiniteMagnitude
            if left != right { return left < right }
            return (lhs.language ?? "") < (rhs.language ?? "")
        }
    }
}
