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
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> String? {
        guard let titles, !titles.isEmpty else { return nil }

        let normalizedPreferred = preferredLanguages.map(languageCode(of:))

        for preferred in normalizedPreferred {
            if let match = titles.first(where: { languageCode(of: $0.language) == preferred }) {
                return match.title
            }
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

    /// "pt-BR" and "pt-br" and "pt" all compare equal; "ko-Latn" stays distinct
    /// from "ko" because a romanisation is a different reading experience.
    private static func languageCode(of tag: String) -> String {
        if tag.hasSuffix("-Latn") { return tag.lowercased() }
        return String(tag.split(separator: "-").first ?? "").lowercased()
    }
}
