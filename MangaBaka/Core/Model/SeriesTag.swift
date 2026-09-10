import Foundation

/// A tag as `tags_v2` describes it, which is far more than a name.
///
/// The app was using v1's `tags` — a flat list of strings — and throwing away
/// everything that makes a tag list readable. `tags_v2` carries the group the
/// tag belongs to, how central it is to this series, whether it spoils the
/// story, and which other tag implied it. Solo Leveling has 146 of them across
/// seventeen groups, which is a wall as a flat list and a table of contents
/// once grouped.
struct SeriesTag: Codable, Identifiable, Sendable, Equatable, Hashable {
    let id: Int
    let name: String
    /// "Activities > Conflict > Large Scale Battles". The first segment is the
    /// group; the last is the name.
    let namePath: String?
    let isGenre: Bool?
    let isSpoiler: Bool?
    let isExplicit: Bool?
    /// Tags that imply this one. "Murder" arrives implied by "Crimes", and
    /// showing both without saying so reads as the API repeating itself.
    let impliedByTagIds: [Int]?
    let contentRating: String?
    /// How central this tag is to *this* series: core, defining, recurrent,
    /// incidental, unweighted.
    let weight: String?
    let seriesCount: Int?

    /// How much this tag says about the series, highest first.
    ///
    /// This is the ordering signal the app never had. A flat alphabetical-ish
    /// list put "Language Barrier" alongside "Level System" as though they
    /// described the series equally well.
    enum Weight: Int, Comparable, Sendable {
        case core = 0
        case defining = 1
        case recurrent = 2
        case incidental = 3
        case unweighted = 4

        static func < (lhs: Weight, rhs: Weight) -> Bool { lhs.rawValue < rhs.rawValue }

        init(_ raw: String?) {
            self = switch raw {
            case "core": .core
            case "defining": .defining
            case "recurrent": .recurrent
            case "incidental": .incidental
            default: .unweighted
            }
        }
    }

    var importance: Weight { Weight(weight) }
    var isImplied: Bool { !(impliedByTagIds ?? []).isEmpty }
    var spoils: Bool { isSpoiler == true }

    /// "Themes", "Character Types", "Settings". Genres are their own group even
    /// though the API files them under a path, because a reader looks for them
    /// first and they are the coarsest thing on the screen.
    var group: String {
        if isGenre == true { return "Genres" }
        let head = (namePath ?? "").split(separator: ">").first?
            .trimmingCharacters(in: .whitespaces)
        return (head?.isEmpty == false ? head : nil) ?? "Other"
    }

    /// "Crimes › Murder" — where this tag sits, without repeating the group.
    ///
    /// The middle of the path is the useful part: it says a tag is a kind of
    /// something, which is exactly what makes an implied tag make sense.
    var lineage: String? {
        let parts = (namePath ?? "").split(separator: ">").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard parts.count > 2 else { return nil }
        return parts.dropFirst().dropLast().joined(separator: " › ")
    }
}

/// One group of tags, in the order they should be read.
struct TagGroup: Identifiable, Sendable, Equatable {
    let name: String
    let tags: [SeriesTag]
    var id: String { name }
}

enum TagGrouping {
    /// The order groups are shown in, coarsest first.
    ///
    /// Taken from how MangaBaka's own site reads rather than invented: genres
    /// are what a reader scans for, then what the story is about, then where
    /// and when, then who is in it. Anything the API adds later falls to the
    /// end alphabetically rather than disappearing.
    static let order = [
        "Genres", "Themes", "Narrative Tropes", "Settings", "Locations",
        "Time Period", "World Building", "Activities", "Occupations",
        "Character Archetype", "Character Types", "Character Traits",
        "Relationship", "Species & Creatures", "Objects",
        "Audience Demographics", "Derivative Work", "Work Info"
    ]

    /// Groups a series' tags, dropping what should not be shown at all.
    ///
    /// - Parameters:
    ///   - allowedRatings: the reader's content filter. A tag can be rated
    ///     independently of its series, and an explicit tag name is itself the
    ///     thing someone filtering content does not want to read.
    ///   - favouredIDs: tag ids from the reader's taste profile. Matched by id,
    ///     never by name: the profile and the tag list are different endpoints
    ///     with different spellings, and matching strings found one tag in 146.
    static func groups(
        from tags: [SeriesTag],
        allowedRatings: [String]?,
        favouredIDs: Set<Int> = []
    ) -> [TagGroup] {
        let visible = tags.filter { tag in
            guard let allowedRatings else { return true }
            guard let rating = tag.contentRating else { return true }
            return allowedRatings.contains(rating)
        }

        let byGroup = Dictionary(grouping: visible, by: \.group)
        return byGroup
            .map { name, tags in
                TagGroup(name: name, tags: tags.sorted { sortsBefore($0, $1, favouredIDs) })
            }
            .sorted { groupsBefore($0.name, $1.name) }
    }

    /// The reader's own interests first, then how central the tag is to the
    /// series, then alphabetically so the order is stable between launches.
    private static func sortsBefore(
        _ lhs: SeriesTag,
        _ rhs: SeriesTag,
        _ favoured: Set<Int>
    ) -> Bool {
        let leftIsMine = favoured.contains(lhs.id)
        let rightIsMine = favoured.contains(rhs.id)
        if leftIsMine != rightIsMine { return leftIsMine }
        if lhs.importance != rhs.importance { return lhs.importance < rhs.importance }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }

    private static func groupsBefore(_ lhs: String, _ rhs: String) -> Bool {
        switch (order.firstIndex(of: lhs), order.firstIndex(of: rhs)) {
        case let (left?, right?): left < right
        case (_?, nil): true
        case (nil, _?): false
        default: lhs < rhs
        }
    }
}
