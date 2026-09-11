import Foundation

/// A genre, as the API's flat list of 46.
struct Genre: Decodable, Identifiable, Sendable, Equatable, Hashable {
    let label: String
    let value: String

    var id: String { value }
}

/// A tag in MangaBaka's taxonomy.
///
/// Tags are a tree, not a flat list: each carries a parent, a level, and a
/// full `name_path` like "Activities > Sports > Boxing". That structure is the
/// interesting part — it makes a browsable hierarchy possible rather than a
/// wall of several thousand chips.
struct Tag: Decodable, Identifiable, Sendable, Equatable, Hashable {
    let id: Int
    let name: String
    /// The full path from the root, useful as a subtitle so a leaf tag is not
    /// ambiguous out of context.
    let namePath: String?
    let parentId: Int?
    /// Depth in the tree; 0 is a root.
    let level: Int?
    let description: String?
    /// How many series carry it. The honest way to order a tag list: a tag on
    /// three series is not worth the same row as one on nine thousand.
    let seriesCount: Int?
    /// Whether it doubles as a genre.
    let isGenre: Bool?
    /// Tags that give away plot. Worth hiding by default on a detail screen.
    let isSpoiler: Bool?
    /// Where a tag has been merged into another, this points at the survivor.
    let mergedWith: Int?
    let contentRating: String?

    var isRoot: Bool { parentId == nil }

    /// A tag that has been merged should not be shown or linked to; the
    /// survivor should be used instead.
    var isUsable: Bool { mergedWith == nil }
}

/// A publisher, imprint or licensor.
struct PublisherRecord: Decodable, Identifiable, Sendable, Equatable, Hashable {
    /// Nullable on the wire (`/v1/publishers/search`). A publisher is opened
    /// by name, so a missing id costs nothing but a stable row identity.
    let publisherID: Int?
    let name: String
    /// "publisher" and similar.
    let type: String?
    /// "both", "original", "english" — which side of the business it is.
    let subType: String?
    let parentId: Int?
    let countryOfOrigin: String?
    let founded: Int?
    /// Whether the publisher has shut down.
    let closed: Bool?

    var id: String { publisherID.map(String.init) ?? name }

    // `aliases` and `languages` are deliberately not decoded: nothing reads
    // them, and the spec has `aliases` as title objects where this once said
    // strings — a shape that threw on the first publisher with an alias.
    enum CodingKeys: String, CodingKey {
        case publisherID = "id"
        case name, type, subType, parentId, countryOfOrigin, founded, closed
    }
}
