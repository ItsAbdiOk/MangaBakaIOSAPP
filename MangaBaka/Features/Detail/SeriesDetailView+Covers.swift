import SwiftUI

/// The covers behind the front one, for the fan and the gallery. Its own
/// file for the lint's ceiling on `SeriesDetailView`.
extension SeriesDetailView {
    /// Everything behind the front cover, in the order Abdi asked for
    /// (2026-09-12): the cover on the page, then every volume Apple Books
    /// sells, then the rest of MangaBaka's collection.
    ///
    /// Apple leads because it is the fuller source — MangaBaka's `/images` has
    /// 4 English covers for ONE PIECE, of 115 volumes — so a reader swiping
    /// right off the front cover gets the official run of the book rather than
    /// whichever four alternates happened to be uploaded.
    ///
    /// Deliberately not deduplicated against MangaBaka's covers. The two
    /// sources are different scans of different editions at different sizes,
    /// with no shared id and no reliable way to tell a true duplicate from the
    /// English and Japanese printings of the same volume; dropping a cover
    /// because it looked like another one is the worse failure here.
    var otherCovers: [SeriesImage] {
        Self.gallery(
            mangaBaka: covers,
            apple: appleVolumes,
            google: googleVolumes,
            front: preferred,
            languages: shown.coverLanguages
        )
    }

    /// `front` is the cover already shown on the page, dropped so the fan never
    /// repeats it. Apple's volumes come in store order and are sorted by number
    /// here, because the search API ranks by relevance, not by volume.
    ///
    /// `languages` narrows MangaBaka's collection to English and the series'
    /// own — see `Series.coverLanguages`. Nil means no narrowing, which is how
    /// a novel and an untypeable series both arrive here.
    nonisolated static func gallery(
        mangaBaka: [SeriesImage],
        apple: [AppleBooksVolume],
        google: [GoogleBooksVolume],
        front: SeriesImage?,
        languages: Set<String>?
    ) -> [SeriesImage] {
        var rest = mangaBaka.filter { speaks($0.language, in: languages) }
        if let front { rest.removeAll { $0.id == front.id } }
        // Apple's own covers are exempt. They are the editions the reader can
        // actually buy in their own store, which is the reason they were put
        // at the front of this list in the first place, and the store sends no
        // language field to filter them by.
        // Apple's run, then any volume number only Google has, then the rest.
        // Same rule as the shelf below the fold (`VolumeShelf.merge`): Apple
        // wins every number they share, so the 800px store art is never
        // replaced by Google's upscaled thumbnail.
        let appleNumbers = Set(apple.map(\.number))
        let store = apple.sorted { $0.number < $1.number }.compactMap(\.galleryImage)
        let filled = google
            .filter { !appleNumbers.contains($0.number) }
            .sorted { $0.number < $1.number }
            .compactMap(\.galleryImage)
        return store + filled + rest
    }

    /// Prefix-matched, because the wire carries regional tags — "pt-br" is
    /// Portuguese and "zh-hans" is Chinese, and an exact match would keep
    /// neither. A cover whose language the API did not send is kept: an
    /// unlabelled cover is far more likely to be a missing field than a
    /// Spanish edition, and hiding real artwork over a null is the worse
    /// mistake.
    nonisolated private static func speaks(_ language: String?, in allowed: Set<String>?) -> Bool {
        guard let allowed else { return true }
        guard let language = language?.lowercased(), !language.isEmpty else { return true }
        return allowed.contains { language.hasPrefix($0) }
    }
}
