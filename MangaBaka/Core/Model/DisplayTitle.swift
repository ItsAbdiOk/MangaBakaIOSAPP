import Foundation

/// Chooses which of a series' many titles to show.
///
/// This is a real decision, not a field lookup: `SeriesV2` has no `title`
/// property at all, only an optional, nullable `titles` array, and every entry
/// in it is flagged `is_primary`. See the note on `SeriesTitle.isPrimary` for
/// the measurement behind that claim.
enum DisplayTitle {
    /// Preference order, most preferred first:
    ///
    /// 1. the reader's own preferred languages, in their order
    /// 2. an official English title
    /// 3. any English title
    /// 4. a romanised title (`-Latn`), which is readable by more people than
    ///    a native-script one
    /// 5. anything marked native
    /// 6. the first title present
    ///
    /// - Returns: `nil` when the series carries no titles at all, which the
    ///   schema permits (`titles` is both optional and nullable). Callers must
    ///   handle that rather than force-unwrapping.
    static func choose(
        from titles: [SeriesTitle]?,
        preferredLanguages: [String] = Locale.preferredLanguages,
        preference: TitlePreference = TitleSettings.preference
    ) -> String? {
        guard let titles, !titles.isEmpty else { return nil }

        if let chosen = matching(preference, in: titles) { return chosen }

        let normalizedPreferred = preferredLanguages.map(languageCode(of:))

        for preferred in normalizedPreferred {
            if let match = best(inLanguage: preferred, of: titles) { return match }
        }

        if let officialEnglish = titles.first(where: {
            languageCode(of: $0.language) == "en" && $0.traits.contains("official")
        }) {
            return officialEnglish.title
        }
        if let anyEnglish = titles.first(where: { languageCode(of: $0.language) == "en" }) {
            return anyEnglish.title
        }
        if let romanised = titles.first(where: { $0.language.hasSuffix("-Latn") }) {
            return romanised.title
        }
        if let native = titles.first(where: { $0.traits.contains("native") }) {
            return native.title
        }
        return titles.first?.title
    }

    /// The reader's explicit choice, where the series can satisfy it.
    ///
    /// Comes before the device's languages: someone who asked for the original
    /// script wants it whatever iOS says their preferred language is. Falls
    /// through when the series carries nothing in that form, because a missing
    /// romanisation should show a title rather than nothing.
    private static func matching(
        _ preference: TitlePreference,
        in titles: [SeriesTitle]
    ) -> String? {
        switch preference {
        case .romanised:
            titles.first { $0.language.hasSuffix("-Latn") }?.title
        case .original:
            // The trait first, then the script. Most series carry no "native"
            // trait at all — the origin-language title is simply tagged `ja`
            // or `ko` with nothing else — so requiring it answered an
            // "original language" request with English and said nothing about
            // having done so. A "-Latn" tag is excluded on purpose: a
            // romanisation is a reading of the original, not the original.
            titles.first { $0.traits.contains("native") }?.title
                ?? titles.first { isNativeScript($0) }?.title
        case .english:
            // Explicit, not "fall through to the device's languages": the
            // choice is the reader's, so a French phone must not quietly
            // override an English preference. Still nil-able — a series with
            // no English title should show something rather than nothing.
            best(inLanguage: "en", of: titles)
        }
    }

    /// The best title in one language.
    ///
    /// **Official first.** A series can carry two titles tagged `en`, and the
    /// API returns them alphabetically: "Lout of Count's Family" is tagged
    /// official, and a ROMANISATION mis-tagged as English — "Baekjakga-ui
    /// Mangnani-ga Doeeotda" — sorts before it. Taking the first match showed
    /// the romanisation to a reader who had asked for English. Verified against
    /// series 638 on 2026-09-10.
    private static func best(inLanguage code: String, of titles: [SeriesTitle]) -> String? {
        let inLanguage = titles.filter { languageCode(of: $0.language) == code }
        return inLanguage.first { $0.traits.contains("official") }?.title
            ?? inLanguage.first?.title
    }

    /// A title written in the language the series came from.
    ///
    /// Everything that is not English and not a romanisation. Deliberately
    /// broad rather than a list of origin languages: the API does not say
    /// which language a series originated in on the titles themselves, and a
    /// hard-coded ja/ko/zh list would silently exclude everything else.
    private static func isNativeScript(_ title: SeriesTitle) -> Bool {
        let code = languageCode(of: title.language)
        return code != "en" && !code.hasSuffix("-latn")
    }

    /// "pt-BR" and "pt-br" and "pt" all compare equal; "ko-Latn" stays distinct
    /// from "ko" because a romanisation is a different reading experience.
    private static func languageCode(of tag: String) -> String {
        if tag.hasSuffix("-Latn") { return tag.lowercased() }
        return String(tag.split(separator: "-").first ?? "").lowercased()
    }
}
