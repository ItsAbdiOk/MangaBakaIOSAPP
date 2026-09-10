import Foundation
import GRDB

/// A cached series row: MangaBaka's ID, the raw JSON we received, and when.
struct CachedSeries: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "series"

    var id: Int
    var payload: Data
    var cachedAt: Date
}

/// One position in an ordered feed.
struct FeedEntry: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "feedEntry"

    var feedKey: String
    var position: Int
    var seriesId: Int
}

/// A series the reader saved or skipped.
struct ShelfEntry: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "shelfEntry"

    enum Kind: String, Codable, Sendable, CaseIterable {
        case saved
        case skipped
    }

    var seriesId: Int
    var kind: String
    var addedAt: Date
    var payload: Data
}

/// A series the reader opened, and when.
///
/// Keyed by the series so re-opening one moves it up the list instead of
/// adding a duplicate. Carries its own copy of the series for the same reason
/// `ShelfEntry` does: the feed cache is disposable and this is not.
struct ViewedEntry: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "viewedEntry"

    var seriesId: Int
    var viewedAt: Date
    var payload: Data
}

/// How strongly one tag runs through the reader's library.
struct TagAffinity: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "tagAffinity"

    var tagId: Int
    var name: String
    var score: Double
    var seriesCount: Int
}

/// A series already counted into the affinities, and the state it counted as.
struct TasteSource: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "tasteSource"

    var seriesId: Int
    var countedAt: Date
    var state: String
}

/// When a feed was last fetched.
struct FeedMetadata: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "feedMetadata"

    var feedKey: String
    var cachedAt: Date
}
