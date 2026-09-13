import Foundation
import Testing
@testable import MangaBaka

/// "Also in" and voice actors on a character's AniList profile — the `media`
/// selection added to `AniListClient.profileQuery` alongside the fields
/// `CharacterProfileTests` already covers.
///
/// The fixture (`anilist-character-media.json`) was captured live on
/// 2026-09-13 against character 40882 (Eren Yeager): three ANIME edges (the
/// three "Shingeki no Kyojin" TV seasons), each crediting the same Japanese
/// voice actor, Yuuki Kaji, under a different staff id-carrying edge —
/// exactly the shape that makes deduplication worth testing rather than
/// assuming.
@Suite("Character profile — appearances and voice actors")
struct CharacterAppearancesTests {
    private func decode(_ json: String) throws -> AniListClient.ProfileResponse {
        let data = try #require(json.data(using: .utf8))
        return try JSONDecoder().decode(AniListClient.ProfileResponse.self, from: data)
    }

    // MARK: - The real fixture

    @Test("The recorded fixture decodes to three anime appearances and one deduplicated voice actor")
    func fixtureDecodesAppearancesAndVoiceActors() throws {
        let data = try Fixture.data("anilist-character-media")
        let decoded = try JSONDecoder().decode(AniListClient.ProfileResponse.self, from: data)
        let node = try #require(decoded.data?.character)

        let appearances = AniListClient.appearances(from: node.media)
        #expect(appearances.count == 3)
        #expect(appearances.allSatisfy { $0.kind == .anime })
        #expect(appearances.map(\.title) == [
            "Shingeki no Kyojin", "Shingeki no Kyojin Season 2", "Shingeki no Kyojin Season 3"
        ])

        // Three edges each carry the same voice actor (id 95672, Yuuki Kaji)
        // — collapsed to one, not counted three times.
        let voiceActors = AniListClient.voiceActors(from: node.media)
        #expect(voiceActors.count == 1)
        #expect(voiceActors.first?.name == "Yuuki Kaji")
        #expect(voiceActors.first?.id == 95672)
        #expect(voiceActors.first?.portraitURL?.absoluteString.hasSuffix("n95672-T33YV7yCDKnL.png") == true)
    }

    @Test("Role is capitalised the same way SeriesCharacter.role already is")
    func roleIsCapitalized() throws {
        let data = try Fixture.data("anilist-character-media")
        let decoded = try JSONDecoder().decode(AniListClient.ProfileResponse.self, from: data)
        let node = try #require(decoded.data?.character)

        let appearances = AniListClient.appearances(from: node.media)
        #expect(appearances.allSatisfy { $0.role == "Main" })
    }

    // MARK: - Tolerant decode (fail-first: a profile with no `media` key at all)

    /// A profile response recorded before `media` existed in the query — or
    /// answered by a server that omits it for any other reason — must still
    /// decode the rest of the profile. `media` is a plain `Optional` property
    /// on `ProfileCharacterNode`, so a missing key decodes to nil rather than
    /// throwing; this pins that down at the mapping layer as well as the
    /// decode layer.
    @Test("A response missing the media key entirely still decodes the description")
    func decodingToleratesAMissingMediaKey() throws {
        let json = """
        {"data":{"Character":{"id":1,"name":{"full":"Someone"},"description":"A short bio."}}}
        """
        let decoded = try decode(json)
        let node = try #require(decoded.data?.character)
        #expect(node.description == "A short bio.")
        #expect(node.media == nil)

        let profile = try #require(AniListClient.profile(from: decoded))
        #expect(profile.description?.isEmpty == false)
        #expect(profile.appearances.isEmpty)
        #expect(profile.voiceActors.isEmpty)
    }

    @Test("An empty media edges array yields no appearances and no voice actors")
    func emptyMediaEdgesYieldsNothing() throws {
        let json = """
        {"data":{"Character":{"id":1,"name":{"full":"Someone"},"media":{"edges":[]}}}}
        """
        let decoded = try decode(json)
        let node = try #require(decoded.data?.character)
        #expect(AniListClient.appearances(from: node.media).isEmpty)
        #expect(AniListClient.voiceActors(from: node.media).isEmpty)
    }

    /// A MANGA edge is real data too (the character's own manga), and must
    /// not be dropped just because it never carries voice actors.
    @Test("A MANGA edge with no voice actors still produces an appearance")
    func mangaEdgeWithNoVoiceActorsStillAppears() throws {
        let json = """
        {"data":{"Character":{"id":1,"name":{"full":"Someone"},"media":{"edges":[
            {"characterRole":"SUPPORTING","voiceActors":[],
             "node":{"id":9,"title":{"romaji":"Some Manga"},"type":"MANGA","format":"MANGA"}}
        ]}}}}
        """
        let decoded = try decode(json)
        let node = try #require(decoded.data?.character)
        let appearances = AniListClient.appearances(from: node.media)
        #expect(appearances.count == 1)
        #expect(appearances.first?.kind == .manga)
        #expect(appearances.first?.role == "Supporting")
        #expect(AniListClient.voiceActors(from: node.media).isEmpty)
    }

    /// An edge whose type is neither ANIME nor MANGA — a hypothetical schema
    /// addition — is dropped rather than guessed at.
    @Test("An edge with an unrecognised type is dropped, not guessed at")
    func unrecognisedTypeIsDropped() throws {
        let json = """
        {"data":{"Character":{"id":1,"name":{"full":"Someone"},"media":{"edges":[
            {"characterRole":"MAIN","voiceActors":[],
             "node":{"id":9,"title":{"romaji":"Mystery"},"type":"NOVEL","format":"NOVEL"}}
        ]}}}}
        """
        let decoded = try decode(json)
        let node = try #require(decoded.data?.character)
        #expect(AniListClient.appearances(from: node.media).isEmpty)
    }

    // MARK: - Shikimori profiles carry neither

    @Test("A Shikimori profile has empty appearances and voice actors — it has no such data")
    func shikimoriProfileHasEmptyArrays() throws {
        let response = ShikimoriClient.Profile(
            id: 1, name: "Someone", russian: nil, japanese: nil, altname: nil,
            url: nil, image: nil, description: nil
        )
        let baseURL = try #require(URL(string: "https://shikimori.io"))
        let profile = try #require(ShikimoriClient.profile(from: response, baseURL: baseURL))
        #expect(profile.appearances.isEmpty)
        #expect(profile.voiceActors.isEmpty)
    }
}
