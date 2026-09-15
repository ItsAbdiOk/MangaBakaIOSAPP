import Foundation

/// A recommended series, with the API's own explanation of why it matched.
///
/// `mix`, `similar` and `readers-also-like` do not return series directly —
/// they wrap each one alongside a score and the tags it shares with what you
/// were looking at (verified against the live API 2026-09-08). That explanation
/// is worth surfacing: "shares 12 tags" is a far better reason to tap something
/// than an unexplained row of covers.
struct Recommendation: Decodable, Identifiable, Equatable, Sendable {
    struct Tag: Codable, Equatable, Sendable, Hashable {
        let id: Int
        let name: String
    }

    let series: Series
    /// Overall match strength, 0-1.
    let score: Double?
    /// Tag overlap with the seed. Only the top few are returned.
    let sharedTags: [Tag]?
    /// How many tags overlap in total, which is usually larger than the list.
    let sharedTagsTotal: Int?
    /// The seed and this series share an author.
    let matchedAuthor: Bool?
    /// They are formally related (sequel, spin-off, adaptation).
    let matchedRelated: Bool?
    /// `readers-also-like` only: how many readers hold both. Measured
    /// 2026-09-15 on series 2060: 798 for its top row. Nil on `similar`
    /// and `mix`, which have no reader signal.
    let sharedUsers: Int?
    /// `readers-also-like` only: the row's place in the API's own order.
    let rank: Int?

    var id: Int { series.id }

    /// The part of the envelope worth keeping beside the series once the
    /// wrapper is gone — see `RecommendationNote`.
    var note: RecommendationNote {
        RecommendationNote(
            sharedTagsTotal: sharedTagsTotal, firstSharedTag: sharedTags?.first?.name,
            matchedAuthor: matchedAuthor, matchedRelated: matchedRelated,
            sharedUsers: sharedUsers, rank: rank, score: score
        )
    }

    /// A short, honest reason this was recommended, or `nil` when the API gave
    /// no basis for one. Never invents a reason.
    var reason: String? {
        if matchedRelated == true { return "Directly related" }
        if matchedAuthor == true { return "Same author" }
        if let total = sharedTagsTotal, total > 0 {
            if let first = sharedTags?.first?.name {
                return total > 1 ? "\(first) + \(total - 1) more tags" : first
            }
            return "\(total) shared tags"
        }
        return nil
    }
}

/// Why a recommended series was recommended, small enough to cache beside
/// the feed row that carried it.
///
/// Asked for by Abdi (2026-09-15): the website's "Similar series" cards say
/// "10 shared tags" and "Readers also like" says "86 readers", and the app's
/// two rows said nothing — `SeriesRepository.fetchConditionalFeed` kept the
/// series and dropped the envelope. The API has carried these fields since
/// the model above was verified (2026-09-08); nothing changed on the wire.
/// `Codable` so a feed row on disk keeps it (`FeedEntry.note`).
struct RecommendationNote: Codable, Sendable, Equatable, Hashable {
    var sharedTagsTotal: Int?
    /// The first of the shared tags by name — the whole list is not kept:
    /// a note is a caption, and the tag pages are one tap away.
    var firstSharedTag: String?
    var matchedAuthor: Bool?
    var matchedRelated: Bool?
    var sharedUsers: Int?
    var rank: Int?
    var score: Double?

    /// The caption under a card: the website's own wording. Readers first,
    /// because it only exists on the one feed that has it; then the strongest
    /// tag-side reason, the same order `Recommendation.reason` uses.
    var line: String? {
        if let sharedUsers, sharedUsers > 0 {
            return sharedUsers == 1 ? "1 reader" : "\(sharedUsers) readers"
        }
        if matchedRelated == true { return "Directly related" }
        if matchedAuthor == true { return "Same author" }
        if let sharedTagsTotal, sharedTagsTotal > 0 {
            return sharedTagsTotal == 1 ? "1 shared tag" : "\(sharedTagsTotal) shared tags"
        }
        return nil
    }
}
