import Foundation

/// One series record from MangaUpdates' `GET /v1/series/{id}` — only the
/// fields this feature (and the fields already useful alongside it) read
/// modelled. The live payload also carries recommendations, authors,
/// publishers, related series and more, none of which this app reads through
/// this type.
struct MangaUpdatesSeries: Codable, Sendable, Equatable {
    let seriesID: Int
    let categories: [CategoryVote]
    let bayesianRating: Double?
    let ratingVotes: Int?
    let latestChapter: Int?
    let status: String?
    let licensed: Bool?
    let completed: Bool?
    /// When MangaUpdates' editors last touched this record. Added for
    /// `OriginalRun.editedAt` (`docs/sources/webtoon-episodes.md`) —
    /// `decodeIfPresent` via the memberwise init below, so a payload
    /// captured before this field existed (or a live answer that omits it)
    /// still decodes rather than failing the whole series read.
    let lastUpdated: LastUpdated?

    enum CodingKeys: String, CodingKey {
        case seriesID = "series_id"
        case categories, status, licensed, completed
        case bayesianRating = "bayesian_rating"
        case ratingVotes = "rating_votes"
        case latestChapter = "latest_chapter"
        case lastUpdated = "last_updated"
    }

    /// A memberwise init with `lastUpdated` defaulted, so every existing
    /// call site built before this field existed keeps compiling — this
    /// struct is also built by hand in tests, not only decoded. Does not
    /// disable the synthesized `Decodable.init(from:)`, which is what
    /// actually reads a live payload.
    init(
        seriesID: Int, categories: [CategoryVote], bayesianRating: Double?, ratingVotes: Int?,
        latestChapter: Int?, status: String?, licensed: Bool?, completed: Bool?,
        lastUpdated: LastUpdated? = nil
    ) {
        self.seriesID = seriesID
        self.categories = categories
        self.bayesianRating = bayesianRating
        self.ratingVotes = ratingVotes
        self.latestChapter = latestChapter
        self.status = status
        self.licensed = licensed
        self.completed = completed
        self.lastUpdated = lastUpdated
    }

    /// MangaUpdates' `{"as_rfc3339": "...", "as_string": "..."}` shape,
    /// already seen on `MangaUpdatesClient.Release`'s sibling `time_added`
    /// field (`MangaUpdatesDecodingTests`) — only `as_rfc3339` is read here.
    struct LastUpdated: Codable, Sendable, Equatable {
        let asRFC3339: String?

        enum CodingKeys: String, CodingKey {
            case asRFC3339 = "as_rfc3339"
        }
    }

    /// `lastUpdated.asRFC3339`, parsed — nil when the field is absent or does
    /// not parse. Feeds `OriginalRun.editedAt`; not a release date, an edit
    /// timestamp.
    /// `Date.ISO8601FormatStyle`'s default reads "2026-08-07T18:28:36-07:00"
    /// — MangaUpdates' own measured shape, no fractional seconds — and is
    /// a value type, so it needs none of the sharing care a
    /// `ISO8601DateFormatter` would under strict concurrency.
    var editedAt: Date? {
        lastUpdated?.asRFC3339.flatMap { try? Date(($0), strategy: .iso8601) }
    }

    /// One community-voted category, exactly as MangaUpdates returns it.
    ///
    /// A category is proposed by one reader and then voted up or down by
    /// everyone else who has read the series — a materially different signal
    /// from a genre, which nobody votes on. See `MangaUpdatesCategories.Category`
    /// for the cleaned-up, ranked shape a caller actually wants.
    struct CategoryVote: Codable, Sendable, Equatable {
        let category: String
        let votesPlus: Int
        let votesMinus: Int

        enum CodingKeys: String, CodingKey {
            case category
            case votesPlus = "votes_plus"
            case votesMinus = "votes_minus"
        }
    }
}

/// Turns a series' raw `categories` votes into the short, ranked list "What
/// it's actually like" shows.
enum MangaUpdatesCategories {
    /// One category, cleaned up for display: the raw string normalised and
    /// its net score computed. Everything below `minimumVotes` or with a
    /// score of zero or less has already been dropped by `ranked`.
    struct Category: Equatable, Sendable {
        let name: String
        /// `votesPlus - votesMinus`. A GUESS, not a Wilson lower bound: at
        /// the vote counts this fixture shows (single digits up to a couple
        /// hundred), a Wilson interval and this plain difference rank the
        /// categories in the same order every time it was checked by hand
        /// against `mangaupdates-berserk.json`. Worth revisiting only if a
        /// series turns up where a low-vote outlier (e.g. 2 votes, both "+")
        /// outranks a heavily-voted category it shouldn't.
        let score: Int
    }

    /// MangaUpdates does not document a "this category is real" cutoff.
    /// GUESS: three votes is enough that a single reader's tag-and-run
    /// cannot appear on the page by itself.
    static let defaultMinimumVotes = 3
    /// GUESS: enough to fill a couple of `FlowLayout` rows before asking the
    /// reader to expand — MangaUpdates' own series page shows every category
    /// it has at once, with no equivalent cutoff.
    static let defaultLimit = 24

    /// The disk-cache key for a series' `/v1/series/{number}` answer.
    /// Versioned like `WebtoonsFeedClient`'s cache: a decoding change here
    /// must not be outlived by a week of a payload read under the old rules.
    static func cacheKey(seriesNumber: Int) -> String { "v1-mu-\(seriesNumber)" }

    /// Matches `WebtoonsFeedClient.cacheLife`: "what it's actually like"
    /// does not change day to day, so a week-old answer is still a good one.
    static let cacheLife: TimeInterval = 7 * 24 * 3600

    /// `series.categories`, cleaned, filtered and ranked highest score
    /// first. Pure and synchronous, so it is testable without a network stub.
    static func ranked(
        _ series: MangaUpdatesSeries,
        minimumVotes: Int = defaultMinimumVotes,
        limit: Int = defaultLimit
    ) -> [Category] {
        let qualifying = series.categories.filter { vote in
            vote.votesPlus + vote.votesMinus >= minimumVotes && vote.votesPlus - vote.votesMinus > 0
        }
        let ranked = qualifying
            .map { Category(name: normalise($0.category), score: $0.votesPlus - $0.votesMinus) }
            .sorted { $0.score > $1.score }
        return Array(ranked.prefix(limit))
    }

    /// "Abusive Family Member/s" → "Abusive Family Member". MangaUpdates
    /// appends "/s" to a category name to mark it as also standing for the
    /// plural, which reads as a typo once it is sitting alone in a chip
    /// rather than in a sentence on their own site.
    private static func normalise(_ raw: String) -> String {
        var name = raw
        if name.hasSuffix("/s") { name.removeLast(2) }
        return name
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }
}
