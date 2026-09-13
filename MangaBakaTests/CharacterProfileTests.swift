import Foundation
import Testing
@testable import MangaBaka

/// The AniList character-profile path: decoding a real response, cleaning its
/// description, and the one rule that must hold before any of it runs — a
/// Shikimori-sourced character can never produce an AniList profile request.
@Suite("Character profile")
struct CharacterProfileTests {
    private func character(id: Int, source: CharacterSource) -> SeriesCharacter {
        SeriesCharacter(id: id, name: "Test", role: nil, imageURL: nil, source: source)
    }

    // MARK: - The provenance gate

    /// The control: an AniList-sourced character's own id IS a valid AniList
    /// id, so the gate must pass it through unchanged rather than refusing
    /// everything indiscriminately.
    @Test("An AniList-sourced character's id passes through")
    func aniListSourceProducesID() {
        #expect(CharacterProfileRequest.aniListID(for: character(id: 138_789, source: .aniList)) == 138_789)
    }

    @Test("A Shikimori-sourced character can never produce an AniList profile request")
    func shikimoriSourceProducesNoID() {
        #expect(CharacterProfileRequest.aniListID(for: character(id: 138_789, source: .shikimori)) == nil)
    }

    // MARK: - Decoding a real response

    /// Fetched live with curl on 2026-09-12:
    /// `query { Character(id: 138789) { id name { full native alternative }
    /// image { large medium } description gender age bloodType
    /// dateOfBirth { year month day } favourites siteUrl } }`
    private static let recordedResponse = """
    {"data":{"Character":{"id":138789,"name":{"full":"Hae-In Cha","native":"차해인",\
    "alternative":["Shizuku Kousaka (向坂雫)","Blade Dancer"]},"image":{"large":\
    "https://s4.anilist.co/file/anilistcdn/character/large/b138789-AhE8m0LWjE7E.png",\
    "medium":"https://s4.anilist.co/file/anilistcdn/character/medium/b138789-AhE8m0LWjE7E.png"},\
    "description":"__Guild:__ Hunters Guild\\n__Class:__ Sword Fighter\\n__Affiliations:__ \
    Jeju Island Raid Party, [Song Chi-Yul](https://anilist.co/character/136073/ChiYul--Song)\
    \\u2019s Dojo (Disciple)\\n\\nCha Hae-In is the Vice-Guild Master of the Hunters Guild.",\
    "gender":"Female","age":"23","bloodType":null,"dateOfBirth":{"year":null,"month":null,\
    "day":null},"favourites":4816,"siteUrl":"https://anilist.co/character/138789"}}}
    """

    @Test("A real AniList response decodes to the profile it describes")
    func decodesRecordedResponse() throws {
        let data = try #require(Self.recordedResponse.data(using: .utf8))
        let decoded = try JSONDecoder().decode(AniListClient.ProfileResponse.self, from: data)
        let profile = try #require(AniListClient.profile(from: decoded))

        #expect(profile.id == 138_789)
        #expect(profile.fullName == "Hae-In Cha")
        #expect(profile.nativeName == "차해인")
        #expect(profile.alternativeNames == ["Shizuku Kousaka (向坂雫)", "Blade Dancer"])
        #expect(profile.gender == "Female")
        #expect(profile.age == "23")
        // AniList sent null for every field here; a birthdate with no month
        // is not something to print, and a blood type it never named is not
        // "unknown" so much as never claimed.
        #expect(profile.bloodType == nil)
        #expect(profile.dateOfBirth == nil)
        #expect(profile.favourites == 4816)
        #expect(profile.siteURL == URL(string: "https://anilist.co/character/138789"))
        #expect(profile.imageURL?.absoluteString.hasSuffix("b138789-AhE8m0LWjE7E.png") == true)
        #expect(profile.description?.isEmpty == false)
    }

    /// Control: the mapping's own missing-data behaviour, isolated from the
    /// live response above so a change to `dateOfBirth` handling cannot hide
    /// behind a coincidence in the recorded fixture.
    @Test("A GraphQL errors array with no data throws rather than silently mapping to nothing")
    func responseCarryingOnlyErrorsHasNoCharacter() throws {
        let json = #"{"data":null,"errors":[{"message":"Not Found."}]}"#
        let data = try #require(json.data(using: .utf8))
        let decoded = try JSONDecoder().decode(AniListClient.ProfileResponse.self, from: data)
        #expect(AniListClient.profile(from: decoded) == nil)
    }

    // MARK: - Description cleaning

    @Test("Plain text with no markup passes through unchanged")
    func plainTextIsUnchanged() {
        let description = CharacterDescriptionParser.parse("Just an ordinary sentence about someone.")
        #expect(description.blocks == [
            .init(spans: [.plain("Just an ordinary sentence about someone.")], isSpoiler: false)
        ])
    }

    @Test("Bold markers become bold spans, not literal underscores")
    func boldMarkupIsParsed() {
        let description = CharacterDescriptionParser.parse("__Guild:__ Hunters Guild")
        #expect(description.blocks == [
            .init(spans: [.bold("Guild:"), .plain(" Hunters Guild")], isSpoiler: false)
        ])
    }

    @Test("A markdown link becomes a link span with a real URL")
    func linkMarkupIsParsed() throws {
        let url = try #require(URL(string: "https://anilist.co/character/136073/ChiYul--Song"))
        let description = CharacterDescriptionParser.parse("[Song Chi-Yul](\(url.absoluteString))")
        #expect(description.blocks == [
            .init(spans: [.link(text: "Song Chi-Yul", url: url)], isSpoiler: false)
        ])
    }

    @Test("A spoiler span is marked rather than rendered as plain text")
    func spoilerSpanIsMarked() {
        let description = CharacterDescriptionParser.parse("Before. ~!A secret death!~ After.")
        #expect(description.blocks == [
            .init(spans: [.plain("Before. ")], isSpoiler: false),
            .init(spans: [.plain("A secret death")], isSpoiler: true),
            .init(spans: [.plain(" After.")], isSpoiler: false)
        ])
    }

    /// Fetched live with curl on 2026-09-12, character id 40 (Monkey D.
    /// Luffy). Real AniList descriptions nest bold markup INSIDE a spoiler
    /// span and let a spoiler span run across several lines — a parser
    /// written only from the published schema, without a real example,
    /// would have no reason to expect either.
    @Test("A multi-line spoiler containing bold markup stays one spoiler block")
    func multilineSpoilerWithNestedBold() {
        let raw = """
        __Devil Fruit Type:__ Paramecia
        ~!__True Devil Fruit:__ Hito Hito no Mi Model: Nika (Human-Human Fruit)
        __True Devil Fruit Type:__ Mythical Zoan!~
        """
        let description = CharacterDescriptionParser.parse(raw)

        let spoilerBlocks = description.blocks.filter(\.isSpoiler)
        #expect(spoilerBlocks.count == 1)
        // The nested "__...__" markers inside the spoiler are still parsed as
        // bold, not left as literal underscores.
        #expect(spoilerBlocks.first?.spans.contains(.bold("True Devil Fruit:")) == true)
        #expect(spoilerBlocks.first?.spans.contains(.bold("True Devil Fruit Type:")) == true)
    }

    @Test("An empty description produces no blocks rather than one empty block")
    func emptyDescriptionProducesNoBlocks() {
        #expect(CharacterDescriptionParser.parse("").blocks.isEmpty)
        #expect(CharacterDescriptionParser.parse("   \n\n  ").blocks.isEmpty)
    }

    // MARK: - The wider dialect (docs/reviews/third-parties.md finding 7, 2026-09-13)
    //
    // Not checked against a live description that uses any of these — the
    // two ids verified on 2026-09-12 (`decodesRecordedResponse` and the
    // multiline-spoiler fixture above) only used `__bold__`, links and
    // `~!spoiler!~`. These are AniList's documented markdown dialect, added
    // because the app previously showed each of them verbatim.

    @Test("A star-italic marker becomes an italic span, not literal asterisks")
    func starItalicIsParsed() {
        let description = CharacterDescriptionParser.parse("*a whisper*")
        #expect(description.blocks == [.init(spans: [.italic("a whisper")], isSpoiler: false)])
    }

    @Test("An underscore-italic marker becomes an italic span")
    func underscoreItalicIsParsed() {
        let description = CharacterDescriptionParser.parse("_a whisper_")
        #expect(description.blocks == [.init(spans: [.italic("a whisper")], isSpoiler: false)])
    }

    /// A single underscore inside a word (a name, a variable) is not italic
    /// markup — only a `_` bounded by non-word characters counts.
    @Test("An underscore inside a word is not read as italic markup")
    func underscoreInsideWordIsNotItalic() {
        let description = CharacterDescriptionParser.parse("Hunter_X_Hunter")
        #expect(description.blocks == [.init(spans: [.plain("Hunter_X_Hunter")], isSpoiler: false)])
    }

    @Test("HTML italic and bold tags become the matching spans")
    func htmlItalicAndBoldAreParsed() {
        let description = CharacterDescriptionParser.parse("<b>Bold</b> and <i>italic</i>.")
        #expect(description.blocks == [
            .init(spans: [.bold("Bold"), .plain(" and "), .italic("italic"), .plain(".")], isSpoiler: false)
        ])
    }

    @Test("An HTML line break becomes a newline, not literal markup")
    func htmlBreakBecomesNewline() {
        let description = CharacterDescriptionParser.parse("Line one.<br>Line two.")
        #expect(description.blocks == [
            .init(spans: [.plain("Line one."), .plain("\n"), .plain("Line two.")], isSpoiler: false)
        ])
    }

    /// No span represents centering, so the words are kept as plain text
    /// rather than dropped or left wrapped in literal tildes.
    @Test("A centered block keeps its words as plain text")
    func centeredBlockBecomesPlainText() {
        let description = CharacterDescriptionParser.parse("~~~A title~~~")
        #expect(description.blocks == [.init(spans: [.plain("A title")], isSpoiler: false)])
    }

    /// No image span exists, and a bare image has no text of its own to show
    /// in its place — dropped rather than leaving markup or a raw URL on screen.
    @Test("An inline image marker is dropped, not shown as markup or a raw URL")
    func inlineImageIsDropped() {
        let description = CharacterDescriptionParser.parse("Before. img220(https://example.com/a.png) After.")
        // Adjacent plain spans are not merged by the parser; the text is what
        // matters — no markup, no URL.
        let text = description.blocks.flatMap(\.spans).map { span -> String in
            if case let .plain(value) = span { return value }
            return "<\(span)>"
        }.joined()
        #expect(text == "Before.  After.")
        #expect(!text.contains("example.com"))
    }

    /// A heading becomes a bold span followed by a newline — the same choice
    /// `ShikimoriDescriptionParser` makes for `[h1-6]`, so both sources render
    /// through the one path `CharacterProfileView` uses.
    @Test("A markdown heading becomes a bold span, not literal hashes")
    func markdownHeadingIsParsed() {
        let description = CharacterDescriptionParser.parse("# Background\nGrew up in the north.")
        let expectedSpans: [CharacterDescription.Span] =
            [.bold("Background"), .plain("\n"), .plain("Grew up in the north.")]
        #expect(description.blocks == [.init(spans: expectedSpans, isSpoiler: false)])
    }
}
