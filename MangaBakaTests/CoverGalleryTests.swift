import Foundation
import Testing
@testable import MangaBaka

/// A series' other covers. Solo Leveling has 24 — the volume covers of four
/// editions in four languages — and until now the page showed one of them and
/// gave no sign the rest existed.
@Suite("Covers")
struct CoverGalleryTests {
    private func image(
        id: Int,
        type: String = "volume",
        index: Double? = 1,
        language: String = "en",
        rating: String? = "safe"
    ) -> SeriesImage {
        let indexText = index.map { "\"\(Int($0))\"" } ?? "null"
        let indexNumber = index.map { String($0) } ?? "null"
        let ratingText = rating.map { "\"\($0)\"" } ?? "null"
        let json = """
        {"id": \(id), "series_id": 1, "type": "\(type)",
         "index": \(indexText), "index_numeric": \(indexNumber),
         "language": "\(language)", "content_rating": \(ratingText),
         "image": {}}
        """
        guard let decoded = try? Fixture.decoder().decode(SeriesImage.self, from: Data(json.utf8))
        else { fatalError("SeriesImage fixture no longer decodes: \(json)") }
        return decoded
    }

    // MARK: Which cover leads

    /// MangaBaka's own pick for a Korean manhwa is usually the Korean volume
    /// one: handsome, and unreadable to most people looking at this app.
    @Test("An English edition is preferred")
    func prefersEnglish() {
        let covers = [
            image(id: 1, language: "ko"),
            image(id: 2, language: "en"),
            image(id: 3, language: "pt")
        ]
        #expect(covers.preferredCover(nativeLanguage: "ko")?.id == 2)
    }

    /// The fallback is the work's own language, not whatever happens to be
    /// first — a Portuguese edition is no more useful than a Korean one to
    /// someone who reads neither, and the original is at least authentic.
    @Test("Without English, the original language wins")
    func fallsBackToNative() {
        let covers = [image(id: 1, language: "pt"), image(id: 2, language: "ko")]
        #expect(covers.preferredCover(nativeLanguage: "ko")?.id == 2)
    }

    /// "pt-br" is Portuguese; a native language of "pt" should match it.
    @Test("Regional variants match their base language")
    func regionalVariants() {
        let covers = [image(id: 1, language: "pt-br")]
        #expect(covers.preferredCover(nativeLanguage: "pt")?.id == 1)
    }

    /// Nothing to prefer means the series' own cover stands, rather than an
    /// arbitrary edition being promoted over it.
    @Test("No match leaves the series cover alone")
    func noMatchIsNil() {
        let covers = [image(id: 1, language: "fr")]
        #expect(covers.preferredCover(nativeLanguage: "ko") == nil)
        #expect([SeriesImage]().preferredCover(nativeLanguage: "ko") == nil)
    }

    /// A series' identity is its first cover. Volume nineteen is a picture of a
    /// character the reader has not met.
    @Test("Volume one leads its edition")
    func volumeOneLeads() {
        let covers = [
            image(id: 1, index: 7),
            image(id: 2, index: 1),
            image(id: 3, index: 3)
        ]
        #expect(covers.preferredCover(nativeLanguage: nil)?.id == 2)
    }

    /// "other" images are promotional art, not the book.
    @Test("A volume cover beats promotional art")
    func volumeBeatsOther() {
        let covers = [image(id: 1, type: "other", index: nil), image(id: 2, index: 5)]
        #expect(covers.preferredCover(nativeLanguage: nil)?.id == 2)
    }

    // MARK: The content filter

    /// The rating is per image: a series rated safe can carry a suggestive
    /// alternate cover. The filter failing on exactly the thing it exists to
    /// hide is a bug this app shipped once already, on recommendations.
    @Test("Covers the reader excluded are not shown")
    func filtersByRating() {
        let covers = [
            image(id: 1, rating: "safe"),
            image(id: 2, index: 2, rating: "explicit")
        ]
        let allowed = covers.presentable(allowedRatings: ["safe", "suggestive"])
        #expect(allowed.map(\.id) == [1])
    }

    /// Nil is how the repository spells "no filter set" — which means
    /// everything, not nothing. Reading it as nothing would empty the gallery
    /// for every reader who turned the filter off.
    @Test("No filter means everything")
    func nilRatingsAllowAll() {
        let covers = [image(id: 1, rating: "explicit"), image(id: 2, index: 2, rating: nil)]
        #expect(covers.presentable(allowedRatings: nil).count == 2)
    }

    /// An image the API rated as nothing is not evidence it is explicit.
    @Test("An unrated cover is not excluded")
    func unratedSurvives() {
        let covers = [image(id: 1, rating: nil)]
        #expect(covers.presentable(allowedRatings: ["safe"]).count == 1)
    }

    // MARK: Order

    /// The API returns them by id, which is upload order and means nothing to a
    /// reader. Flicking through should go 1, 2, 3.
    @Test("Covers are ordered by volume, then language")
    func ordering() {
        let covers = [
            image(id: 1, index: 3, language: "en"),
            image(id: 2, index: 1, language: "ko"),
            image(id: 3, index: 1, language: "en")
        ]
        #expect(covers.presentable(allowedRatings: nil).map(\.id) == [3, 2, 1])
    }

    // MARK: Captions

    @Test("A cover says which volume and language it is")
    func caption() {
        #expect(image(id: 1, index: 3, language: "en").caption == "Vol. 3 · EN")
    }

    /// A caption is worth having only when it says something. An image with no
    /// volume and no language has nothing to caption.
    @Test("A cover with nothing to say has no caption")
    func emptyCaption() {
        let json = #"{"id": 1, "series_id": 1, "image": {}}"#
        let bare = try? Fixture.decoder().decode(SeriesImage.self, from: Data(json.utf8))
        #expect(bare?.caption == nil)
    }
}

/// The synopsis clamp, and the bug that made it useless.
@Suite("The synopsis opens", .enabled(if: SourceTree.isAvailable))
struct SynopsisExpansionTests {
    /// The first version measured the unclamped text inside the clamped text's
    /// own background, so it compared a measurement against itself, concluded
    /// nothing was ever truncated, and never showed "View more" on any series.
    /// The two probes have to be separate, and one of them has to be a second
    /// copy of the text laid out with no limit.
    @Test("Truncation is measured against an unclamped copy")
    func measuresBothHeights() throws {
        let source = try SourceTree.read("MangaBaka/Features/Detail/DetailSynopsis.swift")
        #expect(source.contains("clampedHeight"))
        #expect(source.contains("fullHeight"))
        #expect(source.contains("fullHeight > clampedHeight"))
        // The unclamped copy must not inherit the line limit.
        #expect(source.contains("fixedSize(horizontal: false, vertical: true)"))
    }

    /// Reaching for a small word after reading eight lines is the wrong
    /// gesture; the text is what the reader is already looking at.
    @Test("The whole block is tappable, both ways")
    func tapToggles() throws {
        let source = try SourceTree.read("MangaBaka/Features/Detail/DetailSynopsis.swift")
        #expect(source.contains("onTapGesture"))
        #expect(source.contains("isExpanded.toggle()"))
        #expect(source.contains("\"View less\""))
    }

    /// A synopsis that fits must not offer to expand, and tapping it must do
    /// nothing rather than collapsing text that was never clamped.
    @Test("A short synopsis has no control")
    func shortSynopsisInert() throws {
        let source = try SourceTree.read("MangaBaka/Features/Detail/DetailSynopsis.swift")
        #expect(source.contains("guard isTruncated || isExpanded else { return }"))
    }
}
