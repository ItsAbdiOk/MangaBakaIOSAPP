import Foundation

/// One entry in a Webtoons series feed.
///
/// Entries are not all episodes. "The Knight Only Lives Today" ends its first
/// season with three `Afterword 1/2/3` items sitting above `Episode 112
/// (Season 1 Finale)`, all published the same Friday (checked live,
/// 2026-09-12). They are real entries with real dates, and they are not
/// chapters — so `number` is nil for them and `isEpisode` is false.
struct WebtoonsEntry: Equatable, Sendable, Codable {
    /// The title exactly as the feed gave it, e.g. "[Season 3] Ep. 235".
    let title: String
    let published: Date
    /// The episode number, where the title is an episode at all.
    let number: Int?
    /// The season, where the title names one.
    let season: Int?

    var isEpisode: Bool { number != nil }
}

/// Reads a Webtoons entry title.
///
/// **An allowlist of the episode word, not a test for a number.** The obvious
/// rule — "trust any title with a number in it" — reads `Afterword 3` as
/// episode 3, and since the afterwords sit at the *top* of the feed that makes
/// the newest entry of a 112-episode series report as episode 3. A wrong
/// number shown confidently is worse than no number, so anything whose leading
/// word is not a known episode word is not an episode.
///
/// The inverse rule was tried first and rejected for the opposite reason: a
/// pattern requiring `Episode <n>` exactly threw away every entry of Tower of
/// God, whose titles read `[Season 3] Ep. 235`.
enum WebtoonsTitle {
    /// The words a feed uses for "episode", lowercased. Korean's 화 (hwa) is
    /// here because Naver's own titles use it — `3부 235화` is season 3,
    /// episode 235 — and the Korean feed is the one that says whether the
    /// original is still running.
    private static let episodeWords = ["episode", "ep", "ep.", "chapter", "ch", "ch."]

    /// The number and season in a title, or nil where it is not an episode.
    static func read(_ title: String) -> (number: Int, season: Int?)? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let season = readSeason(trimmed)
        // Anything bracketed is a prefix like "[Season 3]", never the episode
        // itself; dropping it leaves the part that has to match a word below.
        let body = trimmed.replacingOccurrences(
            of: "\\[[^\\]]*\\]", with: " ", options: .regularExpression
        ).trimmingCharacters(in: .whitespaces)

        if let number = readKorean(body) { return (number, season) }

        let parts = body.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let word = parts.first?.lowercased(), episodeWords.contains(word),
              parts.count == 2
        else { return nil }
        // "112 (Season 1 Finale)" → 112. The trailing note is kept out of the
        // number without being guessed at.
        guard let number = leadingInt(String(parts[1])) else { return nil }
        return (number, season)
    }

    /// "235화" → 235. Naver writes the number and the unit as one token.
    private static func readKorean(_ body: String) -> Int? {
        guard let range = body.range(of: "[0-9]+화", options: .regularExpression) else { return nil }
        return Int(body[range].dropLast())
    }

    /// "[Season 3] …" and Naver's "3부 …" both name a season.
    private static func readSeason(_ title: String) -> Int? {
        if let range = title.range(of: "(?i)season[ ]*[0-9]+", options: .regularExpression) {
            return leadingInt(String(title[range].drop { !$0.isNumber }))
        }
        if let range = title.range(of: "[0-9]+부", options: .regularExpression) {
            return Int(title[range].dropLast())
        }
        return nil
    }

    private static func leadingInt(_ text: String) -> Int? {
        let digits = text.drop { !$0.isNumber }.prefix { $0.isNumber }
        return digits.isEmpty ? nil : Int(digits)
    }

    /// Whether a title marks the end of a run rather than an ordinary episode.
    ///
    /// Webtoons writes it into the title: `Episode 112 (Season 1 Finale)`.
    /// Worth reading because a series that has just finished a season is
    /// between seasons, not overdue — and to a gap-based estimate those look
    /// identical while meaning opposite things to a reader.
    static func marksFinale(_ title: String) -> Bool {
        title.range(of: "(?i)finale|final episode|(?i)the end", options: .regularExpression) != nil
    }
}
