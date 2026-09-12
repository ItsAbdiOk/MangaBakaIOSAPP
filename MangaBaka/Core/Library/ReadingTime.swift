import Foundation

/// A rough "time to catch up" figure for chapters not yet read.
///
/// Nobody records how long a chapter actually takes them, so this is not
/// measured on this app's readers at all. The per-chapter constants below are
/// carried over from a sibling project's calibration
/// (`tagsgen/reading/ttc.py`, calibrated 2026-08) against 152 series of
/// Abdi's own Tachimanga reading history — measured for exactly one reader,
/// a GUESS for anyone else.
///
/// That calibration run also found the spread wide: p25 was 122s/chapter,
/// p75 was 266s/chapter, against per-type means in the 170-214s range. This
/// is meant to read as a filter — "roughly how much is left" — never as a
/// promise of a precise number.
enum ReadingTime {
    /// Seconds per chapter by lowercased series type, from the sibling
    /// project's calibration run. Manhua measured 171s/chapter in that run,
    /// but on only 7 series — too thin to trust — so it is left out here and
    /// falls through to `defaultSecondsPerChapter` instead.
    static let secondsPerChapter: [String: Double] = [
        "manga": 170,
        "manhwa": 214
    ]

    /// What everything that isn't manga or manhwa is charged, manhua
    /// included. Also from the sibling project's calibration, also a GUESS.
    static let defaultSecondsPerChapter: Double = 202

    /// Hours to read `chapters` more chapters of a series of the given
    /// `type`. `nil` when `chapters` is nil or not positive — there is
    /// nothing left to estimate.
    static func hours(chapters: Double?, type: String?) -> Double? {
        guard let chapters, chapters > 0 else { return nil }
        let perChapter = secondsPerChapter[type?.lowercased() ?? ""] ?? defaultSecondsPerChapter
        return chapters * perChapter / 3600
    }

    /// A rounded, low-precision label — never more than 2 significant
    /// figures: "≈ 45 min" under an hour, "≈ 14 h" from there up to a day,
    /// "≈ 4 days" beyond that. The day figure assumes 8 reading hours a
    /// day — a GUESS, not anyone's measured pace, chosen only so the number
    /// reads as "a weekend's worth" instead of a work-hours estimate.
    static func label(chapters: Double?, type: String?) -> String? {
        guard let hours = hours(chapters: chapters, type: type) else { return nil }
        if hours < 1 {
            let minutes = Int((hours * 60).rounded())
            return "≈ \(minutes) min"
        }
        if hours < 24 {
            return "≈ \(Int(hours.rounded())) h"
        }
        let days = Int((hours / 8).rounded())
        return "≈ \(days) days"
    }
}
