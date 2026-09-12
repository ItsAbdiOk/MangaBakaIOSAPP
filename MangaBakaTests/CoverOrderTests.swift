import Foundation
import Testing
@testable import MangaBaka

/// The order of the covers behind the front one.
///
/// Asked for by Abdi on 2026-09-12: the cover on the page, then every volume
/// Apple Books sells, then the rest of MangaBaka's own collection. Apple leads
/// because it is the fuller source — 115 ONE PIECE volumes in the store against
/// 4 English covers on MangaBaka's `/images`.
@Suite("Cover order")
struct CoverOrderTests {
    private func volume(_ number: Int, artwork: String? = "https://example.com/a.jpg") -> AppleBooksVolume {
        AppleBooksVolume(
            id: number,
            number: number,
            title: "Vol. \(number)",
            artworkURL: artwork.flatMap(URL.init(string:)),
            storeURL: nil,
            price: nil,
            formattedPrice: nil,
            releaseDate: nil
        )
    }

    @Test("A volume with artwork becomes a gallery entry captioned by number")
    func galleryImage() throws {
        let image = try #require(volume(3).galleryImage)
        #expect(image.type == "volume")
        #expect(image.indexNumeric == 3)
        #expect(image.caption == "Vol. 3")
        #expect(image.image.raw?.absoluteString == "https://example.com/a.jpg")
    }

    /// A grey rectangle in the gallery is worse than one fewer page.
    @Test("A volume the store sent without artwork is not a gallery entry")
    func artworklessVolumeIsDropped() {
        #expect(volume(1, artwork: nil).galleryImage == nil)
    }

    private func mangaBakaCover(_ id: Int, language: String? = "en") -> SeriesImage {
        let languageText = language.map { "\"\($0)\"" } ?? "null"
        let json = """
        {"id": \(id), "series_id": 1, "type": "volume", "index": "\(id)",
         "index_numeric": \(id), "language": \(languageText), "content_rating": "safe",
         "image": {"raw": "https://mangabaka.example/\(id).jpg"}}
        """
        guard let decoded = try? Fixture.decoder().decode(SeriesImage.self, from: Data(json.utf8))
        else { fatalError("SeriesImage fixture no longer decodes: \(json)") }
        return decoded
    }

    /// The whole point: Apple's run sits between the front cover and the rest.
    @Test("Apple's volumes come first, then MangaBaka's, minus the front cover")
    func appleLeadsAndFrontIsDropped() {
        let mine = [mangaBakaCover(10), mangaBakaCover(11), mangaBakaCover(12)]
        let ordered = SeriesDetailView.gallery(
            mangaBaka: mine, apple: [volume(3), volume(1), volume(2)], google: [],
            front: mine[1], languages: nil
        )
        #expect(ordered.map(\.indexNumeric) == [1, 2, 3, 10, 12])
        #expect(ordered.prefix(3).allSatisfy { $0.image.raw?.host() == "example.com" })
    }

    /// The control: with no store answer the order is exactly what it was
    /// before this change, so a series Apple does not sell is untouched.
    @Test("No Apple volumes leaves MangaBaka's own order alone")
    func noStoreIsUnchanged() {
        let mine = [mangaBakaCover(10), mangaBakaCover(11)]
        let ordered = SeriesDetailView.gallery(
            mangaBaka: mine, apple: [], google: [], front: mine[0], languages: nil
        )
        #expect(ordered.map(\.indexNumeric) == [11])
    }

    @Test("Volumes are ordered by number, however the store sent them")
    func appleCoversAreOrdered() {
        let ordered = SeriesDetailView.gallery(
            mangaBaka: [], apple: [volume(3), volume(1), volume(2)], google: [], front: nil, languages: nil
        )
        #expect(ordered.map(\.indexNumeric) == [1, 2, 3])
    }

    /// A manhwa's fan should be English and Korean and nothing else — the page
    /// was leading with Portuguese and Indonesian editions.
    @Test("Only English and the series' own language survive")
    func foreignEditionsAreDropped() {
        let mine = [
            mangaBakaCover(1, language: "en"),
            mangaBakaCover(2, language: "ko"),
            mangaBakaCover(3, language: "pt-br"),
            mangaBakaCover(4, language: "id"),
            mangaBakaCover(5, language: "es")
        ]
        let ordered = SeriesDetailView.gallery(
            mangaBaka: mine, apple: [], google: [], front: nil, languages: ["en", "ko"]
        )
        #expect(ordered.map(\.indexNumeric) == [1, 2])
    }

    /// Regional tags are the normal spelling on the wire, so an exact match
    /// would throw away the very editions being kept.
    @Test("A regional tag still counts as its language")
    func regionalTagsMatch() {
        let mine = [mangaBakaCover(1, language: "zh-hans"), mangaBakaCover(2, language: "en-GB")]
        let ordered = SeriesDetailView.gallery(
            mangaBaka: mine, apple: [], google: [], front: nil, languages: ["en", "zh"]
        )
        #expect(ordered.map(\.indexNumeric) == [1, 2])
    }

    /// A null language is a missing field far more often than a foreign
    /// edition, and hiding real artwork over it is the worse mistake.
    @Test("A cover with no language is kept, and so is Apple's")
    func unlabelledCoversSurvive() {
        let ordered = SeriesDetailView.gallery(
            mangaBaka: [mangaBakaCover(9, language: nil)],
            apple: [volume(1)], google: [],
            front: nil,
            languages: ["en", "ja"]
        )
        #expect(ordered.map(\.indexNumeric) == [1, 9])
    }

    /// The control: no language rule leaves every cover exactly as it was.
    @Test("No language rule keeps everything")
    func noRuleKeepsEverything() {
        let mine = [mangaBakaCover(1, language: "pt-br"), mangaBakaCover(2, language: "id")]
        let ordered = SeriesDetailView.gallery(
            mangaBaka: mine, apple: [], google: [], front: nil, languages: nil
        )
        #expect(ordered.map(\.indexNumeric) == [1, 2])
    }
}

/// Which cover languages a series allows. See `Series.coverLanguages`.
@Suite("Cover languages by series type")
struct CoverLanguageTests {
    private func series(type: String?, nativeLanguage: String? = nil) -> Series {
        var titles: [SeriesTitle] = []
        if let nativeLanguage {
            titles = [
                SeriesTitle(
                    language: nativeLanguage, traits: ["native"], title: "native", isPrimary: true
                )
            ]
        }
        return SeriesFactory.make(id: 1, titles: titles, type: type)
    }

    @Test("Each type implies the language a reader would expect")
    func typesImplyLanguages() {
        #expect(series(type: "manga").coverLanguages == ["en", "ja"])
        #expect(series(type: "manhwa").coverLanguages == ["en", "ko"])
        #expect(series(type: "manhua").coverLanguages == ["en", "zh"])
    }

    /// Novels are exempt at Abdi's ask, and a type that implies no language
    /// must not silently narrow to English alone.
    @Test("Novels and untypeable series are not narrowed")
    func exemptTypes() {
        #expect(series(type: "novel").coverLanguages == nil)
        #expect(series(type: "novel", nativeLanguage: "ja").coverLanguages == nil)
        #expect(series(type: "other").coverLanguages == nil)
        #expect(series(type: nil).coverLanguages == nil)
    }

    /// The series' own data beats the guess from its type: a series is only
    /// typed once, and the native title is the thing that actually says.
    @Test("A native title wins over the type's implication")
    func nativeTitleWins() {
        #expect(series(type: "manga", nativeLanguage: "ko").coverLanguages == ["en", "ko"])
    }
}

/// Apple's volumes plus the numbers only Google has. See `VolumeShelf`.
@Suite("Merging two stores onto one shelf")
struct VolumeShelfTests {
    private func apple(_ number: Int) -> AppleBooksVolume {
        AppleBooksVolume(
            id: number, number: number, title: "Vol. \(number)",
            artworkURL: URL(string: "https://apple.example/\(number).jpg"),
            storeURL: URL(string: "https://books.apple.com/\(number)"),
            price: 6.99, formattedPrice: "£6.99", releaseDate: nil
        )
    }

    private func google(_ number: Int, art: Bool = true) -> GoogleBooksVolume {
        GoogleBooksVolume(
            id: "g\(number)", number: number, title: "Vol. \(number)", language: "en",
            thumbnailURL: art ? URL(string: "https://books.google.example/\(number).jpg") : nil,
            pageURL: URL(string: "https://books.google.com/about/\(number)")
        )
    }

    /// Abdi's own example: Apple has 1–13, Google has 1–15, so the shelf is
    /// Apple's 13 with Google's 14 and 15 added at the end.
    @Test("Apple's volumes lead and Google only fills the numbers Apple lacks")
    func googleFillsGapsOnly() {
        let shelf = VolumeShelf.merge(
            apple: (1...13).map(apple), google: (1...15).map { google($0) }
        )
        #expect(shelf.map(\.number) == Array(1...15))
        #expect(shelf.filter { $0.source == .googleBooks }.map(\.number) == [14, 15])
        // The overlap stays Apple's: its art is 600px against Google's upscale,
        // and only Apple's spine carries a price.
        #expect(shelf.prefix(13).allSatisfy { $0.source == .appleBooks })
        #expect(shelf[0].formattedPrice == "£6.99")
        #expect(shelf[13].formattedPrice == nil)
    }

    /// The control: a series Apple carries completely comes out untouched.
    @Test("Google adds nothing when Apple already has every volume")
    func noGapsMeansNoGoogle() {
        let shelf = VolumeShelf.merge(apple: (1...5).map(apple), google: (1...5).map { google($0) })
        #expect(shelf.allSatisfy { $0.source == .appleBooks })
        #expect(VolumeShelf.needsGoogle(apple: (1...5).map(apple), expected: 5) == false)
    }

    /// A running series has no final volume, so there is always possibly more.
    @Test("A gap, or an unknown total, is what makes Google worth asking")
    func needsGoogleRule() {
        #expect(VolumeShelf.needsGoogle(apple: (1...3).map(apple), expected: 5))
        #expect(VolumeShelf.needsGoogle(apple: [apple(1), apple(3)], expected: 3))
        #expect(VolumeShelf.needsGoogle(apple: (1...3).map(apple), expected: nil))
        #expect(VolumeShelf.needsGoogle(apple: [], expected: 5))
    }

    @Test("A Google volume with no artwork never reaches the shelf")
    func artworklessGoogleIsDropped() {
        let shelf = VolumeShelf.merge(apple: [apple(1)], google: [google(2, art: false), google(3)])
        #expect(shelf.map(\.number) == [1, 3])
    }

    /// The header has to name Google wherever Google's covers are shown —
    /// their branding terms require the attribution, not just the link.
    @Test("The header names whichever stores actually contributed")
    func attributionNamesBoth() {
        let both = VolumeShelf.merge(apple: [apple(1)], google: [google(2)])
        #expect(VolumeShelf.attribution(for: both) == "Apple & Google Books")
        #expect(VolumeShelf.attribution(for: VolumeShelf.merge(apple: [apple(1)], google: []))
                == "Apple Books")
        #expect(VolumeShelf.attribution(for: VolumeShelf.merge(apple: [], google: [google(1)]))
                == "Google Books")
        #expect(VolumeShelf.attribution(for: []) == nil)
    }
}
