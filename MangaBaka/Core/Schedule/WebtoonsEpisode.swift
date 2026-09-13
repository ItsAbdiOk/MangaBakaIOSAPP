import Foundation

/// One entry in a release feed — Webtoons, Naver, or a GigaViewer magazine RSS.
///
/// Entries are not all episodes. "The Knight Only Lives Today" ends its first
/// season with three `Afterword 1/2/3` items sitting above `Episode 112
/// (Season 1 Finale)`, all published the same Friday (checked live,
/// 2026-09-12). They are real entries with real dates, and they are not
/// chapters — so `number` is nil for them and `isEpisode` is false.
struct ReleaseEntry: Equatable, Sendable, Codable {
    /// The title exactly as the feed gave it, e.g. "[Season 3] Ep. 235".
    let title: String
    let published: Date
    /// The episode number, where the title is an episode at all.
    let number: Int?
    /// The season, where the title names one.
    let season: Int?

    var isEpisode: Bool { number != nil }
}

/// Reads an episode title — Webtoons' English forms, Naver's Korean ones, and
/// a Japanese publisher's `第N話` forms off a GigaViewer magazine RSS.
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

        // Japanese magazine RSS titles put the episode marker inside its own
        // brackets — "[第33話] カテナチオ" — rather than as a prefix ahead of a
        // separate episode word, so this is checked on the untouched title
        // before the bracket-stripping below would remove it.
        if let number = readJapanese(trimmed) { return (number, season) }

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

    /// Korean words for a non-episode article — side stories, specials,
    /// afterwords, prologues — Naver's `articleList` carries alongside the
    /// numbered episodes. This is the same bug the Afterword rule exists to
    /// prevent on the English side, reintroduced here: "외전 3화" (side story
    /// 3) has exactly the shape "[0-9]+화" and would otherwise read as
    /// episode 3, with the original then reported ahead or behind by exactly
    /// as much as that side story is wrong. Rejected outright wherever the
    /// word appears, rather than requiring it be the leading word — unlike
    /// `episodeWords`, a season prefix ("3부") legitimately comes first.
    private static let nonEpisodeKoreanWords = ["외전", "특별편", "후기", "프롤로그"]

    /// "235화" → 235, "3부 235화" → 235. Naver writes the number and the unit
    /// as one token.
    private static func readKorean(_ body: String) -> Int? {
        guard !nonEpisodeKoreanWords.contains(where: body.contains) else { return nil }
        guard let range = body.range(of: "[0-9]+화", options: .regularExpression) else { return nil }
        return Int(body[range].dropLast())
    }

    /// "第33話" → 33, "第12-1話" → 12 (the leading number, a sub-episode
    /// dropped rather than guessed at), "第77話①" → 77 (the circled digit is
    /// not part of the pattern and is simply left after the match).
    ///
    /// **Widened 2026-09-13** after a live `shonenjumpplus.com/rss` read found
    /// roughly a third of 40 titles in shapes this used to reject: full-width
    /// digits (`第１２２話`), no `第` at all (`106話`), `回` instead of `話`
    /// (`4375回`), and a bare `#N` (`#96`). Folding full-width digits to
    /// half-width first is what `GigaViewerFeedClient.normalise` already does
    /// for the series title — this had been the half of the fix that stayed
    /// undone for episode titles. `画目`/`歩目`/`おまけN` forms seen in the
    /// same feed are left unmatched; which of those actually number an
    /// episode is a judgement call, not made here.
    private static func readJapanese(_ title: String) -> Int? {
        let folded = title.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? title
        if let range = folded.range(
            of: "第?[0-9]+(-[0-9]+)?(話|回)", options: .regularExpression
        ), let numberRange = folded[range].range(of: "[0-9]+", options: .regularExpression) {
            return Int(folded[range][numberRange])
        }
        if let range = folded.range(of: "#[0-9]+", options: .regularExpression) {
            return Int(folded[range].dropFirst())
        }
        return nil
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
    ///
    /// **Anchored 2026-09-13.** The marker used to be searched for anywhere in
    /// the title, so an ordinary episode whose subtitle happens to contain the
    /// words ended the season by accident — "Episode 30: The End of Summer"
    /// is not a finale. The marker now has to sit inside parentheses (the
    /// shape Webtoons actually writes it in) or right at the end of the
    /// title; the bare "the end" is dropped entirely rather than anchored,
    /// since even anchored it is too generic a phrase to trust.
    static func marksFinale(_ title: String) -> Bool {
        let pattern = "\\([^)]*(?:finale|final episode)[^)]*\\)|(?:finale|final episode)\\s*$"
        return title.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
