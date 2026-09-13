import Testing
@testable import MangaBaka

/// `CharacterNameMatch`: the rough fuzzy match `CharacterService` unions
/// AniList's and Shikimori's casts with. Every case here is quoted directly
/// from Abdi's own examples, 2026-09-13, when he asked for the union.
@Suite("Character name matching")
struct CharacterNameMatchTests {
    @Test("A reordered full name matches, hyphen or not")
    func reorderedFullNameMatches() {
        #expect(CharacterNameMatch.matches("Sung Jin-Woo", "Jinwoo Sung"))
        #expect(CharacterNameMatch.matches("Cha Hae-In", "Hae-In Cha"))
    }

    @Test("A shorthand matches a token of the fuller name")
    func shorthandMatchesToken() {
        #expect(CharacterNameMatch.matches("Beru", "Beru (Ant King)"))
        #expect(CharacterNameMatch.matches("Beru (Ant King)", "Beru"))
    }

    /// The control: two different people must not match just because they
    /// share a first name and a similar-looking surname.
    @Test("A similar but different surname does not match")
    func similarSurnameDoesNotMatch() {
        #expect(!CharacterNameMatch.matches("Thomas Andre", "Thomas Anderson"))
    }

    @Test("An exact match matches")
    func exactMatch() {
        #expect(CharacterNameMatch.matches("Igris", "Igris"))
    }

    @Test("Two unrelated names do not match")
    func unrelatedNamesDoNotMatch() {
        #expect(!CharacterNameMatch.matches("Sung Jin-Woo", "Igris"))
    }

    @Test("An empty name never matches, even itself")
    func emptyNamesNeverMatch() {
        #expect(!CharacterNameMatch.matches("", ""))
        #expect(!CharacterNameMatch.matches("", "Sung Jin-Woo"))
    }

    /// Rule 2: same surname, same first-name initial — an abbreviated first
    /// name against a full one, same order on both sides.
    @Test("Same surname and first initial matches an abbreviated first name")
    func surnameAndInitialMatches() {
        #expect(CharacterNameMatch.matches("J. Sung", "Jin-Woo Sung"))
    }

    /// Rule 4: native names match even when the romanised ones do not at all.
    @Test("Matching native names match even when the romanised names differ entirely")
    func nativeNamesMatch() {
        #expect(CharacterNameMatch.matches(
            "Totally Different Spelling", "Something Else Entirely",
            nativeA: "성진우", nativeB: "성진우"
        ))
    }

    @Test("Diacritics and case do not stop a match")
    func diacriticsAndCaseFold() {
        #expect(CharacterNameMatch.matches("CHA HAE-IN", "hae-in chá"))
    }

    @Test("Punctuation and extra whitespace do not stop a match")
    func punctuationAndWhitespaceFold() {
        #expect(CharacterNameMatch.matches("  Sung   Jin-Woo  ", "Jinwoo, Sung"))
    }
}
