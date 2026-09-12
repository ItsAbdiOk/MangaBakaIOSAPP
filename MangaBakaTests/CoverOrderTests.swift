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
            mangaBaka: mine, apple: [volume(3), volume(1), volume(2)], front: mine[1], languages: nil
        )
        #expect(ordered.map(\.indexNumeric) == [1, 2, 3, 10, 12])
        #expect(ordered.prefix(3).allSatisfy { $0.image.raw?.host() == "example.com" })
    }

    /// The control: with no store answer the order is exactly what it was
    /// before this change, so a series Apple does not sell is untouched.
    @Test("No Apple volumes leaves MangaBaka's own order alone")
    func noStoreIsUnchanged() {
        let mine = [mangaBakaCover(10), mangaBakaCover(11)]
        let ordered = SeriesDetailView.gallery(mangaBaka: mine, apple: [], front: mine[0], languages: nil)
        #expect(ordered.map(\.indexNumeric) == [11])
    }

    @Test("Volumes are ordered by number, however the store sent them")
    func appleCoversAreOrdered() {
        let ordered = SeriesDetailView.gallery(
            mangaBaka: [], apple: [volume(3), volume(1), volume(2)], front: nil, languages: nil
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
            mangaBaka: mine, apple: [], front: nil, languages: ["en", "ko"]
        )
        #expect(ordered.map(\.indexNumeric) == [1, 2])
    }

    /// Regional tags are the normal spelling on the wire, so an exact match
    /// would throw away the very editions being kept.
    @Test("A regional tag still counts as its language")
    func regionalTagsMatch() {
        let mine = [mangaBakaCover(1, language: "zh-hans"), mangaBakaCover(2, language: "en-GB")]
        let ordered = SeriesDetailView.gallery(
            mangaBaka: mine, apple: [], front: nil, languages: ["en", "zh"]
        )
        #expect(ordered.map(\.indexNumeric) == [1, 2])
    }

    /// A null language is a missing field far more often than a foreign
    /// edition, and hiding real artwork over it is the worse mistake.
    @Test("A cover with no language is kept, and so is Apple's")
    func unlabelledCoversSurvive() {
        let ordered = SeriesDetailView.gallery(
            mangaBaka: [mangaBakaCover(9, language: nil)],
            apple: [volume(1)],
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
            mangaBaka: mine, apple: [], front: nil, languages: nil
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
