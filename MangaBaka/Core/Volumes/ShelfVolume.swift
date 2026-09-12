import Foundation

/// One volume on the series page's shelf, whichever store it came from.
///
/// Apple and Google describe a volume differently — Apple has a price and a
/// store link, Google has neither — so the row renders this rather than either
/// store's own type.
struct ShelfVolume: Identifiable, Sendable, Equatable {
    enum Source: Sendable, Equatable {
        case appleBooks
        case googleBooks
    }

    let number: Int
    let cover: Cover
    /// Apple's store page, or Google's volume page. Google's branding terms
    /// require every result of theirs on screen to open its own link, so for
    /// a `.googleBooks` volume this is not decoration — see `VolumeShelf`.
    let link: URL?
    /// Apple only. Google is a data source here, not a shop.
    let formattedPrice: String?
    let source: Source

    var id: String { "\(source)-\(number)" }
}

/// Builds one shelf out of both stores.
enum VolumeShelf {
    /// Apple's volumes, plus any volume *number* Apple does not have and
    /// Google does.
    ///
    /// Abdi's rule (2026-09-12): "if apple has the first 13 volumes of solo
    /// leveling but google had all 15, then we would show apples first 13 and
    /// add googles last 2 at the end." So this is a merge by volume number
    /// where Apple always wins a collision — never two spines for volume 13,
    /// and never Google's 128px thumbnail in place of Apple's 600px art.
    ///
    /// Google is only ever additive. A series Apple carries completely comes
    /// out of here byte-for-byte as it went in.
    static func merge(apple: [AppleBooksVolume], google: [GoogleBooksVolume]) -> [ShelfVolume] {
        var byNumber: [Int: ShelfVolume] = [:]
        for volume in google where volume.thumbnailURL != nil {
            byNumber[volume.number] = ShelfVolume(
                number: volume.number,
                cover: volume.cover,
                link: volume.pageURL,
                formattedPrice: nil,
                source: .googleBooks
            )
        }
        // Second, so Apple overwrites Google on any number they share.
        for volume in apple {
            byNumber[volume.number] = ShelfVolume(
                number: volume.number,
                cover: volume.cover,
                link: volume.storeURL,
                formattedPrice: volume.formattedPrice,
                source: .appleBooks
            )
        }
        return byNumber.values.sorted { $0.number < $1.number }
    }

    /// Names whichever stores actually put a volume on the shelf.
    ///
    /// Naming Google is not a courtesy: their branding terms require their
    /// content to be attributed wherever it is shown. Naming Apple alone
    /// while showing two of Google's covers would be the non-compliant case.
    static func attribution(for volumes: [ShelfVolume]) -> String? {
        let sources = Set(volumes.map(\.source))
        return switch (sources.contains(.appleBooks), sources.contains(.googleBooks)) {
        case (true, true): "Apple & Google Books"
        case (true, false): "Apple Books"
        case (false, true): "Google Books"
        case (false, false): nil
        }
    }

    /// Whether Google's volumes need fetching at all.
    ///
    /// Gap-filling only: if Apple already has every volume up to the series'
    /// last, there is nothing for Google to add, and asking anyway spends a
    /// keyed quota for a result that would be discarded. `expected` is
    /// MangaBaka's `final_volume`, which is nil for a series still running —
    /// and a running series can always gain one, so nil means "ask".
    static func needsGoogle(apple: [AppleBooksVolume], expected: Int?) -> Bool {
        guard let expected, expected > 0 else { return true }
        let have = Set(apple.map(\.number))
        return !(1...expected).allSatisfy(have.contains)
    }
}
