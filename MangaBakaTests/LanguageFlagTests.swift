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

    /// The system names the language; a reader should not have to decode
    /// "KO-LATN".
    @Test("The language's name, qualified by region or script")
    func names() {
        #expect(LanguageFlag.name(for: "ko") == "Korean")
        #expect(LanguageFlag.name(for: "ko-latn") == "Korean (Latin)")
        #expect(LanguageFlag.name(for: "pt-br") == "Portuguese (Brazil)")
        #expect(LanguageFlag.name(for: "xx") == "XX")
    }

    /// The schema's title-language enum includes `es-la` (Latin America) and
    /// romanisation markers like `ko-ro`/`ja-ro`; ICU cannot tell those from
    /// real region codes on its own — `forRegionCode: "la"` is "Laos",
    /// `"ro"` is "Romania". Fails without the fix: `name(for: "es-la")`
    /// returns "Spanish (Laos)", not the language alone.
    @Test("A non-country two-letter code does not become a wrong country")
    func nonCountryRegionsAreNotNamed() {
        #expect(LanguageFlag.name(for: "es-la") != "Spanish (Laos)")
        #expect(LanguageFlag.name(for: "es-la") == "Spanish")
        #expect(LanguageFlag.name(for: "ko-ro") != "Korean (Romania)")
        #expect(LanguageFlag.name(for: "ko-ro") == "Korean")
    }

    /// `zh-Hant` and `zh-Hans` must read as different scripts, not both as
    /// bare "Chinese" — which is what a lowercased `"hant"`/`"hans"` handed
    /// to `localizedString(forScriptCode:)` would collapse to if ICU does
    /// not canonicalise the case itself.
    @Test("Traditional and simplified Chinese are named differently")
    func scriptSubtagsAreDistinguished() {
        #expect(LanguageFlag.name(for: "zh-Hant") != LanguageFlag.name(for: "zh-Hans"))
    }

    @Test("A title row carries one flag per language, in order")
    func rowFlags() {
        let row = SeriesTitle.Alternative(title: "Solo Leveling", languages: ["en", "tr", "pt-br", "xx"])
        #expect(row.flags == "🇬🇧 🇹🇷 🇧🇷")
        // "ja" and "ja-latn" are one country; ONE PUNCH-MAN showed two flags.
        let japanese = SeriesTitle.Alternative(title: "ONE PUNCH-MAN", languages: ["ja", "ja-latn"])
        #expect(japanese.flags == "🇯🇵")
    }
}
