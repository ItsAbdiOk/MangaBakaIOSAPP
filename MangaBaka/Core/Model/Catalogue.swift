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
    /// "physical", "digital" or "both" — what it puts out. The schema's enum
    /// (`docs/schemas/mangabaka_openapi.json`); an earlier comment here named
    /// values it does not have.
    let subType: String?
    let parentId: Int?
    let countryOfOrigin: String?
    /// `string|null, format: date` on the wire (`"2008-07-01"` on Kodansha
    /// USA, live 2026-09-13) — not the `Int` this was typed as until then,
    /// which threw the whole `[PublisherRecord]` array under `try?` for any
    /// search whose results included a founded publisher. Both fixtures had
    /// `founded: null` and never caught it. See `PublisherDetail.founded`.
    let founded: String?
    /// Also a date (`format: date`), not a `Bool`: the day the publisher
    /// closed, when known. Presence, not a boolean field, is "closed".
    let closed: String?

    var id: String { publisherID.map(String.init) ?? name }

    // `aliases` and `languages` are deliberately not decoded: nothing reads
    // them, and the spec has `aliases` as title objects where this once said
    // strings — a shape that threw on the first publisher with an alias.
    enum CodingKeys: String, CodingKey {
        case publisherID = "id"
        case name, type, subType, parentId, countryOfOrigin, founded, closed
    }
}
