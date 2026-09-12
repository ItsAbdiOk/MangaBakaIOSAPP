import Foundation
import Testing
@testable import MangaBaka

/// The Shikimori half of the character-profile path: decoding a real
/// response, cleaning its BBCode description, the provenance gate holding in
/// both directions, and the rule that an untranslated description is never
/// shown.
@Suite("Shikimori character profile")
struct ShikimoriCharacterProfileTests {
    private func character(id: Int, source: CharacterSource) -> SeriesCharacter {
        SeriesCharacter(id: id, name: "Test", role: nil, imageURL: nil, source: source)
    }

    // MARK: - Decoding a real response

    /// Fetched live with curl on 2026-09-12: `GET
    /// https://shikimori.one/api/characters/40` (Monkey D. Luffy), truncated
    /// mid-sentence in the description — long enough to exercise `\r\n`,
    /// `[h3]` and `[character=id]`, short enough to keep the fixture
    /// readable.
    private static let recordedLuffyResponse = """
    {"id": 40, "name": "Luffy Monkey D.", "russian": "Луффи Монки Д.", \
    "japanese": "モンキー・D・ルフィ", "altname": "Mugiwara, Straw Hat", \
    "url": "/characters/40-luffy-monkey-d", "image": {"original": \
    "/system/characters/original/40.jpg?1718830202", "preview": \
    "/system/characters/preview/40.jpg?1718830202"}, "description": \
    "Главный герой манги и аниме «Большой куш».\\r\\n\\r\\n[h3]Внешность[/h3]Не особо \
    высокий паренёк. После атаки [character=22687]Акаину[/character] в битве \
    при Маринфорде появился шрам."}
    """

    private static let baseURL = URL(string: "https://shikimori.one").unsafelyUnwrappedTestFallback

    @Test("A real Shikimori response decodes to the profile it describes")
    func decodesRecordedResponse() throws {
        let data = try #require(Self.recordedLuffyResponse.data(using: .utf8))
        let decoded = try JSONDecoder().decode(ShikimoriClient.Profile.self, from: data)
        let profile = try #require(ShikimoriClient.profile(from: decoded, baseURL: Self.baseURL))

        #expect(profile.id == 40)
        // Already romaji — never translated. See `CharacterProfile.requiresTranslation`.
        #expect(profile.fullName == "Luffy Monkey D.")
        #expect(profile.nativeName == "モンキー・D・ルフィ")
        #expect(profile.alternativeNames == ["Mugiwara", "Straw Hat"])
        #expect(profile.source == .shikimori)
        #expect(profile.requiresTranslation)
        #expect(
            profile.imageURL?.absoluteString
                == "https://shikimori.one/system/characters/original/40.jpg?1718830202"
        )
        #expect(profile.siteURL?.absoluteString == "https://shikimori.one/characters/40-luffy-monkey-d")
        // Shikimori's character endpoint sends none of these — nothing is
        // guessed in their place.
        #expect(profile.facts.isEmpty)
        #expect(profile.description?.isEmpty == false)
    }

    /// Control: a response with no id or name produces no profile, isolated
    /// from the live fixture above so a change to the `guard` cannot hide
    /// behind a coincidence in the recording.
    @Test("A Shikimori response with no id maps to no profile")
    func responseWithNoIDHasNoProfile() throws {
        let json = #"{"id": null, "name": "Ghost"}"#
        let decoded = try JSONDecoder().decode(ShikimoriClient.Profile.self, from: Data(json.utf8))
        #expect(ShikimoriClient.profile(from: decoded, baseURL: Self.baseURL) == nil)
    }

    // MARK: - BBCode description cleaning

    @Test("Plain text with no BBCode passes through unchanged")
    func plainTextIsUnchanged() {
        let description = ShikimoriDescriptionParser.parse("Просто обычное предложение о ком-то.")
        #expect(description.blocks == [
            .init(spans: [.plain("Просто обычное предложение о ком-то.")], isSpoiler: false)
        ])
    }

    @Test("A heading becomes a bold span, not literal brackets")
    func headingBecomesBold() {
        let description = ShikimoriDescriptionParser.parse("[h3]Внешность[/h3]Текст после.")
        #expect(description.blocks == [
            .init(spans: [.bold("Внешность"), .plain("\n"), .plain("Текст после.")], isSpoiler: false)
        ])
    }

    @Test("CRLF line endings are normalized before parsing")
    func crlfIsNormalized() {
        let description = ShikimoriDescriptionParser.parse("Первая строка.\r\n\r\nВторая строка.")
        let joined = description.blocks.flatMap(\.spans).map(Self.text(of:)).joined()
        #expect(!joined.contains("\r"))
    }

    /// Fetched live with curl on 2026-09-12, character id 1 (Spike Spiegel) —
    /// real Shikimori BBCode nesting a `[character=id]` link inside a
    /// `[spoiler]` block, alongside a separate `[url=href]` link outside it.
    @Test("A spoiler containing a character link stays one block, and a url link outside it does not")
    func spoilerWithNestedCharacterLinkAndSeparateURLLink() {
        let raw = """
        Владеет техникой [url=http://ru.wikipedia.org/wiki/Джиткундо]джиткундо[/url]. Не боится умереть.\r
        [spoiler]Простреленный глаз заменён кибернетическим. \
        Любил только [character=2735]Джулию[/character].[/spoiler]
        """
        let description = ShikimoriDescriptionParser.parse(raw)

        let spoilerBlocks = description.blocks.filter(\.isSpoiler)
        let plainBlocks = description.blocks.filter { !$0.isSpoiler }
        #expect(spoilerBlocks.count == 1)

        // The character reference survived as a link whose text is the
        // character's name, wherever URL parsing landed it.
        let spoilerText = spoilerBlocks.flatMap(\.spans).map(Self.text(of:)).joined()
        #expect(spoilerText.contains("Джулию"))
        let spoilerHasCharacterLink = spoilerBlocks.flatMap(\.spans).contains {
            if case let .link(text, _) = $0 { return text == "Джулию" }
            return false
        }
        #expect(spoilerHasCharacterLink)

        // The [url=...] link is outside the spoiler, not swallowed by it.
        let plainText = plainBlocks.flatMap(\.spans).map(Self.text(of:)).joined()
        #expect(plainText.contains("джиткундо"))
    }

    @Test("An empty description produces no blocks rather than one empty block")
    func emptyDescriptionProducesNoBlocks() {
        #expect(ShikimoriDescriptionParser.parse("").blocks.isEmpty)
        #expect(ShikimoriDescriptionParser.parse("  \r\n\r\n ").blocks.isEmpty)
    }

    private static func text(of span: CharacterDescription.Span) -> String {
        switch span {
        case let .plain(text), let .bold(text), let .italic(text): text
        case let .link(text, _): text
        }
    }

    // MARK: - The provenance gate, both directions

    /// Control: an AniList-sourced character's own id IS a valid AniList id.
    @Test("An AniList-sourced character yields an AniList request and never a Shikimori one")
    func aniListSourceYieldsOnlyAniListID() {
        let subject = character(id: 138_789, source: .aniList)
        #expect(CharacterProfileRequest.aniListID(for: subject) == 138_789)
        #expect(CharacterProfileRequest.shikimoriID(for: subject) == nil)
    }

    @Test("A Shikimori-sourced character yields a Shikimori request and never an AniList one")
    func shikimoriSourceYieldsOnlyShikimoriID() {
        let subject = character(id: 40, source: .shikimori)
        #expect(CharacterProfileRequest.shikimoriID(for: subject) == 40)
        #expect(CharacterProfileRequest.aniListID(for: subject) == nil)
    }

    @Test("Both sources report a profile as available, through the id each one actually owns")
    func bothSourcesReportProfileAvailable() {
        #expect(CharacterProfileRequest.isProfileAvailable(for: character(id: 1, source: .aniList)))
        #expect(CharacterProfileRequest.isProfileAvailable(for: character(id: 1, source: .shikimori)))
    }

    // MARK: - An untranslated description is never shown

    @MainActor
    private struct FailingTranslator: DescriptionTranslating {
        struct Failure: Error {}
        func translations(for texts: [String]) async throws -> [String] { throw Failure() }
    }

    @MainActor
    private struct EchoTranslator: DescriptionTranslating {
        func translations(for texts: [String]) async throws -> [String] {
            texts.map { "EN:\($0)" }
        }
    }

    /// The mechanism `CharacterProfileView.translateIfNeeded` relies on:
    /// when translation fails, there is nothing to swap the description in
    /// with, so the view's own code keeps showing the profile it already set
    /// with `withDescription(nil)` — never the Russian original. A real
    /// on-device `TranslationSession` cannot be constructed in a unit test
    /// (it needs a live `.translationTask` and an installed language pack),
    /// so this proves the failure path at the level that can be tested
    /// without one.
    @Test("A failing translator throws rather than returning the Russian text")
    func failingTranslatorThrows() async {
        let description = ShikimoriDescriptionParser.parse("Русский текст.")
        await #expect(throws: FailingTranslator.Failure.self) {
            _ = try await CharacterDescriptionTranslator.translate(description, using: FailingTranslator())
        }
    }

    /// Control: a translator that succeeds does produce a description, and
    /// it keeps the exact span shape (spoiler flag, link URL) it started
    /// with — proving `failingTranslatorThrows` above is testing translation
    /// failure specifically, not some unrelated break in `translate` itself.
    @Test("A succeeding translator replaces each span's text but keeps its shape")
    func succeedingTranslatorKeepsSpanShape() async throws {
        let url = try #require(URL(string: "https://shikimori.one/characters/2735"))
        let original = CharacterDescription(blocks: [
            .init(spans: [.plain("До."), .link(text: "Джулию", url: url)], isSpoiler: false),
            .init(spans: [.bold("Секрет")], isSpoiler: true)
        ])

        let translated = try await CharacterDescriptionTranslator.translate(original, using: EchoTranslator())

        #expect(translated.blocks[0].isSpoiler == false)
        #expect(translated.blocks[0].spans == [.plain("EN:До."), .link(text: "EN:Джулию", url: url)])
        #expect(translated.blocks[1].isSpoiler)
        #expect(translated.blocks[1].spans == [.bold("EN:Секрет")])
    }
}

private extension Optional where Wrapped == URL {
    var unsafelyUnwrappedTestFallback: URL {
        guard let self else { preconditionFailure("Hard-coded test base URL failed to parse.") }
        return self
    }
}
