import Testing
@testable import MangaBaka

/// Flags beside language codes. A judgement per language, a region when the
/// tag names a real one, and nothing rather than a wrong flag.
@Suite("Language flags")
struct LanguageFlagTests {
    @Test("The language's flag, or the region's when the tag names one")
    func flags() {
        #expect(LanguageFlag.emoji(for: "en") == "🇬🇧")
        #expect(LanguageFlag.emoji(for: "ko") == "🇰🇷")
        #expect(LanguageFlag.emoji(for: "pt-br") == "🇧🇷")
        #expect(LanguageFlag.emoji(for: "PT-BR") == "🇧🇷")
        #expect(LanguageFlag.emoji(for: "zh-hk") == "🇭🇰")
        #expect(LanguageFlag.emoji(for: "zh") == "🇨🇳")
    }

    /// "ko-latn" is a script, "es-la" a continent; neither is a country.
    @Test("A script or an unknown region falls back to the language; an unknown language to nothing")
    func fallbacks() {
        #expect(LanguageFlag.emoji(for: "ko-latn") == "🇰🇷")
        #expect(LanguageFlag.emoji(for: "ja-latn") == "🇯🇵")
        #expect(LanguageFlag.emoji(for: "es-la") == "🇪🇸")
        #expect(LanguageFlag.emoji(for: "xx") == nil)
        #expect(LanguageFlag.emoji(for: "") == nil)
    }

    @Test("A title row carries one flag per language, in order")
    func rowFlags() {
        let row = SeriesTitle.Alternative(title: "Solo Leveling", languages: ["en", "tr", "pt-br", "xx"])
        #expect(row.flags == "🇬🇧 🇹🇷 🇧🇷")
    }
}
