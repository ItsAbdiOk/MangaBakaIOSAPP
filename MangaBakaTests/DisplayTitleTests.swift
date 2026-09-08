import Foundation
import Testing
@testable import MangaBaka

@Suite("Display title selection")
struct DisplayTitleTests {
    private func title(_ language: String, _ traits: [String], _ text: String) -> SeriesTitle {
        SeriesTitle(language: language, traits: traits, title: text, isPrimary: true)
    }

    /// The bug this guards against: every title in a real response carries
    /// `is_primary: true`, so choosing by that flag returns an arbitrary
    /// language. Verified against live data on 2026-09-08 (25/25, 14/14, 18/18).
    @Test("is_primary alone does not decide the title")
    func isPrimaryIsNotTheSelector() {
        let titles = [
            title("ko", ["native"], "나 혼자만 레벨업"),
            title("hu", [], "Hungarian"),
            title("en", ["official"], "Solo Leveling")
        ]
        #expect(titles.allSatisfy { $0.isPrimary == true })
        #expect(DisplayTitle.choose(from: titles, preferredLanguages: ["en-GB"]) == "Solo Leveling")
    }

    @Test("Reader's preferred language wins over English")
    func preferredLanguageWins() {
        let titles = [
            title("en", ["official"], "English"),
            title("fr", ["official"], "French")
        ]
        #expect(DisplayTitle.choose(from: titles, preferredLanguages: ["fr-FR"]) == "French")
    }

    @Test("Regional variants match their base language")
    func regionalVariantsMatch() {
        let titles = [title("pt-br", ["official"], "Portuguese")]
        #expect(DisplayTitle.choose(from: titles, preferredLanguages: ["pt-PT"]) == "Portuguese")
    }

    @Test("Falls back to official English, then any English")
    func englishFallback() {
        let officialAndPlain = [
            title("en", [], "Plain English"),
            title("en", ["official"], "Official English")
        ]
        #expect(
            DisplayTitle.choose(from: officialAndPlain, preferredLanguages: ["de-DE"])
                == "Official English"
        )

        let plainOnly = [title("en", [], "Plain English")]
        #expect(DisplayTitle.choose(from: plainOnly, preferredLanguages: ["de-DE"]) == "Plain English")
    }

    @Test("Prefers a romanisation over a native script when neither is the reader's language")
    func romanisedBeatsNative() {
        let titles = [
            title("ja", ["native"], "ネイティブ"),
            title("ja-Latn", [], "Romanised")
        ]
        #expect(DisplayTitle.choose(from: titles, preferredLanguages: ["de-DE"]) == "Romanised")
    }

    @Test("A romanisation is not treated as its base language")
    func romanisationIsDistinctFromBaseLanguage() {
        let titles = [
            title("ja-Latn", [], "Romanised"),
            title("ja", ["native"], "ネイティブ")
        ]
        // A reader who asked for Japanese wants Japanese, not a transliteration.
        #expect(DisplayTitle.choose(from: titles, preferredLanguages: ["ja-JP"]) == "ネイティブ")
    }

    @Test("No titles yields nil rather than a crash or a placeholder")
    func emptyAndNil() {
        #expect(DisplayTitle.choose(from: nil, preferredLanguages: ["en"]) == nil)
        #expect(DisplayTitle.choose(from: [], preferredLanguages: ["en"]) == nil)
    }
}
