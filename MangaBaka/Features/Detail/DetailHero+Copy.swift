import Foundation

/// The hero's derived copy — kicker, byline, chapter count — pulled out of
/// `DetailHero.swift` for the lint's type-body ceiling (2026-09-15). Pure
/// functions; `DetailHeroTests` reads them as `DetailHero.kicker(for:)` etc.
extension DetailHero {
    nonisolated static func kicker(for series: Series) -> String? {
        let parts = [typeLabel(series.type), SeriesStatus.label(for: series.status)]
            .compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "Manhwa", "OEL" — `series.type` verbatim-capitalized read "Oel" for
    /// original-English series, an initialism `.capitalized` cannot know
    /// about. `FormatPreferences.Format.oel.title` is the app's own answer
    /// for it (used on the format-preferences screen); everything else stays
    /// on `.capitalized`, since `Format.novel.title` is "Novels" — right for
    /// a settings toggle, wrong for a single series' inline type ("Novel",
    /// not "Novels · 8.6"). Shared with `DiscoverView.meta(for:)`, which had
    /// the same OEL defect.
    nonisolated static func typeLabel(_ type: String?) -> String? {
        guard let type, !type.isEmpty else { return nil }
        if type.lowercased() == FormatPreferences.Format.oel.rawValue {
            return FormatPreferences.Format.oel.title
        }
        return type.capitalized
    }

    /// The mockup writes "native title · author". A series with no native title
    /// distinct from the displayed one shows the author alone rather than a
    /// separator with nothing before it.
    var byline: String? { Self.byline(for: series) }

    /// P18, 2026-09-15: this used to derive a native title from `titles`
    /// (trait `"native"`, filtered against `displayTitle`) — a guess from
    /// before the v1 record carried `native_title` itself. The "Also known
    /// as" sheet (`AlternativeTitlesButton`, below) already reads
    /// `series.nativeTitle`, the API field; the byline now reads the same
    /// field rather than a second, independently-derived answer to the same
    /// question, which could diverge whenever the API's `native_title` is
    /// not itself tagged `native` in `titles`. `series.nativeTitle` is
    /// authoritative: it is what the API states the native title to be,
    /// where the trait search was only ever an inference from the title
    /// list.
    nonisolated static func byline(for series: Series) -> String? {
        let native = series.nativeTitle.flatMap { $0 != series.displayTitle ? $0 : nil }
        let parts = [native, series.authors?.joined(separator: ", ")]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "212 chapters". Nil when MangaBaka has no count, which is common enough
    /// on new series that the line has to be able to not exist.
    var chapterCount: String? { Self.chapterCount(for: series) }

    nonisolated static func chapterCount(for series: Series) -> String? {
        guard let chapters = series.totalChapters, chapters > 0 else { return nil }
        let whole = Int(wholeOrClamped: chapters)
        return "\(whole) \(whole == 1 ? "chapter" : "chapters")"
    }
}
