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

    var id: Int { series.id }

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
