import Foundation

/// The original-language run of a series, as MangaUpdates' own editors
/// describe it in free text — not a schedule, a chapter/volume count with an
/// ongoing/complete flag and when it was last touched.
///
/// Built for Korean webtoons specifically. `docs/sources/webtoon-episodes.md`
/// measured, across four surveys, that no lawful source publishes a
/// scheduled next episode for one — twelve candidates, zero of twelve.
/// `MangaUpdatesSeries.status` is the closest honest substitute the app
/// already downloads: Tower of God's reads `"652 Chapters (Ongoing)  \n18
/// Volumes (Ongoing)\n\nS1: 78 Chapters + Prologue  \n..."`, human-edited,
/// not live.
///
/// **Never a date, and never trust it more than it earns.** The two caveats
/// `docs/sources/publishers.md` (§"Encode the two caveats in the code") sets
/// for exactly this kind of field hold here: absence does not mean nothing
/// is coming (a series can be missing from MangaUpdates, or its `status` can
/// be unparseable, and still be actively publishing); and the count is only
/// as fresh as its last human edit, not a live figure — `editedAt` exists so
/// a caller can say so on screen.
struct OriginalRun: Equatable, Sendable {
    let chapters: Int
    let volumes: Int?
    let isOngoing: Bool
    /// When MangaUpdates' editors last touched this record —
    /// `last_updated.as_rfc3339`, not a release date. Nil when the field was
    /// absent from the payload or did not parse.
    let editedAt: Date?

    /// The first line's shape, anchored at the start of `status`:
    /// `"<chapters> Chapters[ + Prologue] (Ongoing|Complete)"`. Both strings
    /// `docs/sources/webtoon-episodes.md` measured live open this way. A
    /// `status` that does not start with a chapter count is not "zero
    /// chapters" — it is "cannot state a chapter count" — so it parses to
    /// nil rather than a guessed zero.
    private static let chaptersPattern =
        "^([0-9]+) Chapters(?: \\+ Prologue)?[^()\\n]*\\((Ongoing|Complete)\\)"
    /// The volumes line, wherever it falls in the text. MangaUpdates puts it
    /// second in both measured samples, but nothing pins that order down as
    /// a contract, so this is searched for rather than anchored.
    private static let volumesPattern =
        "([0-9]+) Volumes(?: \\+ Prologue)?[^()\\n]*\\((Ongoing|Complete)\\)"

    /// Parses `series.status` (plus `series.editedAt`) into a run, or nil
    /// when `status` is nil, empty, or not the shape above at all.
    nonisolated static func parse(_ series: MangaUpdatesSeries) -> OriginalRun? {
        guard let status = series.status,
              let match = status.range(of: chaptersPattern, options: .regularExpression)
        else { return nil }
        let head = status[match]
        guard let chapters = leadingInt(head), let state = parenthesised(head)
        else { return nil }

        let volumes = status.range(of: volumesPattern, options: .regularExpression)
            .flatMap { leadingInt(status[$0]) }

        return OriginalRun(
            chapters: chapters, volumes: volumes, isOngoing: state == "Ongoing",
            editedAt: series.editedAt
        )
    }

    private static func leadingInt(_ text: Substring) -> Int? {
        let digits = text.prefix { $0.isNumber }
        return digits.isEmpty ? nil : Int(digits)
    }

    /// The word inside the last parenthesised group in `text` — "Ongoing" or
    /// "Complete" out of "652 Chapters (Ongoing)".
    private static func parenthesised(_ text: Substring) -> String? {
        guard let open = text.lastIndex(of: "("), let close = text.lastIndex(of: ")"), open < close
        else { return nil }
        return String(text[text.index(after: open)..<close])
    }

    /// "≈652 in Korean · ongoing · MangaUpdates, edited 7 Aug" —
    /// `DetailScheduleBlock`'s approximation line, built here so the wording
    /// has one place to change and one set of tests.
    ///
    /// - Parameter language: e.g. "Korean", from `OriginalLanguageName`. Nil
    ///   folds to "the original" so the line still reads for a series whose
    ///   type this app cannot name a language for.
    func summaryLine(language: String?) -> String {
        let place = language.map { "in \($0)" } ?? "in the original"
        let state = isOngoing ? "ongoing" : "complete"
        let edited = editedAt.map { "MangaUpdates, edited \(Self.editedFormatter.string(from: $0))" }
            ?? "MangaUpdates"
        return "≈\(chapters) \(place) · \(state) · \(edited)"
    }

    private static let editedFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}

/// "ja"/"ko"/"zh" → "Japanese"/"Korean"/"Chinese", for `OriginalRun
/// .summaryLine`. No helper in the codebase already maps a language code to
/// its display name — `SeriesDetailView+Editions.threeLetter` maps the same
/// three codes to ISO 639-2/B for a library filter, a different job — so this
/// is new. Only the codes `Series.nativeLanguage`/`impliedLanguage` can
/// actually produce are listed; anything else is nil rather than guessed.
enum OriginalLanguageName {
    private static let names = ["ja": "Japanese", "ko": "Korean", "zh": "Chinese"]

    nonisolated static func name(for code: String?) -> String? {
        code.flatMap { names[$0.lowercased()] }
    }
}
