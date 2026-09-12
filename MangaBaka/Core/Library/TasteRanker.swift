import Foundation

/// Scores a series by how much its tags overlap the reader's tag affinities.
///
/// Ported from a sibling project's `by_tags()` rule: the score sums the
/// reader's affinity for each tag the series carries, weighted by how central
/// that tag is *to this series*, then divides by the tag count raised to
/// 0.7. The exponent is taken as-is from that project, not re-derived here —
/// it exists to punish a series that racked up a high raw sum only because it
/// has dozens of tags, without punishing it as hard as dividing by the plain
/// count would.
struct TasteRanker: Sendable {
    /// tag id → affinity score, from `TasteLedger.favoured(limit:)`.
    let weights: [Int: Double]

    /// A series with fewer tags than this can't say anything about taste —
    /// there just isn't enough to judge, so it always scores 0.
    static let minimumTags = 3

    init(affinities: [TagAffinity]) {
        weights = Dictionary(affinities.map { ($0.tagId, $0.score) }, uniquingKeysWith: { first, _ in first })
    }

    var isEmpty: Bool { weights.isEmpty }

    /// How central a tag is *to this series*, same table `TasteLedger.weight`
    /// uses for the same reason: a core tag describes the book, an incidental
    /// one just happens in it.
    private static func seriesWeight(_ importance: SeriesTag.Weight) -> Double {
        switch importance {
        case .core: 4
        case .defining: 3
        case .recurrent: 2
        case .incidental, .unweighted: 1
        }
    }

    /// sum(profile[tag] * seriesWeight(tag)) / count(tags)^0.7, min 3 tags.
    ///
    /// The exponent is the sibling project's constant, not derived here — it
    /// sits between "divide by count" (which crushes long tag lists) and "no
    /// length penalty at all" (which lets a 100-tag series win on volume
    /// alone by picking up more matches than a tightly tagged one).
    func score(_ series: Series) -> Double {
        let tags = series.richTags
        guard !isEmpty, tags.count >= Self.minimumTags else { return 0 }

        let sum = tags.reduce(into: 0.0) { total, tag in
            guard let affinity = weights[tag.id] else { return }
            total += affinity * Self.seriesWeight(tag.importance)
        }
        guard sum > 0 else { return 0 }
        return sum / pow(Double(tags.count), 0.7)
    }

    /// The matched tag names, strongest affinity first, for a "shares X, Y"
    /// reason line. Capped at `limit`.
    func reasons(for series: Series, limit: Int = 3) -> [String] {
        guard !isEmpty else { return [] }
        return series.richTags
            .compactMap { tag -> (String, Double)? in
                guard let affinity = weights[tag.id] else { return nil }
                return (tag.name, affinity)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
    }

    /// Stable re-order by score descending. Ties (including all-zero, unscored
    /// items) keep their input order — a plain `sorted(by:)` is not guaranteed
    /// stable, so scores are paired with their original index and that index
    /// breaks ties.
    func rank<T>(_ items: [T], by series: (T) -> Series) -> [T] {
        items.enumerated()
            .sorted { lhs, rhs in
                let leftScore = score(series(lhs.element))
                let rightScore = score(series(rhs.element))
                if leftScore != rightScore { return leftScore > rightScore }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }
}
